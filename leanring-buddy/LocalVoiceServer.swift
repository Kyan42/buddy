//
//  LocalVoiceServer.swift
//  leanring-buddy
//
//  Launches and supervises Clicky's local neural voice server
//  (tts-server/pocket_tts_server.py, Pocket TTS on MLX). The server loads the
//  model once (~1s), prints a JSON "ready" line with its loopback port, then
//  streams 16-bit PCM for each sentence Clicky posts to /speak.
//
//  The server exits on its own when its stdin closes, so it never outlives
//  Clicky. If it isn't set up or it crashes, Clicky keeps talking with
//  Apple's built-in voice (see StreamingSentenceSpeaker).
//

import Foundation

nonisolated struct LocalVoiceServerReadyInfo: Sendable {
    let port: Int
    let sampleRate: Double
    let msToReady: Int
}

nonisolated final class LocalVoiceServer: @unchecked Sendable {

    /// One server per app: it speaks (StreamingSentenceSpeaker) and
    /// transcribes push-to-talk (ParakeetTranscriptionProvider).
    static let shared = LocalVoiceServer()

    /// Random per-launch secret. The server rejects requests without it, so
    /// other local apps can't use it to make Clicky say things.
    let secretToken = UUID().uuidString

    let serverDirectoryPath: String

    /// All mutable state is only touched on this serial queue.
    private let serverStateQueue = DispatchQueue(label: "clicky.local-voice-server")
    private var serverProcess: Process?
    /// Kept for the server's whole lifetime: closing it tells the server to exit.
    private var serverStandardInputPipe: Pipe?
    private var unprocessedStandardOutputBuffer = Data()
    private var recentStandardErrorLines: [String] = []
    private var readyInfo: LocalVoiceServerReadyInfo?
    private var isStarting = false
    private var launchDate = Date()
    /// Restart attempts in the recent window, so a broken setup can't crash-loop.
    private var recentRestartDates: [Date] = []

    /// Where the server lives. Set in Info.plist (`LocalVoiceServerDirectory`,
    /// filled from the build setting $(PROJECT_DIR)), with a fallback for
    /// builds that don't expand it.
    static func resolveServerDirectoryPath() -> String {
        if let configuredDirectoryPath = Bundle.main.object(forInfoDictionaryKey: "LocalVoiceServerDirectory") as? String,
           !configuredDirectoryPath.contains("$("),
           FileManager.default.fileExists(atPath: configuredDirectoryPath) {
            return configuredDirectoryPath
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("dev/my-clicky/tts-server")
    }

    init(serverDirectoryPath: String = LocalVoiceServer.resolveServerDirectoryPath()) {
        self.serverDirectoryPath = serverDirectoryPath
    }

    private var pythonExecutablePath: String {
        return (serverDirectoryPath as NSString).appendingPathComponent(".venv/bin/python")
    }

    private var serverScriptPath: String {
        return (serverDirectoryPath as NSString).appendingPathComponent("pocket_tts_server.py")
    }

    /// The port and sample rate once the server has printed its ready line, else nil.
    var currentReadyInfo: LocalVoiceServerReadyInfo? {
        return serverStateQueue.sync { readyInfo }
    }

    // MARK: - Lifecycle

    /// Starts the server if it isn't running or starting. Safe to call often.
    func startIfNeeded() {
        serverStateQueue.async {
            self.startServerProcessIfNeeded()
        }
    }

    /// Called when a request failed: forget the current server and start a fresh one,
    /// at most 3 times per 10 minutes.
    func markUnhealthyAndRestart(reason: String) {
        serverStateQueue.async {
            ClickyLocalTelemetry.shared.recordEvent("voice_server_marked_unhealthy", fields: [
                "reason": reason,
                "recentStderr": self.recentStandardErrorLines.suffix(10).joined(separator: "\n"),
            ])
            self.stopServerProcess()

            let tenMinutesAgo = Date().addingTimeInterval(-600)
            self.recentRestartDates = self.recentRestartDates.filter { $0 > tenMinutesAgo }
            guard self.recentRestartDates.count < 3 else {
                ClickyLocalTelemetry.shared.recordEvent("voice_server_restart_skipped", fields: [
                    "reason": "3 restarts in the last 10 minutes; staying on the Apple voice until Clicky restarts",
                ])
                return
            }
            self.recentRestartDates.append(Date())
            self.startServerProcessIfNeeded()
        }
    }

    func terminate() {
        serverStateQueue.sync {
            stopServerProcess()
        }
    }

    // MARK: - Private (always on serverStateQueue)

    private func startServerProcessIfNeeded() {
        guard serverProcess == nil, !isStarting else { return }

        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: pythonExecutablePath),
              fileManager.fileExists(atPath: serverScriptPath) else {
            print("🔊 Local voice server not set up at \(serverDirectoryPath); using the Apple voice")
            ClickyLocalTelemetry.shared.recordEvent("voice_server_not_set_up", fields: [
                "serverDirectory": serverDirectoryPath,
                "expectedPython": pythonExecutablePath,
            ])
            return
        }

        isStarting = true
        launchDate = Date()
        unprocessedStandardOutputBuffer = Data()
        recentStandardErrorLines = []

        let newServerProcess = Process()
        newServerProcess.executableURL = URL(fileURLWithPath: pythonExecutablePath)
        // -I: isolated mode, ignores PYTHON* env vars and the user's site-packages.
        newServerProcess.arguments = ["-I", serverScriptPath]
        newServerProcess.currentDirectoryURL = URL(fileURLWithPath: serverDirectoryPath)
        newServerProcess.environment = makeServerEnvironment()

        let standardInputPipe = Pipe()
        let standardOutputPipe = Pipe()
        let standardErrorPipe = Pipe()
        newServerProcess.standardInput = standardInputPipe
        newServerProcess.standardOutput = standardOutputPipe
        newServerProcess.standardError = standardErrorPipe

        standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] readableHandle in
            let newlyReadData = readableHandle.availableData
            guard !newlyReadData.isEmpty else {
                readableHandle.readabilityHandler = nil
                return
            }
            self?.serverStateQueue.async {
                self?.appendStandardOutputAndLookForReadyLine(newlyReadData)
            }
        }

        // Always drain stderr: if nobody reads it, the pipe fills and the server freezes.
        standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] readableHandle in
            let newlyReadData = readableHandle.availableData
            guard !newlyReadData.isEmpty else {
                readableHandle.readabilityHandler = nil
                return
            }
            let newErrorText = String(decoding: newlyReadData, as: UTF8.self)
            self?.serverStateQueue.async {
                guard let self else { return }
                self.recentStandardErrorLines += newErrorText.split(separator: "\n").map(String.init)
                if self.recentStandardErrorLines.count > 40 {
                    self.recentStandardErrorLines.removeFirst(self.recentStandardErrorLines.count - 40)
                }
            }
        }

        newServerProcess.terminationHandler = { [weak self] terminatedProcess in
            self?.serverStateQueue.async {
                self?.handleServerProcessExited(terminatedProcess)
            }
        }

        do {
            try newServerProcess.run()
            serverProcess = newServerProcess
            serverStandardInputPipe = standardInputPipe
            ClickyLocalTelemetry.shared.recordEvent("voice_server_launching", fields: [
                "serverDirectory": serverDirectoryPath,
                "processID": Int(newServerProcess.processIdentifier),
            ])
        } catch {
            isStarting = false
            ClickyLocalTelemetry.shared.recordEvent("voice_server_launch_failed", fields: ["error": "\(error)"])
        }
    }

    private func makeServerEnvironment() -> [String: String] {
        let currentEnvironment = ProcessInfo.processInfo.environment
        var serverEnvironment: [String: String] = [:]
        // HOME is needed to find the Hugging Face model cache (~/.cache/huggingface).
        for environmentKey in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] {
            if let environmentValue = currentEnvironment[environmentKey] {
                serverEnvironment[environmentKey] = environmentValue
            }
        }
        serverEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        serverEnvironment["CLICKY_VOICE_SERVER_TOKEN"] = secretToken
        // The model is already downloaded; skipping the online version check
        // is the difference between ~1s and ~35s startup.
        serverEnvironment["HF_HUB_OFFLINE"] = "1"
        serverEnvironment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        return serverEnvironment
    }

    private func appendStandardOutputAndLookForReadyLine(_ newlyReadData: Data) {
        unprocessedStandardOutputBuffer.append(newlyReadData)
        let newlineByte = UInt8(ascii: "\n")
        while let newlineIndex = unprocessedStandardOutputBuffer.firstIndex(of: newlineByte) {
            let lineData = Data(unprocessedStandardOutputBuffer[unprocessedStandardOutputBuffer.startIndex..<newlineIndex])
            unprocessedStandardOutputBuffer.removeSubrange(unprocessedStandardOutputBuffer.startIndex...newlineIndex)

            guard let readyLine = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
                  readyLine["ready"] as? Bool == true,
                  let port = readyLine["port"] as? Int else { continue }

            let newReadyInfo = LocalVoiceServerReadyInfo(
                port: port,
                sampleRate: (readyLine["sampleRate"] as? NSNumber)?.doubleValue ?? 24000,
                msToReady: readyLine["msToReady"] as? Int ?? -1
            )
            readyInfo = newReadyInfo
            isStarting = false
            print("🔊 Local voice server ready on 127.0.0.1:\(port) (\(newReadyInfo.msToReady) ms)")
            ClickyLocalTelemetry.shared.recordEvent("voice_server_ready", fields: [
                "port": port,
                "sampleRate": newReadyInfo.sampleRate,
                "msToReadyInsideServer": newReadyInfo.msToReady,
                "msSinceLaunch": Int(Date().timeIntervalSince(launchDate) * 1000),
                "model": readyLine["model"] as? String ?? "",
            ])
        }
    }

    private func handleServerProcessExited(_ terminatedProcess: Process) {
        // Ignore exits of a process we already replaced.
        guard terminatedProcess === serverProcess else { return }
        ClickyLocalTelemetry.shared.recordEvent("voice_server_exited", fields: [
            "exitStatus": Int(terminatedProcess.terminationStatus),
            "wasReady": readyInfo != nil,
            "recentStderr": recentStandardErrorLines.suffix(15).joined(separator: "\n"),
        ])
        serverProcess = nil
        serverStandardInputPipe = nil
        readyInfo = nil
        isStarting = false
    }

    private func stopServerProcess() {
        readyInfo = nil
        isStarting = false
        try? serverStandardInputPipe?.fileHandleForWriting.close()
        serverStandardInputPipe = nil
        serverProcess?.terminate()
        serverProcess = nil
    }
}

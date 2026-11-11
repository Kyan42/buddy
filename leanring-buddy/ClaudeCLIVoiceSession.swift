//
//  ClaudeCLIVoiceSession.swift
//  leanring-buddy
//
//  A long-lived ("warm") Claude Code CLI process that powers the voice
//  brain using the user's own Claude subscription (`claude auth login`).
//
//  Why a long-lived process: starting the CLI and its first turn costs
//  ~2-3s, but follow-up turns on an already-running process start talking
//  in ~0.6-1.5s. We talk to it over stdin/stdout using the CLI's
//  stream-json mode, which streams text deltas as they are generated.
//
//  Tool calls (like `point`) are NOT handled here. The CLI calls them on
//  ClickyLocalToolServer over MCP; this class only streams the spoken text.
//

import Foundation

/// Everything the voice session needs to start the CLI process.
nonisolated struct ClaudeCLIVoiceSessionConfiguration: Sendable {
    let claudeExecutablePath: String
    let modelIdentifier: String
    let systemPrompt: String
    /// MCP server URL for Clicky's own tools (point, etc.), or nil for no tools.
    let localToolServerURL: URL?
    /// Fully-qualified tool names the CLI may call without asking, e.g. "mcp__clicky__point".
    let allowedToolNames: [String]
    /// `--effort` level (low, medium, high...). Lower effort means less thinking
    /// before the first word, which matters most for voice. nil = CLI default.
    var effortLevel: String? = nil
}

/// Events delivered for one user turn, always on the main thread.
nonisolated enum ClaudeCLIVoiceTurnEvent: Sendable {
    /// A chunk of spoken text. Chunks concatenate into the full reply.
    case spokenTextDelta(String)
    /// The turn finished normally. `fullSpokenText` is everything that was said.
    case turnCompleted(fullSpokenText: String)
    /// The turn failed. `userFacingReason` is short and safe to speak aloud.
    case turnFailed(userFacingReason: String)
}

/// One image attached to a user turn (a screenshot), with a text label that
/// tells Claude which screen it is and its pixel dimensions.
nonisolated struct ClaudeCLIVoiceTurnImage: Sendable {
    let jpegImageData: Data
    let imageLabel: String
}

/// Readiness of the Claude CLI on this Mac, checked once at launch.
nonisolated enum ClaudeCLIInstallationStatus: Sendable {
    case readyToUse
    case notInstalled
    case notLoggedIn
}

nonisolated final class ClaudeCLIVoiceSession: @unchecked Sendable {

    // MARK: - Locating and checking the CLI

    /// Where the official installer (`curl -fsSL https://claude.ai/install.sh | bash`) puts the CLI.
    static let defaultClaudeExecutablePath: String = {
        return (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/claude")
    }()

    /// A minimal environment like a normal login shell has. We deliberately do
    /// NOT pass through the app's own environment so the CLI uses the user's
    /// subscription login from `claude auth login` and nothing else.
    static func makeCleanEnvironmentForClaudeCLI(claudeExecutablePath: String) -> [String: String] {
        let currentEnvironment = ProcessInfo.processInfo.environment
        var cleanEnvironment: [String: String] = [:]
        for environmentKey in ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"] {
            if let environmentValue = currentEnvironment[environmentKey] {
                cleanEnvironment[environmentKey] = environmentValue
            }
        }
        let claudeExecutableDirectory = (claudeExecutablePath as NSString).deletingLastPathComponent
        cleanEnvironment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:\(claudeExecutableDirectory)"
        return cleanEnvironment
    }

    /// Runs `claude auth status` to find out whether the CLI exists and is logged in.
    static func checkInstallationStatus(claudeExecutablePath: String) async -> ClaudeCLIInstallationStatus {
        guard FileManager.default.isExecutableFile(atPath: claudeExecutablePath) else {
            return .notInstalled
        }

        return await withCheckedContinuation { continuation in
            let authStatusProcess = Process()
            authStatusProcess.executableURL = URL(fileURLWithPath: claudeExecutablePath)
            authStatusProcess.arguments = ["auth", "status"]
            authStatusProcess.environment = makeCleanEnvironmentForClaudeCLI(claudeExecutablePath: claudeExecutablePath)
            let standardOutputPipe = Pipe()
            authStatusProcess.standardOutput = standardOutputPipe
            authStatusProcess.standardError = Pipe()

            authStatusProcess.terminationHandler = { _ in
                let outputData = standardOutputPipe.fileHandleForReading.readDataToEndOfFile()
                let parsedStatus = (try? JSONSerialization.jsonObject(with: outputData)) as? [String: Any]
                let isLoggedIn = parsedStatus?["loggedIn"] as? Bool ?? false
                continuation.resume(returning: isLoggedIn ? .readyToUse : .notLoggedIn)
            }

            do {
                try authStatusProcess.run()
            } catch {
                continuation.resume(returning: .notInstalled)
            }
        }
    }

    // MARK: - State

    let configuration: ClaudeCLIVoiceSessionConfiguration

    /// All mutable state below is only touched on this serial queue.
    private let sessionStateQueue = DispatchQueue(label: "clicky.claude-cli-voice-session")

    private var claudeCLIProcess: Process?
    private var standardInputHandle: FileHandle?
    private var unprocessedStandardOutputBuffer = Data()
    /// Last lines the CLI printed to stderr, kept for error messages. We must
    /// keep draining stderr or the pipe fills up and the CLI freezes mid-turn.
    private var recentStandardErrorLines: [String] = []

    /// Event handler for the turn currently streaming. Set to nil when a turn is
    /// interrupted so the leftover output of the old turn is dropped.
    private var activeTurnEventHandler: ((ClaudeCLIVoiceTurnEvent) -> Void)?
    /// True from the moment a user message is written until its `result` arrives.
    private var isTurnInFlight = false
    /// A turn that was requested while an interrupted turn was still winding down.
    private var turnWaitingToBeSent: (messageLine: String, eventHandler: (ClaudeCLIVoiceTurnEvent) -> Void)?
    private var spokenTextOfActiveTurn = ""
    /// Whether this turn already had a text block, so we can add a space when a
    /// new text block starts after a tool call ("here." + "That" -> "here. That").
    private var hasStartedAnyTextBlockInActiveTurn = false
    private var interruptRequestCounter = 0

    /// When the active turn's user message was written, and what streamed back when,
    /// measured here on the reading queue (not the main thread) so the diagnostic
    /// log shows Claude's real timing even if the UI thread is busy.
    private var activeTurnStartDate = Date()
    private var activeTurnStreamTimeline: [String] = []
    private var hasRecordedFirstTextDeltaOfCurrentBlock = false

    private func appendToStreamTimeline(_ timelineEntryName: String) {
        let msSinceTurnStart = Int(Date().timeIntervalSince(activeTurnStartDate) * 1000)
        activeTurnStreamTimeline.append("\(msSinceTurnStart)ms \(timelineEntryName)")
    }

    /// Number of user turns that finished on this process. Used to decide when to
    /// rotate to a fresh process (every screenshot stays in context until then).
    private(set) var completedTurnCount = 0

    init(configuration: ClaudeCLIVoiceSessionConfiguration) {
        self.configuration = configuration
    }

    var isRunning: Bool {
        return sessionStateQueue.sync { claudeCLIProcess?.isRunning ?? false }
    }

    // MARK: - Process lifecycle

    /// Starts the CLI process. Cheap to call ahead of time so the process is warm
    /// before the user speaks.
    func startProcess() throws {
        try sessionStateQueue.sync {
            guard claudeCLIProcess == nil else { return }

            var commandLineArguments = [
                "-p",
                "--input-format", "stream-json",
                "--output-format", "stream-json",
                "--verbose",
                "--include-partial-messages",
                "--model", configuration.modelIdentifier,
                "--system-prompt", configuration.systemPrompt,
                // No built-in tools (no Bash, no file edits) for the voice brain.
                "--tools", "",
                // Ignore the user's Claude Code settings/hooks/CLAUDE.md files so
                // the voice brain behaves the same everywhere.
                "--setting-sources", "",
                "--strict-mcp-config",
                "--no-session-persistence",
            ]

            if let localToolServerURL = configuration.localToolServerURL {
                let mcpConfiguration: [String: Any] = [
                    "mcpServers": [
                        "clicky": ["type": "http", "url": localToolServerURL.absoluteString]
                    ]
                ]
                let mcpConfigurationData = try JSONSerialization.data(withJSONObject: mcpConfiguration)
                commandLineArguments += ["--mcp-config", String(decoding: mcpConfigurationData, as: UTF8.self)]
            }

            if !configuration.allowedToolNames.isEmpty {
                commandLineArguments += ["--allowedTools"] + configuration.allowedToolNames
            }

            if let effortLevel = configuration.effortLevel {
                commandLineArguments += ["--effort", effortLevel]
            }

            let newClaudeCLIProcess = Process()
            newClaudeCLIProcess.executableURL = URL(fileURLWithPath: configuration.claudeExecutablePath)
            newClaudeCLIProcess.arguments = commandLineArguments
            newClaudeCLIProcess.environment = Self.makeCleanEnvironmentForClaudeCLI(
                claudeExecutablePath: configuration.claudeExecutablePath
            )
            newClaudeCLIProcess.currentDirectoryURL = FileManager.default.temporaryDirectory

            let standardInputPipe = Pipe()
            let standardOutputPipe = Pipe()
            let standardErrorPipe = Pipe()
            newClaudeCLIProcess.standardInput = standardInputPipe
            newClaudeCLIProcess.standardOutput = standardOutputPipe
            newClaudeCLIProcess.standardError = standardErrorPipe

            standardOutputPipe.fileHandleForReading.readabilityHandler = { [weak self] readableHandle in
                let newlyReadData = readableHandle.availableData
                guard !newlyReadData.isEmpty else {
                    // Empty data means end-of-file (the process exited). Remove the
                    // handler so it can't keep firing.
                    readableHandle.readabilityHandler = nil
                    return
                }
                self?.sessionStateQueue.async {
                    self?.appendStandardOutputDataAndProcessCompleteLines(newlyReadData)
                }
            }

            standardErrorPipe.fileHandleForReading.readabilityHandler = { [weak self] readableHandle in
                let newlyReadData = readableHandle.availableData
                guard !newlyReadData.isEmpty else {
                    readableHandle.readabilityHandler = nil
                    return
                }
                let newErrorText = String(decoding: newlyReadData, as: UTF8.self)
                self?.sessionStateQueue.async {
                    guard let self else { return }
                    self.recentStandardErrorLines += newErrorText.split(separator: "\n").map(String.init)
                    if self.recentStandardErrorLines.count > 40 {
                        self.recentStandardErrorLines.removeFirst(self.recentStandardErrorLines.count - 40)
                    }
                }
            }

            newClaudeCLIProcess.terminationHandler = { [weak self] terminatedProcess in
                self?.sessionStateQueue.async {
                    self?.handleProcessTerminated(exitStatus: terminatedProcess.terminationStatus)
                }
            }

            try newClaudeCLIProcess.run()
            claudeCLIProcess = newClaudeCLIProcess
            standardInputHandle = standardInputPipe.fileHandleForWriting
            print("🧠 Claude CLI voice session started (model: \(configuration.modelIdentifier))")
            ClickyLocalTelemetry.shared.recordEvent("cli_session_started", fields: [
                "model": configuration.modelIdentifier,
                "processID": Int(newClaudeCLIProcess.processIdentifier),
                "hasLocalTools": configuration.localToolServerURL != nil,
            ])
        }
    }

    /// Stops the CLI process. Any streaming turn is dropped silently.
    func terminateProcess() {
        sessionStateQueue.sync {
            activeTurnEventHandler = nil
            turnWaitingToBeSent = nil
            isTurnInFlight = false
            try? standardInputHandle?.close()
            standardInputHandle = nil
            claudeCLIProcess?.terminate()
            claudeCLIProcess = nil
        }
    }

    // MARK: - Turns

    /// Sends one user turn (screenshots + transcript). Events arrive on the main thread.
    func sendUserTurn(
        images: [ClaudeCLIVoiceTurnImage],
        userText: String,
        onTurnEvent: @escaping (ClaudeCLIVoiceTurnEvent) -> Void
    ) {
        var messageContentBlocks: [[String: Any]] = []
        for image in images {
            messageContentBlocks.append([
                "type": "image",
                "source": [
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": image.jpegImageData.base64EncodedString(),
                ],
            ])
            messageContentBlocks.append(["type": "text", "text": image.imageLabel])
        }
        messageContentBlocks.append(["type": "text", "text": userText])

        let userMessage: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": messageContentBlocks],
        ]

        guard let userMessageData = try? JSONSerialization.data(withJSONObject: userMessage) else {
            deliverTurnEventOnMainThread(.turnFailed(userFacingReason: "i couldn't package up your screen."), to: onTurnEvent)
            return
        }
        let userMessageLine = String(decoding: userMessageData, as: UTF8.self)

        sessionStateQueue.async {
            if self.isTurnInFlight {
                // An interrupted turn is still winding down. Send this one as soon
                // as the old turn's `result` arrives so their outputs never mix.
                self.turnWaitingToBeSent = (userMessageLine, onTurnEvent)
                return
            }
            self.writeUserMessageLine(userMessageLine, eventHandler: onTurnEvent)
        }
    }

    /// Stops the turn that is currently streaming (the user started talking again).
    /// Its remaining output is discarded.
    func interruptActiveTurn() {
        sessionStateQueue.async {
            guard self.isTurnInFlight else { return }
            self.activeTurnEventHandler = nil
            self.turnWaitingToBeSent = nil
            self.interruptRequestCounter += 1
            let interruptRequest: [String: Any] = [
                "type": "control_request",
                "request_id": "clicky-interrupt-\(self.interruptRequestCounter)",
                "request": ["subtype": "interrupt"],
            ]
            if let interruptRequestData = try? JSONSerialization.data(withJSONObject: interruptRequest) {
                self.writeLineToStandardInput(String(decoding: interruptRequestData, as: UTF8.self))
            }
        }
    }

    // MARK: - Private (always called on sessionStateQueue)

    private func writeUserMessageLine(_ userMessageLine: String, eventHandler: @escaping (ClaudeCLIVoiceTurnEvent) -> Void) {
        guard claudeCLIProcess?.isRunning == true else {
            deliverTurnEventOnMainThread(
                .turnFailed(userFacingReason: "my claude connection isn't running. try again in a second."),
                to: eventHandler
            )
            return
        }
        activeTurnEventHandler = eventHandler
        isTurnInFlight = true
        spokenTextOfActiveTurn = ""
        hasStartedAnyTextBlockInActiveTurn = false
        activeTurnStartDate = Date()
        activeTurnStreamTimeline = []
        writeLineToStandardInput(userMessageLine)
    }

    private func writeLineToStandardInput(_ line: String) {
        guard let standardInputHandle else { return }
        do {
            try standardInputHandle.write(contentsOf: Data((line + "\n").utf8))
        } catch {
            print("⚠️ Claude CLI stdin write failed: \(error)")
        }
    }

    private func appendStandardOutputDataAndProcessCompleteLines(_ newlyReadData: Data) {
        unprocessedStandardOutputBuffer.append(newlyReadData)
        let newlineByte = UInt8(ascii: "\n")
        while let newlineIndex = unprocessedStandardOutputBuffer.firstIndex(of: newlineByte) {
            let completeLineData = unprocessedStandardOutputBuffer[unprocessedStandardOutputBuffer.startIndex..<newlineIndex]
            unprocessedStandardOutputBuffer.removeSubrange(unprocessedStandardOutputBuffer.startIndex...newlineIndex)
            handleStreamJSONLine(Data(completeLineData))
        }
    }

    private func handleStreamJSONLine(_ lineData: Data) {
        guard let streamEvent = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any],
              let streamEventType = streamEvent["type"] as? String else {
            return
        }

        switch streamEventType {
        case "stream_event":
            guard let innerEvent = streamEvent["event"] as? [String: Any],
                  let innerEventType = innerEvent["type"] as? String else { return }

            switch innerEventType {
            case "content_block_start":
                let contentBlockType = (innerEvent["content_block"] as? [String: Any])?["type"] as? String ?? "?"
                appendToStreamTimeline("block start (\(contentBlockType))")
                hasRecordedFirstTextDeltaOfCurrentBlock = false
            case "content_block_delta":
                if !hasRecordedFirstTextDeltaOfCurrentBlock,
                   (innerEvent["delta"] as? [String: Any])?["type"] as? String == "text_delta" {
                    hasRecordedFirstTextDeltaOfCurrentBlock = true
                    appendToStreamTimeline("first text delta")
                }
            case "content_block_stop":
                appendToStreamTimeline("block stop (\(spokenTextOfActiveTurn.count) chars so far)")
            case "message_stop":
                appendToStreamTimeline("message stop")
            default:
                break
            }

            if innerEventType == "content_block_start",
               let contentBlock = innerEvent["content_block"] as? [String: Any],
               contentBlock["type"] as? String == "text" {
                // A text block that follows a tool call needs a separating space,
                // otherwise sentences run together ("here.That") and the speech
                // sentence splitter can't find the boundary.
                if hasStartedAnyTextBlockInActiveTurn,
                   let lastCharacter = spokenTextOfActiveTurn.last,
                   !lastCharacter.isWhitespace {
                    emitSpokenTextDelta(" ")
                }
                hasStartedAnyTextBlockInActiveTurn = true
            }

            if innerEventType == "content_block_delta",
               let delta = innerEvent["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta",
               let textChunk = delta["text"] as? String {
                emitSpokenTextDelta(textChunk)
            }

        case "result":
            isTurnInFlight = false
            let resultWasError = streamEvent["is_error"] as? Bool ?? false
            appendToStreamTimeline("result")
            ClickyLocalTelemetry.shared.recordEvent("cli_stream_timeline", fields: [
                "model": configuration.modelIdentifier,
                "wasInterrupted": activeTurnEventHandler == nil,
                "isError": resultWasError,
                "timelineSinceMessageWritten": activeTurnStreamTimeline,
                "cliReportedDurationMs": streamEvent["duration_ms"] as? Int ?? -1,
                "cliReportedApiDurationMs": streamEvent["duration_api_ms"] as? Int ?? -1,
            ])
            if let finishedTurnEventHandler = activeTurnEventHandler {
                if resultWasError {
                    let rawErrorText = (streamEvent["result"] as? String) ?? ""
                    ClickyLocalTelemetry.shared.recordEvent("cli_turn_error", fields: [
                        "rawResultText": String(rawErrorText.prefix(2000)),
                        "resultSubtype": streamEvent["subtype"] as? String ?? "",
                        "recentStderr": recentStandardErrorLines.suffix(10).joined(separator: "\n"),
                    ])
                    deliverTurnEventOnMainThread(
                        .turnFailed(userFacingReason: Self.makeUserFacingReason(fromRawErrorText: rawErrorText)),
                        to: finishedTurnEventHandler
                    )
                } else {
                    completedTurnCount += 1
                    deliverTurnEventOnMainThread(.turnCompleted(fullSpokenText: spokenTextOfActiveTurn), to: finishedTurnEventHandler)
                }
            }
            activeTurnEventHandler = nil

            if let turnWaitingToBeSent {
                self.turnWaitingToBeSent = nil
                writeUserMessageLine(turnWaitingToBeSent.messageLine, eventHandler: turnWaitingToBeSent.eventHandler)
            }

        default:
            break
        }
    }

    private func emitSpokenTextDelta(_ textChunk: String) {
        spokenTextOfActiveTurn += textChunk
        guard let activeTurnEventHandler else { return }
        deliverTurnEventOnMainThread(.spokenTextDelta(textChunk), to: activeTurnEventHandler)
    }

    private func handleProcessTerminated(exitStatus: Int32) {
        print("⚠️ Claude CLI voice session exited (status \(exitStatus)). Last stderr: \(recentStandardErrorLines.suffix(5).joined(separator: " | "))")
        ClickyLocalTelemetry.shared.recordEvent("cli_session_exited", fields: [
            "model": configuration.modelIdentifier,
            "exitStatus": Int(exitStatus),
            "completedTurns": completedTurnCount,
            "wasMidTurn": activeTurnEventHandler != nil,
            "recentStderr": recentStandardErrorLines.suffix(15).joined(separator: "\n"),
        ])
        if let interruptedTurnEventHandler = activeTurnEventHandler {
            let rawErrorText = recentStandardErrorLines.joined(separator: "\n")
            deliverTurnEventOnMainThread(
                .turnFailed(userFacingReason: Self.makeUserFacingReason(fromRawErrorText: rawErrorText)),
                to: interruptedTurnEventHandler
            )
        }
        activeTurnEventHandler = nil
        turnWaitingToBeSent = nil
        isTurnInFlight = false
        claudeCLIProcess = nil
        standardInputHandle = nil
    }

    /// Turns raw CLI error output into a short sentence Clicky can say out loud.
    private static func makeUserFacingReason(fromRawErrorText rawErrorText: String) -> String {
        let lowercasedErrorText = rawErrorText.lowercased()
        if lowercasedErrorText.contains("login") || lowercasedErrorText.contains("auth") || lowercasedErrorText.contains("401") {
            return "i'm not logged in to claude. run claude auth login in your terminal."
        }
        if lowercasedErrorText.contains("rate") || lowercasedErrorText.contains("limit") || lowercasedErrorText.contains("429") {
            return "i hit your claude usage limit. try again in a bit, or switch me to sonnet."
        }
        if lowercasedErrorText.contains("overloaded") || lowercasedErrorText.contains("529") {
            return "claude is overloaded right now. try again in a moment."
        }
        return "something went wrong talking to claude. try again."
    }

    private func deliverTurnEventOnMainThread(
        _ turnEvent: ClaudeCLIVoiceTurnEvent,
        to turnEventHandler: @escaping (ClaudeCLIVoiceTurnEvent) -> Void
    ) {
        DispatchQueue.main.async {
            turnEventHandler(turnEvent)
        }
    }
}

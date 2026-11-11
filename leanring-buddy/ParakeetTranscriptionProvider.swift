//
//  ParakeetTranscriptionProvider.swift
//  leanring-buddy
//
//  Push-to-talk transcription with NVIDIA's Parakeet TDT 0.6B v2, running
//  on-device in Clicky's local voice server (tts-server, MLX). Parakeet is
//  much better than Apple Speech at technical words ("Claude Code", "end
//  effector", "LeRobot"), which Apple kept mishearing.
//
//  Apple Speech still runs alongside every session, for two reasons:
//    - it shows live partial text while you talk (Parakeet transcribes the
//      whole clip once you let go), and
//    - if the voice server isn't ready, isn't set up, or fails, Apple's
//      transcript is used instead, so push-to-talk never breaks.
//

import AVFoundation
import Foundation

/// Which engine produced the last final transcript, for the local log
/// (`transcript_final.transcriber`). Written from the transcription queue and
/// read on the main thread, so it guards itself with a lock.
nonisolated final class ClickyLastTranscriptReport: @unchecked Sendable {
    static let shared = ClickyLastTranscriptReport()

    private let lock = NSLock()
    private var lastTranscriberDescription = "apple-speech"
    private var lastMillisecondsToTranscribe: Int?

    func record(transcriberDescription: String, millisecondsToTranscribe: Int?) {
        lock.lock()
        lastTranscriberDescription = transcriberDescription
        lastMillisecondsToTranscribe = millisecondsToTranscribe
        lock.unlock()
    }

    func latest() -> (transcriberDescription: String, millisecondsToTranscribe: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (lastTranscriberDescription, lastMillisecondsToTranscribe)
    }
}

final class ParakeetTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Parakeet (local, Apple Speech fallback)"
    // Apple Speech runs alongside as the live preview and the fallback.
    let requiresSpeechRecognitionPermission = true
    let isConfigured = true
    let unavailableExplanation: String? = nil

    private let localVoiceServer: LocalVoiceServer
    private let appleSpeechProvider = AppleSpeechTranscriptionProvider()

    init(localVoiceServer: LocalVoiceServer) {
        self.localVoiceServer = localVoiceServer
    }

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        // The voice server also starts at launch; this covers a crash since then.
        localVoiceServer.startIfNeeded()

        let parakeetSession = ParakeetTranscriptionSession(
            localVoiceServer: localVoiceServer,
            onTranscriptUpdate: onTranscriptUpdate,
            onFinalTranscriptReady: onFinalTranscriptReady,
            onError: onError
        )

        // Apple's results go to the Parakeet session, which decides what to
        // pass on. If Apple Speech can't start, Parakeet works on its own.
        do {
            let appleSpeechSession = try await appleSpeechProvider.startStreamingSession(
                keyterms: keyterms,
                onTranscriptUpdate: { [weak parakeetSession] appleTranscriptText in
                    parakeetSession?.handleApplePartialTranscript(appleTranscriptText)
                },
                onFinalTranscriptReady: { [weak parakeetSession] appleTranscriptText in
                    parakeetSession?.handleAppleFinalTranscript(appleTranscriptText)
                },
                onError: { [weak parakeetSession] appleError in
                    parakeetSession?.handleAppleError(appleError)
                }
            )
            parakeetSession.attachAppleSpeechSession(appleSpeechSession)
        } catch {
            print("⚠️ Parakeet: Apple Speech fallback unavailable: \(error.localizedDescription)")
        }

        return parakeetSession
    }
}

private final class ParakeetTranscriptionSession: BuddyStreamingTranscriptionSession {
    /// The dictation manager's own safety net: if no final transcript arrives
    /// within this long after release, it submits the latest partial text
    /// (Apple's). Longer than the Parakeet request timeout below.
    let finalTranscriptFallbackDelaySeconds: TimeInterval = 5.0

    private static let parakeetSampleRate = 16_000
    /// If Parakeet hasn't answered by then, Apple's transcript is used. Normal
    /// push-to-talk clips take a few hundred milliseconds.
    private static let parakeetRequestTimeoutSeconds: TimeInterval = 4.0

    private let localVoiceServer: LocalVoiceServer
    private let onTranscriptUpdate: (String) -> Void
    private let onFinalTranscriptReady: (String) -> Void
    private let onError: (Error) -> Void

    private let audioPCM16Converter = BuddyPCM16AudioConverter(targetSampleRate: Double(parakeetSampleRate))
    /// All mutable state below is only touched on this queue (audio arrives
    /// on the microphone thread, Apple's callbacks on its own).
    private let stateQueue = DispatchQueue(label: "clicky.parakeet.transcription")

    private var appleSpeechSession: (any BuddyStreamingTranscriptionSession)?
    private var bufferedPCM16AudioData = Data()
    private var latestApplePartialTranscript = ""
    private var appleFinalTranscript: String?
    private var appleError: Error?
    private var hasRequestedFinalTranscript = false
    private var hasParakeetGivenUp = false
    private var hasDeliveredFinalTranscript = false
    private var isCancelled = false
    private var parakeetRequestTask: Task<Void, Never>?

    init(
        localVoiceServer: LocalVoiceServer,
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        self.localVoiceServer = localVoiceServer
        self.onTranscriptUpdate = onTranscriptUpdate
        self.onFinalTranscriptReady = onFinalTranscriptReady
        self.onError = onError
    }

    func attachAppleSpeechSession(_ appleSpeechSession: any BuddyStreamingTranscriptionSession) {
        stateQueue.sync {
            self.appleSpeechSession = appleSpeechSession
        }
    }

    // MARK: - BuddyStreamingTranscriptionSession

    func appendAudioBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        let appleSpeechSessionForThisBuffer = stateQueue.sync { appleSpeechSession }
        appleSpeechSessionForThisBuffer?.appendAudioBuffer(audioBuffer)

        guard let audioPCM16Data = audioPCM16Converter.convertToPCM16Data(from: audioBuffer),
              !audioPCM16Data.isEmpty else {
            return
        }
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.bufferedPCM16AudioData.append(audioPCM16Data)
        }
    }

    func requestFinalTranscript() {
        stateQueue.async {
            guard !self.hasRequestedFinalTranscript, !self.isCancelled else { return }
            self.hasRequestedFinalTranscript = true
            self.appleSpeechSession?.requestFinalTranscript()

            let recordedPCM16AudioData = self.bufferedPCM16AudioData
            self.bufferedPCM16AudioData = Data()
            self.parakeetRequestTask = Task {
                await self.transcribeWithParakeet(recordedPCM16AudioData)
            }
        }
    }

    func cancel() {
        stateQueue.async {
            self.isCancelled = true
            self.bufferedPCM16AudioData = Data()
            self.appleSpeechSession?.cancel()
            self.appleSpeechSession = nil
            self.parakeetRequestTask?.cancel()
        }
    }

    // MARK: - Apple Speech (live preview and fallback)

    func handleApplePartialTranscript(_ appleTranscriptText: String) {
        stateQueue.async {
            guard !self.isCancelled, !self.hasDeliveredFinalTranscript else { return }
            self.latestApplePartialTranscript = appleTranscriptText
            // Live text while you talk. Also what the dictation manager falls
            // back to if nothing final ever arrives.
            self.onTranscriptUpdate(appleTranscriptText)
        }
    }

    func handleAppleFinalTranscript(_ appleTranscriptText: String) {
        stateQueue.async {
            self.appleFinalTranscript = appleTranscriptText
            self.deliverAppleTranscriptIfParakeetGaveUp()
        }
    }

    func handleAppleError(_ appleSpeechError: Error) {
        stateQueue.async {
            self.appleError = appleSpeechError
            self.deliverAppleTranscriptIfParakeetGaveUp()
        }
    }

    // MARK: - Parakeet

    private func transcribeWithParakeet(_ recordedPCM16AudioData: Data) async {
        let parakeetRequestStartDate = Date()
        do {
            let parakeetTranscriptText = try await requestParakeetTranscript(recordedPCM16AudioData)
            let millisecondsToTranscribe = Int(Date().timeIntervalSince(parakeetRequestStartDate) * 1000)
            stateQueue.async {
                // An empty Parakeet result for a clip Apple heard words in is
                // more likely a glitch than silence, so prefer Apple then.
                if parakeetTranscriptText.isEmpty && !self.latestApplePartialTranscript.isEmpty {
                    self.parakeetGaveUp(reason: "empty transcript")
                    return
                }
                ClickyLastTranscriptReport.shared.record(
                    transcriberDescription: "parakeet",
                    millisecondsToTranscribe: millisecondsToTranscribe
                )
                self.deliverFinalTranscript(parakeetTranscriptText)
            }
        } catch {
            stateQueue.async {
                self.parakeetGaveUp(reason: error.localizedDescription)
            }
        }
    }

    private func requestParakeetTranscript(_ recordedPCM16AudioData: Data) async throws -> String {
        guard let readyInfo = localVoiceServer.currentReadyInfo else {
            throw ParakeetTranscriptionError(message: "voice server not ready")
        }
        guard !recordedPCM16AudioData.isEmpty else { return "" }

        var transcribeRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(readyInfo.port)/transcribe")!)
        transcribeRequest.httpMethod = "POST"
        transcribeRequest.timeoutInterval = Self.parakeetRequestTimeoutSeconds
        transcribeRequest.setValue(localVoiceServer.secretToken, forHTTPHeaderField: "X-Clicky-Token")
        transcribeRequest.setValue("audio/L16", forHTTPHeaderField: "Content-Type")
        transcribeRequest.httpBody = recordedPCM16AudioData

        let (responseData, response) = try await URLSession.shared.data(for: transcribeRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParakeetTranscriptionError(message: "no HTTP response")
        }
        guard httpResponse.statusCode == 200 else {
            // 503 means the model is still loading (first seconds after launch)
            // or isn't downloaded.
            throw ParakeetTranscriptionError(message: "server answered \(httpResponse.statusCode)")
        }
        guard let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let transcriptText = responseJSON["text"] as? String else {
            throw ParakeetTranscriptionError(message: "unreadable response")
        }
        return transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Called on stateQueue. From here on, Apple's transcript is the answer.
    private func parakeetGaveUp(reason: String) {
        print("⚠️ Parakeet: using Apple Speech instead (\(reason))")
        hasParakeetGivenUp = true
        ClickyLastTranscriptReport.shared.record(
            transcriberDescription: "apple-speech (parakeet: \(reason))",
            millisecondsToTranscribe: nil
        )
        deliverAppleTranscriptIfParakeetGaveUp()
    }

    /// Called on stateQueue.
    private func deliverAppleTranscriptIfParakeetGaveUp() {
        guard hasParakeetGivenUp, !hasDeliveredFinalTranscript, !isCancelled else { return }
        if let appleFinalTranscript {
            deliverFinalTranscript(appleFinalTranscript)
        } else if let appleError {
            if latestApplePartialTranscript.isEmpty {
                hasDeliveredFinalTranscript = true
                onError(appleError)
            } else {
                deliverFinalTranscript(latestApplePartialTranscript)
            }
        } else if appleSpeechSession == nil {
            // No Apple Speech at all: nothing better is coming.
            deliverFinalTranscript(latestApplePartialTranscript)
        }
        // Otherwise Apple's final transcript is still on its way; it calls
        // back into here when it lands.
    }

    /// Called on stateQueue.
    private func deliverFinalTranscript(_ transcriptText: String) {
        guard !hasDeliveredFinalTranscript, !isCancelled else { return }
        hasDeliveredFinalTranscript = true
        appleSpeechSession?.cancel()
        onTranscriptUpdate(transcriptText)
        onFinalTranscriptReady(transcriptText)
    }
}

private struct ParakeetTranscriptionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

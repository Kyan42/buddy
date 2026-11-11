//
//  StreamingSentenceSpeaker.swift
//  leanring-buddy
//
//  Speaks Claude's reply while it is still streaming in, and fires the reply's
//  pen marks (circles, underlines, arrows, points) at the moment the voice
//  reaches the words they belong to.
//
//  Text chunks are buffered until a sentence ends, and each finished sentence
//  is spoken right away, so the reply starts talking ~1s after Claude starts
//  writing. Marks arrive between text chunks (see ClickyInlineMarkParser) and
//  are pinned to a character position inside a sentence; the playback clock,
//  not the arrival time, decides when they fire. Generation runs several
//  seconds ahead of speech, so firing on arrival would draw things long before
//  they're mentioned.
//
//  Two voices:
//  - Pocket TTS (preferred): local neural voice from LocalVoiceServer. Audio
//    streams back as 16-bit PCM in ~0.1s buffers on an AVAudioPlayerNode. A
//    mark is attached to the buffer that contains its estimated position and
//    fires when the buffer before it finishes playing (buffer completions are
//    the clock; they stay correct even if audio briefly runs dry).
//  - Apple's on-device voices (fallback): used for a whole reply whenever the
//    voice server isn't ready, and for the rest of a reply if it fails mid-way.
//    Marks fire from willSpeakRangeOfSpeechString, i.e. on the exact word.
//

import AVFoundation
import Foundation

/// Turns a stream of little-endian 16-bit PCM bytes into float samples. Network
/// chunks don't line up with 2-byte samples, so an odd trailing byte is kept and
/// joined with the next chunk; converting chunks independently would shift
/// every later sample by one byte and play as loud static.
nonisolated struct PCM16StreamToFloatSampleConverter {
    private var leftoverByteFromPreviousChunk: UInt8?

    mutating func convertNextChunk(_ pcmChunk: Data) -> [Float] {
        var bytesToConvert = Data()
        if let leftoverByteFromPreviousChunk {
            bytesToConvert.append(leftoverByteFromPreviousChunk)
            self.leftoverByteFromPreviousChunk = nil
        }
        bytesToConvert.append(pcmChunk)

        if bytesToConvert.count % 2 == 1 {
            leftoverByteFromPreviousChunk = bytesToConvert.last
            bytesToConvert.removeLast()
        }

        let sampleCount = bytesToConvert.count / 2
        var floatSamples = [Float](repeating: 0, count: sampleCount)
        bytesToConvert.withUnsafeBytes { rawBuffer in
            for sampleIndex in 0..<sampleCount {
                let lowByte = UInt16(rawBuffer[sampleIndex * 2])
                let highByte = UInt16(rawBuffer[sampleIndex * 2 + 1])
                let signedSample = Int16(bitPattern: lowByte | (highByte << 8))
                floatSamples[sampleIndex] = Float(signedSample) / 32768.0
            }
        }
        return floatSamples
    }
}

/// How fast Clicky talks and how much room it leaves between ideas. Chosen in
/// the menu bar panel; also tells Claude how to pace its explanation.
enum ClickySpeechPace: String, CaseIterable {
    case slow
    case normal
    case fast

    var displayName: String {
        switch self {
        case .slow: return "Slow"
        case .normal: return "Normal"
        case .fast: return "Fast"
        }
    }

    /// Playback speed relative to the voice's natural speed (pitch is kept).
    var voiceRateMultiplier: Float {
        switch self {
        case .slow: return 0.82
        case .normal: return 1.0
        case .fast: return 1.15
        }
    }

    /// Silence before each sentence after the first, so each idea (and its pen
    /// mark) has a moment to land before the next one starts.
    var pauseBetweenSentencesSeconds: Double {
        switch self {
        case .slow: return 0.45
        case .normal: return 0.15
        case .fast: return 0.0
        }
    }
}

/// A mark pinned to a position inside one spoken sentence.
private struct MarkPinnedToSentencePosition {
    let mark: ClickyParsedScreenMark
    /// Characters into the (trimmed) sentence text where the mark was written.
    let characterOffsetInSentence: Int
}

/// One sentence handed to a voice, with the marks that belong to it.
@MainActor
private final class SentenceQueuedForSpeaking {
    let sentenceIndexInReply: Int
    let sentenceText: String
    /// Marks not fired yet, in order.
    var marksNotYetFired: [MarkPinnedToSentencePosition]

    init(sentenceIndexInReply: Int, sentenceText: String, marks: [MarkPinnedToSentencePosition]) {
        self.sentenceIndexInReply = sentenceIndexInReply
        self.sentenceText = sentenceText
        self.marksNotYetFired = marks
    }
}

@MainActor
final class StreamingSentenceSpeaker: NSObject {

    /// Called once per reply, when the first sentence actually starts playing.
    var onFirstSentenceStartedSpeaking: (() -> Void)?
    /// Called when the last queued sentence finishes playing (not when stopped by barge-in).
    var onAllQueuedSentencesFinishedSpeaking: (() -> Void)?
    /// Called when playback reaches a mark. `clockSource` says what triggered it, for the log.
    var onMarkReachedInSpeech: ((_ mark: ClickyParsedScreenMark, _ sentenceIndex: Int, _ clockSource: String) -> Void)?

    private enum ReplyVoiceBackend: String {
        case pocketTTS = "pocket-tts"
        case appleSpeech = "apple-speech"
    }

    private let localVoiceServer: LocalVoiceServer?

    /// Voice speed and pauses between sentences. Takes effect immediately for
    /// the Pocket voice, and from the next sentence for the Apple voice.
    var speechPace: ClickySpeechPace = .normal {
        didSet {
            pocketTimePitchNode.rate = speechPace.voiceRateMultiplier
        }
    }

    // Shared state
    private var unspokenTextBuffer = ""
    /// Marks that arrived while their sentence was still being written, with their
    /// position (in characters) inside unspokenTextBuffer.
    private var marksWaitingForTheirSentence: [(mark: ClickyParsedScreenMark, characterOffsetInBuffer: Int)] = []
    private var numberOfSentencesQueuedInReply = 0
    private var mostRecentlyQueuedSentence: SentenceQueuedForSpeaking?
    private var hasAnnouncedFirstSentenceForCurrentReply = false
    /// True once Claude finished streaming this reply (finishReply was called).
    private var hasReplyFinishedStreaming = true
    private var currentReplyBackend: ReplyVoiceBackend = .appleSpeech
    /// When beginNewReply was called, for per-sentence timing in the diagnostic log.
    private var currentReplyBeganDate = Date()
    /// Bumped on every new reply and every stop, so late callbacks from older
    /// replies can be recognized and ignored.
    private var replyGeneration = 0

    // Apple voice
    private let speechSynthesizer = AVSpeechSynthesizer()
    private let preferredAppleVoice: AVSpeechSynthesisVoice? = StreamingSentenceSpeaker.findBestInstalledEnglishVoice()
    /// Apple sentences queued or playing, by utterance identity (so late
    /// "cancelled" callbacks from a stopped reply can't affect the next reply).
    private var appleSentencesByUtteranceIdentifier: [ObjectIdentifier: SentenceQueuedForSpeaking] = [:]

    // Pocket TTS voice
    private let pocketAudioEngine = AVAudioEngine()
    private let pocketPlayerNode = AVAudioPlayerNode()
    /// Slows down or speeds up the Pocket voice without changing its pitch.
    private let pocketTimePitchNode = AVAudioUnitTimePitch()
    private var pocketPlaybackFormat: AVAudioFormat?
    private var sentencesWaitingForPocketSynthesis: [SentenceQueuedForSpeaking] = []
    private var pocketSynthesisTask: Task<Void, Never>?
    private var pocketAudioEngineConfigurationObserver: NSObjectProtocol?
    /// Every scheduled buffer gets the next number; buffers play in this order.
    private var nextPocketBufferSequenceNumber = 0
    /// Buffers scheduled whose audio hasn't finished playing yet.
    private var pocketBufferSequenceNumbersNotYetPlayed: Set<Int> = []
    /// Highest buffer number known to have started playing.
    private var highestPocketBufferSequenceNumberStarted = -1
    /// Marks to fire when a given buffer starts playing.
    private var pocketMarksToFireWhenBufferStarts: [Int: [(mark: ClickyParsedScreenMark, sentenceIndex: Int)]] = [:]
    /// Pocket TTS speaks ~0.063s per character (measured: 3.68s for a 59-character
    /// sentence). Used to place marks inside a sentence whose audio is still streaming.
    private static let pocketEstimatedSecondsPerCharacter = 0.063

    /// A dedicated session so cancelling a request (barge-in) never affects others.
    private let voiceServerURLSession: URLSession = {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = 10
        return URLSession(configuration: sessionConfiguration)
    }()

    init(localVoiceServer: LocalVoiceServer? = nil) {
        self.localVoiceServer = localVoiceServer
        super.init()
        speechSynthesizer.delegate = self

        // The audio engine stops itself whenever the output device or format changes
        // (headphones plugged in, AirPods switching profile when the mic opens).
        // Calling play() on a stopped engine throws an exception that crashes the
        // app, so restart it here and also check before every schedule.
        pocketAudioEngineConfigurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: pocketAudioEngine,
            queue: .main
        ) { [weak self] _ in
            let weakSpeaker = self
            Task { @MainActor in
                weakSpeaker?.handlePocketAudioEngineConfigurationChange()
            }
        }
    }

    /// True while any sentence is still playing or waiting to play.
    var isSpeaking: Bool {
        return !appleSentencesByUtteranceIdentifier.isEmpty
            || speechSynthesizer.isSpeaking
            || !pocketBufferSequenceNumbersNotYetPlayed.isEmpty
            || !sentencesWaitingForPocketSynthesis.isEmpty
            || pocketSynthesisTask != nil
    }

    /// Which voice is speaking the current reply, for the local diagnostic log.
    var voiceDescriptionForLogs: String {
        switch currentReplyBackend {
        case .pocketTTS:
            return "pocket-tts (local neural voice)"
        case .appleSpeech:
            guard let preferredAppleVoice else { return "apple-speech: system default" }
            return "apple-speech: \(preferredAppleVoice.name) (\(preferredAppleVoice.language), quality \(preferredAppleVoice.quality.rawValue))"
        }
    }

    // MARK: - Feeding text and marks

    /// Call before streaming a new reply. Picks the voice for the whole reply.
    func beginNewReply() {
        stopSpeakingImmediately()
        hasAnnouncedFirstSentenceForCurrentReply = false
        hasReplyFinishedStreaming = false
        currentReplyBeganDate = Date()

        if let readyInfo = localVoiceServer?.currentReadyInfo {
            currentReplyBackend = .pocketTTS
            // Start the audio output now, while Claude is still thinking, so the
            // first sentence doesn't pay for it.
            do {
                try ensurePocketAudioEngineIsRunning(sampleRate: readyInfo.sampleRate)
            } catch {
                ClickyLocalTelemetry.shared.recordEvent("voice_fell_back_to_apple", fields: [
                    "reason": "audio engine failed to start: \(error)",
                ])
                currentReplyBackend = .appleSpeech
            }
        } else {
            currentReplyBackend = .appleSpeech
            // Not ready yet (still starting, crashed, or not set up): try again for next time.
            localVoiceServer?.startIfNeeded()
        }
    }

    /// Append a streamed chunk of speakable text (marks already removed).
    /// Any complete sentences are spoken right away.
    func appendStreamedText(_ streamedTextChunk: String) {
        unspokenTextBuffer += streamedTextChunk
        speakAllCompleteSentencesInBuffer()
    }

    /// Pins a mark to the current end of the streamed text: it fires when the
    /// voice reaches the words that come right after it.
    func appendMarkAtCurrentTextPosition(_ mark: ClickyParsedScreenMark) {
        marksWaitingForTheirSentence.append((mark: mark, characterOffsetInBuffer: unspokenTextBuffer.count))
    }

    /// The reply finished streaming: speak whatever is left in the buffer.
    func finishReply() {
        let remainingRawText = unspokenTextBuffer
        unspokenTextBuffer = ""
        hasReplyFinishedStreaming = true

        let remainingTrimmedText = remainingRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainingTrimmedText.isEmpty {
            let pinnedMarks = takeMarksForSentence(rawSentenceText: remainingRawText, takeAllRemainingMarks: true)
            queueSentenceForSpeaking(trimmedSentenceText: remainingTrimmedText, pinnedMarks: pinnedMarks)
        } else if !marksWaitingForTheirSentence.isEmpty {
            // Marks written after the last word fire when the last sentence ends.
            let trailingMarks = marksWaitingForTheirSentence.map { $0.mark }
            marksWaitingForTheirSentence.removeAll()
            attachMarksToEndOfMostRecentSentence(trailingMarks)
        }
        notifyIfAllSpeechFinished()
    }

    /// Speaks whatever is buffered without ending the reply, because more text
    /// will follow later (for example after the app fetches something Claude
    /// asked for). A sentence is normally only spoken once something follows its
    /// full stop, so without this a lead-in like "let me check." would sit
    /// unspoken for the whole wait.
    func speakBufferedTextWithoutFinishingReply() {
        let bufferedRawText = unspokenTextBuffer
        let bufferedTrimmedText = bufferedRawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bufferedTrimmedText.isEmpty else { return }
        unspokenTextBuffer = ""
        let pinnedMarks = takeMarksForSentence(rawSentenceText: bufferedRawText, takeAllRemainingMarks: true)
        queueSentenceForSpeaking(trimmedSentenceText: bufferedTrimmedText, pinnedMarks: pinnedMarks)
    }

    /// Speaks a standalone message (for example an error), replacing anything playing.
    /// Always uses the Apple voice: errors must be heard even if the voice server is the problem.
    func speakStandaloneMessage(_ messageText: String) {
        stopSpeakingImmediately()
        hasAnnouncedFirstSentenceForCurrentReply = false
        currentReplyBackend = .appleSpeech
        hasReplyFinishedStreaming = true
        queueSentenceForSpeaking(trimmedSentenceText: messageText, pinnedMarks: [])
    }

    /// Barge-in: the user started talking, so stop at once and drop queued sentences
    /// and every mark that hasn't been drawn yet.
    func stopSpeakingImmediately() {
        replyGeneration += 1
        unspokenTextBuffer = ""
        marksWaitingForTheirSentence.removeAll()
        numberOfSentencesQueuedInReply = 0
        mostRecentlyQueuedSentence = nil

        appleSentencesByUtteranceIdentifier.removeAll()
        speechSynthesizer.stopSpeaking(at: .immediate)

        // Cancelling the task cancels its in-flight HTTP request, so the server
        // stops generating the old sentence and is free for the next reply.
        pocketSynthesisTask?.cancel()
        pocketSynthesisTask = nil
        sentencesWaitingForPocketSynthesis.removeAll()
        pocketBufferSequenceNumbersNotYetPlayed.removeAll()
        pocketMarksToFireWhenBufferStarts.removeAll()
        highestPocketBufferSequenceNumberStarted = nextPocketBufferSequenceNumber - 1
        // Only touch the player once it's attached to the engine (first Pocket reply).
        if pocketPlayerNode.engine != nil {
            pocketPlayerNode.stop()
        }
    }

    // MARK: - Sentence splitting and mark pinning

    /// A sentence ends at . ! or ? followed by whitespace. We wait for the
    /// whitespace so decimals like "2.5" and "e.g." mid-stream don't split early.
    private func speakAllCompleteSentencesInBuffer() {
        while let sentenceEndIndex = findEndOfFirstCompleteSentence(in: unspokenTextBuffer) {
            let rawSentenceText = String(unspokenTextBuffer[..<sentenceEndIndex])
            unspokenTextBuffer = String(unspokenTextBuffer[sentenceEndIndex...])
            let pinnedMarks = takeMarksForSentence(rawSentenceText: rawSentenceText, takeAllRemainingMarks: false)

            let trimmedSentenceText = rawSentenceText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedSentenceText.isEmpty {
                // Nothing to say (just whitespace): keep its marks for the next sentence.
                marksWaitingForTheirSentence.insert(
                    contentsOf: pinnedMarks.map { (mark: $0.mark, characterOffsetInBuffer: 0) },
                    at: 0
                )
                continue
            }
            queueSentenceForSpeaking(trimmedSentenceText: trimmedSentenceText, pinnedMarks: pinnedMarks)
        }
    }

    /// Removes and returns the marks that belong to the sentence just cut from the
    /// front of the buffer, converting buffer offsets to offsets inside the trimmed
    /// sentence. A mark at or past the sentence's end (e.g. "here. <circle/>next")
    /// belongs to the next sentence, so it stays and its offset shifts.
    private func takeMarksForSentence(rawSentenceText: String, takeAllRemainingMarks: Bool) -> [MarkPinnedToSentencePosition] {
        let rawSentenceLength = rawSentenceText.count
        let leadingWhitespaceLength = rawSentenceText.prefix(while: { $0.isWhitespace }).count
        let trimmedSentenceLength = rawSentenceText.trimmingCharacters(in: .whitespacesAndNewlines).count

        var marksForThisSentence: [MarkPinnedToSentencePosition] = []
        var marksForLaterSentences: [(mark: ClickyParsedScreenMark, characterOffsetInBuffer: Int)] = []

        for waitingMark in marksWaitingForTheirSentence {
            if takeAllRemainingMarks || waitingMark.characterOffsetInBuffer < rawSentenceLength {
                let offsetInTrimmedSentence = min(
                    max(0, waitingMark.characterOffsetInBuffer - leadingWhitespaceLength),
                    trimmedSentenceLength
                )
                marksForThisSentence.append(MarkPinnedToSentencePosition(
                    mark: waitingMark.mark,
                    characterOffsetInSentence: offsetInTrimmedSentence
                ))
            } else {
                marksForLaterSentences.append((
                    mark: waitingMark.mark,
                    characterOffsetInBuffer: waitingMark.characterOffsetInBuffer - rawSentenceLength
                ))
            }
        }
        marksWaitingForTheirSentence = marksForLaterSentences
        return marksForThisSentence
    }

    private func findEndOfFirstCompleteSentence(in text: String) -> String.Index? {
        var currentIndex = text.startIndex
        while currentIndex < text.endIndex {
            let currentCharacter = text[currentIndex]
            let nextIndex = text.index(after: currentIndex)
            if (currentCharacter == "." || currentCharacter == "!" || currentCharacter == "?"),
               nextIndex < text.endIndex,
               text[nextIndex].isWhitespace {
                return nextIndex
            }
            currentIndex = nextIndex
        }
        return nil
    }

    private func queueSentenceForSpeaking(trimmedSentenceText: String, pinnedMarks: [MarkPinnedToSentencePosition]) {
        let queuedSentence = SentenceQueuedForSpeaking(
            sentenceIndexInReply: numberOfSentencesQueuedInReply,
            sentenceText: trimmedSentenceText,
            marks: pinnedMarks
        )
        numberOfSentencesQueuedInReply += 1
        mostRecentlyQueuedSentence = queuedSentence

        ClickyLocalTelemetry.shared.recordEvent("voice_sentence_queued", fields: [
            "backend": currentReplyBackend.rawValue,
            "sentenceIndex": queuedSentence.sentenceIndexInReply,
            "sentenceCharacters": trimmedSentenceText.count,
            "marksPinned": pinnedMarks.map { "#\($0.mark.markNumberInReply) \($0.mark.kind.rawValue) @char \($0.characterOffsetInSentence)" },
            "msSinceReplyBegan": Int(Date().timeIntervalSince(currentReplyBeganDate) * 1000),
            "sentencesAlreadyWaiting": sentencesWaitingForPocketSynthesis.count,
            "pocketSynthesisAlreadyRunning": pocketSynthesisTask != nil,
        ])

        switch currentReplyBackend {
        case .pocketTTS:
            sentencesWaitingForPocketSynthesis.append(queuedSentence)
            startPocketSynthesisLoopIfIdle()
        case .appleSpeech:
            queueSentenceWithAppleVoice(queuedSentence)
        }
    }

    /// Marks written after the reply's last word: fire when the last sentence ends,
    /// or right away if it already finished playing.
    private func attachMarksToEndOfMostRecentSentence(_ trailingMarks: [ClickyParsedScreenMark]) {
        guard let mostRecentlyQueuedSentence, isSpeaking else {
            for trailingMark in trailingMarks {
                fireMark(trailingMark, sentenceIndex: max(0, numberOfSentencesQueuedInReply - 1), clockSource: "after-last-sentence")
            }
            return
        }
        let endOfSentenceOffset = mostRecentlyQueuedSentence.sentenceText.count
        mostRecentlyQueuedSentence.marksNotYetFired += trailingMarks.map {
            MarkPinnedToSentencePosition(mark: $0, characterOffsetInSentence: endOfSentenceOffset)
        }
        // If the sentence's audio is already fully scheduled, its marks were assigned
        // to buffers already; put these on its last scheduled buffer.
        if currentReplyBackend == .pocketTTS, !sentencesWaitingForPocketSynthesis.contains(where: { $0 === mostRecentlyQueuedSentence }) {
            let lastScheduledBufferNumber = nextPocketBufferSequenceNumber - 1
            let marksToAttach = mostRecentlyQueuedSentence.marksNotYetFired
            mostRecentlyQueuedSentence.marksNotYetFired.removeAll()
            attachMarksToPocketBuffer(
                marksToAttach.map { (mark: $0.mark, sentenceIndex: mostRecentlyQueuedSentence.sentenceIndexInReply) },
                bufferSequenceNumber: lastScheduledBufferNumber
            )
        }
    }

    private func fireMark(_ mark: ClickyParsedScreenMark, sentenceIndex: Int, clockSource: String) {
        onMarkReachedInSpeech?(mark, sentenceIndex, clockSource)
    }

    private func announceFirstAudioIfNeeded() {
        guard !hasAnnouncedFirstSentenceForCurrentReply else { return }
        hasAnnouncedFirstSentenceForCurrentReply = true
        onFirstSentenceStartedSpeaking?()
    }

    private func notifyIfAllSpeechFinished() {
        guard hasReplyFinishedStreaming,
              hasAnnouncedFirstSentenceForCurrentReply,
              unspokenTextBuffer.isEmpty,
              !isSpeaking else { return }
        onAllQueuedSentencesFinishedSpeaking?()
    }

    // MARK: - Pocket TTS playback

    /// Synthesizes queued sentences one at a time, in order. Each sentence's audio
    /// is scheduled as it streams in, so playback starts within ~50-150ms and the
    /// next sentence is ready before the current one finishes playing.
    private func startPocketSynthesisLoopIfIdle() {
        guard pocketSynthesisTask == nil else { return }
        let generationForThisLoop = replyGeneration

        pocketSynthesisTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled,
                  self.replyGeneration == generationForThisLoop,
                  !self.sentencesWaitingForPocketSynthesis.isEmpty {
                let nextSentence = self.sentencesWaitingForPocketSynthesis.removeFirst()
                do {
                    try await self.streamOneSentenceFromVoiceServer(nextSentence, replyGeneration: generationForThisLoop)
                } catch is CancellationError {
                    return
                } catch {
                    guard self.replyGeneration == generationForThisLoop, !Task.isCancelled else { return }
                    if (error as? URLError)?.code == .cancelled { return }
                    self.fallBackToAppleVoiceForRestOfReply(
                        failedSentence: nextSentence,
                        failureReason: "\(error)"
                    )
                    break
                }
            }
            if self.replyGeneration == generationForThisLoop {
                self.pocketSynthesisTask = nil
                self.notifyIfAllSpeechFinished()
            }
        }
    }

    private func streamOneSentenceFromVoiceServer(_ queuedSentence: SentenceQueuedForSpeaking, replyGeneration generationForThisSentence: Int) async throws {
        guard let localVoiceServer, let readyInfo = localVoiceServer.currentReadyInfo else {
            throw URLError(.cannotConnectToHost)
        }

        try ensurePocketAudioEngineIsRunning(sampleRate: readyInfo.sampleRate)
        guard let pocketPlaybackFormat else { throw URLError(.cannotDecodeContentData) }

        var speakRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(readyInfo.port)/speak")!)
        speakRequest.httpMethod = "POST"
        speakRequest.setValue(localVoiceServer.secretToken, forHTTPHeaderField: "X-Clicky-Token")
        speakRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        speakRequest.httpBody = try JSONSerialization.data(withJSONObject: ["text": queuedSentence.sentenceText])

        let requestStartDate = Date()
        // Schedule audio in ~0.1s pieces as it arrives. Bytes are read off the
        // main thread so a long reply never stutters the cursor animation.
        let bytesPerScheduledPiece = Int(readyInfo.sampleRate * 0.1) * 2
        let pcmPieceStream = Self.streamPCMPiecesFromVoiceServer(
            speakRequest: speakRequest,
            urlSession: voiceServerURLSession,
            bytesPerPiece: bytesPerScheduledPiece
        )
        var pcmConverter = PCM16StreamToFloatSampleConverter()
        var hasLoggedFirstAudioForThisSentence = false
        var framesScheduledForThisSentence = 0
        var lastBufferNumberOfThisSentence: Int?

        // Where each mark should land, in audio frames from the start of this
        // sentence. The sentence's exact length is unknown until it finishes
        // streaming, so this uses the measured speaking rate.
        let estimatedSentenceFrameCount = Double(queuedSentence.sentenceText.count)
            * Self.pocketEstimatedSecondsPerCharacter * readyInfo.sampleRate
        func estimatedTargetFrame(of pinnedMark: MarkPinnedToSentencePosition) -> Int {
            let fractionThroughSentence = Double(pinnedMark.characterOffsetInSentence)
                / Double(max(1, queuedSentence.sentenceText.count))
            return Int(fractionThroughSentence * estimatedSentenceFrameCount)
        }

        func scheduleFloatSamples(_ floatSamples: [Float], isPauseBeforeSentence: Bool = false) {
            guard !floatSamples.isEmpty,
                  self.replyGeneration == generationForThisSentence,
                  let pcmBuffer = AVAudioPCMBuffer(pcmFormat: pocketPlaybackFormat, frameCapacity: AVAudioFrameCount(floatSamples.count)) else { return }
            pcmBuffer.frameLength = AVAudioFrameCount(floatSamples.count)
            floatSamples.withUnsafeBufferPointer { samplePointer in
                pcmBuffer.floatChannelData![0].update(from: samplePointer.baseAddress!, count: floatSamples.count)
            }

            let bufferSequenceNumber = nextPocketBufferSequenceNumber
            nextPocketBufferSequenceNumber += 1

            // The pause before a sentence is silence: it carries no marks and doesn't
            // count toward the sentence's own audio, so a mark on the first word fires
            // when the words start, not when the pause starts.
            var marksInThisBuffer: [MarkPinnedToSentencePosition] = []
            if !isPauseBeforeSentence {
                let bufferEndFrameInSentence = framesScheduledForThisSentence + floatSamples.count
                framesScheduledForThisSentence = bufferEndFrameInSentence
                lastBufferNumberOfThisSentence = bufferSequenceNumber
                // Marks whose estimated position falls before the end of this buffer
                // fire when this buffer starts playing.
                marksInThisBuffer = queuedSentence.marksNotYetFired.filter { estimatedTargetFrame(of: $0) < bufferEndFrameInSentence }
            }
            queuedSentence.marksNotYetFired.removeAll { pinnedMark in
                marksInThisBuffer.contains { $0.mark.markNumberInReply == pinnedMark.mark.markNumberInReply }
            }

            let playerWasIdle = pocketBufferSequenceNumbersNotYetPlayed.isEmpty
            pocketBufferSequenceNumbersNotYetPlayed.insert(bufferSequenceNumber)
            pocketPlayerNode.scheduleBuffer(pcmBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                // Called on an audio thread; hop to the main actor.
                let weakSpeaker = self
                Task { @MainActor in
                    weakSpeaker?.handlePocketBufferFinishedPlaying(
                        bufferSequenceNumber: bufferSequenceNumber,
                        replyGeneration: generationForThisSentence
                    )
                }
            }
            if playerWasIdle {
                // Nothing else is queued, so this buffer starts playing right now.
                highestPocketBufferSequenceNumberStarted = bufferSequenceNumber
            }
            attachMarksToPocketBuffer(
                marksInThisBuffer.map { (mark: $0.mark, sentenceIndex: queuedSentence.sentenceIndexInReply) },
                bufferSequenceNumber: bufferSequenceNumber
            )
            if !pocketPlayerNode.isPlaying {
                pocketPlayerNode.play()
            }

            if !isPauseBeforeSentence && !hasLoggedFirstAudioForThisSentence {
                hasLoggedFirstAudioForThisSentence = true
                ClickyLocalTelemetry.shared.recordEvent("voice_sentence_first_audio", fields: [
                    "backend": ReplyVoiceBackend.pocketTTS.rawValue,
                    "sentenceIndex": queuedSentence.sentenceIndexInReply,
                    "msFromRequestToFirstAudio": Int(Date().timeIntervalSince(requestStartDate) * 1000),
                    "sentenceCharacters": queuedSentence.sentenceText.count,
                ])
                announceFirstAudioIfNeeded()
            }
        }

        // Breathing room between sentences (set by the pace). Scheduled right away,
        // so it starts exactly when the previous sentence ends.
        let pauseBeforeSentenceSeconds = queuedSentence.sentenceIndexInReply > 0 ? speechPace.pauseBetweenSentencesSeconds : 0
        if pauseBeforeSentenceSeconds > 0 {
            let pauseFrameCount = Int(pauseBeforeSentenceSeconds * readyInfo.sampleRate)
            scheduleFloatSamples([Float](repeating: 0, count: pauseFrameCount), isPauseBeforeSentence: true)
        }

        for try await pcmPiece in pcmPieceStream {
            try Task.checkCancellation()
            try ensurePocketAudioEngineIsRunning(sampleRate: readyInfo.sampleRate)
            scheduleFloatSamples(pcmConverter.convertNextChunk(pcmPiece))
        }

        // The sentence came out shorter than estimated: any marks not placed yet
        // go on its last buffer (they're near the end of the sentence).
        if !queuedSentence.marksNotYetFired.isEmpty, replyGeneration == generationForThisSentence {
            let leftoverMarks = queuedSentence.marksNotYetFired
            queuedSentence.marksNotYetFired.removeAll()
            if let lastBufferNumberOfThisSentence {
                attachMarksToPocketBuffer(
                    leftoverMarks.map { (mark: $0.mark, sentenceIndex: queuedSentence.sentenceIndexInReply) },
                    bufferSequenceNumber: lastBufferNumberOfThisSentence
                )
            } else {
                for leftoverMark in leftoverMarks {
                    fireMark(leftoverMark.mark, sentenceIndex: queuedSentence.sentenceIndexInReply, clockSource: "pocket-no-audio")
                }
            }
        }
    }

    /// Fires the marks now if the buffer is already playing, otherwise when it starts.
    private func attachMarksToPocketBuffer(
        _ marksToAttach: [(mark: ClickyParsedScreenMark, sentenceIndex: Int)],
        bufferSequenceNumber: Int
    ) {
        guard !marksToAttach.isEmpty else { return }
        if bufferSequenceNumber <= highestPocketBufferSequenceNumberStarted {
            for markToFire in marksToAttach {
                fireMark(markToFire.mark, sentenceIndex: markToFire.sentenceIndex, clockSource: "pocket-buffer-already-playing")
            }
        } else {
            pocketMarksToFireWhenBufferStarts[bufferSequenceNumber, default: []] += marksToAttach
        }
    }

    /// Reads the /speak response on a background task and yields it in pieces of
    /// about `bytesPerPiece`. Ending the consumer (barge-in) cancels the request.
    private nonisolated static func streamPCMPiecesFromVoiceServer(
        speakRequest: URLRequest,
        urlSession: URLSession,
        bytesPerPiece: Int
    ) -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            let backgroundReadingTask = Task.detached {
                do {
                    let (responseByteStream, urlResponse) = try await urlSession.bytes(for: speakRequest)
                    guard (urlResponse as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    var pendingPCMBytes = Data()
                    pendingPCMBytes.reserveCapacity(bytesPerPiece)
                    for try await responseByte in responseByteStream {
                        pendingPCMBytes.append(responseByte)
                        if pendingPCMBytes.count >= bytesPerPiece {
                            continuation.yield(pendingPCMBytes)
                            pendingPCMBytes = Data()
                            pendingPCMBytes.reserveCapacity(bytesPerPiece)
                        }
                    }
                    if !pendingPCMBytes.isEmpty {
                        continuation.yield(pendingPCMBytes)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                backgroundReadingTask.cancel()
            }
        }
    }

    /// Starts (or restarts) the engine and player. Throws instead of crashing if
    /// the audio hardware won't start, so the caller can fall back to Apple's voice.
    private func ensurePocketAudioEngineIsRunning(sampleRate: Double) throws {
        if pocketPlaybackFormat == nil || pocketPlaybackFormat?.sampleRate != sampleRate {
            guard let newPlaybackFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
                throw URLError(.cannotDecodeContentData)
            }
            if pocketPlayerNode.engine == nil {
                pocketAudioEngine.attach(pocketPlayerNode)
            }
            if pocketTimePitchNode.engine == nil {
                pocketAudioEngine.attach(pocketTimePitchNode)
            }
            // player -> time pitch (pace) -> speakers
            pocketAudioEngine.disconnectNodeOutput(pocketPlayerNode)
            pocketAudioEngine.disconnectNodeOutput(pocketTimePitchNode)
            pocketAudioEngine.connect(pocketPlayerNode, to: pocketTimePitchNode, format: newPlaybackFormat)
            pocketAudioEngine.connect(pocketTimePitchNode, to: pocketAudioEngine.mainMixerNode, format: newPlaybackFormat)
            pocketTimePitchNode.rate = speechPace.voiceRateMultiplier
            pocketPlaybackFormat = newPlaybackFormat
        }
        if !pocketAudioEngine.isRunning {
            let engineStartBeganDate = Date()
            pocketAudioEngine.prepare()
            try pocketAudioEngine.start()
            ClickyLocalTelemetry.shared.recordEvent("voice_audio_engine_started", fields: [
                "msToStart": Int(Date().timeIntervalSince(engineStartBeganDate) * 1000),
                "msSinceReplyBegan": Int(Date().timeIntervalSince(currentReplyBeganDate) * 1000),
            ])
        }
    }

    private func handlePocketAudioEngineConfigurationChange() {
        ClickyLocalTelemetry.shared.recordEvent("voice_audio_engine_configuration_changed", fields: [
            "wasSpeaking": isSpeaking,
            "marksWaitingOnBuffers": pocketMarksToFireWhenBufferStarts.values.reduce(0) { $0 + $1.count },
        ])
        // Scheduled buffers were dropped with the old configuration, so their
        // completions will never come. Fire their marks now rather than never.
        let orphanedMarks = pocketMarksToFireWhenBufferStarts.keys.sorted().flatMap { pocketMarksToFireWhenBufferStarts[$0] ?? [] }
        pocketMarksToFireWhenBufferStarts.removeAll()
        pocketBufferSequenceNumbersNotYetPlayed.removeAll()
        highestPocketBufferSequenceNumberStarted = nextPocketBufferSequenceNumber - 1
        for orphanedMark in orphanedMarks {
            fireMark(orphanedMark.mark, sentenceIndex: orphanedMark.sentenceIndex, clockSource: "pocket-engine-reset")
        }
        if pocketPlaybackFormat != nil, !pocketAudioEngine.isRunning {
            try? pocketAudioEngine.start()
        }
        notifyIfAllSpeechFinished()
    }

    private func handlePocketBufferFinishedPlaying(bufferSequenceNumber: Int, replyGeneration generationOfFinishedBuffer: Int) {
        // Buffers dropped by a barge-in stop also report "finished"; ignore those.
        guard generationOfFinishedBuffer == replyGeneration,
              pocketBufferSequenceNumbersNotYetPlayed.remove(bufferSequenceNumber) != nil else { return }

        // Buffers play in order, so the next one (if already scheduled) starts now.
        let nextBufferSequenceNumber = bufferSequenceNumber + 1
        if pocketBufferSequenceNumbersNotYetPlayed.contains(nextBufferSequenceNumber) {
            highestPocketBufferSequenceNumberStarted = max(highestPocketBufferSequenceNumberStarted, nextBufferSequenceNumber)
            if let marksForNextBuffer = pocketMarksToFireWhenBufferStarts.removeValue(forKey: nextBufferSequenceNumber) {
                for markToFire in marksForNextBuffer {
                    fireMark(markToFire.mark, sentenceIndex: markToFire.sentenceIndex, clockSource: "pocket-buffer-started")
                }
            }
        }
        notifyIfAllSpeechFinished()
    }

    /// The voice server failed mid-reply: finish this reply with Apple's voice
    /// and restart the server in the background for the next one.
    private func fallBackToAppleVoiceForRestOfReply(failedSentence: SentenceQueuedForSpeaking, failureReason: String) {
        print("🔊 Pocket TTS failed (\(failureReason)); finishing this reply with the Apple voice")
        ClickyLocalTelemetry.shared.recordEvent("voice_fell_back_to_apple", fields: [
            "reason": failureReason,
            "sentencesMovedToAppleVoice": 1 + sentencesWaitingForPocketSynthesis.count,
        ])
        localVoiceServer?.markUnhealthyAndRestart(reason: failureReason)

        let sentencesForAppleVoice = [failedSentence] + sentencesWaitingForPocketSynthesis
        sentencesWaitingForPocketSynthesis.removeAll()
        currentReplyBackend = .appleSpeech
        for sentenceForAppleVoice in sentencesForAppleVoice {
            queueSentenceWithAppleVoice(sentenceForAppleVoice)
        }
    }

    // MARK: - Apple voice playback

    private func queueSentenceWithAppleVoice(_ queuedSentence: SentenceQueuedForSpeaking) {
        let sentenceUtterance = AVSpeechUtterance(string: queuedSentence.sentenceText)
        if let preferredAppleVoice {
            sentenceUtterance.voice = preferredAppleVoice
        }
        sentenceUtterance.rate = min(
            AVSpeechUtteranceMaximumSpeechRate,
            AVSpeechUtteranceDefaultSpeechRate * speechPace.voiceRateMultiplier
        )
        // Only the pace's deliberate pause between sentences; any other gap makes
        // streamed speech sound choppy.
        sentenceUtterance.preUtteranceDelay = queuedSentence.sentenceIndexInReply > 0 ? speechPace.pauseBetweenSentencesSeconds : 0
        sentenceUtterance.postUtteranceDelay = 0
        appleSentencesByUtteranceIdentifier[ObjectIdentifier(sentenceUtterance)] = queuedSentence
        speechSynthesizer.speak(sentenceUtterance)
    }

    private func handleAppleUtteranceStarted(utteranceIdentifier: ObjectIdentifier) {
        // Ignore stray callbacks from a reply that was already stopped.
        guard let startedSentence = appleSentencesByUtteranceIdentifier[utteranceIdentifier] else { return }
        announceFirstAudioIfNeeded()
        fireAppleSentenceMarks(in: startedSentence, upToCharacterOffset: 0, clockSource: "apple-sentence-start")
    }

    /// The Apple voice is about to say the word starting at `characterLocation`:
    /// fire every mark written before that word.
    private func handleAppleWordAboutToBeSpoken(utteranceIdentifier: ObjectIdentifier, characterLocation: Int) {
        guard let speakingSentence = appleSentencesByUtteranceIdentifier[utteranceIdentifier] else { return }
        fireAppleSentenceMarks(in: speakingSentence, upToCharacterOffset: characterLocation, clockSource: "apple-word")
    }

    private func handleAppleUtteranceFinished(utteranceIdentifier: ObjectIdentifier) {
        // Ignore callbacks for sentences that were already dropped by a barge-in stop.
        guard let finishedSentence = appleSentencesByUtteranceIdentifier.removeValue(forKey: utteranceIdentifier) else { return }
        fireAppleSentenceMarks(in: finishedSentence, upToCharacterOffset: Int.max, clockSource: "apple-sentence-end")
        notifyIfAllSpeechFinished()
    }

    private func fireAppleSentenceMarks(in queuedSentence: SentenceQueuedForSpeaking, upToCharacterOffset characterOffsetLimit: Int, clockSource: String) {
        let marksDueNow = queuedSentence.marksNotYetFired.filter { $0.characterOffsetInSentence <= characterOffsetLimit }
        guard !marksDueNow.isEmpty else { return }
        queuedSentence.marksNotYetFired.removeAll { $0.characterOffsetInSentence <= characterOffsetLimit }
        for dueMark in marksDueNow {
            fireMark(dueMark.mark, sentenceIndex: queuedSentence.sentenceIndexInReply, clockSource: clockSource)
        }
    }

    /// Prefers Premium, then Enhanced, then any US English voice, then any English voice.
    /// Novelty voices (Zarvox, Wobble, Bubbles...) and Personal Voice are skipped.
    private static func findBestInstalledEnglishVoice() -> AVSpeechSynthesisVoice? {
        let installedEnglishVoices = AVSpeechSynthesisVoice.speechVoices().filter { installedVoice in
            installedVoice.language.hasPrefix("en")
                && !installedVoice.voiceTraits.contains(.isNoveltyVoice)
                && !installedVoice.voiceTraits.contains(.isPersonalVoice)
        }
        let voicesByPreference = installedEnglishVoices.sorted { firstVoice, secondVoice in
            if firstVoice.quality != secondVoice.quality {
                return firstVoice.quality.rawValue > secondVoice.quality.rawValue
            }
            let firstVoiceIsUSEnglish = firstVoice.language == "en-US"
            let secondVoiceIsUSEnglish = secondVoice.language == "en-US"
            return firstVoiceIsUSEnglish && !secondVoiceIsUSEnglish
        }
        let chosenVoice = voicesByPreference.first
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
        print("🔊 Apple fallback voice: \(chosenVoice?.name ?? "system default") (\(chosenVoice?.language ?? "?"))")
        return chosenVoice
    }
}

extension StreamingSentenceSpeaker: AVSpeechSynthesizerDelegate {
    // The synthesizer calls its delegate off the main thread, so hop back to
    // the main actor before touching any state.
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleAppleUtteranceStarted(utteranceIdentifier: utteranceIdentifier)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        // NSRange counts UTF-16 units; convert to a Character offset to match marks.
        let utteranceText = utterance.speechString
        let characterLocation: Int = {
            guard let stringIndex = Range(NSRange(location: characterRange.location, length: 0), in: utteranceText)?.lowerBound else {
                return characterRange.location
            }
            return utteranceText.distance(from: utteranceText.startIndex, to: stringIndex)
        }()
        Task { @MainActor in
            self.handleAppleWordAboutToBeSpoken(utteranceIdentifier: utteranceIdentifier, characterLocation: characterLocation)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleAppleUtteranceFinished(utteranceIdentifier: utteranceIdentifier)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceIdentifier = ObjectIdentifier(utterance)
        Task { @MainActor in
            self.handleAppleUtteranceFinished(utteranceIdentifier: utteranceIdentifier)
        }
    }
}

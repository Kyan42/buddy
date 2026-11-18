//
//  ClickyClaudeCodeSessionReader.swift
//  leanring-buddy
//
//  Lets the voice brain see the user's Claude Code sessions (terminal and the
//  desktop app's Code tab), which hold far more context than one screenshot.
//
//  Two things come out of this file:
//
//    1. A short list of recent sessions (title, folder, last active, open or
//       not). It is added to every question so Claude knows what exists and
//       can match a title it sees on screen.
//    2. A readable digest of one session: the session's own latest summary
//       plus the typed conversation since, with tool output, hidden reasoning
//       and injected reminders left out. A 30 MB session file holds roughly
//       20-60 KB of this.
//
//  Session files grow to 100 MB and more. Reading one from the start takes
//  under a second, but that has been 30 times slower before (see the note
//  where the folder name is read), and the files keep growing. Two rules keep
//  any slow read away from the user:
//
//    - The list never reads a session file. It is built from the folder
//      listing plus whatever has already been read (title and folder name),
//      so a question never waits for it.
//    - Session files are only ever added to, so a file that has grown is read
//      from where the last read stopped, not from the start.
//
//  Where the data lives (all local, read-only here):
//
//    ~/.claude/projects/<folder>/<session-id>.jsonl   one JSON object per line
//    ~/.claude/sessions/<pid>.json                    sessions running right now
//
//  IMPORTANT: this file format is internal to Claude Code and can change with
//  any update. Everything here is written to fail softly: an unreadable file
//  or an unexpected line is skipped, and the worst outcome is an empty list or
//  a "couldn't read it" answer. Nothing in here may ever fail a voice turn.
//

import Foundation

/// One Claude Code session, as offered to Claude in the per-question list.
nonisolated struct ClickyClaudeCodeSessionListing: Sendable, Equatable {
    let sessionID: String
    /// The first 8 characters of the session ID: what Claude sees and writes back.
    let shortSessionID: String
    let sessionFileURL: URL
    let title: String
    let folderName: String
    let lastActiveDate: Date
    let isOpenRightNow: Bool
}

nonisolated enum ClickyClaudeCodeSessionDigestResult: Sendable {
    case digest(digestText: String, millisecondsToBuild: Int)
    case couldNotReadSession(reason: String)
}

nonisolated final class ClickyClaudeCodeSessionReader: @unchecked Sendable {

    /// How many sessions the per-question list shows, most recent first.
    static let maximumSessionsInList = 10
    /// Upper bound for one digest (about 10,000 tokens). Timing tests showed no
    /// visible difference between 12,000 and 41,000 characters, so this is about
    /// keeping the warm CLI session's context from filling up, not about speed.
    static let maximumDigestCharacters = 40_000

    private let projectsFolderURL: URL
    private let runningSessionsFolderURL: URL

    /// The app reads ~/.claude. Tests pass a temporary folder laid out the same way.
    init(claudeCodeFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)) {
        projectsFolderURL = claudeCodeFolderURL.appendingPathComponent("projects", isDirectory: true)
        runningSessionsFolderURL = claudeCodeFolderURL.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Three kinds of work, each on its own queue so none waits for another.
    /// Nothing here runs on the main thread.
    /// The list is quick (it never reads a session file) and must stay quick
    /// while a long read is running, so it has a queue to itself.
    private let sessionListingQueue = DispatchQueue(label: "clicky.claude-code-session-listing", qos: .userInitiated)
    /// Background reading of what is new in the recent session files. The
    /// first read after launch covers every recent file from the start.
    private let sessionRefreshQueue = DispatchQueue(label: "clicky.claude-code-session-refresh", qos: .utility)
    /// Reading one session because Claude asked for it. Kept apart from the
    /// background refresh so the user is not left waiting behind it.
    private let sessionDigestQueue = DispatchQueue(label: "clicky.claude-code-session-digest", qos: .userInitiated)

    /// What has been gathered from a session file's lines so far.
    private struct SessionFileContent {
        var title: String?
        var folderName: String?
        /// The summary Claude Code wrote the last time the session's context filled up.
        var latestSummaryText = ""
        /// The typed conversation after that summary, oldest first.
        var messagesAfterLatestSummary: [(speakerName: String, messageText: String)] = []
    }

    /// What one session file held the last time it was read, and how far that
    /// read got, so the next read can continue from there.
    private struct ParsedSessionFile {
        let fileModificationDate: Date
        let fileByteCount: Int
        /// The position just past the last complete line that was read.
        let byteCountReadSoFar: Int
        /// The last few bytes before that position. If they are no longer
        /// there, the file was rewritten and must be read from the start.
        let bytesJustBeforeReadPosition: Data
        let content: SessionFileContent
    }

    /// A session file is not read again while its size and modification date
    /// are unchanged, and when it has grown only the new part is read.
    /// The background refresh, a digest and the list all use this from
    /// different queues, so every access holds parsedSessionFilesLock.
    private var parsedSessionFilesByPath: [String: ParsedSessionFile] = [:]
    private let parsedSessionFilesLock = NSLock()

    // MARK: - Public (safe to call from the main thread)

    /// The most recently active sessions, newest first. Empty when there are
    /// none or the folder can't be read.
    ///
    /// Returns in milliseconds whatever else is going on: which sessions
    /// exist, when each was last active and whether it is open come from the
    /// folder listing, and the title and folder name are whatever
    /// refreshRecentSessions has read so far. A session that has not been read
    /// yet shows as "(untitled)" until the refresh gets to it.
    func listRecentSessions() async -> [ClickyClaudeCodeSessionListing] {
        return await withCheckedContinuation { continuation in
            sessionListingQueue.async {
                continuation.resume(returning: self.listRecentSessionsFromWhatHasBeenRead())
            }
        }
    }

    /// Reads what is new in the most recent session files, so the list has
    /// their current titles. The app starts this and does not wait for it;
    /// tests wait for it.
    func refreshRecentSessions() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            sessionRefreshQueue.async {
                self.refreshRecentSessionsOnRefreshQueue()
                continuation.resume()
            }
        }
    }

    /// The digest of one session from the list.
    func buildDigest(ofSession sessionListing: ClickyClaudeCodeSessionListing) async -> ClickyClaudeCodeSessionDigestResult {
        return await withCheckedContinuation { continuation in
            sessionDigestQueue.async {
                continuation.resume(returning: self.buildDigestOnDigestQueue(ofSession: sessionListing))
            }
        }
    }

    /// The note added to each question, or nil when there are no sessions.
    /// The wording matches what the prompt section was tested with.
    static func sessionListNoteForClaude(sessionListings: [ClickyClaudeCodeSessionListing], now: Date = Date()) -> String? {
        guard !sessionListings.isEmpty else { return nil }
        var noteLines = ["(their claude code sessions on this mac, most recent first. read one with read_session when you need what was said in it:"]
        for sessionListing in sessionListings {
            let openNote = sessionListing.isOpenRightNow ? ", open now" : ""
            let lastActiveDescription = describeHowLongAgo(sessionListing.lastActiveDate, now: now)
            noteLines.append("- \"\(sessionListing.title)\" · folder \(sessionListing.folderName) · \(lastActiveDescription)\(openNote) · id \(sessionListing.shortSessionID)")
        }
        return noteLines.joined(separator: "\n") + ")"
    }

    /// Finds the session Claude asked for. Claude copies the short ID from the
    /// list, but may also write the full ID or add stray spaces.
    static func sessionListing(
        matchingIDWrittenByClaude idWrittenByClaude: String,
        in sessionListings: [ClickyClaudeCodeSessionListing]
    ) -> ClickyClaudeCodeSessionListing? {
        let requestedID = idWrittenByClaude.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // An empty or tiny ID would be a prefix of every session.
        guard requestedID.count >= 6 else { return nil }
        return sessionListings.first { sessionListing in
            sessionListing.sessionID.hasPrefix(requestedID) || requestedID.hasPrefix(sessionListing.shortSessionID)
        }
    }

    // MARK: - Listing and refreshing

    /// The newest session files by modification date. Reads folder listings
    /// only, never a session file.
    private func mostRecentSessionFiles() -> [(sessionFileURL: URL, modificationDate: Date)] {
        let fileManager = FileManager.default
        guard let projectFolderURLs = try? fileManager.contentsOfDirectory(
            at: projectsFolderURL,
            includingPropertiesForKeys: nil
        ) else { return [] }

        // Sessions sit directly inside each project folder. Deeper .jsonl files
        // belong to subagents and are not conversations with the user.
        var sessionFiles: [(sessionFileURL: URL, modificationDate: Date)] = []
        for projectFolderURL in projectFolderURLs {
            let filesInProjectFolder = (try? fileManager.contentsOfDirectory(
                at: projectFolderURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for fileURL in filesInProjectFolder where fileURL.pathExtension == "jsonl" {
                let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                sessionFiles.append((sessionFileURL: fileURL, modificationDate: modificationDate ?? .distantPast))
            }
        }
        sessionFiles.sort { $0.modificationDate > $1.modificationDate }
        return Array(sessionFiles.prefix(Self.maximumSessionsInList))
    }

    private func listRecentSessionsFromWhatHasBeenRead() -> [ClickyClaudeCodeSessionListing] {
        let recentSessionFiles = mostRecentSessionFiles()
        let idsOfSessionsOpenRightNow = readIDsOfSessionsOpenRightNow()
        let parsedSessionFilesReadSoFar = withParsedSessionFilesLock { parsedSessionFilesByPath }

        return recentSessionFiles.map { sessionFile in
            let sessionID = sessionFile.sessionFileURL.deletingPathExtension().lastPathComponent
            // A title read a while ago is still used when the file has grown
            // since: titles rarely change, and a question must never wait for
            // a session file to be read.
            let contentReadSoFar = parsedSessionFilesReadSoFar[sessionFile.sessionFileURL.path]?.content
            return ClickyClaudeCodeSessionListing(
                sessionID: sessionID,
                shortSessionID: String(sessionID.prefix(8)),
                sessionFileURL: sessionFile.sessionFileURL,
                title: contentReadSoFar?.title ?? "(untitled)",
                folderName: contentReadSoFar?.folderName ?? "?",
                lastActiveDate: sessionFile.modificationDate,
                isOpenRightNow: idsOfSessionsOpenRightNow.contains(sessionID)
            )
        }
    }

    private func refreshRecentSessionsOnRefreshQueue() {
        // Newest first, so the sessions the user is most likely to ask about
        // have their titles soonest.
        let recentSessionFiles = mostRecentSessionFiles()
        for sessionFile in recentSessionFiles {
            _ = parsedSessionFile(at: sessionFile.sessionFileURL)
        }

        // Forget files that dropped out of the list, so the cache stays small.
        let pathsStillListed = Set(recentSessionFiles.map { $0.sessionFileURL.path })
        withParsedSessionFilesLock {
            parsedSessionFilesByPath = parsedSessionFilesByPath.filter { pathsStillListed.contains($0.key) }
        }
    }

    private func withParsedSessionFilesLock<Result>(_ accessParsedSessionFiles: () -> Result) -> Result {
        parsedSessionFilesLock.lock()
        defer { parsedSessionFilesLock.unlock() }
        return accessParsedSessionFiles()
    }

    /// Claude Code keeps one small JSON file per running session.
    private func readIDsOfSessionsOpenRightNow() -> Set<String> {
        let registryFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: runningSessionsFolderURL,
            includingPropertiesForKeys: nil
        )) ?? []
        var idsOfSessionsOpenRightNow: Set<String> = []
        for registryFileURL in registryFileURLs where registryFileURL.pathExtension == "json" {
            guard let registryData = try? Data(contentsOf: registryFileURL),
                  let registryEntry = (try? JSONSerialization.jsonObject(with: registryData)) as? [String: Any],
                  let sessionID = registryEntry["sessionId"] as? String else { continue }
            idsOfSessionsOpenRightNow.insert(sessionID)
        }
        return idsOfSessionsOpenRightNow
    }

    private static func describeHowLongAgo(_ lastActiveDate: Date, now: Date) -> String {
        let minutesSinceActive = now.timeIntervalSince(lastActiveDate) / 60
        if minutesSinceActive < 2 {
            return "active right now"
        } else if minutesSinceActive < 90 {
            return "active \(Int(minutesSinceActive)) min ago"
        } else if minutesSinceActive < 60 * 36 {
            return "active \(Int(minutesSinceActive / 60)) hours ago"
        } else {
            return "active \(Int(minutesSinceActive / 60 / 24)) days ago"
        }
    }

    // MARK: - Digest (sessionDigestQueue only)

    private func buildDigestOnDigestQueue(ofSession sessionListing: ClickyClaudeCodeSessionListing) -> ClickyClaudeCodeSessionDigestResult {
        let digestStartDate = Date()
        guard let sessionFileContent = parsedSessionFile(at: sessionListing.sessionFileURL)?.content else {
            return .couldNotReadSession(reason: "the session file could not be read")
        }

        var summaryText = sessionFileContent.latestSummaryText
        var conversationLines = sessionFileContent.messagesAfterLatestSummary.map { "\($0.speakerName): \($0.messageText)" }
        var olderMessagesLeftOutNote = ""

        // The newest messages matter most, so the summary gets at most 40% of
        // the budget and the conversation is kept from the end backwards.
        let summaryCharacterBudget = Int(Double(Self.maximumDigestCharacters) * 0.4)
        if summaryText.count > summaryCharacterBudget {
            summaryText = String(summaryText.prefix(summaryCharacterBudget)) + " …(summary cut short)"
        }
        var remainingCharacterBudget = Self.maximumDigestCharacters - summaryText.count
        var keptConversationLines: [String] = []
        for conversationLine in conversationLines.reversed() {
            if remainingCharacterBudget - conversationLine.count < 0 && !keptConversationLines.isEmpty {
                olderMessagesLeftOutNote = "(…\(conversationLines.count - keptConversationLines.count) older messages left out)\n"
                break
            }
            // A single enormous message is cut, but never below 2,000 characters.
            keptConversationLines.insert(String(conversationLine.prefix(max(remainingCharacterBudget, 2000))), at: 0)
            remainingCharacterBudget -= conversationLine.count
        }
        conversationLines = keptConversationLines

        let lastActiveDescription = Self.describeHowLongAgo(sessionListing.lastActiveDate, now: Date())
        var digestText = "session \"\(sessionFileContent.title ?? "(untitled)")\" in folder \(sessionFileContent.folderName ?? "?"), \(lastActiveDescription).\n"
        if !summaryText.isEmpty {
            digestText += "\nsummary of the earlier part of this session, written when its context filled up:\n" + summaryText + "\n"
        }
        digestText += "\nthe conversation since then, oldest first:\n" + olderMessagesLeftOutNote + conversationLines.joined(separator: "\n\n")

        return .digest(
            digestText: digestText,
            millisecondsToBuild: Int(Date().timeIntervalSince(digestStartDate) * 1000)
        )
    }

    // MARK: - Reading one session file (any of the queues)

    private static let newlineByte = UInt8(ascii: "\n")
    private static let customTitleMarker = Data("\"custom-title\"".utf8)
    private static let userEntryMarker = Data("\"type\":\"user\"".utf8)
    private static let assistantEntryMarker = Data("\"type\":\"assistant\"".utf8)
    /// Claude Code injects these blocks into messages; the user never typed them.
    private static let injectedReminderRegex = try! NSRegularExpression(
        pattern: "<system-reminder>.*?</system-reminder>",
        options: [.dotMatchesLineSeparators]
    )
    /// How many bytes before the read position are kept to notice a rewritten file.
    private static let rewriteCheckByteCount = 64

    /// What a session file holds right now. Returns the saved result when the
    /// file hasn't changed. When it has grown, only the new lines are read.
    /// Safe to call from several queues at once: two callers may read the same
    /// file at the same moment, which wastes a little work but is correct.
    private func parsedSessionFile(at sessionFileURL: URL) -> ParsedSessionFile? {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: sessionFileURL.path)
        let fileModificationDate = fileAttributes?[.modificationDate] as? Date ?? .distantPast
        let fileByteCount = (fileAttributes?[.size] as? NSNumber)?.intValue ?? 0

        let parsedSessionFileFromLastRead = withParsedSessionFilesLock { parsedSessionFilesByPath[sessionFileURL.path] }
        if let parsedSessionFileFromLastRead,
           parsedSessionFileFromLastRead.fileModificationDate == fileModificationDate,
           parsedSessionFileFromLastRead.fileByteCount == fileByteCount {
            return parsedSessionFileFromLastRead
        }

        // Mapped, not loaded: only the part that is actually read is brought in.
        guard let sessionFileData = try? Data(contentsOf: sessionFileURL, options: .mappedIfSafe) else { return nil }

        // Continue from the last read when the file was only added to.
        var sessionFileContent = SessionFileContent()
        var byteCountReadSoFar = 0
        if let parsedSessionFileFromLastRead,
           Self.sessionFileData(sessionFileData, stillBeginsWithWhatWasRead: parsedSessionFileFromLastRead) {
            sessionFileContent = parsedSessionFileFromLastRead.content
            byteCountReadSoFar = parsedSessionFileFromLastRead.byteCountReadSoFar
        }

        // Only lines that end in a newline are read. A live session's last line
        // can be half written; it is picked up by the next read, once complete.
        // Reading it now would count it twice.
        let unreadData = sessionFileData[byteCountReadSoFar...]
        if let lastNewlineIndex = unreadData.lastIndex(of: Self.newlineByte) {
            for lineData in sessionFileData[byteCountReadSoFar..<lastNewlineIndex].split(separator: Self.newlineByte) {
                Self.addLine(lineData, to: &sessionFileContent)
            }
            // A slice of Data keeps the positions of the whole file, so this
            // index is already a position in the file.
            byteCountReadSoFar = lastNewlineIndex + 1
        }

        let rewriteCheckStart = max(0, byteCountReadSoFar - Self.rewriteCheckByteCount)
        let parsedSessionFile = ParsedSessionFile(
            fileModificationDate: fileModificationDate,
            fileByteCount: fileByteCount,
            byteCountReadSoFar: byteCountReadSoFar,
            bytesJustBeforeReadPosition: Data(sessionFileData[rewriteCheckStart..<byteCountReadSoFar]),
            content: sessionFileContent
        )
        withParsedSessionFilesLock {
            // Another queue may have saved a read of a newer state of this file
            // while this one was running. Keep that one.
            if let parsedSessionFileSavedMeanwhile = parsedSessionFilesByPath[sessionFileURL.path],
               parsedSessionFileSavedMeanwhile.fileModificationDate > fileModificationDate {
                return
            }
            parsedSessionFilesByPath[sessionFileURL.path] = parsedSessionFile
        }
        return parsedSessionFile
    }

    /// Whether the file still starts with everything the last read covered. A
    /// file that got shorter, or whose bytes just before the read position
    /// changed, was rewritten, and continuing from the middle would be wrong.
    private static func sessionFileData(_ sessionFileData: Data, stillBeginsWithWhatWasRead parsedSessionFileFromLastRead: ParsedSessionFile) -> Bool {
        let byteCountReadSoFar = parsedSessionFileFromLastRead.byteCountReadSoFar
        guard byteCountReadSoFar <= sessionFileData.count else { return false }
        let bytesExpectedBeforeReadPosition = parsedSessionFileFromLastRead.bytesJustBeforeReadPosition
        let rewriteCheckStart = byteCountReadSoFar - bytesExpectedBeforeReadPosition.count
        guard rewriteCheckStart >= 0 else { return false }
        return sessionFileData[rewriteCheckStart..<byteCountReadSoFar].elementsEqual(bytesExpectedBeforeReadPosition)
    }

    /// Takes in one line of a session file: a title, a summary, or something
    /// the user or Claude typed. Everything else is skipped.
    private static func addLine(_ lineData: Data, to sessionFileContent: inout SessionFileContent) {
        // Most of the file is tool output and bookkeeping. Checking for a
        // marker first avoids decoding megabytes of JSON we would skip anyway.
        let isTitleLine = bytes(of: lineData.prefix(300), contain: customTitleMarker)
        let mightBeConversationLine = bytes(of: lineData, contain: userEntryMarker)
            || bytes(of: lineData, contain: assistantEntryMarker)
        guard isTitleLine || mightBeConversationLine else { return }

        // Skip what doesn't decode.
        guard let entry = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { return }
        let entryType = entry["type"] as? String

        if entryType == "custom-title" {
            if let customTitle = entry["customTitle"] as? String, !customTitle.isEmpty {
                sessionFileContent.title = customTitle
            }
            return
        }

        // Sidechains are subagents talking to Claude; meta entries are the app's own notes.
        guard entryType == "user" || entryType == "assistant",
              entry["isSidechain"] as? Bool != true,
              entry["isMeta"] as? Bool != true else { return }

        if let workingDirectoryPath = entry["cwd"] as? String, !workingDirectoryPath.isEmpty {
            // Taken from the text of the path, never by building a file URL:
            // URL(fileURLWithPath:) asks the file system whether the path is a
            // folder, once per message. For a session that ran on a Linux
            // machine the path starts with /home, which macOS treats as a
            // network mount point, and each of those checks took 6 ms. That
            // was 30 seconds across the recent sessions, and it is what once
            // held a question up for 38 seconds.
            sessionFileContent.folderName = (workingDirectoryPath as NSString).lastPathComponent
        }

        let messageText = typedTextOfEntry(entry)
        guard !messageText.isEmpty,
              !messageText.hasPrefix("[SYSTEM NOTIFICATION"),
              !messageText.hasPrefix("<task-notification>") else { return }

        if entry["isCompactSummary"] as? Bool == true {
            // A newer summary replaces everything before it.
            sessionFileContent.latestSummaryText = messageText
            sessionFileContent.messagesAfterLatestSummary = []
        } else {
            sessionFileContent.messagesAfterLatestSummary.append((
                speakerName: entryType == "user" ? "user" : "claude",
                messageText: messageText
            ))
        }
    }

    /// Whether a byte sequence appears in a line. Uses the C library's search
    /// because lines can be megabytes long and Data.range(of:) is several times
    /// slower, which matters on the first read of a session of 100 MB or more.
    private static func bytes(of lineData: Data, contain markerData: Data) -> Bool {
        return lineData.withUnsafeBytes { (lineBytes: UnsafeRawBufferPointer) -> Bool in
            markerData.withUnsafeBytes { (markerBytes: UnsafeRawBufferPointer) -> Bool in
                guard let lineBaseAddress = lineBytes.baseAddress,
                      let markerBaseAddress = markerBytes.baseAddress else { return false }
                return memmem(lineBaseAddress, lineBytes.count, markerBaseAddress, markerBytes.count) != nil
            }
        }
    }

    /// The words of one entry: its text blocks only (no tool calls, tool
    /// results, images or hidden reasoning), with injected reminders removed.
    private static func typedTextOfEntry(_ entry: [String: Any]) -> String {
        let message = entry["message"] as? [String: Any]
        var entryText = ""
        if let contentString = message?["content"] as? String {
            entryText = contentString
        } else if let contentBlocks = message?["content"] as? [Any] {
            entryText = contentBlocks
                .compactMap { $0 as? [String: Any] }
                .filter { $0["type"] as? String == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: "\n")
        }
        let fullRange = NSRange(entryText.startIndex..., in: entryText)
        let textWithoutInjectedReminders = injectedReminderRegex.stringByReplacingMatches(
            in: entryText,
            range: fullRange,
            withTemplate: ""
        )
        return textWithoutInjectedReminders.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

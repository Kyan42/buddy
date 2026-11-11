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

    private static let claudeCodeFolderURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
    private static let projectsFolderURL = claudeCodeFolderURL.appendingPathComponent("projects", isDirectory: true)
    private static let runningSessionsFolderURL = claudeCodeFolderURL.appendingPathComponent("sessions", isDirectory: true)

    /// Session files are large, so all reading happens on this queue, never on
    /// the main thread.
    private let sessionReadingQueue = DispatchQueue(label: "clicky.claude-code-session-reader", qos: .userInitiated)

    /// What one session file held the last time it was read. Only touched on
    /// sessionReadingQueue.
    private struct ParsedSessionFile {
        let fileModificationDate: Date
        let fileByteCount: Int
        let title: String?
        let folderName: String?
        /// The summary Claude Code wrote the last time the session's context filled up.
        let latestSummaryText: String
        /// The typed conversation after that summary, oldest first.
        let messagesAfterLatestSummary: [(speakerName: String, messageText: String)]
    }

    /// A session file is only parsed again when its size or modification date
    /// changed, so closed sessions cost nothing after the first question.
    private var parsedSessionFilesByPath: [String: ParsedSessionFile] = [:]

    // MARK: - Public (safe to call from the main thread)

    /// The most recently active sessions, newest first. Empty when there are
    /// none or the folder can't be read.
    func listRecentSessions() async -> [ClickyClaudeCodeSessionListing] {
        return await withCheckedContinuation { continuation in
            sessionReadingQueue.async {
                continuation.resume(returning: self.listRecentSessionsOnReadingQueue())
            }
        }
    }

    /// The digest of one session from the list.
    func buildDigest(ofSession sessionListing: ClickyClaudeCodeSessionListing) async -> ClickyClaudeCodeSessionDigestResult {
        return await withCheckedContinuation { continuation in
            sessionReadingQueue.async {
                continuation.resume(returning: self.buildDigestOnReadingQueue(ofSession: sessionListing))
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

    // MARK: - Listing (sessionReadingQueue only)

    private func listRecentSessionsOnReadingQueue() -> [ClickyClaudeCodeSessionListing] {
        let fileManager = FileManager.default
        guard let projectFolderURLs = try? fileManager.contentsOfDirectory(
            at: Self.projectsFolderURL,
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

        let idsOfSessionsOpenRightNow = readIDsOfSessionsOpenRightNow()
        var sessionListings: [ClickyClaudeCodeSessionListing] = []
        for sessionFile in sessionFiles.prefix(Self.maximumSessionsInList) {
            let sessionID = sessionFile.sessionFileURL.deletingPathExtension().lastPathComponent
            let parsedSessionFile = parsedSessionFile(at: sessionFile.sessionFileURL)
            sessionListings.append(ClickyClaudeCodeSessionListing(
                sessionID: sessionID,
                shortSessionID: String(sessionID.prefix(8)),
                sessionFileURL: sessionFile.sessionFileURL,
                title: parsedSessionFile?.title ?? "(untitled)",
                folderName: parsedSessionFile?.folderName ?? "?",
                lastActiveDate: sessionFile.modificationDate,
                isOpenRightNow: idsOfSessionsOpenRightNow.contains(sessionID)
            ))
        }

        // Forget files that dropped out of the list, so the cache stays small.
        let pathsStillListed = Set(sessionListings.map { $0.sessionFileURL.path })
        parsedSessionFilesByPath = parsedSessionFilesByPath.filter { pathsStillListed.contains($0.key) }
        return sessionListings
    }

    /// Claude Code keeps one small JSON file per running session.
    private func readIDsOfSessionsOpenRightNow() -> Set<String> {
        let registryFileURLs = (try? FileManager.default.contentsOfDirectory(
            at: Self.runningSessionsFolderURL,
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

    // MARK: - Digest (sessionReadingQueue only)

    private func buildDigestOnReadingQueue(ofSession sessionListing: ClickyClaudeCodeSessionListing) -> ClickyClaudeCodeSessionDigestResult {
        let digestStartDate = Date()
        guard let parsedSessionFile = parsedSessionFile(at: sessionListing.sessionFileURL) else {
            return .couldNotReadSession(reason: "the session file could not be read")
        }

        var summaryText = parsedSessionFile.latestSummaryText
        var conversationLines = parsedSessionFile.messagesAfterLatestSummary.map { "\($0.speakerName): \($0.messageText)" }
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
        var digestText = "session \"\(parsedSessionFile.title ?? "(untitled)")\" in folder \(parsedSessionFile.folderName ?? "?"), \(lastActiveDescription).\n"
        if !summaryText.isEmpty {
            digestText += "\nsummary of the earlier part of this session, written when its context filled up:\n" + summaryText + "\n"
        }
        digestText += "\nthe conversation since then, oldest first:\n" + olderMessagesLeftOutNote + conversationLines.joined(separator: "\n\n")

        return .digest(
            digestText: digestText,
            millisecondsToBuild: Int(Date().timeIntervalSince(digestStartDate) * 1000)
        )
    }

    // MARK: - Reading one session file (sessionReadingQueue only)

    private static let newlineByte = UInt8(ascii: "\n")
    private static let customTitleMarker = Data("\"custom-title\"".utf8)
    private static let userEntryMarker = Data("\"type\":\"user\"".utf8)
    private static let assistantEntryMarker = Data("\"type\":\"assistant\"".utf8)
    /// Claude Code injects these blocks into messages; the user never typed them.
    private static let injectedReminderRegex = try! NSRegularExpression(
        pattern: "<system-reminder>.*?</system-reminder>",
        options: [.dotMatchesLineSeparators]
    )

    /// Returns the cached result when the file hasn't changed, otherwise reads it.
    private func parsedSessionFile(at sessionFileURL: URL) -> ParsedSessionFile? {
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: sessionFileURL.path)
        let fileModificationDate = fileAttributes?[.modificationDate] as? Date ?? .distantPast
        let fileByteCount = (fileAttributes?[.size] as? NSNumber)?.intValue ?? 0

        if let cachedParsedSessionFile = parsedSessionFilesByPath[sessionFileURL.path],
           cachedParsedSessionFile.fileModificationDate == fileModificationDate,
           cachedParsedSessionFile.fileByteCount == fileByteCount {
            return cachedParsedSessionFile
        }

        guard let sessionFileData = try? Data(contentsOf: sessionFileURL, options: .mappedIfSafe) else { return nil }

        var title: String?
        var folderName: String?
        var latestSummaryText = ""
        var messagesAfterLatestSummary: [(speakerName: String, messageText: String)] = []

        for lineData in sessionFileData.split(separator: Self.newlineByte) {
            // Most of the file is tool output and bookkeeping. Checking for a
            // marker first avoids decoding megabytes of JSON we would skip anyway.
            let isTitleLine = Self.bytes(of: lineData.prefix(300), contain: Self.customTitleMarker)
            let mightBeConversationLine = Self.bytes(of: lineData, contain: Self.userEntryMarker)
                || Self.bytes(of: lineData, contain: Self.assistantEntryMarker)
            guard isTitleLine || mightBeConversationLine else { continue }

            // A live session's last line can be half written: skip what doesn't decode.
            guard let entry = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] else { continue }
            let entryType = entry["type"] as? String

            if entryType == "custom-title" {
                if let customTitle = entry["customTitle"] as? String, !customTitle.isEmpty {
                    title = customTitle
                }
                continue
            }

            // Sidechains are subagents talking to Claude; meta entries are the app's own notes.
            guard entryType == "user" || entryType == "assistant",
                  entry["isSidechain"] as? Bool != true,
                  entry["isMeta"] as? Bool != true else { continue }

            if let workingDirectoryPath = entry["cwd"] as? String, !workingDirectoryPath.isEmpty {
                folderName = URL(fileURLWithPath: workingDirectoryPath).lastPathComponent
            }

            let messageText = Self.typedTextOfEntry(entry)
            guard !messageText.isEmpty,
                  !messageText.hasPrefix("[SYSTEM NOTIFICATION"),
                  !messageText.hasPrefix("<task-notification>") else { continue }

            if entry["isCompactSummary"] as? Bool == true {
                // A newer summary replaces everything before it.
                latestSummaryText = messageText
                messagesAfterLatestSummary = []
            } else {
                messagesAfterLatestSummary.append((
                    speakerName: entryType == "user" ? "user" : "claude",
                    messageText: messageText
                ))
            }
        }

        let parsedSessionFile = ParsedSessionFile(
            fileModificationDate: fileModificationDate,
            fileByteCount: fileByteCount,
            title: title,
            folderName: folderName,
            latestSummaryText: latestSummaryText,
            messagesAfterLatestSummary: messagesAfterLatestSummary
        )
        parsedSessionFilesByPath[sessionFileURL.path] = parsedSessionFile
        return parsedSessionFile
    }

    /// Whether a byte sequence appears in a line. Uses the C library's search
    /// because lines can be megabytes long and Data.range(of:) is several times
    /// slower, which matters when a live 30 MB session is re-read every question.
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

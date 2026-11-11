//
//  ClickyMemoryStore.swift
//  leanring-buddy
//
//  Buddy's long-term memory: one plain-text notes file that is loaded into
//  every conversation, and that Buddy adds to by writing small tags in its
//  replies (<remember>, <forget>). This file owns the notes on disk.
//
//  Folder (only Buddy writes here): ~/.claude/buddy-memory/
//
//    MEMORY.md         the notes. One fact per line, under three headings:
//
//                        ## About the user
//                        - [2026-11-10] [said] m-0001 Works on robot learning
//
//                        ## How the user wants you to behave
//                        ## Ongoing work
//
//                      Each line carries the date it was saved, where it came
//                      from ("said" = the user said it out loud), and an id
//                      that Buddy uses to replace or forget it later.
//    archive.md        lines that were replaced or forgotten, so nothing
//                      disappears without a trace.
//    memory-log.jsonl  one JSON object per write: what changed and which
//                      question caused it.
//
//  The user may edit MEMORY.md by hand at any time, so every change here is
//  made line by line: lines this code does not recognise are kept exactly as
//  they are, and missing headings or ids are tolerated. The whole file is
//  never rewritten from memory. (Research on agent memory found that letting
//  a model rewrite its whole memory at once can collapse it; single-line
//  edits made by ordinary code avoid that.)
//
//  The file name and folder layout match Claude Code's own memory, so a
//  Claude Code session can be pointed at this folder later.
//

import Foundation

/// One change Buddy asked for by writing a tag in its reply.
nonisolated enum ClickyMemoryWriteRequest: Sendable, Equatable {
    /// <remember section="user">text</remember>
    case remember(sectionWrittenByClaude: String?, noteText: String)
    /// <remember replaces="m-0012">text</remember>
    case replace(noteIDToReplace: String, noteText: String)
    /// <forget id="m-0012"/>
    case forget(noteID: String)
}

nonisolated enum ClickyMemoryWriteResult: Sendable, Equatable {
    case saved(noteID: String, noteLine: String, totalNoteCount: Int)
    case replaced(replacedNoteID: String, newNoteID: String, noteLine: String, totalNoteCount: Int)
    case forgotten(noteID: String, totalNoteCount: Int)
    case rejected(reason: String)
}

nonisolated final class ClickyMemoryStore: @unchecked Sendable {

    /// Claude Code loads at most this much of a memory index, so the same
    /// limits apply to what Buddy is shown.
    static let maximumNoteLinesLoaded = 200
    static let maximumNoteBytesLoaded = 25_000
    /// A note is one short line. Longer text is cut, not rejected, because the
    /// start of a sentence is usually the part worth keeping.
    static let maximumNoteCharacters = 240

    private enum NoteSection: CaseIterable {
        case aboutTheUser
        case howToBehave
        case ongoingWork

        var headingLine: String {
            switch self {
            case .aboutTheUser: return "## About the user"
            case .howToBehave: return "## How the user wants you to behave"
            case .ongoingWork: return "## Ongoing work"
            }
        }

        /// Maps the section name Claude wrote in the tag. Anything unexpected
        /// lands under "About the user" so a note is never lost over a label.
        static func matching(sectionWrittenByClaude: String?) -> NoteSection {
            let normalizedSectionName = (sectionWrittenByClaude ?? "").trimmingCharacters(in: .whitespaces).lowercased()
            if normalizedSectionName.hasPrefix("behav") { return .howToBehave }
            if normalizedSectionName.hasPrefix("work") { return .ongoingWork }
            return .aboutTheUser
        }
    }

    let memoryFolderURL: URL
    var notesFileURL: URL { memoryFolderURL.appendingPathComponent("MEMORY.md") }
    private var archiveFileURL: URL { memoryFolderURL.appendingPathComponent("archive.md") }
    private var writeLogFileURL: URL { memoryFolderURL.appendingPathComponent("memory-log.jsonl") }

    /// All reads and writes of the memory files happen on this queue, one at a
    /// time, so two writes from the same reply can never interleave.
    private let memoryFileQueue = DispatchQueue(label: "clicky.memory-store", qos: .userInitiated)

    private static let noteIDRegex = try! NSRegularExpression(pattern: #"(?<![\w-])m-(\d+)(?![\w-])"#)

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// The default folder sits next to Claude Code's own data. A different
    /// folder can be passed in for tests.
    init(memoryFolderURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude", isDirectory: true)
        .appendingPathComponent("buddy-memory", isDirectory: true)) {
        self.memoryFolderURL = memoryFolderURL
    }

    // MARK: - Loading (safe to call from the main thread; the file is small)

    /// The notes as Buddy should see them at the start of a conversation, or
    /// nil when nothing has been saved yet.
    func loadNotesTextForPrompt() -> String? {
        return memoryFileQueue.sync {
            guard let notesFileText = try? String(contentsOf: notesFileURL, encoding: .utf8) else { return nil }
            let hasAnyNote = notesFileText.split(separator: "\n").contains { Self.isNoteLine(String($0)) }
            guard hasAnyNote else { return nil }

            var loadedLines = notesFileText.components(separatedBy: "\n")
            if loadedLines.count > Self.maximumNoteLinesLoaded {
                loadedLines = Array(loadedLines.prefix(Self.maximumNoteLinesLoaded))
            }
            var loadedText = loadedLines.joined(separator: "\n")
            if loadedText.utf8.count > Self.maximumNoteBytesLoaded {
                loadedText = String(decoding: loadedText.utf8.prefix(Self.maximumNoteBytesLoaded), as: UTF8.self)
            }
            return loadedText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Makes sure MEMORY.md exists (with its three headings) so it can be opened
    /// in an editor even before the first note.
    func createNotesFileIfMissing() {
        memoryFileQueue.sync {
            _ = readNoteLinesCreatingFileIfMissing()
        }
    }

    // MARK: - Writing

    /// Applies one change and reports what happened. Never throws: a change that
    /// can't be applied comes back as `.rejected` with the reason.
    func apply(
        _ writeRequest: ClickyMemoryWriteRequest,
        interactionID: String?,
        userTranscript: String
    ) async -> ClickyMemoryWriteResult {
        return await withCheckedContinuation { continuation in
            memoryFileQueue.async {
                let writeResult = self.applyOnMemoryFileQueue(writeRequest)
                self.appendToWriteLog(
                    writeRequest: writeRequest,
                    writeResult: writeResult,
                    interactionID: interactionID,
                    userTranscript: userTranscript
                )
                continuation.resume(returning: writeResult)
            }
        }
    }

    private func applyOnMemoryFileQueue(_ writeRequest: ClickyMemoryWriteRequest) -> ClickyMemoryWriteResult {
        guard var noteFileLines = readNoteLinesCreatingFileIfMissing() else {
            return .rejected(reason: "the memory folder could not be created or read")
        }

        switch writeRequest {
        case .remember(let sectionWrittenByClaude, let noteText):
            guard let cleanedNoteText = Self.cleanedNoteText(noteText) else {
                return .rejected(reason: "the note was empty")
            }
            let newNoteID = nextUnusedNoteID(noteFileLines: noteFileLines)
            let newNoteLine = makeNoteLine(noteID: newNoteID, noteText: cleanedNoteText)
            let noteSection = NoteSection.matching(sectionWrittenByClaude: sectionWrittenByClaude)
            Self.insert(noteLine: newNoteLine, under: noteSection, into: &noteFileLines)
            guard writeNoteLines(noteFileLines) else {
                return .rejected(reason: "the notes file could not be written")
            }
            return .saved(noteID: newNoteID, noteLine: newNoteLine, totalNoteCount: Self.countNoteLines(noteFileLines))

        case .replace(let noteIDToReplace, let noteText):
            guard let cleanedNoteText = Self.cleanedNoteText(noteText) else {
                return .rejected(reason: "the replacement note was empty")
            }
            guard let normalizedNoteID = Self.normalizedNoteID(noteIDToReplace),
                  let lineIndexToReplace = Self.indexOfNoteLine(withID: normalizedNoteID, in: noteFileLines) else {
                return .rejected(reason: "no note with id \(noteIDToReplace)")
            }
            let newNoteID = nextUnusedNoteID(noteFileLines: noteFileLines)
            let newNoteLine = makeNoteLine(noteID: newNoteID, noteText: cleanedNoteText)
            let replacedNoteLine = noteFileLines[lineIndexToReplace]
            // The new line takes the old one's place, so the note stays under its heading.
            noteFileLines[lineIndexToReplace] = newNoteLine
            guard writeNoteLines(noteFileLines) else {
                return .rejected(reason: "the notes file could not be written")
            }
            appendToArchive(removedNoteLine: replacedNoteLine, whatHappened: "replaced by \(newNoteID)")
            return .replaced(
                replacedNoteID: normalizedNoteID,
                newNoteID: newNoteID,
                noteLine: newNoteLine,
                totalNoteCount: Self.countNoteLines(noteFileLines)
            )

        case .forget(let noteID):
            guard let normalizedNoteID = Self.normalizedNoteID(noteID),
                  let lineIndexToRemove = Self.indexOfNoteLine(withID: normalizedNoteID, in: noteFileLines) else {
                return .rejected(reason: "no note with id \(noteID)")
            }
            let forgottenNoteLine = noteFileLines.remove(at: lineIndexToRemove)
            guard writeNoteLines(noteFileLines) else {
                return .rejected(reason: "the notes file could not be written")
            }
            appendToArchive(removedNoteLine: forgottenNoteLine, whatHappened: "forgotten")
            return .forgotten(noteID: normalizedNoteID, totalNoteCount: Self.countNoteLines(noteFileLines))
        }
    }

    // MARK: - Note lines

    /// One line, no line breaks, no leading list dash, cut to the length cap.
    private static func cleanedNoteText(_ noteText: String) -> String? {
        var cleanedText = noteText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while cleanedText.hasPrefix("-") || cleanedText.hasPrefix("#") {
            cleanedText = String(cleanedText.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        guard !cleanedText.isEmpty else { return nil }
        if cleanedText.count > maximumNoteCharacters {
            cleanedText = String(cleanedText.prefix(maximumNoteCharacters)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleanedText
    }

    private func makeNoteLine(noteID: String, noteText: String) -> String {
        // "said" records where the note came from: the user said it out loud.
        return "- [\(dayFormatter.string(from: Date()))] [said] \(noteID) \(noteText)"
    }

    /// A note is any list line. Hand-written notes without a date or id count too.
    private static func isNoteLine(_ line: String) -> Bool {
        return line.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
    }

    private static func countNoteLines(_ noteFileLines: [String]) -> Int {
        return noteFileLines.filter { isNoteLine($0) }.count
    }

    /// "m-12", "M-0012" and " m-0012 " all mean the same note.
    private static func normalizedNoteID(_ noteIDWrittenByClaude: String) -> String? {
        let trimmedNoteID = noteIDWrittenByClaude.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmedNoteID.hasPrefix("m-"), let noteNumber = Int(trimmedNoteID.dropFirst(2)) else { return nil }
        return formattedNoteID(noteNumber: noteNumber)
    }

    private static func formattedNoteID(noteNumber: Int) -> String {
        return "m-" + String(format: "%04d", noteNumber)
    }

    private static func noteNumbers(in text: String) -> [Int] {
        let fullRange = NSRange(text.startIndex..., in: text)
        return noteIDRegex.matches(in: text, range: fullRange).compactMap { idMatch in
            Range(idMatch.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }

    private static func indexOfNoteLine(withID normalizedNoteID: String, in noteFileLines: [String]) -> Int? {
        return noteFileLines.firstIndex { noteFileLine in
            isNoteLine(noteFileLine)
                && noteNumbers(in: noteFileLine).contains { formattedNoteID(noteNumber: $0) == normalizedNoteID }
        }
    }

    /// Ids are never reused, so a forgotten note's id can't come back meaning
    /// something else. That is why the archive is scanned as well.
    private func nextUnusedNoteID(noteFileLines: [String]) -> String {
        let archiveText = (try? String(contentsOf: archiveFileURL, encoding: .utf8)) ?? ""
        let highestNoteNumberInUse = (Self.noteNumbers(in: noteFileLines.joined(separator: "\n")) + Self.noteNumbers(in: archiveText)).max() ?? 0
        return Self.formattedNoteID(noteNumber: highestNoteNumberInUse + 1)
    }

    /// Puts the line at the end of its section. A heading the user deleted is
    /// added back at the end of the file.
    private static func insert(noteLine: String, under noteSection: NoteSection, into noteFileLines: inout [String]) {
        let headingIndex = noteFileLines.firstIndex { noteFileLine in
            noteFileLine.trimmingCharacters(in: .whitespaces).lowercased() == noteSection.headingLine.lowercased()
        }
        guard let headingIndex else {
            if let lastLine = noteFileLines.last, !lastLine.trimmingCharacters(in: .whitespaces).isEmpty {
                noteFileLines.append("")
            }
            noteFileLines.append(noteSection.headingLine)
            noteFileLines.append(noteLine)
            return
        }

        // The section runs until the next heading or the end of the file.
        var sectionEndIndex = noteFileLines.count
        for lineIndex in (headingIndex + 1)..<noteFileLines.count where noteFileLines[lineIndex].hasPrefix("#") {
            sectionEndIndex = lineIndex
            break
        }
        // Insert after the section's last note, so notes stay together and any
        // blank line or text the user wrote after them stays where it is. A
        // section with no notes yet gets its first one right under the heading.
        var insertionIndex = headingIndex + 1
        for lineIndex in (headingIndex + 1)..<sectionEndIndex where isNoteLine(noteFileLines[lineIndex]) {
            insertionIndex = lineIndex + 1
        }
        noteFileLines.insert(noteLine, at: insertionIndex)
    }

    // MARK: - Files

    private func readNoteLinesCreatingFileIfMissing() -> [String]? {
        do {
            try FileManager.default.createDirectory(at: memoryFolderURL, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        if let notesFileText = try? String(contentsOf: notesFileURL, encoding: .utf8) {
            return notesFileText.components(separatedBy: "\n")
        }
        guard !FileManager.default.fileExists(atPath: notesFileURL.path) else {
            // The file is there but unreadable: leave it alone rather than replace it.
            return nil
        }
        var freshNoteFileLines: [String] = []
        for noteSection in NoteSection.allCases {
            freshNoteFileLines.append(noteSection.headingLine)
            freshNoteFileLines.append("")
        }
        return writeNoteLines(freshNoteFileLines) ? freshNoteFileLines : nil
    }

    /// Written to a temporary file and swapped in, so a crash mid-write can't
    /// leave half a notes file behind.
    private func writeNoteLines(_ noteFileLines: [String]) -> Bool {
        var notesFileText = noteFileLines.joined(separator: "\n")
        if !notesFileText.hasSuffix("\n") {
            notesFileText += "\n"
        }
        do {
            try Data(notesFileText.utf8).write(to: notesFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func appendToArchive(removedNoteLine: String, whatHappened: String) {
        let archiveEntry = "\(removedNoteLine)   <- \(whatHappened) on \(dayFormatter.string(from: Date()))\n"
        appendText(archiveEntry, to: archiveFileURL)
    }

    private func appendToWriteLog(
        writeRequest: ClickyMemoryWriteRequest,
        writeResult: ClickyMemoryWriteResult,
        interactionID: String?,
        userTranscript: String
    ) {
        var logEntry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "interaction": interactionID ?? "",
            "whatTheUserSaid": userTranscript,
        ]
        switch writeRequest {
        case .remember(let sectionWrittenByClaude, let noteText):
            logEntry["request"] = "remember"
            logEntry["section"] = sectionWrittenByClaude ?? ""
            logEntry["noteText"] = noteText
        case .replace(let noteIDToReplace, let noteText):
            logEntry["request"] = "replace"
            logEntry["noteIDToReplace"] = noteIDToReplace
            logEntry["noteText"] = noteText
        case .forget(let noteID):
            logEntry["request"] = "forget"
            logEntry["noteID"] = noteID
        }
        switch writeResult {
        case .saved(let noteID, _, _):
            logEntry["result"] = "saved as \(noteID)"
        case .replaced(let replacedNoteID, let newNoteID, _, _):
            logEntry["result"] = "replaced \(replacedNoteID) with \(newNoteID)"
        case .forgotten(let noteID, _):
            logEntry["result"] = "forgot \(noteID)"
        case .rejected(let reason):
            logEntry["result"] = "rejected: \(reason)"
        }
        guard let logEntryData = try? JSONSerialization.data(withJSONObject: logEntry, options: [.sortedKeys]) else { return }
        appendText(String(decoding: logEntryData, as: UTF8.self) + "\n", to: writeLogFileURL)
    }

    private func appendText(_ text: String, to fileURL: URL) {
        if let fileHandle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? fileHandle.close() }
            _ = try? fileHandle.seekToEnd()
            try? fileHandle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: fileURL, options: .atomic)
        }
    }
}

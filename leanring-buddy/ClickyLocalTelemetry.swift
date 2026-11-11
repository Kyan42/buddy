//
//  ClickyLocalTelemetry.swift
//  leanring-buddy
//
//  Local-only diagnostic log so a developer (or a coding agent) can see what
//  Clicky actually did during a push-to-talk interaction: what it heard,
//  what it saw, what it said, where it pointed, and how long each step took.
//  Nothing here is ever sent anywhere.
//
//  Layout (under ~/Library/Logs/Clicky/):
//    events-YYYY-MM-DD.jsonl          one JSON object per line, append-only
//    interactions/<interactionID>/     screenshots sent to Claude for that turn
//
//  Each push-to-talk gets an interactionID like "20261108-114502-3fa1".
//  Events carry `msSinceHotkeyPressed`, and every finished interaction ends
//  with an "interaction_summary" event holding the key latencies.
//  Old files are deleted at launch (screenshots after 7 days, events after 30).
//

import Foundation

nonisolated final class ClickyLocalTelemetry: @unchecked Sendable {

    static let shared = ClickyLocalTelemetry()

    let logsDirectoryURL: URL = {
        let libraryLogsURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        return libraryLogsURL.appendingPathComponent("Clicky", isDirectory: true)
    }()

    private var interactionsDirectoryURL: URL {
        return logsDirectoryURL.appendingPathComponent("interactions", isDirectory: true)
    }

    /// All file writes happen on this serial queue so logging never blocks the UI.
    private let fileWritingQueue = DispatchQueue(label: "clicky.local-telemetry", qos: .utility)

    private let isoTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let dayFileNameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private let interactionIDDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private init() {
        try? FileManager.default.createDirectory(at: interactionsDirectoryURL, withIntermediateDirectories: true)
    }

    // MARK: - Interaction IDs

    /// A readable, sortable ID for one push-to-talk interaction.
    func makeNewInteractionID() -> String {
        let randomSuffix = String(UUID().uuidString.prefix(4)).lowercased()
        return "\(interactionIDDateFormatter.string(from: Date()))-\(randomSuffix)"
    }

    // MARK: - Recording

    /// Appends one event line. `fields` must be JSON-serializable (strings,
    /// numbers, bools, arrays, dictionaries). Values that aren't are stringified.
    func recordEvent(
        _ eventName: String,
        interactionID: String? = nil,
        msSinceHotkeyPressed: Int? = nil,
        fields: [String: Any] = [:]
    ) {
        let eventTimestamp = Date()
        var eventLine: [String: Any] = [
            "time": isoTimestampFormatter.string(from: eventTimestamp),
            "event": eventName,
        ]
        if let interactionID { eventLine["interaction"] = interactionID }
        if let msSinceHotkeyPressed { eventLine["msSinceHotkeyPressed"] = msSinceHotkeyPressed }
        for (fieldName, fieldValue) in fields {
            eventLine[fieldName] = JSONSerialization.isValidJSONObject([fieldValue]) ? fieldValue : String(describing: fieldValue)
        }

        let eventsFileURL = logsDirectoryURL.appendingPathComponent("events-\(dayFileNameFormatter.string(from: eventTimestamp)).jsonl")

        fileWritingQueue.async {
            guard let lineData = try? JSONSerialization.data(withJSONObject: eventLine, options: [.sortedKeys]) else { return }
            var lineWithNewline = lineData
            lineWithNewline.append(UInt8(ascii: "\n"))
            if let existingFileHandle = try? FileHandle(forWritingTo: eventsFileURL) {
                existingFileHandle.seekToEndOfFile()
                existingFileHandle.write(lineWithNewline)
                try? existingFileHandle.close()
            } else {
                try? lineWithNewline.write(to: eventsFileURL)
            }
        }
    }

    /// Saves a screenshot that was sent to Claude, and returns its path for the event log.
    @discardableResult
    func saveScreenshot(jpegImageData: Data, interactionID: String, screenIndex: Int) -> String {
        let interactionDirectoryURL = interactionsDirectoryURL.appendingPathComponent(interactionID, isDirectory: true)
        let screenshotFileURL = interactionDirectoryURL.appendingPathComponent("screen\(screenIndex).jpg")
        fileWritingQueue.async {
            try? FileManager.default.createDirectory(at: interactionDirectoryURL, withIntermediateDirectories: true)
            try? jpegImageData.write(to: screenshotFileURL)
        }
        return screenshotFileURL.path
    }

    /// Saves the board as it looked when a reply finished, and returns its path for the event log.
    @discardableResult
    func saveBoardSnapshot(pngImageData: Data, interactionID: String) -> String {
        let interactionDirectoryURL = interactionsDirectoryURL.appendingPathComponent(interactionID, isDirectory: true)
        let boardSnapshotFileURL = interactionDirectoryURL.appendingPathComponent("board.png")
        fileWritingQueue.async {
            try? FileManager.default.createDirectory(at: interactionDirectoryURL, withIntermediateDirectories: true)
            try? pngImageData.write(to: boardSnapshotFileURL)
        }
        return boardSnapshotFileURL.path
    }

    // MARK: - Main Thread Freeze Detector

    private let freezeDetectorQueue = DispatchQueue(label: "clicky.main-thread-freeze-detector", qos: .utility)
    private var freezeDetectorTimer: DispatchSourceTimer?
    /// Only one ping at a time, so one long freeze is logged once with its full length.
    private var isFreezeDetectorPingOutstanding = false

    /// Every 100ms, asks the main thread to reply and measures how long it took.
    /// Replies slower than 250ms are logged as "main_thread_stall": a frozen main
    /// thread delays speech, pointing and every UI update, and is otherwise
    /// invisible in the log because event timestamps are taken when the main
    /// thread gets around to them.
    func startMainThreadFreezeDetector() {
        guard freezeDetectorTimer == nil else { return }
        let newFreezeDetectorTimer = DispatchSource.makeTimerSource(queue: freezeDetectorQueue)
        newFreezeDetectorTimer.schedule(deadline: .now() + 1, repeating: .milliseconds(100))
        newFreezeDetectorTimer.setEventHandler { [weak self] in
            guard let self, !self.isFreezeDetectorPingOutstanding else { return }
            self.isFreezeDetectorPingOutstanding = true
            let pingSentDate = Date()
            DispatchQueue.main.async {
                let msMainThreadTookToRespond = Int(Date().timeIntervalSince(pingSentDate) * 1000)
                if msMainThreadTookToRespond >= 250 {
                    self.recordEvent("main_thread_stall", fields: [
                        "msMainThreadWasBusy": msMainThreadTookToRespond,
                        "stallStartedAt": self.isoTimestampFormatter.string(from: pingSentDate),
                    ])
                }
                self.freezeDetectorQueue.async {
                    self.isFreezeDetectorPingOutstanding = false
                }
            }
        }
        newFreezeDetectorTimer.resume()
        freezeDetectorTimer = newFreezeDetectorTimer
    }

    // MARK: - Cleanup

    /// Deletes screenshots older than 7 days and event files older than 30 days.
    func deleteOldLogFiles() {
        fileWritingQueue.async {
            let fileManager = FileManager.default
            let now = Date()
            let screenshotRetentionCutoff = now.addingTimeInterval(-7 * 24 * 60 * 60)
            let eventRetentionCutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)

            let interactionFolders = (try? fileManager.contentsOfDirectory(
                at: self.interactionsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for interactionFolder in interactionFolders {
                let folderModificationDate = (try? interactionFolder.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if folderModificationDate < screenshotRetentionCutoff {
                    try? fileManager.removeItem(at: interactionFolder)
                }
            }

            let logFiles = (try? fileManager.contentsOfDirectory(
                at: self.logsDirectoryURL,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for logFile in logFiles where logFile.pathExtension == "jsonl" {
                let fileModificationDate = (try? logFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
                if fileModificationDate < eventRetentionCutoff {
                    try? fileManager.removeItem(at: logFile)
                }
            }
        }
    }
}

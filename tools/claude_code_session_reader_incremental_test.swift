// Tests the two things that keep ClickyClaudeCodeSessionReader fast, using
// made-up session files in a temporary folder (never the real ~/.claude):
//
//   1. A session file that has grown is read from where the last read stopped,
//      and the result is the same as reading the whole file from the start.
//      Also covers a file cut off in the middle of a line, a file that got
//      shorter, and a file that was rewritten.
//   2. The session list comes back in milliseconds while a long read of a big
//      file is still running.
//
// Run from the repo root:
//   mkdir -p /tmp/sessionreaderincrementaltest && cp tools/claude_code_session_reader_incremental_test.swift /tmp/sessionreaderincrementaltest/main.swift
//   swiftc -O -swift-version 5 -default-isolation MainActor leanring-buddy/ClickyClaudeCodeSessionReader.swift /tmp/sessionreaderincrementaltest/main.swift -o /tmp/sessionreaderincrementaltest/run
//   /tmp/sessionreaderincrementaltest/run
import Foundation

let temporaryClaudeCodeFolderURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("buddy-session-reader-test-\(UUID().uuidString)", isDirectory: true)
let projectFolderURL = temporaryClaudeCodeFolderURL.appendingPathComponent("projects/-tmp-demo-project", isDirectory: true)
try FileManager.default.createDirectory(at: projectFolderURL, withIntermediateDirectories: true)

var failureCount = 0
func check(_ description: String, _ passed: Bool, _ detail: String = "") {
    print((passed ? "PASS  " : "FAIL  ") + description + (detail.isEmpty ? "" : "  (\(detail))"))
    if !passed { failureCount += 1 }
}

// MARK: - Made-up session lines, shaped like Claude Code's

func jsonLine(_ entry: [String: Any]) -> String {
    return String(decoding: try! JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
}
func userLine(_ text: String) -> String {
    return jsonLine(["type": "user", "cwd": "/tmp/demo-project", "message": ["role": "user", "content": text]])
}
func claudeLine(_ text: String) -> String {
    return jsonLine(["type": "assistant", "cwd": "/tmp/demo-project", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}
func titleLine(_ title: String) -> String {
    return jsonLine(["type": "custom-title", "customTitle": title])
}
func summaryLine(_ text: String) -> String {
    return jsonLine(["type": "user", "isCompactSummary": true, "message": ["role": "user", "content": text]])
}
/// A tool result: a "user" entry with no typed text, which the reader must skip.
func toolResultLine(paddingCharacterCount: Int) -> String {
    return jsonLine(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": String(repeating: "x", count: paddingCharacterCount)]]]])
}

func write(_ lines: [String], to sessionFileURL: URL, endingMidLine: Bool = false) {
    var fileText = lines.joined(separator: "\n") + "\n"
    if endingMidLine {
        // Drop the final newline and half of the last line, as if Claude Code
        // were in the middle of writing it.
        fileText = String(fileText.dropLast(1 + lines.last!.count / 2))
    }
    try! Data(fileText.utf8).write(to: sessionFileURL)
}

func digestText(from sessionReader: ClickyClaudeCodeSessionReader, ofSessionAt sessionFileURL: URL) async -> String {
    let sessionListings = await sessionReader.listRecentSessions()
    guard let sessionListing = sessionListings.first(where: { $0.sessionFileURL.lastPathComponent == sessionFileURL.lastPathComponent }) else { return "(not listed)" }
    switch await sessionReader.buildDigest(ofSession: sessionListing) {
    case .digest(let digestText, _): return digestText
    case .couldNotReadSession(let reason): return "(could not read: \(reason))"
    }
}
func digestTextFromAFreshReader(ofSessionAt sessionFileURL: URL) async -> String {
    return await digestText(from: ClickyClaudeCodeSessionReader(claudeCodeFolderURL: temporaryClaudeCodeFolderURL), ofSessionAt: sessionFileURL)
}

// MARK: - 1. Reading only what is new gives the same result as reading it all

let growingSessionFileURL = projectFolderURL.appendingPathComponent("11111111-aaaa-bbbb-cccc-000000000001.jsonl")
let allLines: [String] = [
    titleLine("First title"),
    userLine("question one"),
    claudeLine("answer one"),
    toolResultLine(paddingCharacterCount: 5_000),
    summaryLine("summary of everything so far"),
    userLine("question two <system-reminder>hidden note</system-reminder>"),
    claudeLine("answer two"),
    titleLine("Second title"),
    userLine("question three"),
    claudeLine("answer three"),
]
let longLivedReader = ClickyClaudeCodeSessionReader(claudeCodeFolderURL: temporaryClaudeCodeFolderURL)

// First three lines, with the third cut off half way.
write(Array(allLines.prefix(3)), to: growingSessionFileURL, endingMidLine: true)
let digestWhileThirdLineIsHalfWritten = await digestText(from: longLivedReader, ofSessionAt: growingSessionFileURL)
check("a half-written last line is left for later", digestWhileThirdLineIsHalfWritten.contains("question one") && !digestWhileThirdLineIsHalfWritten.contains("answer one"))

// The file grows in three steps; after each, the long-lived reader (which reads
// only the new part) must agree with a reader that starts from nothing.
for lineCount in [3, 6, allLines.count] {
    // A modification date one second apart, so the reader sees each change even
    // on a file system with coarse timestamps.
    try await Task.sleep(nanoseconds: 1_100_000_000)
    write(Array(allLines.prefix(lineCount)), to: growingSessionFileURL)
    let digestFromContinuedRead = await digestText(from: longLivedReader, ofSessionAt: growingSessionFileURL)
    let digestFromFullRead = await digestTextFromAFreshReader(ofSessionAt: growingSessionFileURL)
    check("grown to \(lineCount) lines: continued read equals a full read", digestFromContinuedRead == digestFromFullRead, "\(digestFromContinuedRead.count) vs \(digestFromFullRead.count) characters")
}
let digestOfWholeFile = await digestText(from: longLivedReader, ofSessionAt: growingSessionFileURL)
check("no line was read twice", digestOfWholeFile.components(separatedBy: "answer two").count == 2 && digestOfWholeFile.components(separatedBy: "question three").count == 2)
check("the newer summary replaced the earlier conversation", digestOfWholeFile.contains("summary of everything so far") && !digestOfWholeFile.contains("question one"))
check("the later title won", digestOfWholeFile.contains("\"Second title\""))
check("the injected reminder was removed", !digestOfWholeFile.contains("hidden note"))

// The file gets shorter.
try await Task.sleep(nanoseconds: 1_100_000_000)
write(Array(allLines.prefix(4)), to: growingSessionFileURL)
let digestAfterShrinkContinued = await digestText(from: longLivedReader, ofSessionAt: growingSessionFileURL)
let digestAfterShrinkFull = await digestTextFromAFreshReader(ofSessionAt: growingSessionFileURL)
check("file got shorter: read again from the start", digestAfterShrinkContinued == digestAfterShrinkFull && digestAfterShrinkContinued.contains("question one"))

// The file is replaced by a longer one with different content.
try await Task.sleep(nanoseconds: 1_100_000_000)
let replacementLines = [titleLine("Replaced"), userLine("a different question"), claudeLine("a different answer"), toolResultLine(paddingCharacterCount: 9_000), userLine("and another"), claudeLine("and another answer")]
write(replacementLines, to: growingSessionFileURL)
let digestAfterRewriteContinued = await digestText(from: longLivedReader, ofSessionAt: growingSessionFileURL)
let digestAfterRewriteFull = await digestTextFromAFreshReader(ofSessionAt: growingSessionFileURL)
check("file rewritten and longer: read again from the start", digestAfterRewriteContinued == digestAfterRewriteFull && !digestAfterRewriteContinued.contains("question one") && digestAfterRewriteContinued.contains("a different question"))

// MARK: - 2. The list does not wait for a long read

// A big file: a title at the very end, after about 400 MB of tool results, so
// its title is only known once the whole file has been read. Each tool result
// is thousands of small JSON objects, which is slow to decode, like the real
// files (a plain long string decodes far too quickly to test anything).
let bigSessionFileURL = projectFolderURL.appendingPathComponent("22222222-aaaa-bbbb-cccc-000000000002.jsonl")
FileManager.default.createFile(atPath: bigSessionFileURL.path, contents: nil)
let bigFileHandle = try FileHandle(forWritingTo: bigSessionFileURL)
let manySmallObjects: [[String: Any]] = (0..<12_000).map { ["type": "text", "text": "line \($0) with a \"quoted\" word and a tab\t", "index": $0, "kept": false] }
let oneMegabyteToolResultLine = Data((jsonLine(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "content": manySmallObjects]]]]) + "\n").utf8)
let bigFileLineCount = 400_000_000 / oneMegabyteToolResultLine.count
for _ in 0..<bigFileLineCount { bigFileHandle.write(oneMegabyteToolResultLine) }
bigFileHandle.write(Data((userLine("the only typed message") + "\n" + titleLine("Big session") + "\n").utf8))
try bigFileHandle.close()

let readerForBigFile = ClickyClaudeCodeSessionReader(claudeCodeFolderURL: temporaryClaudeCodeFolderURL)
let refreshStartDate = Date()
let refreshTask = Task.detached { await readerForBigFile.refreshRecentSessions() }
// Give the refresh a moment to get going, then ask for the list while it runs.
try await Task.sleep(nanoseconds: 200_000_000)
let listStartDate = Date()
let listingsDuringRefresh = await readerForBigFile.listRecentSessions()
let millisecondsToListDuringRefresh = Int(Date().timeIntervalSince(listStartDate) * 1000)
let bigSessionListingDuringRefresh = listingsDuringRefresh.first { $0.shortSessionID == "22222222" }
await refreshTask.value
let secondsToRefresh = Date().timeIntervalSince(refreshStartDate)
let listingsAfterRefresh = await readerForBigFile.listRecentSessions()
let bigSessionListingAfterRefresh = listingsAfterRefresh.first { $0.shortSessionID == "22222222" }

print(String(format: "      reading the 400 MB file took %.1f s; the list, asked for 0.2 s in, took %d ms", secondsToRefresh, millisecondsToListDuringRefresh))
check("the long read was still running when the list was asked for", secondsToRefresh > 1.0, String(format: "the read took %.1f s", secondsToRefresh))
check("the list came back in under 100 ms during the long read", millisecondsToListDuringRefresh < 100, "\(millisecondsToListDuringRefresh) ms")
check("the unread session is listed, without a title yet", bigSessionListingDuringRefresh?.title == "(untitled)")
check("after the read, the list has its title and folder", bigSessionListingAfterRefresh?.title == "Big session" && bigSessionListingAfterRefresh?.folderName == "demo-project")

// The digest of the big session, from the read the refresh already did.
let digestOfBigSession = await digestText(from: readerForBigFile, ofSessionAt: bigSessionFileURL)
check("the big session's digest holds its one typed message", digestOfBigSession.contains("the only typed message"))

// MARK: - 3. A session that ran on another machine is not slow to read

// Its working folder starts with /home. On macOS that is a network mount
// point, and asking the file system about a path under it takes several
// milliseconds. Doing that once per message made 5,000 messages take 30 seconds.
try? FileManager.default.removeItem(at: bigSessionFileURL)
let remoteSessionFileURL = projectFolderURL.appendingPathComponent("33333333-aaaa-bbbb-cccc-000000000003.jsonl")
let remoteSessionLines: [String] = (0..<5_000).map { messageNumber in
    jsonLine(["type": "user", "cwd": "/home/someone/remote-project", "message": ["role": "user", "content": "message \(messageNumber)"]])
}
write([titleLine("Remote session")] + remoteSessionLines, to: remoteSessionFileURL)
let readerForRemoteSession = ClickyClaudeCodeSessionReader(claudeCodeFolderURL: temporaryClaudeCodeFolderURL)
let remoteReadStartDate = Date()
await readerForRemoteSession.refreshRecentSessions()
let secondsToReadRemoteSession = Date().timeIntervalSince(remoteReadStartDate)
let remoteSessionListing = await readerForRemoteSession.listRecentSessions().first { $0.shortSessionID == "33333333" }
print(String(format: "      reading 5,000 messages with a /home working folder took %.2f s", secondsToReadRemoteSession))
check("5,000 messages from another machine are read in under 2 seconds", secondsToReadRemoteSession < 2.0, String(format: "%.1f s", secondsToReadRemoteSession))
check("its folder name is the last part of the path", remoteSessionListing?.folderName == "remote-project" && remoteSessionListing?.title == "Remote session")

try? FileManager.default.removeItem(at: temporaryClaudeCodeFolderURL)
print(failureCount == 0 ? "ALL PASSED" : "\(failureCount) FAILED")
exit(failureCount == 0 ? 0 : 1)

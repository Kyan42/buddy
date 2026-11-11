// Runs ClickyClaudeCodeSessionReader on the real session files on this Mac and
// prints sizes and timings (never the conversation text). Run from the repo root:
//   mkdir -p /tmp/sessionreadertest && cp tools/claude_code_session_reader_test.swift /tmp/sessionreadertest/main.swift
//   swiftc -swift-version 5 -default-isolation MainActor leanring-buddy/ClickyClaudeCodeSessionReader.swift /tmp/sessionreadertest/main.swift -o /tmp/sessionreadertest/run
//   /tmp/sessionreadertest/run [folder-to-write-digests-into]
// With a folder argument, the list note (session-list-note.txt) and each digest
// (<short-id>.txt) are also saved there, to compare with another implementation.
import Foundation

let sessionReader = ClickyClaudeCodeSessionReader()
let digestOutputFolderPath: String? = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : nil

let firstListingStartDate = Date()
let sessionListings = await sessionReader.listRecentSessions()
let firstListingMilliseconds = Int(Date().timeIntervalSince(firstListingStartDate) * 1000)

let secondListingStartDate = Date()
_ = await sessionReader.listRecentSessions()
let secondListingMilliseconds = Int(Date().timeIntervalSince(secondListingStartDate) * 1000)

print("listed \(sessionListings.count) sessions: first time \(firstListingMilliseconds) ms, again (cached) \(secondListingMilliseconds) ms")
let sessionListNote = ClickyClaudeCodeSessionReader.sessionListNoteForClaude(sessionListings: sessionListings) ?? ""
print("list note: \(sessionListNote.count) characters, \(sessionListNote.split(separator: "\n").count) lines")
if let digestOutputFolderPath {
    try? sessionListNote.write(toFile: digestOutputFolderPath + "/session-list-note.txt", atomically: true, encoding: .utf8)
}

for sessionListing in sessionListings {
    let fileByteCount = ((try? FileManager.default.attributesOfItem(atPath: sessionListing.sessionFileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
    switch await sessionReader.buildDigest(ofSession: sessionListing) {
    case .digest(let digestText, let millisecondsToBuild):
        print("\(sessionListing.shortSessionID)  file \(fileByteCount / 1_000_000) MB  title \(sessionListing.title.count) chars  folder \(sessionListing.folderName)  open=\(sessionListing.isOpenRightNow)  digest \(digestText.unicodeScalars.count) chars in \(millisecondsToBuild) ms")
        if let digestOutputFolderPath {
            try? digestText.write(toFile: digestOutputFolderPath + "/" + sessionListing.shortSessionID + ".txt", atomically: true, encoding: .utf8)
        }
    case .couldNotReadSession(let reason):
        print("\(sessionListing.shortSessionID)  COULD NOT READ: \(reason)")
    }
}

// Matching the ID Claude writes back.
let firstShortSessionID = sessionListings.first?.shortSessionID ?? "none"
func matches(_ idWrittenByClaude: String) -> Bool {
    return ClickyClaudeCodeSessionReader.sessionListing(matchingIDWrittenByClaude: idWrittenByClaude, in: sessionListings) != nil
}
print("id matching: short=\(matches(firstShortSessionID)) full=\(matches(sessionListings.first?.sessionID ?? "none")) padded=\(matches(" " + firstShortSessionID + " ")) empty=\(matches("")) tooShort=\(matches(String(firstShortSessionID.prefix(3)))) unknown=\(matches("zzzzzzzz"))")

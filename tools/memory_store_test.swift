// Tests ClickyMemoryStore in a temporary folder (never the real ~/.claude/buddy-memory). Run from the repo root:
//   mkdir -p /tmp/memorystoretest && cp tools/memory_store_test.swift /tmp/memorystoretest/main.swift
//   swiftc -swift-version 5 -default-isolation MainActor leanring-buddy/ClickyMemoryStore.swift /tmp/memorystoretest/main.swift -o /tmp/memorystoretest/run
//   /tmp/memorystoretest/run    # prints PASS or FAIL
import Foundation

var failureCount = 0
func check(_ condition: Bool, _ description: String) {
    print((condition ? "  ok    " : "  FAIL  ") + description)
    if !condition { failureCount += 1 }
}

let temporaryFolderURL = FileManager.default.temporaryDirectory.appendingPathComponent("buddy-memory-test-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: temporaryFolderURL) }
let memoryStore = ClickyMemoryStore(memoryFolderURL: temporaryFolderURL)
func notesFileText() -> String { (try? String(contentsOf: memoryStore.notesFileURL, encoding: .utf8)) ?? "" }
func archiveFileText() -> String { (try? String(contentsOf: temporaryFolderURL.appendingPathComponent("archive.md"), encoding: .utf8)) ?? "" }
func apply(_ writeRequest: ClickyMemoryWriteRequest) async -> ClickyMemoryWriteResult {
    return await memoryStore.apply(writeRequest, interactionID: "test-interaction", userTranscript: "test transcript")
}

print("== starting empty")
check(memoryStore.loadNotesTextForPrompt() == nil, "no notes yet: nothing to load")

print("== saving")
let firstSave = await apply(.remember(sectionWrittenByClaude: "user", noteText: "Advisor's name is Doctor Rao"))
if case .saved(let noteID, let noteLine, let totalNoteCount) = firstSave {
    check(noteID == "m-0001", "first note gets id m-0001")
    check(noteLine.hasSuffix("[said] m-0001 Advisor's name is Doctor Rao"), "line carries the source mark, the id and the text")
    check(totalNoteCount == 1, "one note in the file")
} else { check(false, "first save should succeed: \(firstSave)") }
_ = await apply(.remember(sectionWrittenByClaude: "behavior", noteText: "  Keep answers short;\n skip the long version  "))
_ = await apply(.remember(sectionWrittenByClaude: "work", noteText: "- Building a memory system for Buddy"))
_ = await apply(.remember(sectionWrittenByClaude: "something unexpected", noteText: "Lives in San Francisco"))
let fileAfterSaves = notesFileText()
check(fileAfterSaves.contains("## How the user wants you to behave\n- ["), "behavior note sits under its heading")
check(fileAfterSaves.contains("m-0002 Keep answers short; skip the long version\n"), "line breaks and extra spaces are collapsed into one line")
check(fileAfterSaves.contains("m-0003 Building a memory system for Buddy"), "a leading list dash in the note text is removed")
check(fileAfterSaves.range(of: "m-0001")!.lowerBound < fileAfterSaves.range(of: "m-0004")!.lowerBound
      && fileAfterSaves.range(of: "m-0004")!.lowerBound < fileAfterSaves.range(of: "## How the user")!.lowerBound, "an unknown section name lands under About the user, after the earlier note")
check(memoryStore.loadNotesTextForPrompt()?.contains("m-0004 Lives in San Francisco") == true, "saved notes are loaded for the prompt")
check(await apply(.remember(sectionWrittenByClaude: "user", noteText: "  \n ")) == .rejected(reason: "the note was empty"), "an empty note is rejected")
let longSave = await apply(.remember(sectionWrittenByClaude: "user", noteText: String(repeating: "word ", count: 200)))
if case .saved(_, let longNoteLine, _) = longSave {
    check(longNoteLine.count < 300 && longNoteLine.hasSuffix("…"), "an overlong note is cut to one short line")
} else { check(false, "long note should be saved cut: \(longSave)") }

print("== replacing and forgetting")
let replacement = await apply(.replace(noteIDToReplace: "M-1", noteText: "Advisor's name is Doctor Rau"))
if case .replaced(let replacedNoteID, let newNoteID, _, _) = replacement {
    check(replacedNoteID == "m-0001" && newNoteID == "m-0006", "replace accepts a loosely written id and gives the new line a new id")
} else { check(false, "replace should succeed: \(replacement)") }
let fileAfterReplace = notesFileText()
check(!fileAfterReplace.contains("Doctor Rao") && fileAfterReplace.contains("m-0006 Advisor's name is Doctor Rau"), "the old line is gone and the new one is in the file")
check(fileAfterReplace.range(of: "m-0006")!.lowerBound < fileAfterReplace.range(of: "m-0004")!.lowerBound, "the new line took the old line's place")
check(archiveFileText().contains("m-0001 Advisor's name is Doctor Rao") && archiveFileText().contains("replaced by m-0006"), "the replaced line went to the archive")
check(await apply(.forget(noteID: "m-0004")) == .forgotten(noteID: "m-0004", totalNoteCount: 4), "forget removes the note and reports the count")
check(archiveFileText().contains("Lives in San Francisco") && archiveFileText().contains("forgotten"), "the forgotten line went to the archive")
check(await apply(.forget(noteID: "m-0004")) == .rejected(reason: "no note with id m-0004"), "forgetting an unknown id is rejected")
check(await apply(.replace(noteIDToReplace: "banana", noteText: "x")) == .rejected(reason: "no note with id banana"), "a malformed id is rejected")
let saveAfterForget = await apply(.remember(sectionWrittenByClaude: "user", noteText: "Prefers metric units"))
if case .saved(let noteID, _, _) = saveAfterForget {
    check(noteID == "m-0007", "ids are never reused, even after a note is forgotten")
} else { check(false, "save after forget should succeed") }

print("== a file the user edited by hand")
let handEditedText = """
# My notes for Buddy

Some free text the user wrote themselves.

## About the user
- Has a dog named Biscuit
- [2026-11-01] [said] m-0041 Speaks Farsi and English

random line that is not a note
## Ongoing work
- [2026-11-02] [said] m-0042 Writing a paper on triggers
"""
try! Data(handEditedText.utf8).write(to: memoryStore.notesFileURL)
let saveIntoHandEditedFile = await apply(.remember(sectionWrittenByClaude: "behavior", noteText: "Use the board for new topics"))
let fileAfterHandEdit = notesFileText()
if case .saved(let noteID, _, let totalNoteCount) = saveIntoHandEditedFile {
    check(noteID == "m-0043", "the next id continues after the highest id in the edited file")
    check(totalNoteCount == 4, "a hand-written note without an id still counts as a note")
} else { check(false, "save into hand-edited file should succeed") }
check(fileAfterHandEdit.hasPrefix(handEditedText), "every line the user wrote is kept exactly as it was")
check(fileAfterHandEdit.contains("\n## How the user wants you to behave\n- ["), "a heading the user removed is added back at the end")
_ = await apply(.remember(sectionWrittenByClaude: "user", noteText: "Works late on Tuesdays"))
let fileAfterSecondHandEditSave = notesFileText()
check(fileAfterSecondHandEditSave.range(of: "Works late on Tuesdays")!.lowerBound < fileAfterSecondHandEditSave.range(of: "random line that is not a note")!.lowerBound, "a new note goes after the section's last note, before stray text")
check(await apply(.forget(noteID: "m-0041")) != .rejected(reason: "no note with id m-0041"), "a note the user kept can still be forgotten by id")
check(notesFileText().contains("Has a dog named Biscuit") && notesFileText().contains("random line that is not a note"), "unrelated lines survive a forget")

print("== write log")
let writeLogLines = ((try? String(contentsOf: temporaryFolderURL.appendingPathComponent("memory-log.jsonl"), encoding: .utf8)) ?? "").split(separator: "\n")
check(writeLogLines.count == 14, "every request, accepted or rejected, is in the log (\(writeLogLines.count) lines)")
check(writeLogLines.allSatisfy { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) != nil }, "each log line is valid JSON")

print(failureCount == 0 ? "PASS" : "FAIL (\(failureCount) checks failed)")

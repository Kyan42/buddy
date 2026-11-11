// Split-invariance test for ClickyInlineMarkParser. Run from the repo root:
//   mkdir -p /tmp/parsertest && cp tools/inline_mark_parser_split_test.swift /tmp/parsertest/main.swift
//   swiftc -swift-version 5 -default-isolation MainActor leanring-buddy/ClickyInlineMarkParser.swift leanring-buddy/ClickyMemoryStore.swift /tmp/parsertest/main.swift -o /tmp/parsertest/run
//   /tmp/parsertest/run tools/fixtures/claude_reply_with_marks_xml.json   # prints PASS or FAIL
import Foundation
// Split-invariance test: every chunking must give the same clean text and the same marks/drops in order.
func describe(_ outputs: [ClickyInlineMarkParserOutput]) -> (text: String, events: [String]) {
    var text = "", events: [String] = []
    for output in outputs {
        switch output {
        case .speakableText(let chunk): text += chunk
        case .mark(let mark): events.append("mark#\(mark.markNumberInReply) \(mark.kind.rawValue) at char \(text.count) box=\(String(describing: mark.screenshotBox)) a=\(String(describing: mark.screenshotPointA)) b=\(String(describing: mark.screenshotPointB)) label=\(mark.label ?? "-") code=\(mark.drawSnippetCode ?? "-")")
        case .droppedTag(let raw, let reason): events.append("dropped at char \(text.count): \(reason) [\(raw.prefix(30))]")
        case .sessionReadRequest(let sessionID, let raw): events.append("session read request at char \(text.count): id=\(sessionID) [\(raw)]")
        case .memoryWriteRequest(let request, let raw): events.append("memory write at char \(text.count): \(request) [\(raw.prefix(40))]")
        }
    }
    return (text, events)
}
func run(_ input: String, chunkSizes: [Int]) -> (text: String, events: [String]) {
    var parser = ClickyInlineMarkParser(); var outputs: [ClickyInlineMarkParserOutput] = []
    let characters = Array(input); var index = 0, sizeIndex = 0
    while index < characters.count {
        let size = max(1, min(chunkSizes[sizeIndex % chunkSizes.count], characters.count - index))
        outputs += parser.consumeStreamedChunk(String(characters[index..<(index + size)])); index += size; sizeIndex += 1
    }
    outputs += parser.finishReply()
    return describe(outputs)
}
let prototype = (try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: String])["text"]!
let tricky = "if x < 3 and y<=4 then <div> stays text. <point x=\"10\" y=\"20\" label=\"go\"/>here. <circle box=\"50,60,10,20\"/>backwards box. <arrow from=\"1,2\" to=\"3,4\"/>arrow. <underline box=\"1,2,3\"/>bad box. <clear/>cleared. <pointer>not ours. <<circle box=\"1,1,2,2\"/>double. <board title=\"Pythagoras\"/>the triangle <draw>for (i = 0; i < 3; i++) { dot([i*10, 5]) } text([1,2], \"<b>a</b>\")</draw> has sides. <draw/>self-closed. <draw>  </draw>blank. <br>stays. trailing <circle box=\"1,2"
var allPassed = true
let sessionRead = "let me pull up that session.<read_session id=\"23f26a60\"/> then <read_session/>no id, <read_session id=\"\"/>empty id, <read_sessions id=\"x\"/>not ours, <circle box=\"1,2,3,4\"/>still a mark. ends with the tag.<read_session id=\" aead9d3f \"/>"
let memoryWrites = "<remember section=\"user\">Advisor's name is Doctor Rao</remember>got it. <remember replaces=\"m-0001\">Moved to the trigger project; uses x < 3 as a threshold</remember>updated. <forget id=\"m-0002\"/>gone. <remember/>no text, <remember section=\"work\">  </remember>blank, <forget/>no id, <remembers>not ours, <forgetful id=\"x\"/>not ours either. <remember section=\"behavior\">\nKeep answers short\n</remember>short. ends inside <remember section=\"user\">never closed"
for (name, input) in [("prototype", prototype), ("tricky", tricky), ("session-read", sessionRead), ("memory", memoryWrites)] {
    let reference = run(input, chunkSizes: [input.count])
    var rng = SystemRandomNumberGenerator()
    let splits: [[Int]] = [[1], [2], [7], [3, 1, 4, 1, 5, 9, 2, 6]] + (0..<20).map { _ in (0..<12).map { _ in Int.random(in: 1...25, using: &rng) } }
    let mismatches = splits.filter { let r = run(input, chunkSizes: $0); return r.text != reference.text || r.events != reference.events }
    allPassed = allPassed && mismatches.isEmpty
    print("== \(name): \(splits.count) chunkings, \(mismatches.isEmpty ? "ALL IDENTICAL" : "\(mismatches.count) MISMATCHES")")
    print("clean text: \(reference.text)")
    reference.events.forEach { print("  \($0)") }
}
print(allPassed ? "PASS" : "FAIL")

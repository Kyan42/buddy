//
//  ClickyInlineMarkParser.swift
//  leanring-buddy
//
//  Claude "draws while it talks" by writing small inline tags into its reply,
//  right before the words they belong to:
//
//    <point x="604" y="585" label="learn more"/>
//    <circle box="440,455,600,552"/>
//    <underline box="458,460,584,480"/>
//    <highlight box="440,370,1180,420"/>
//    <arrow from="300,340" to="610,340"/>
//    <clear/>
//
//  and the board (a whiteboard window Claude draws its own figures on):
//
//    <board title="Pythagorean theorem"/>
//    <draw>tri = polygon([[120,460],[480,460],[120,160]])</draw>
//
//  A <draw> tag has a body: a short JavaScript snippet for the board, read
//  until "</draw>" (so "<" inside the snippet is fine).
//
//  One tag is a request, not a mark:
//
//    <read_session id="23f26a60"/>
//
//  Claude writes it to ask for one of the user's Claude Code sessions. It is
//  reported the moment it is parsed (it does not wait for the voice), and the
//  app answers by sending that session as the next message.
//
//  Three more are requests to change Buddy's long-term memory. They are also
//  reported the moment they are parsed, and the app edits the notes file:
//
//    <remember section="user">Advisor's name is Doctor Rao</remember>
//    <remember replaces="m-0012">Moved to the trigger project</remember>
//    <forget id="m-0012"/>
//
//  Coordinates are pixels in the screenshot Claude saw (top-left origin). Any
//  mark may add screen="N" to target another monitor.
//
//  This parser runs on the streamed text before anything is spoken. It splits
//  the stream into speakable text and marks, in order, no matter how the text
//  is chunked. Only "<" followed by a known mark name starts a tag, so code,
//  XML or math in a reply ("x < 3", "<div>") stays ordinary text. Tags that
//  never close or grow too long are dropped (reported, never spoken).
//

import CoreGraphics
import Foundation

nonisolated enum ClickyScreenMarkKind: String, Sendable {
    case point
    case circle
    case underline
    case highlight
    case arrow
    case clear
    /// Opens a fresh board (label holds its title).
    case board
    /// Runs a drawing snippet on the board (drawSnippetCode holds it).
    case draw
}

/// One mark parsed from Claude's reply, in screenshot pixel coordinates.
nonisolated struct ClickyParsedScreenMark: Sendable, Equatable {
    /// 1-based order of this mark within the reply.
    let markNumberInReply: Int
    let kind: ClickyScreenMarkKind
    /// The tag exactly as Claude wrote it, for the diagnostic log.
    let rawTagText: String
    /// For point: the target. For arrow: the start.
    let screenshotPointA: CGPoint?
    /// For arrow: the end (where the arrowhead goes).
    let screenshotPointB: CGPoint?
    /// For circle / underline / highlight: the area, normalized so origin is top-left.
    let screenshotBox: CGRect?
    let label: String?
    /// 1-based screen number from the screenshot label, or nil for the cursor's screen.
    let screenNumber: Int?
    /// For draw: the JavaScript snippet to run on the board.
    var drawSnippetCode: String? = nil
}

nonisolated enum ClickyInlineMarkParserOutput: Sendable, Equatable {
    case speakableText(String)
    case mark(ClickyParsedScreenMark)
    case droppedTag(rawTagText: String, reason: String)
    /// Claude asked to read one of the user's Claude Code sessions.
    case sessionReadRequest(sessionIDWrittenByClaude: String, rawTagText: String)
    /// Claude asked to save, replace or forget a note in its long-term memory.
    case memoryWriteRequest(ClickyMemoryWriteRequest, rawTagText: String)
}

nonisolated struct ClickyInlineMarkParser {

    static let sessionReadRequestTagName = "read_session"
    static let rememberTagName = "remember"
    static let forgetTagName = "forget"
    static let recognizedTagNames = [
        "point", "circle", "underline", "highlight", "arrow", "clear", "board", "draw",
        sessionReadRequestTagName, rememberTagName, forgetTagName,
    ]

    /// Tags longer than this are assumed to be broken and dropped.
    private static let maximumTagLength = 300
    /// A drawing snippet longer than this is assumed to be runaway output and dropped.
    private static let maximumDrawSnippetLength = 4000
    private static let drawClosingTag = "</draw>"
    /// A memory note is one short line, so anything much longer is runaway output.
    private static let maximumRememberNoteLength = 600
    private static let rememberClosingTag = "</remember>"

    private enum ParsingState {
        /// Normal text.
        case readingText
        /// Saw "<", collecting characters until we know whether it's one of our tags.
        case decidingWhetherTagStarts(collectedText: String)
        /// Inside one of our tags, collecting until ">".
        case readingTag(collectedText: String)
        /// After "<draw>", collecting the snippet until "</draw>".
        case readingDrawSnippetBody(openingTagText: String, collectedSnippet: String)
        /// After "<remember ...>", collecting the note until "</remember>".
        case readingRememberNoteBody(openingTagText: String, collectedNoteText: String)
    }

    private var parsingState: ParsingState = .readingText
    private var numberOfMarksParsedSoFar = 0

    /// Feed the next streamed chunk. Returns outputs in order.
    mutating func consumeStreamedChunk(_ streamedChunk: String) -> [ClickyInlineMarkParserOutput] {
        var outputs: [ClickyInlineMarkParserOutput] = []
        var pendingSpeakableText = ""

        func flushPendingSpeakableText() {
            if !pendingSpeakableText.isEmpty {
                outputs.append(.speakableText(pendingSpeakableText))
                pendingSpeakableText = ""
            }
        }

        var charactersToProcess = Array(streamedChunk)
        var characterIndex = 0
        while characterIndex < charactersToProcess.count {
            let character = charactersToProcess[characterIndex]
            characterIndex += 1

            switch parsingState {
            case .readingText:
                if character == "<" {
                    parsingState = .decidingWhetherTagStarts(collectedText: "<")
                } else {
                    pendingSpeakableText.append(character)
                }

            case .decidingWhetherTagStarts(let collectedText):
                let collectedTextIncludingCharacter = collectedText + String(character)
                let textAfterOpeningBracket = String(collectedTextIncludingCharacter.dropFirst())

                if Self.isCompleteTagNameFollowedByBoundary(textAfterOpeningBracket) {
                    parsingState = .readingTag(collectedText: collectedTextIncludingCharacter)
                    if character == ">" && Self.isOpeningDrawTagWithBody(collectedTextIncludingCharacter) {
                        // "<draw>": the snippet body follows.
                        parsingState = .readingDrawSnippetBody(openingTagText: collectedTextIncludingCharacter, collectedSnippet: "")
                    } else if character == ">" && Self.isOpeningRememberTagWithBody(collectedTextIncludingCharacter) {
                        parsingState = .readingRememberNoteBody(openingTagText: collectedTextIncludingCharacter, collectedNoteText: "")
                    } else if character == ">" {
                        // e.g. "<clear>" closed immediately
                        flushPendingSpeakableText()
                        outputs.append(completeTag(collectedTextIncludingCharacter))
                    }
                } else if Self.couldStillBecomeTagName(textAfterOpeningBracket) {
                    parsingState = .decidingWhetherTagStarts(collectedText: collectedTextIncludingCharacter)
                } else {
                    // Not one of our tags: the "<" and what followed are plain text.
                    // Re-process the current character in case it is itself a "<".
                    pendingSpeakableText.append(collectedText)
                    parsingState = .readingText
                    characterIndex -= 1
                }

            case .readingTag(let collectedText):
                let collectedTextIncludingCharacter = collectedText + String(character)
                if character == ">" && Self.isOpeningDrawTagWithBody(collectedTextIncludingCharacter) {
                    parsingState = .readingDrawSnippetBody(openingTagText: collectedTextIncludingCharacter, collectedSnippet: "")
                } else if character == ">" && Self.isOpeningRememberTagWithBody(collectedTextIncludingCharacter) {
                    parsingState = .readingRememberNoteBody(openingTagText: collectedTextIncludingCharacter, collectedNoteText: "")
                } else if character == ">" {
                    flushPendingSpeakableText()
                    outputs.append(completeTag(collectedTextIncludingCharacter))
                } else if collectedTextIncludingCharacter.count > Self.maximumTagLength {
                    flushPendingSpeakableText()
                    outputs.append(.droppedTag(rawTagText: collectedTextIncludingCharacter, reason: "tag longer than \(Self.maximumTagLength) characters"))
                    parsingState = .readingText
                } else {
                    parsingState = .readingTag(collectedText: collectedTextIncludingCharacter)
                }

            case .readingDrawSnippetBody(let openingTagText, let collectedSnippet):
                let snippetIncludingCharacter = collectedSnippet + String(character)
                if snippetIncludingCharacter.hasSuffix(Self.drawClosingTag) {
                    flushPendingSpeakableText()
                    let snippetCode = String(snippetIncludingCharacter.dropLast(Self.drawClosingTag.count))
                    outputs.append(completeDrawTag(openingTagText: openingTagText, snippetCode: snippetCode))
                } else if snippetIncludingCharacter.count > Self.maximumDrawSnippetLength {
                    flushPendingSpeakableText()
                    outputs.append(.droppedTag(
                        rawTagText: openingTagText + snippetIncludingCharacter,
                        reason: "drawing snippet longer than \(Self.maximumDrawSnippetLength) characters"
                    ))
                    parsingState = .readingText
                } else {
                    parsingState = .readingDrawSnippetBody(openingTagText: openingTagText, collectedSnippet: snippetIncludingCharacter)
                }

            case .readingRememberNoteBody(let openingTagText, let collectedNoteText):
                let noteTextIncludingCharacter = collectedNoteText + String(character)
                if noteTextIncludingCharacter.hasSuffix(Self.rememberClosingTag) {
                    flushPendingSpeakableText()
                    let noteText = String(noteTextIncludingCharacter.dropLast(Self.rememberClosingTag.count))
                    outputs.append(completeRememberTag(openingTagText: openingTagText, noteText: noteText))
                } else if noteTextIncludingCharacter.count > Self.maximumRememberNoteLength {
                    flushPendingSpeakableText()
                    outputs.append(.droppedTag(
                        rawTagText: openingTagText + noteTextIncludingCharacter,
                        reason: "memory note longer than \(Self.maximumRememberNoteLength) characters"
                    ))
                    parsingState = .readingText
                } else {
                    parsingState = .readingRememberNoteBody(openingTagText: openingTagText, collectedNoteText: noteTextIncludingCharacter)
                }
            }
        }
        charactersToProcess.removeAll()

        flushPendingSpeakableText()
        return outputs
    }

    /// The reply finished streaming. A half-written tag is dropped; a lone "<" that
    /// never became a tag is returned as text.
    mutating func finishReply() -> [ClickyInlineMarkParserOutput] {
        defer { parsingState = .readingText }
        switch parsingState {
        case .readingText:
            return []
        case .decidingWhetherTagStarts(let collectedText):
            return [.speakableText(collectedText)]
        case .readingTag(let collectedText):
            return [.droppedTag(rawTagText: collectedText, reason: "reply ended inside the tag")]
        case .readingDrawSnippetBody(let openingTagText, let collectedSnippet):
            return [.droppedTag(rawTagText: openingTagText + collectedSnippet, reason: "reply ended before </draw>")]
        case .readingRememberNoteBody(let openingTagText, let collectedNoteText):
            return [.droppedTag(rawTagText: openingTagText + collectedNoteText, reason: "reply ended before </remember>")]
        }
    }

    // MARK: - Tag recognition

    private static func couldStillBecomeTagName(_ textAfterOpeningBracket: String) -> Bool {
        return recognizedTagNames.contains { $0.hasPrefix(textAfterOpeningBracket) }
    }

    /// True for "circle " / "circle/" / "circle>" etc.
    private static func isCompleteTagNameFollowedByBoundary(_ textAfterOpeningBracket: String) -> Bool {
        guard let boundaryCharacter = textAfterOpeningBracket.last,
              boundaryCharacter == " " || boundaryCharacter == "/" || boundaryCharacter == ">" || boundaryCharacter == "\n" else {
            return false
        }
        let candidateTagName = String(textAfterOpeningBracket.dropLast())
        return recognizedTagNames.contains(candidateTagName)
    }

    /// "<draw>" or "<draw ...>" (not "<draw/>"): a snippet body follows.
    private static func isOpeningDrawTagWithBody(_ fullTagText: String) -> Bool {
        let tagName = fullTagText.dropFirst().prefix(while: { $0 != " " && $0 != "/" && $0 != ">" && $0 != "\n" })
        return tagName == "draw" && !fullTagText.hasSuffix("/>")
    }

    /// "<remember ...>" (not "<remember/>"): the note text follows.
    private static func isOpeningRememberTagWithBody(_ fullTagText: String) -> Bool {
        let tagName = fullTagText.dropFirst().prefix(while: { $0 != " " && $0 != "/" && $0 != ">" && $0 != "\n" })
        return tagName == rememberTagName && !fullTagText.hasSuffix("/>")
    }

    /// "<remember section="user">text</remember>" saves a new note;
    /// "<remember replaces="m-0012">text</remember>" replaces an existing one.
    private mutating func completeRememberTag(openingTagText: String, noteText: String) -> ClickyInlineMarkParserOutput {
        parsingState = .readingText
        let rawTagText = openingTagText + noteText + Self.rememberClosingTag
        let trimmedNoteText = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNoteText.isEmpty else {
            return .droppedTag(rawTagText: rawTagText, reason: "empty memory note")
        }
        let attributes = Self.attributes(inFullTagText: openingTagText)
        if let noteIDToReplace = attributes["replaces"], !noteIDToReplace.trimmingCharacters(in: .whitespaces).isEmpty {
            return .memoryWriteRequest(
                .replace(noteIDToReplace: noteIDToReplace.trimmingCharacters(in: .whitespaces), noteText: trimmedNoteText),
                rawTagText: rawTagText
            )
        }
        return .memoryWriteRequest(
            .remember(sectionWrittenByClaude: attributes["section"], noteText: trimmedNoteText),
            rawTagText: rawTagText
        )
    }

    private mutating func completeDrawTag(openingTagText: String, snippetCode: String) -> ClickyInlineMarkParserOutput {
        parsingState = .readingText
        let rawTagText = openingTagText + snippetCode + Self.drawClosingTag
        let trimmedSnippetCode = snippetCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSnippetCode.isEmpty else {
            return .droppedTag(rawTagText: rawTagText, reason: "empty drawing snippet")
        }
        numberOfMarksParsedSoFar += 1
        return .mark(ClickyParsedScreenMark(
            markNumberInReply: numberOfMarksParsedSoFar, kind: .draw, rawTagText: rawTagText,
            screenshotPointA: nil, screenshotPointB: nil, screenshotBox: nil,
            label: nil, screenNumber: nil, drawSnippetCode: trimmedSnippetCode
        ))
    }

    /// Parses a finished tag. The caller flushes pending text first so the mark
    /// lands at the right position in the output.
    private mutating func completeTag(_ fullTagText: String) -> ClickyInlineMarkParserOutput {
        parsingState = .readingText
        let tagName = fullTagText.dropFirst().prefix(while: { $0 != " " && $0 != "/" && $0 != ">" && $0 != "\n" })
        if tagName == Self.sessionReadRequestTagName {
            return Self.parseSessionReadRequest(fromFullTagText: fullTagText)
        }
        if tagName == Self.forgetTagName {
            guard let noteID = Self.attributes(inFullTagText: fullTagText)["id"]?.trimmingCharacters(in: .whitespaces),
                  !noteID.isEmpty else {
                return .droppedTag(rawTagText: fullTagText, reason: "forget needs id=\"...\"")
            }
            return .memoryWriteRequest(.forget(noteID: noteID), rawTagText: fullTagText)
        }
        if tagName == Self.rememberTagName {
            // Only reached for "<remember/>": a note with no text.
            return .droppedTag(rawTagText: fullTagText, reason: "remember needs text: <remember>...</remember>")
        }
        switch Self.parseMark(fromFullTagText: fullTagText, nextMarkNumber: numberOfMarksParsedSoFar + 1) {
        case .success(let parsedMark):
            numberOfMarksParsedSoFar += 1
            return .mark(parsedMark)
        case .failure(let parseFailure):
            return .droppedTag(rawTagText: fullTagText, reason: parseFailure.reason)
        }
    }

    // MARK: - Attribute parsing

    private struct MarkParseFailure: Error {
        let reason: String
    }

    private static let attributeRegex = try! NSRegularExpression(pattern: #"([a-zA-Z]+)\s*=\s*"([^"]*)""#)

    /// The name="value" pairs of a tag, with lowercased names.
    private static func attributes(inFullTagText fullTagText: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let fullTagRange = NSRange(fullTagText.startIndex..., in: fullTagText)
        for attributeMatch in attributeRegex.matches(in: fullTagText, range: fullTagRange) {
            guard let nameRange = Range(attributeMatch.range(at: 1), in: fullTagText),
                  let valueRange = Range(attributeMatch.range(at: 2), in: fullTagText) else { continue }
            attributes[String(fullTagText[nameRange]).lowercased()] = String(fullTagText[valueRange])
        }
        return attributes
    }

    /// "<read_session id="23f26a60"/>": the id names a session from the list
    /// sent with the question.
    private static func parseSessionReadRequest(fromFullTagText fullTagText: String) -> ClickyInlineMarkParserOutput {
        let fullTagRange = NSRange(fullTagText.startIndex..., in: fullTagText)
        for attributeMatch in attributeRegex.matches(in: fullTagText, range: fullTagRange) {
            guard let nameRange = Range(attributeMatch.range(at: 1), in: fullTagText),
                  let valueRange = Range(attributeMatch.range(at: 2), in: fullTagText),
                  fullTagText[nameRange].lowercased() == "id" else { continue }
            let sessionIDWrittenByClaude = fullTagText[valueRange].trimmingCharacters(in: .whitespaces)
            guard !sessionIDWrittenByClaude.isEmpty else { break }
            return .sessionReadRequest(sessionIDWrittenByClaude: sessionIDWrittenByClaude, rawTagText: fullTagText)
        }
        return .droppedTag(rawTagText: fullTagText, reason: "read_session needs id=\"...\"")
    }

    private static func parseMark(fromFullTagText fullTagText: String, nextMarkNumber: Int) -> Result<ClickyParsedScreenMark, MarkParseFailure> {
        let tagNameAndAttributes = fullTagText.dropFirst().prefix(while: { $0 != " " && $0 != "/" && $0 != ">" && $0 != "\n" })
        guard let markKind = ClickyScreenMarkKind(rawValue: String(tagNameAndAttributes)) else {
            return .failure(MarkParseFailure(reason: "unknown tag name"))
        }

        var attributes: [String: String] = [:]
        let fullTagRange = NSRange(fullTagText.startIndex..., in: fullTagText)
        for attributeMatch in attributeRegex.matches(in: fullTagText, range: fullTagRange) {
            guard let nameRange = Range(attributeMatch.range(at: 1), in: fullTagText),
                  let valueRange = Range(attributeMatch.range(at: 2), in: fullTagText) else { continue }
            attributes[String(fullTagText[nameRange]).lowercased()] = String(fullTagText[valueRange])
        }

        func parseNumberList(_ attributeName: String, expectedCount: Int) -> [CGFloat]? {
            guard let rawValue = attributes[attributeName] else { return nil }
            let numbers = rawValue.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count == expectedCount else { return nil }
            return numbers.map { CGFloat($0) }
        }

        let screenNumber = attributes["screen"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let label = attributes["label"]

        switch markKind {
        case .point:
            guard let xValue = attributes["x"].flatMap({ Double($0) }),
                  let yValue = attributes["y"].flatMap({ Double($0) }) else {
                return .failure(MarkParseFailure(reason: "point needs numeric x and y"))
            }
            return .success(ClickyParsedScreenMark(
                markNumberInReply: nextMarkNumber, kind: .point, rawTagText: fullTagText,
                screenshotPointA: CGPoint(x: xValue, y: yValue), screenshotPointB: nil,
                screenshotBox: nil, label: label, screenNumber: screenNumber
            ))

        case .circle, .underline, .highlight:
            guard let boxNumbers = parseNumberList("box", expectedCount: 4) else {
                return .failure(MarkParseFailure(reason: "\(markKind.rawValue) needs box=\"x1,y1,x2,y2\""))
            }
            // Normalize so the box is valid whichever corners Claude listed first.
            let normalizedBox = CGRect(
                x: min(boxNumbers[0], boxNumbers[2]),
                y: min(boxNumbers[1], boxNumbers[3]),
                width: abs(boxNumbers[2] - boxNumbers[0]),
                height: abs(boxNumbers[3] - boxNumbers[1])
            )
            return .success(ClickyParsedScreenMark(
                markNumberInReply: nextMarkNumber, kind: markKind, rawTagText: fullTagText,
                screenshotPointA: nil, screenshotPointB: nil,
                screenshotBox: normalizedBox, label: label, screenNumber: screenNumber
            ))

        case .arrow:
            guard let fromNumbers = parseNumberList("from", expectedCount: 2),
                  let toNumbers = parseNumberList("to", expectedCount: 2) else {
                return .failure(MarkParseFailure(reason: "arrow needs from=\"x,y\" and to=\"x,y\""))
            }
            return .success(ClickyParsedScreenMark(
                markNumberInReply: nextMarkNumber, kind: .arrow, rawTagText: fullTagText,
                screenshotPointA: CGPoint(x: fromNumbers[0], y: fromNumbers[1]),
                screenshotPointB: CGPoint(x: toNumbers[0], y: toNumbers[1]),
                screenshotBox: nil, label: label, screenNumber: screenNumber
            ))

        case .board:
            return .success(ClickyParsedScreenMark(
                markNumberInReply: nextMarkNumber, kind: .board, rawTagText: fullTagText,
                screenshotPointA: nil, screenshotPointB: nil,
                screenshotBox: nil, label: attributes["title"], screenNumber: nil
            ))

        case .draw:
            return .failure(MarkParseFailure(reason: "draw needs a snippet: <draw>...</draw>"))

        case .clear:
            return .success(ClickyParsedScreenMark(
                markNumberInReply: nextMarkNumber, kind: .clear, rawTagText: fullTagText,
                screenshotPointA: nil, screenshotPointB: nil,
                screenshotBox: nil, label: nil, screenNumber: nil
            ))
        }
    }
}

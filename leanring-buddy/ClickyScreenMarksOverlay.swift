//
//  ClickyScreenMarksOverlay.swift
//  leanring-buddy
//
//  Draws Clicky's pen marks (circles, underlines, highlights, arrows) on the
//  full-screen overlay while it talks, each one animating on like a pen
//  stroke the moment the voice reaches it. Marks are stored in global AppKit
//  coordinates and each screen's overlay draws only its own.
//
//  The "hand-drawn" wobble is seeded from the mark's ID, so a mark looks the
//  same every time SwiftUI redraws it (the cursor view redraws ~60x/second).
//

import SwiftUI

/// A pen mark placed on a real screen, in global AppKit coordinates (y up).
struct ClickyScreenMarkOnDisplay: Identifiable, Equatable {
    let markID: UUID
    let kind: ClickyScreenMarkKind
    /// The display this mark belongs to (global AppKit frame).
    let displayFrame: CGRect
    /// Arrow start.
    let globalPointA: CGPoint?
    /// Arrow end (arrowhead).
    let globalPointB: CGPoint?
    /// Circle / underline / highlight area.
    let globalBox: CGRect?
    /// True when Claude aimed this mark at its own board window (the board was
    /// in the screenshot). Every other mark belongs to the app underneath, so
    /// it is hidden wherever the board covers it.
    let isDrawnOnBoardWindow: Bool

    var id: UUID { markID }
}

/// "Fly the blue cursor here now." A new request ID every time.
struct ClickyCursorPenFlightRequest: Equatable {
    let requestID: UUID
    let globalDestination: CGPoint
    let displayFrame: CGRect
    /// Short label to show next to the cursor (point marks only), or nil for none.
    let bubbleText: String?
}

/// All marks for one screen. Equatable so the 60fps cursor redraws don't
/// rebuild the mark paths unless the marks actually changed.
struct ClickyScreenMarksLayer: View, Equatable {
    let screenMarks: [ClickyScreenMarkOnDisplay]
    let screenFrame: CGRect
    /// Where the board window is (global AppKit coordinates), or nil while hidden.
    let boardWindowFrame: CGRect?

    var body: some View {
        ZStack {
            // Marks on the app underneath. This overlay sits above every window,
            // so without the mask they would show on top of the board; cutting the
            // board's area out makes them behave like ink on the page beneath it.
            ZStack {
                ForEach(screenMarks.filter { $0.displayFrame == screenFrame && !$0.isDrawnOnBoardWindow }) { screenMark in
                    ClickyScreenMarkStrokeView(screenMark: screenMark, screenFrame: screenFrame)
                        .transition(.opacity)
                }
            }
            .frame(width: screenFrame.width, height: screenFrame.height)
            .mask(
                ClickyScreenAreaNotCoveredByBoardShape(boardWindowFrameInLayer: boardWindowFrameInLayer)
                    .fill(style: FillStyle(eoFill: true))
            )

            // Marks Claude aimed at the board itself stay visible on it.
            ForEach(screenMarks.filter { $0.displayFrame == screenFrame && $0.isDrawnOnBoardWindow }) { screenMark in
                ClickyScreenMarkStrokeView(screenMark: screenMark, screenFrame: screenFrame)
                    .transition(.opacity)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    /// The board's frame in this layer's coordinates (y down), or nil when the
    /// board is hidden or on another screen.
    private var boardWindowFrameInLayer: CGRect? {
        guard let boardWindowFrame, boardWindowFrame.intersects(screenFrame) else { return nil }
        return CGRect(
            x: boardWindowFrame.minX - screenFrame.minX,
            y: screenFrame.maxY - boardWindowFrame.maxY,
            width: boardWindowFrame.width,
            height: boardWindowFrame.height
        )
    }
}

/// The whole screen with a hole where the board window is. Filled with the
/// even-odd rule, so the inner rectangle is cut out of the outer one.
private struct ClickyScreenAreaNotCoveredByBoardShape: Shape {
    let boardWindowFrameInLayer: CGRect?

    func path(in wholeLayerRect: CGRect) -> Path {
        var areaPath = Path()
        areaPath.addRect(wholeLayerRect)
        if let boardWindowFrameInLayer {
            areaPath.addRect(boardWindowFrameInLayer)
        }
        return areaPath
    }
}

/// One mark, drawn on with a pen-stroke animation when it appears.
private struct ClickyScreenMarkStrokeView: View {
    let screenMark: ClickyScreenMarkOnDisplay
    let screenFrame: CGRect

    @State private var drawProgress: CGFloat = 0

    private let penColor = DS.Colors.overlayCursorBlue
    private let penLineWidth: CGFloat = 3

    var body: some View {
        markShape
            .shadow(color: penColor.opacity(0.6), radius: 5, x: 0, y: 0)
            .onAppear {
                withAnimation(.easeOut(duration: drawDurationSeconds)) {
                    drawProgress = 1
                }
            }
    }

    private var drawDurationSeconds: Double {
        switch screenMark.kind {
        case .circle: return 0.55
        case .arrow: return 0.45
        case .highlight: return 0.4
        case .underline: return 0.35
        case .point, .clear, .board, .draw: return 0.3
        }
    }

    @ViewBuilder
    private var markShape: some View {
        let wobbleSeed = Self.makeWobbleSeed(from: screenMark.markID)
        switch screenMark.kind {
        case .circle:
            if let localBox = localBox {
                HandDrawnLoopShape(loopBounds: localBox.insetBy(dx: -12, dy: -9), wobbleSeed: wobbleSeed)
                    .trim(from: 0, to: drawProgress)
                    .stroke(penColor, style: StrokeStyle(lineWidth: penLineWidth, lineCap: .round, lineJoin: .round))
            }
        case .underline:
            if let localBox = localBox {
                HandDrawnLineShape(
                    lineStart: CGPoint(x: localBox.minX - 2, y: localBox.maxY + 4),
                    lineEnd: CGPoint(x: localBox.maxX + 2, y: localBox.maxY + 4),
                    wobbleSeed: wobbleSeed,
                    includesArrowhead: false
                )
                .trim(from: 0, to: drawProgress)
                .stroke(penColor, style: StrokeStyle(lineWidth: penLineWidth, lineCap: .round, lineJoin: .round))
            }
        case .highlight:
            if let localBox = localBox {
                HighlighterSweepShape(highlightBounds: localBox.insetBy(dx: -3, dy: -2), sweepProgress: drawProgress)
                    .fill(penColor.opacity(0.22))
            }
        case .arrow:
            if let localStart = localPointA, let localEnd = localPointB {
                HandDrawnLineShape(lineStart: localStart, lineEnd: localEnd, wobbleSeed: wobbleSeed, includesArrowhead: true)
                    .trim(from: 0, to: drawProgress)
                    .stroke(penColor, style: StrokeStyle(lineWidth: penLineWidth, lineCap: .round, lineJoin: .round))
            }
        case .point, .clear, .board, .draw:
            EmptyView()
        }
    }

    // MARK: - Coordinate conversion (global AppKit, y up → this overlay, y down)

    private func convertGlobalPointToLocal(_ globalPoint: CGPoint) -> CGPoint {
        return CGPoint(x: globalPoint.x - screenFrame.minX, y: screenFrame.maxY - globalPoint.y)
    }

    private var localBox: CGRect? {
        guard let globalBox = screenMark.globalBox else { return nil }
        return CGRect(
            x: globalBox.minX - screenFrame.minX,
            y: screenFrame.maxY - globalBox.maxY,
            width: globalBox.width,
            height: globalBox.height
        )
    }

    private var localPointA: CGPoint? { screenMark.globalPointA.map(convertGlobalPointToLocal) }
    private var localPointB: CGPoint? { screenMark.globalPointB.map(convertGlobalPointToLocal) }

    private static func makeWobbleSeed(from markID: UUID) -> UInt64 {
        let uuidBytes = markID.uuid
        return [uuidBytes.0, uuidBytes.1, uuidBytes.2, uuidBytes.3, uuidBytes.4, uuidBytes.5, uuidBytes.6, uuidBytes.7]
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

// MARK: - Seeded randomness

/// Tiny deterministic random generator so a mark's wobble never changes between redraws.
private struct SeededWobbleGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    /// A value in -1...1.
    mutating func nextSignedUnit() -> CGFloat {
        // xorshift64*
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let randomBits = state &* 2685821657736338717
        return CGFloat(Double(randomBits >> 11) / Double(1 << 53)) * 2 - 1
    }
}

// MARK: - Shapes

/// A loose, slightly uneven loop around an area, overshooting its start a little
/// like a real pen circle.
private struct HandDrawnLoopShape: Shape {
    let loopBounds: CGRect
    let wobbleSeed: UInt64

    func path(in rect: CGRect) -> Path {
        var wobbleGenerator = SeededWobbleGenerator(seed: wobbleSeed)
        let centerPoint = CGPoint(x: loopBounds.midX, y: loopBounds.midY)
        let horizontalRadius = loopBounds.width / 2
        let verticalRadius = loopBounds.height / 2

        let startAngle = -CGFloat.pi * 0.62 + wobbleGenerator.nextSignedUnit() * 0.25
        let totalSweepAngle = CGFloat.pi * 2 * 1.1
        let radiusWobbleAmplitude: CGFloat = 0.045
        let wobblePhaseOffset = wobbleGenerator.nextSignedUnit() * .pi
        let numberOfPathPoints = 72

        var loopPath = Path()
        for pointIndex in 0...numberOfPathPoints {
            let progressAlongLoop = CGFloat(pointIndex) / CGFloat(numberOfPathPoints)
            let angle = startAngle + progressAlongLoop * totalSweepAngle
            // The loop spirals slightly outward so the overshoot doesn't retrace the start.
            let spiralGrowth = 1 + progressAlongLoop * 0.06
            let radiusWobble = 1 + radiusWobbleAmplitude * sin(angle * 2.3 + wobblePhaseOffset)
            let loopPoint = CGPoint(
                x: centerPoint.x + cos(angle) * horizontalRadius * radiusWobble * spiralGrowth,
                y: centerPoint.y + sin(angle) * verticalRadius * radiusWobble * spiralGrowth
            )
            if pointIndex == 0 {
                loopPath.move(to: loopPoint)
            } else {
                loopPath.addLine(to: loopPoint)
            }
        }
        return loopPath
    }
}

/// A slightly curved hand-drawn line, optionally ending in an arrowhead (drawn
/// last, so trimming makes the head appear at the end of the stroke).
private struct HandDrawnLineShape: Shape {
    let lineStart: CGPoint
    let lineEnd: CGPoint
    let wobbleSeed: UInt64
    let includesArrowhead: Bool

    func path(in rect: CGRect) -> Path {
        var wobbleGenerator = SeededWobbleGenerator(seed: wobbleSeed)
        let lineDeltaX = lineEnd.x - lineStart.x
        let lineDeltaY = lineEnd.y - lineStart.y
        let lineLength = max(1, hypot(lineDeltaX, lineDeltaY))

        // Bow the line a little to one side, perpendicular to its direction.
        let perpendicularX = -lineDeltaY / lineLength
        let perpendicularY = lineDeltaX / lineLength
        let bowAmount = min(lineLength * 0.06, 14) * (0.6 + 0.4 * wobbleGenerator.nextSignedUnit())
        let controlPoint = CGPoint(
            x: (lineStart.x + lineEnd.x) / 2 + perpendicularX * bowAmount,
            y: (lineStart.y + lineEnd.y) / 2 + perpendicularY * bowAmount
        )

        var linePath = Path()
        linePath.move(to: lineStart)
        linePath.addQuadCurve(to: lineEnd, control: controlPoint)

        if includesArrowhead {
            // Head points along the curve's final direction (control point → end).
            let finalDirectionX = lineEnd.x - controlPoint.x
            let finalDirectionY = lineEnd.y - controlPoint.y
            let finalDirectionLength = max(1, hypot(finalDirectionX, finalDirectionY))
            let unitDirectionX = finalDirectionX / finalDirectionLength
            let unitDirectionY = finalDirectionY / finalDirectionLength
            let arrowheadLength: CGFloat = 14
            let arrowheadSpread: CGFloat = 0.5

            func arrowheadBarb(rotatedBy rotationAngle: CGFloat) -> CGPoint {
                let rotatedX = unitDirectionX * cos(rotationAngle) - unitDirectionY * sin(rotationAngle)
                let rotatedY = unitDirectionX * sin(rotationAngle) + unitDirectionY * cos(rotationAngle)
                return CGPoint(x: lineEnd.x - rotatedX * arrowheadLength, y: lineEnd.y - rotatedY * arrowheadLength)
            }
            linePath.addLine(to: arrowheadBarb(rotatedBy: arrowheadSpread))
            linePath.move(to: lineEnd)
            linePath.addLine(to: arrowheadBarb(rotatedBy: -arrowheadSpread))
        }
        return linePath
    }
}

/// A translucent highlighter swipe that grows left to right.
private struct HighlighterSweepShape: Shape {
    let highlightBounds: CGRect
    var sweepProgress: CGFloat

    var animatableData: CGFloat {
        get { sweepProgress }
        set { sweepProgress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let sweptBounds = CGRect(
            x: highlightBounds.minX,
            y: highlightBounds.minY,
            width: highlightBounds.width * max(0, min(1, sweepProgress)),
            height: highlightBounds.height
        )
        return Path(roundedRect: sweptBounds, cornerRadius: 4)
    }
}

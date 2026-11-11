//
//  ClickyBoardPanelManager.swift
//  leanring-buddy
//
//  Clicky's board: a floating whiteboard window where Claude draws its own
//  figures, graphs and equations while it explains something.
//
//  The drawing itself happens in a web page bundled with the app
//  (ClickyBoard/clicky-board.html: rough.js for the hand-drawn look, KaTeX for
//  equations, no network access). Claude writes <draw>...</draw> snippets in
//  its reply; when the voice reaches one, CompanionManager hands it to
//  runDrawSnippet, and the page reveals what it drew over the time the voice
//  spends on that sentence.
//
//  The window is a non-activating floating panel (it never steals focus from
//  the app the user is working in), draggable by its title bar, resizable from
//  the corner grip, and it remembers where the user put it.
//

import AppKit
import Combine
import SwiftUI
import WebKit

/// What happened when a drawing snippet ran on the board.
struct ClickyBoardStepResult {
    let succeeded: Bool
    let errorMessage: String?
    let numberOfItemsDrawn: Int
}

/// The title shown in the board's title bar (observed by the SwiftUI title bar).
@MainActor
final class ClickyBoardTitleBarState: ObservableObject {
    @Published var boardTitle: String = ClickyBoardPanelManager.untitledBoardTitle
}

@MainActor
final class ClickyBoardPanelManager: NSObject {

    static let untitledBoardTitle = "Buddy's board"

    /// Board space is 1000 x 625 units (see clicky-board.js); the window keeps
    /// roughly that shape so nothing is letterboxed much.
    private static let boardAspectRatio: CGFloat = 625.0 / 1000.0
    private static let titleBarHeight: CGFloat = 34
    private static let minimumBoardSize = NSSize(width: 420, height: 300)
    private static let frameAutosaveName = "ClickyBoardWindow"

    private var boardPanel: NSPanel?
    private var boardWebView: WKWebView?
    private let titleBarState = ClickyBoardTitleBarState()

    /// The page posts "ready" once its fonts are loaded. Calls made before that
    /// wait here, so the first drawing measures its text correctly.
    private var isBoardPageReady = false
    private var callsWaitingForBoardPage: [() -> Void] = []

    private(set) var isBoardShowing = false
    private(set) var currentBoardTitle: String?
    /// Every snippet that ran on the current board, in order. Sent back to Claude
    /// each turn so it knows what's already drawn (and which names it assigned).
    private(set) var drawSnippetsOnCurrentBoard: [String] = []

    /// Called when the user closes the board with its close button.
    var onBoardClosedByUser: (() -> Void)?

    /// Called whenever the part of the screen the board covers changes: it came
    /// on screen, was dragged or resized, or was closed (nil). Pen marks on the
    /// screen are kept from showing over this area.
    var onBoardWindowFrameChanged: ((CGRect?) -> Void)?

    /// Where the board window sits (global AppKit coordinates), or nil while hidden.
    var boardWindowFrameWhileShowing: CGRect? {
        guard isBoardShowing, let boardPanel else { return nil }
        return boardPanel.frame
    }

    /// The window number ScreenCaptureKit knows the board by, so screenshots can
    /// include it (Claude should see its own board, and not point at app content
    /// the board is covering).
    var boardWindowNumberWhileShowing: Int? {
        guard isBoardShowing, let boardPanel else { return nil }
        return boardPanel.windowNumber
    }

    // MARK: - Setup

    /// Builds the (hidden) window and loads the board page at launch, so the
    /// first board appears instantly when Claude starts drawing.
    func prepareBoardInBackground() {
        guard boardPanel == nil else { return }
        createBoardPanel()
        loadBoardPage()
    }

    private func createBoardPanel() {
        let boardPanel = ClickyBoardPanel(
            contentRect: Self.defaultBoardFrame(),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        boardPanel.isFloatingPanel = true
        boardPanel.level = .floating
        boardPanel.isOpaque = false
        boardPanel.backgroundColor = .clear
        boardPanel.hasShadow = true
        boardPanel.hidesOnDeactivate = false
        boardPanel.isExcludedFromWindowsMenu = true
        boardPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        boardPanel.isMovableByWindowBackground = false
        boardPanel.minSize = Self.minimumBoardSize
        boardPanel.isReleasedWhenClosed = false

        let roundedContainerView = NSView()
        roundedContainerView.wantsLayer = true
        roundedContainerView.layer?.cornerRadius = 14
        roundedContainerView.layer?.masksToBounds = true
        roundedContainerView.layer?.backgroundColor = NSColor(red: 0.984, green: 0.980, blue: 0.965, alpha: 1).cgColor
        roundedContainerView.layer?.borderWidth = 1
        roundedContainerView.layer?.borderColor = NSColor.black.withAlphaComponent(0.12).cgColor

        let titleBarHostingView = NSHostingView(rootView: ClickyBoardTitleBarView(
            titleBarState: titleBarState,
            onCloseClicked: { [weak self] in self?.closeBoardBecauseUserClickedClose() }
        ))

        let boardWebView = makeBoardWebView()
        let resizeGripView = ClickyBoardResizeGripView(minimumWindowSize: Self.minimumBoardSize)

        for subview in [titleBarHostingView, boardWebView, resizeGripView] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            roundedContainerView.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            titleBarHostingView.topAnchor.constraint(equalTo: roundedContainerView.topAnchor),
            titleBarHostingView.leadingAnchor.constraint(equalTo: roundedContainerView.leadingAnchor),
            titleBarHostingView.trailingAnchor.constraint(equalTo: roundedContainerView.trailingAnchor),
            titleBarHostingView.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),

            boardWebView.topAnchor.constraint(equalTo: titleBarHostingView.bottomAnchor),
            boardWebView.leadingAnchor.constraint(equalTo: roundedContainerView.leadingAnchor),
            boardWebView.trailingAnchor.constraint(equalTo: roundedContainerView.trailingAnchor),
            boardWebView.bottomAnchor.constraint(equalTo: roundedContainerView.bottomAnchor),

            resizeGripView.trailingAnchor.constraint(equalTo: roundedContainerView.trailingAnchor),
            resizeGripView.bottomAnchor.constraint(equalTo: roundedContainerView.bottomAnchor),
            resizeGripView.widthAnchor.constraint(equalToConstant: 20),
            resizeGripView.heightAnchor.constraint(equalToConstant: 20),
        ])

        boardPanel.contentView = roundedContainerView
        // Restores the frame the user last dragged/resized the board to, if any.
        boardPanel.setFrameAutosaveName(Self.frameAutosaveName)
        self.boardPanel = boardPanel
        self.boardWebView = boardWebView

        // The user dragging or resizing the board changes which pen marks it covers.
        for boardFrameChangeNotificationName in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(
                forName: boardFrameChangeNotificationName,
                object: boardPanel,
                queue: .main
            ) { [weak self] _ in
                // AppKit posts window notifications on the main thread.
                MainActor.assumeIsolated {
                    guard let self, self.isBoardShowing else { return }
                    self.onBoardWindowFrameChanged?(self.boardWindowFrameWhileShowing)
                }
            }
        }
    }

    private func makeBoardWebView() -> WKWebView {
        let webViewConfiguration = WKWebViewConfiguration()
        // A weak relay, because WKUserContentController retains its handlers.
        webViewConfiguration.userContentController.add(
            ClickyBoardScriptMessageRelay(boardPanelManager: self),
            name: "clickyBoard"
        )
        let boardWebView = WKWebView(frame: .zero, configuration: webViewConfiguration)
        boardWebView.navigationDelegate = self
        boardWebView.allowsMagnification = false
        boardWebView.allowsBackForwardNavigationGestures = false
        return boardWebView
    }

    private func loadBoardPage() {
        guard let boardWebView,
              let boardPageURL = Bundle.main.url(forResource: "clicky-board", withExtension: "html"),
              let bundleResourcesURL = Bundle.main.resourceURL else {
            print("⚠️ Board page (clicky-board.html) is missing from the app bundle")
            return
        }
        boardWebView.loadFileURL(boardPageURL, allowingReadAccessTo: bundleResourcesURL)
    }

    /// Right side of the screen the user's cursor is on, about 46% of its width.
    private static func defaultBoardFrame() -> NSRect {
        let mouseLocation = NSEvent.mouseLocation
        let targetScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main
        let visibleFrame = targetScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let boardWidth = min(760, visibleFrame.width * 0.46)
        let boardHeight = boardWidth * boardAspectRatio + titleBarHeight
        return NSRect(
            x: visibleFrame.maxX - boardWidth - 24,
            y: visibleFrame.midY - boardHeight / 2,
            width: boardWidth,
            height: boardHeight
        )
    }

    // MARK: - Showing and drawing

    /// Wipes the board, sets its title and brings it on screen (without
    /// activating Clicky or taking focus from the user's app).
    func showNewBoard(title: String?) {
        prepareBoardInBackground()
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentBoardTitle = (trimmedTitle?.isEmpty == false) ? trimmedTitle : nil
        titleBarState.boardTitle = currentBoardTitle ?? Self.untitledBoardTitle
        drawSnippetsOnCurrentBoard = []
        runWhenBoardPageIsReady { [weak self] in
            self?.boardWebView?.callAsyncJavaScript("clickyBoard.newBoard({})", arguments: [:], in: nil, in: .page) { _ in }
        }
        bringBoardOnScreen()
    }

    /// Runs one of Claude's drawing snippets. What it draws is revealed over
    /// `revealDurationSeconds`. A board opens first if none is showing.
    func runDrawSnippet(_ snippetCode: String, revealDurationSeconds: Double, completion: @escaping (ClickyBoardStepResult) -> Void) {
        if !isBoardShowing {
            showNewBoard(title: nil)
        }
        drawSnippetsOnCurrentBoard.append(snippetCode)
        runWhenBoardPageIsReady { [weak self] in
            guard let boardWebView = self?.boardWebView else { return }
            boardWebView.callAsyncJavaScript(
                "return clickyBoard.runStep(snippetCode, revealDurationSeconds)",
                arguments: ["snippetCode": snippetCode, "revealDurationSeconds": revealDurationSeconds],
                in: nil,
                in: .page
            ) { javaScriptResult in
                switch javaScriptResult {
                case .success(let returnedValue):
                    let stepReport = returnedValue as? [String: Any] ?? [:]
                    completion(ClickyBoardStepResult(
                        succeeded: stepReport["ok"] as? Bool ?? false,
                        errorMessage: stepReport["error"] as? String,
                        numberOfItemsDrawn: (stepReport["itemsDrawn"] as? NSNumber)?.intValue ?? 0
                    ))
                case .failure(let javaScriptError):
                    completion(ClickyBoardStepResult(succeeded: false, errorMessage: "\(javaScriptError)", numberOfItemsDrawn: 0))
                }
            }
        }
    }

    /// Jumps every stroke still being drawn to its end (the user talked over Clicky).
    func finishDrawingImmediately() {
        guard isBoardPageReady else { return }
        boardWebView?.callAsyncJavaScript("clickyBoard.finishNow()", arguments: [:], in: nil, in: .page) { _ in }
    }

    /// A PNG of the board as it looks with every stroke finished, for the local log.
    func takeFinishedBoardSnapshot(completion: @escaping (Data?) -> Void) {
        guard isBoardShowing, isBoardPageReady, let boardWebView else {
            completion(nil)
            return
        }
        boardWebView.callAsyncJavaScript("clickyBoard.finishNow()", arguments: [:], in: nil, in: .page) { _ in
            boardWebView.takeSnapshot(with: nil) { snapshotImage, _ in
                guard let snapshotImage,
                      let tiffData = snapshotImage.tiffRepresentation,
                      let bitmapImage = NSBitmapImageRep(data: tiffData) else {
                    completion(nil)
                    return
                }
                completion(bitmapImage.representation(using: .png, properties: [:]))
            }
        }
    }

    /// A note for Claude's next turn describing what's on the board, or nil when
    /// no board is open.
    func boardStateDescriptionForClaude() -> String? {
        guard isBoardShowing else { return nil }
        let titleDescription = currentBoardTitle.map { "titled \"\($0)\"" } ?? "untitled"
        guard !drawSnippetsOnCurrentBoard.isEmpty else {
            return "(your board is open, \(titleDescription), and still empty.)"
        }
        // Keep the note short: the most recent snippets matter most.
        let maximumCharactersOfSnippets = 4000
        var includedSnippets: [String] = []
        var includedCharacterCount = 0
        for snippet in drawSnippetsOnCurrentBoard.reversed() {
            if includedCharacterCount + snippet.count > maximumCharactersOfSnippets && !includedSnippets.isEmpty { break }
            includedSnippets.insert(snippet, at: 0)
            includedCharacterCount += snippet.count
        }
        let omittedSnippetCount = drawSnippetsOnCurrentBoard.count - includedSnippets.count
        var description = "(your board is open, \(titleDescription). what you've drawn on it so far, in order"
        if omittedSnippetCount > 0 {
            description += " (the first \(omittedSnippetCount) snippets are left out here)"
        }
        description += "; names you assigned still work in new snippets:\n"
        description += includedSnippets.map { "<draw>\($0)</draw>" }.joined(separator: "\n")
        description += ")"
        return description
    }

    private func bringBoardOnScreen() {
        guard let boardPanel else { return }
        guard !isBoardShowing else { return }
        isBoardShowing = true
        boardPanel.alphaValue = 0
        boardPanel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { animationContext in
            animationContext.duration = 0.25
            boardPanel.animator().alphaValue = 1
        }
        onBoardWindowFrameChanged?(boardPanel.frame)
    }

    private func closeBoardBecauseUserClickedClose() {
        guard let boardPanel, isBoardShowing else { return }
        isBoardShowing = false
        currentBoardTitle = nil
        drawSnippetsOnCurrentBoard = []
        NSAnimationContext.runAnimationGroup({ animationContext in
            animationContext.duration = 0.2
            boardPanel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls animation completions on the main thread.
            MainActor.assumeIsolated {
                // The board was reopened while it was fading out: keep it.
                guard let self, !self.isBoardShowing else { return }
                boardPanel.orderOut(nil)
                self.boardWebView?.callAsyncJavaScript("clickyBoard.newBoard({})", arguments: [:], in: nil, in: .page) { _ in }
            }
        })
        onBoardWindowFrameChanged?(nil)
        onBoardClosedByUser?()
    }

    // MARK: - Page readiness

    private func runWhenBoardPageIsReady(_ callNeedingBoardPage: @escaping () -> Void) {
        if isBoardPageReady {
            callNeedingBoardPage()
        } else {
            callsWaitingForBoardPage.append(callNeedingBoardPage)
        }
    }

    fileprivate func handleMessageFromBoardPage(_ messageBody: Any) {
        guard let messageFields = messageBody as? [String: Any],
              let messageType = messageFields["type"] as? String else { return }
        if messageType == "ready" {
            isBoardPageReady = true
            let waitingCalls = callsWaitingForBoardPage
            callsWaitingForBoardPage = []
            waitingCalls.forEach { $0() }
        }
    }
}

// MARK: - Navigation (the board page never leaves the bundle)

extension ClickyBoardPanelManager: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
        // Only the bundled board page may load; a snippet can't navigate anywhere.
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // The page crashed (a runaway snippet, say): reload a blank board.
        isBoardPageReady = false
        drawSnippetsOnCurrentBoard = []
        loadBoardPage()
    }
}

/// Forwards the page's messages without WKUserContentController retaining the manager.
private final class ClickyBoardScriptMessageRelay: NSObject, WKScriptMessageHandler {
    weak var boardPanelManager: ClickyBoardPanelManager?

    init(boardPanelManager: ClickyBoardPanelManager) {
        self.boardPanelManager = boardPanelManager
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        boardPanelManager?.handleMessageFromBoardPage(message.body)
    }
}

// MARK: - Window pieces

/// Borderless panels can't become key by default, and SwiftUI buttons in a
/// window that can't become key may ignore clicks (same reason as the menu bar
/// panel's KeyablePanel). Being a non-activating panel, it still never
/// activates Clicky or pulls focus from the user's app until they click it.
private final class ClickyBoardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The board's title bar: its title and a close button. Dragging anywhere else
/// on the bar moves the window.
private struct ClickyBoardTitleBarView: View {
    @ObservedObject var titleBarState: ClickyBoardTitleBarState
    let onCloseClicked: () -> Void

    @State private var isHoveringCloseButton = false

    var body: some View {
        ZStack {
            ClickyBoardWindowDragArea()

            HStack(spacing: 8) {
                Circle()
                    .fill(DS.Colors.overlayCursorBlue)
                    .frame(width: 8, height: 8)
                    .allowsHitTesting(false)
                Text(titleBarState.boardTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(red: 0.17, green: 0.18, blue: 0.20))
                    .lineLimit(1)
                    .allowsHitTesting(false)
                Spacer(minLength: 8)
                Button(action: onCloseClicked) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color(red: 0.17, green: 0.18, blue: 0.20).opacity(isHoveringCloseButton ? 0.9 : 0.5))
                        .frame(width: 22, height: 22)
                        .background(
                            Circle().fill(Color.black.opacity(isHoveringCloseButton ? 0.08 : 0))
                        )
                }
                .buttonStyle(.plain)
                .help("Close the board")
                .onHover { isHovering in
                    isHoveringCloseButton = isHovering
                }
                .pointerCursor()
            }
            .padding(.horizontal, 12)
        }
        .frame(height: 34)
        .background(Color(red: 0.945, green: 0.937, blue: 0.914))
    }
}

/// An invisible AppKit view behind the title bar that drags the window.
private struct ClickyBoardWindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        return ClickyBoardWindowDragView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ClickyBoardWindowDragView: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

/// The bottom-right corner grip: drag it to resize the board (the top-left
/// corner stays put).
private final class ClickyBoardResizeGripView: NSView {
    private let minimumWindowSize: NSSize
    private var windowFrameWhenDragStarted: NSRect = .zero
    private var mouseLocationWhenDragStarted: NSPoint = .zero

    init(minimumWindowSize: NSSize) {
        self.minimumWindowSize = minimumWindowSize
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Three short diagonal strokes, the usual "drag to resize" grip.
        NSColor.black.withAlphaComponent(0.28).setStroke()
        for gripLineIndex in 0..<3 {
            let inset = CGFloat(5 + gripLineIndex * 4)
            let gripLine = NSBezierPath()
            gripLine.move(to: NSPoint(x: inset, y: 4))
            gripLine.line(to: NSPoint(x: bounds.width - 4, y: bounds.height - inset))
            gripLine.lineWidth = 1.2
            gripLine.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) {
        windowFrameWhenDragStarted = window?.frame ?? .zero
        mouseLocationWhenDragStarted = NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let currentMouseLocation = NSEvent.mouseLocation
        let horizontalDragDistance = currentMouseLocation.x - mouseLocationWhenDragStarted.x
        let verticalDragDistance = currentMouseLocation.y - mouseLocationWhenDragStarted.y
        let newWidth = max(minimumWindowSize.width, windowFrameWhenDragStarted.width + horizontalDragDistance)
        // Dragging down (mouse y decreasing) makes the window taller.
        let newHeight = max(minimumWindowSize.height, windowFrameWhenDragStarted.height - verticalDragDistance)
        let topEdge = windowFrameWhenDragStarted.maxY
        window.setFrame(
            NSRect(x: windowFrameWhenDragStarted.minX, y: topEdge - newHeight, width: newWidth, height: newHeight),
            display: true
        )
    }
}

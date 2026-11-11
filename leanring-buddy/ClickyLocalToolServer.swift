//
//  ClickyLocalToolServer.swift
//  leanring-buddy
//
//  A tiny MCP (Model Context Protocol) server over HTTP, bound to 127.0.0.1,
//  that exposes Clicky's own UI tools to the Claude CLI. The CLI connects to
//  it via `--mcp-config` and calls tools like `point` while it is talking,
//  so the cursor can fly to an element mid-sentence instead of after the
//  whole reply is finished.
//
//  Only the subset of MCP that the CLI needs is implemented: `initialize`,
//  notifications, `tools/list` and `tools/call`, each answered with a single
//  JSON response (no server-sent event streams).
//
//  Security: the server only listens on loopback and the URL contains a
//  random secret path, so other local apps can't drive the cursor.
//

import Foundation
import Network

/// Arguments Claude sends with a `point` tool call.
nonisolated struct ClickyPointToolArguments: Sendable {
    /// Pixel coordinates in the screenshot's coordinate space (top-left origin).
    let screenshotPixelX: Double
    let screenshotPixelY: Double
    /// Short 1-3 word description of the element, e.g. "save button".
    let elementLabel: String
    /// 1-based screen number from the screenshot label, or nil for the cursor's screen.
    let screenNumber: Int?
}

/// Mutable "already resumed" flag shared with the listener's state handler.
nonisolated private final class ContinuationResumeOnceGuard: @unchecked Sendable {
    var hasResumed = false
}

nonisolated final class ClickyLocalToolServer: @unchecked Sendable {

    /// Name used in `--mcp-config`. Tool names the CLI sees are `mcp__clicky__<tool>`.
    static let mcpServerName = "clicky"
    static let pointToolFullyQualifiedName = "mcp__clicky__point"

    /// Called on the main thread whenever Claude calls the `point` tool.
    var onPointToolCalled: ((ClickyPointToolArguments) -> Void)?

    private let serverQueue = DispatchQueue(label: "clicky.local-tool-server")
    private var networkListener: NWListener?
    private let secretPathComponent = UUID().uuidString.lowercased()
    private(set) var serverURL: URL?

    private static let pointToolDefinition: [String: Any] = [
        "name": "point",
        "description": """
        Fly Clicky's on-screen cursor to a UI element and point at it. Use the pixel \
        coordinate space of the screenshot the element appears in (origin top-left, x to \
        the right, y down). Call it right after your first spoken sentence, only when the \
        user needs to find or click a specific element.
        """,
        "inputSchema": [
            "type": "object",
            "properties": [
                "x": ["type": "integer", "description": "x pixel coordinate in the screenshot"],
                "y": ["type": "integer", "description": "y pixel coordinate in the screenshot"],
                "label": ["type": "string", "description": "1-3 word name of the element, e.g. \"save button\""],
                "screen": ["type": "integer", "description": "screen number from the screenshot label; omit for the cursor's screen"],
            ],
            "required": ["x", "y", "label"],
        ],
    ]

    // MARK: - Lifecycle

    /// Starts listening on a random loopback port and returns the URL to pass to the CLI.
    func startListening() async throws -> URL {
        let listenerParameters = NWParameters.tcp
        listenerParameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let newNetworkListener = try NWListener(using: listenerParameters)

        newNetworkListener.newConnectionHandler = { [weak self] newConnection in
            self?.handleNewConnection(newConnection)
        }

        let listeningPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // State updates arrive serially on serverQueue; the box just lets the
            // compiler accept the "resume only once" flag inside the handler.
            let resumeOnceGuard = ContinuationResumeOnceGuard()
            newNetworkListener.stateUpdateHandler = { listenerState in
                guard !resumeOnceGuard.hasResumed else { return }
                switch listenerState {
                case .ready:
                    resumeOnceGuard.hasResumed = true
                    continuation.resume(returning: newNetworkListener.port?.rawValue ?? 0)
                case .failed(let listenerError):
                    resumeOnceGuard.hasResumed = true
                    continuation.resume(throwing: listenerError)
                default:
                    break
                }
            }
            newNetworkListener.start(queue: serverQueue)
        }

        networkListener = newNetworkListener
        let newServerURL = URL(string: "http://127.0.0.1:\(listeningPort)/mcp/\(secretPathComponent)")!
        serverURL = newServerURL
        print("🛠️ Clicky tool server listening on 127.0.0.1:\(listeningPort)")
        return newServerURL
    }

    func stopListening() {
        networkListener?.cancel()
        networkListener = nil
    }

    // MARK: - HTTP handling

    private func handleNewConnection(_ connection: NWConnection) {
        connection.start(queue: serverQueue)
        receiveHTTPRequest(on: connection, accumulatedRequestData: Data())
    }

    /// Reads until the full request (headers + Content-Length body) has arrived.
    private func receiveHTTPRequest(on connection: NWConnection, accumulatedRequestData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] receivedData, _, isComplete, receiveError in
            guard let self else { return }
            var requestDataSoFar = accumulatedRequestData
            if let receivedData { requestDataSoFar.append(receivedData) }

            if let parsedRequest = Self.parseHTTPRequestIfComplete(requestDataSoFar) {
                self.respondToHTTPRequest(parsedRequest, on: connection)
                return
            }

            if isComplete || receiveError != nil {
                connection.cancel()
                return
            }
            self.receiveHTTPRequest(on: connection, accumulatedRequestData: requestDataSoFar)
        }
    }

    private struct ParsedHTTPRequest {
        let method: String
        let path: String
        let body: Data
    }

    private static func parseHTTPRequestIfComplete(_ requestData: Data) -> ParsedHTTPRequest? {
        let headerTerminator = Data("\r\n\r\n".utf8)
        guard let headerTerminatorRange = requestData.range(of: headerTerminator) else { return nil }

        let headerText = String(decoding: requestData[requestData.startIndex..<headerTerminatorRange.lowerBound], as: UTF8.self)
        let headerLines = headerText.components(separatedBy: "\r\n")
        let requestLineParts = (headerLines.first ?? "").split(separator: " ")
        guard requestLineParts.count >= 2 else { return nil }

        var contentLength = 0
        for headerLine in headerLines.dropFirst() {
            let headerParts = headerLine.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2, headerParts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                contentLength = Int(headerParts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }

        let bodyStartIndex = headerTerminatorRange.upperBound
        let availableBodyLength = requestData.distance(from: bodyStartIndex, to: requestData.endIndex)
        guard availableBodyLength >= contentLength else { return nil }

        let bodyEndIndex = requestData.index(bodyStartIndex, offsetBy: contentLength)
        return ParsedHTTPRequest(
            method: String(requestLineParts[0]),
            path: String(requestLineParts[1]),
            body: Data(requestData[bodyStartIndex..<bodyEndIndex])
        )
    }

    private func respondToHTTPRequest(_ parsedRequest: ParsedHTTPRequest, on connection: NWConnection) {
        guard parsedRequest.path == "/mcp/\(secretPathComponent)" else {
            sendHTTPResponse(statusLine: "404 Not Found", jsonBody: nil, on: connection)
            return
        }
        // We don't offer a server-to-client event stream, which MCP signals with 405 on GET.
        guard parsedRequest.method == "POST" else {
            sendHTTPResponse(statusLine: "405 Method Not Allowed", jsonBody: nil, on: connection)
            return
        }
        guard let jsonRPCRequest = (try? JSONSerialization.jsonObject(with: parsedRequest.body)) as? [String: Any],
              let jsonRPCMethod = jsonRPCRequest["method"] as? String else {
            sendHTTPResponse(statusLine: "400 Bad Request", jsonBody: nil, on: connection)
            return
        }

        // Notifications (no "id") just get acknowledged.
        guard let jsonRPCRequestID = jsonRPCRequest["id"] else {
            sendHTTPResponse(statusLine: "202 Accepted", jsonBody: nil, on: connection)
            return
        }

        let jsonRPCParams = jsonRPCRequest["params"] as? [String: Any] ?? [:]
        let jsonRPCResult: [String: Any]

        switch jsonRPCMethod {
        case "initialize":
            jsonRPCResult = [
                "protocolVersion": jsonRPCParams["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": Self.mcpServerName, "version": "0.1"],
            ]
        case "tools/list":
            jsonRPCResult = ["tools": [Self.pointToolDefinition]]
        case "tools/call":
            jsonRPCResult = handleToolCall(jsonRPCParams)
        case "ping":
            jsonRPCResult = [:]
        default:
            let methodNotFoundResponse: [String: Any] = [
                "jsonrpc": "2.0",
                "id": jsonRPCRequestID,
                "error": ["code": -32601, "message": "Method not found: \(jsonRPCMethod)"],
            ]
            sendHTTPResponse(statusLine: "200 OK", jsonBody: methodNotFoundResponse, on: connection)
            return
        }

        let jsonRPCResponse: [String: Any] = ["jsonrpc": "2.0", "id": jsonRPCRequestID, "result": jsonRPCResult]
        sendHTTPResponse(statusLine: "200 OK", jsonBody: jsonRPCResponse, on: connection)
    }

    /// Answers immediately and hands the work to the main thread. Claude waits
    /// for this answer before it keeps talking, so we never wait for animations.
    private func handleToolCall(_ toolCallParams: [String: Any]) -> [String: Any] {
        let calledToolName = toolCallParams["name"] as? String ?? ""
        let toolArguments = toolCallParams["arguments"] as? [String: Any] ?? [:]

        guard calledToolName == "point" else {
            return ["content": [["type": "text", "text": "unknown tool \(calledToolName)"]], "isError": true]
        }

        guard let screenshotPixelX = (toolArguments["x"] as? NSNumber)?.doubleValue,
              let screenshotPixelY = (toolArguments["y"] as? NSNumber)?.doubleValue else {
            return ["content": [["type": "text", "text": "point needs integer x and y"]], "isError": true]
        }

        let pointToolArguments = ClickyPointToolArguments(
            screenshotPixelX: screenshotPixelX,
            screenshotPixelY: screenshotPixelY,
            elementLabel: toolArguments["label"] as? String ?? "element",
            screenNumber: (toolArguments["screen"] as? NSNumber)?.intValue
        )

        DispatchQueue.main.async { [weak self] in
            self?.onPointToolCalled?(pointToolArguments)
        }
        return ["content": [["type": "text", "text": "pointing at \(pointToolArguments.elementLabel)"]]]
    }

    private func sendHTTPResponse(statusLine: String, jsonBody: [String: Any]?, on connection: NWConnection) {
        var bodyData = Data()
        if let jsonBody, let serializedBody = try? JSONSerialization.data(withJSONObject: jsonBody) {
            bodyData = serializedBody
        }
        var responseHeaderText = "HTTP/1.1 \(statusLine)\r\n"
        if !bodyData.isEmpty {
            responseHeaderText += "Content-Type: application/json\r\n"
        }
        responseHeaderText += "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"

        var responseData = Data(responseHeaderText.utf8)
        responseData.append(bodyData)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

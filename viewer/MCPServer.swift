import Foundation
import CoreGraphics
import ImageIO
import Network
import UniformTypeIdentifiers

struct MCPDesktopSnapshot {
    let connectionID: UUID?
    let state: SessionState
    let image: CGImage? // Immutable owning image; never a borrowed VNC buffer.
}

// Stateless Streamable HTTP. The viewer owns Start/Stop and the
// snapshot and input providers. No blocking VNC calls, pasteboard access,
// files or logging here. Input is denied unless explicitly enabled locally.
@MainActor
final class MCPServer {
    private let supportedVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]
    private let snapshot: () -> MCPDesktopSnapshot
    private let submitInput: (VNCInputPlan) throws -> VNCInputHandle
    private var controlConnectionID: UUID?
    private(set) var controlStatus = "Control off."

    var controlAvailable: Bool {
        let current = snapshot()
        return port != nil && current.state.ready && current.image != nil && current.connectionID != nil
    }

    var controlEnabled: Bool {
        let current = snapshot()
        return port != nil && current.state.ready && current.image != nil && controlConnectionID != nil &&
            controlConnectionID == current.connectionID
    }

    private var inputTask: Task<Void, Never>?
    private var inputHandle: VNCInputHandle?
    private var inputRequestID: Data?
    private var inputConnection: MCPHTTPConnection?

    var didChange: (() -> Void)?
    let authorization = MCPAuthorization()
    private(set) var port: UInt16?
    private(set) var status = "Stopped. No MCP access."

    var active: Bool { listener != nil }
    var endpoint: String? { port.map { "http://127.0.0.1:\($0)/mcp" } }

    // Each Start gets a new identity. Async callbacks must match that identity
    // before publishing a result, even if Stop was followed immediately by Start.
    private var listener: NWListener?
    private var runID = UUID()
    private var startDeadline: Task<Void, Never>?
    private var connections: [UUID: MCPHTTPConnection] = [:]

    // Only one screenshot can encode at a time. Its response belongs to one
    // request and one TCP connection; there is no image cache or replay buffer.
    private var screenshotTask: Task<Void, Never>?
    private var screenshotRequestID: Data?
    private var screenshotConnection: MCPHTTPConnection?
    private var nextScreenshot: TimeInterval = 0

    init(
        snapshot: @escaping () -> MCPDesktopSnapshot,
        submitInput: @escaping (VNCInputPlan) throws -> VNCInputHandle
    ) {
        self.snapshot = snapshot
        self.submitInput = submitInput
        authorization.didChange = { [weak self] in self?.didChange?() }
        authorization.didRevokeAccess = { [weak self] reportingConnection in
            guard let self else { return }
            self.revokeControl(reason: "MCP authorization revoked.")
            self.screenshotTask?.cancel()
            self.screenshotRequestID = nil
            self.screenshotConnection = nil
            for client in Array(self.connections.values) where client.id != reportingConnection {
                client.close()
            }
        }
        authorization.didFail = { [weak self] message in
            guard let self else { return }
            self.stop()
            self.status = message
            self.didChange?()
        }
    }

    // Permission is bound to the connection that was visible when enabled.
    // It never carries over to a new VNC connection or a new server run.
    func setControlEnabled(_ enabled: Bool) {
        guard enabled else {
            revokeControl(reason: "Disabled in the viewer.")
            return
        }
        guard controlAvailable, inputHandle == nil else {
            controlStatus = "Control off. Wait for a connected desktop and any pending input release."
            didChange?()
            return
        }
        controlConnectionID = snapshot().connectionID
        controlStatus = "Control enabled. Local input takes over; pointer movement alone does not."
        didChange?()
    }

    func revokeControl(reason: String) {
        controlConnectionID = nil
        inputHandle?.cancel(reason: reason)
        controlStatus = "Control off. " + reason
        didChange?()
    }

    func connectionDidChange() {
        if controlConnectionID != nil && !controlEnabled {
            revokeControl(reason: "The VNC connection ended or changed.")
        } else {
            didChange?()
        }
    }

    // MARK: - Explicit server lifecycle

    func start() {
        guard listener == nil else { return }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: MCPAuthorization.port)!
        )
        parameters.allowLocalEndpointReuse = false

        do {
            let listener = try NWListener(using: parameters)
            self.listener = listener
            let currentRunID = UUID()
            runID = currentRunID
            status = "Starting on 127.0.0.1:\(MCPAuthorization.port)…"

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.runID == currentRunID, self.listener != nil else { return }

                    switch state {
                    case .ready:
                        guard let port = self.listener?.port?.rawValue else {
                            self.stop()
                            return
                        }
                        self.startDeadline?.cancel()
                        self.startDeadline = nil
                        // Own the fixed port before accessing Keychain. A
                        // second viewer must never load or mutate this authority.
                        do {
                            try self.authorization.start()
                        } catch {
                            self.stop()
                            self.status = error.localizedDescription + " Server remains stopped."
                            self.didChange?()
                            return
                        }
                        guard self.runID == currentRunID, self.listener != nil else {
                            self.authorization.stop()
                            return
                        }
                        self.port = port
                        self.status = "Running · this Mac only"
                        self.didChange?()

                    case .failed:
                        self.stop()
                        self.status = "Could not bind 127.0.0.1:\(MCPAuthorization.port). Another viewer or app may be using it. No alternate port was chosen."
                        self.didChange?()

                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self,
                          self.runID == currentRunID,
                          self.port != nil,
                          self.connections.count < 8,
                          case .hostPort(let host, _) = connection.endpoint,
                          host == NWEndpoint.Host("127.0.0.1") else {
                        connection.cancel()
                        return
                    }

                    let client = MCPHTTPConnection(
                        connection: connection,
                        authorize: { [weak self] request, client in
                            self?.authorizeRequest(request, client: client) ?? false
                        },
                        handle: { [weak self] request, client in
                            self?.handleRequest(request, client: client)
                        },
                        didClose: { [weak self] id in
                            self?.connections.removeValue(forKey: id)
                        }
                    )
                    self.connections[client.id] = client
                    client.start()
                }
            }

            listener.start(queue: .main)
            startDeadline = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                } catch {
                    return
                }
                guard let self, self.runID == currentRunID, self.port == nil else { return }

                self.stop()
                self.status = "Loopback listener startup timed out. Try Start again."
                self.didChange?()
            }
        } catch {
            status = "Could not create the loopback server. Server remains stopped."
        }
        didChange?()
    }

    func stop() {
        revokeControl(reason: "MCP server stopped.")
        runID = UUID() // Invalidates callbacks and encoded images from this run.
        startDeadline?.cancel()
        startDeadline = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        authorization.stop()
        port = nil

        for client in Array(connections.values) {
            client.close()
        }
        connections.removeAll()

        // ImageIO cannot be interrupted mid-encode. Keep the task occupied
        // until it finishes, but cancel its right to return a screenshot.
        screenshotTask?.cancel()
        screenshotRequestID = nil
        screenshotConnection = nil
        status = "Stopped. No MCP access until Start; remembered sign-ins are retained."
        didChange?()
    }

    // MARK: - HTTP access checks

    private func authorizeRequest(_ request: MCPHTTPRequest, client: MCPHTTPConnection) -> Bool {
        guard let port else {
            client.close()
            return false
        }

        // No browser cross-origin access, CORS, forwarded hosts or DNS names.
        if let origin = request.headers["origin"], origin != "http://127.0.0.1:\(port)" {
            client.respond(status: "403 Forbidden")
            return false
        }
        guard request.headers["host"] == "127.0.0.1:\(port)" else {
            client.respond(status: "403 Forbidden")
            return false
        }

        if request.path != "/mcp" {
            return authorization.authorizeRoute(request, client: client)
        }
        guard authorization.accepts(request.headers["authorization"]) else {
            authorization.challenge(client)
            return false
        }
        if let version = request.headers["mcp-protocol-version"], !supportedVersions.contains(version) {
            client.respond(status: "400 Bad Request")
            return false
        }
        guard request.method == "POST" else {
            // No server-initiated events or resumability. GET and DELETE are
            // explicitly allowed to return 405 by Streamable HTTP.
            client.respond(status: "405 Method Not Allowed", extra: "Allow: POST\r\n")
            return false
        }

        let acceptedTypes = (request.headers["accept"] ?? "").lowercased()
            .split(separator: ",")
            .compactMap { item -> String? in
                let parts = item.split(separator: ";").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard let type = parts.first else { return nil }

                for parameter in parts.dropFirst() where parameter.hasPrefix("q=") {
                    guard let quality = Double(parameter.dropFirst(2)), quality > 0, quality <= 1 else {
                        return nil
                    }
                }
                return type
            }
        guard acceptedTypes.contains("application/json"), acceptedTypes.contains("text/event-stream") else {
            client.respond(status: "406 Not Acceptable")
            return false
        }

        let contentType = request.headers["content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard contentType == "application/json" else {
            client.respond(status: "415 Unsupported Media Type")
            return false
        }
        return true
    }

    // MARK: - JSON-RPC responses

    private func sendJSONResponse(
        _ response: [String: Any],
        to client: MCPHTTPConnection,
        status: String = "200 OK"
    ) {
        guard let data = try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys]) else {
            client.respond(status: "500 Internal Server Error")
            return
        }
        client.respond(status: status, body: data)
    }

    private func sendRPCResult(_ client: MCPHTTPConnection, id: Any, result: [String: Any]) {
        sendJSONResponse(["jsonrpc": "2.0", "id": id, "result": result], to: client)
    }

    private func sendRPCError(
        _ client: MCPHTTPConnection,
        id: Any,
        code: Int = -32600,
        message: String = "Invalid request",
        status: String = "200 OK"
    ) {
        let response: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": code, "message": message]
        ]
        sendJSONResponse(response, to: client, status: status)
    }

    private func sendToolError(_ client: MCPHTTPConnection, id: Any, message: String) {
        sendRPCResult(client, id: id, result: [
            "content": [["type": "text", "text": message]],
            "isError": true
        ])
    }

    // MARK: - MCP request dispatch

    private func handleRequest(_ request: MCPHTTPRequest, client: MCPHTTPConnection) {
        if request.path != "/mcp" {
            authorization.handle(request, client: client)
            return
        }
        // Recheck after body receipt: the token may have expired while reading.
        guard authorization.accepts(request.headers["authorization"]) else {
            authorization.challenge(client)
            return
        }
        guard String(data: request.body, encoding: .utf8) != nil, !request.body.contains(0) else {
            sendRPCError(
                client, id: NSNull(), code: -32700,
                message: "Expected UTF-8 JSON", status: "400 Bad Request"
            )
            return
        }

        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: request.body, options: [.fragmentsAllowed])
        } catch {
            sendRPCError(client, id: NSNull(), code: -32700, message: "Parse error", status: "400 Bad Request")
            return
        }
        guard let envelope = decoded as? [String: Any], envelope["jsonrpc"] as? String == "2.0" else {
            sendRPCError(client, id: NSNull(), status: "400 Bad Request")
            return
        }

        let requestID = envelope["id"]
        if let requestID {
            let isStringID = requestID is String
            let isNumberID = (requestID as? NSNumber).map {
                CFGetTypeID($0) != CFBooleanGetTypeID()
            } ?? false
            guard isStringID || isNumberID else {
                sendRPCError(client, id: NSNull(), status: "400 Bad Request")
                return
            }
        }
        guard let method = envelope["method"] as? String,
              envelope["result"] == nil,
              envelope["error"] == nil,
              envelope["params"] == nil || envelope["params"] is [String: Any] else {
            sendRPCError(client, id: requestID ?? NSNull(), status: "400 Bad Request")
            return
        }
        let parameters = envelope["params"] as? [String: Any] ?? [:]

        // Notifications have no JSON-RPC response. Cancellation invalidates
        // the pending screenshot response without interrupting ImageIO.
        guard let requestID else {
            guard method.hasPrefix("notifications/") else {
                client.respond(status: "400 Bad Request")
                return
            }
            if method == "notifications/cancelled",
               let cancelledID = parameters["requestId"],
               let encodedID = try? JSONSerialization.data(
                   withJSONObject: cancelledID, options: [.fragmentsAllowed]
               ) {
                if encodedID == screenshotRequestID {
                    screenshotTask?.cancel()
                    screenshotRequestID = nil
                    screenshotConnection?.close()
                    screenshotConnection = nil
                }
                if encodedID == inputRequestID {
                    // Keep observing the worker until its releases complete.
                    inputHandle?.cancel(reason: "Cancelled by the MCP client.")
                    inputConnection?.close()
                }
            }
            client.respond(status: "202 Accepted")
            return
        }

        switch method {
        case "initialize":
            guard let requestedVersion = parameters["protocolVersion"] as? String,
                  parameters["capabilities"] is [String: Any],
                  let clientInfo = parameters["clientInfo"] as? [String: Any],
                  clientInfo["name"] is String,
                  clientInfo["version"] is String else {
                sendRPCError(client, id: requestID, code: -32602, message: "Invalid initialization parameters")
                return
            }
            let negotiatedVersion = supportedVersions.contains(requestedVersion)
                ? requestedVersion
                : supportedVersions[0]
            sendRPCResult(client, id: requestID, result: [
                "protocolVersion": negotiatedVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "sharedesk-viewer", "version": "0.1"],
                "instructions": "Access to the viewer's current remote desktop. Screenshots may contain sensitive information. " +
                    "Input requires the viewer's Allow MCP Control switch. Use target from current status or screenshot metadata. " +
                    "Pointer coordinates are full remote pixels; scale resized PNG coordinates using its metadata. " +
                    "Input can perform destructive actions as the logged-in Ubuntu user. No clipboard or connection-control tools."
            ])

        case "ping":
            sendRPCResult(client, id: requestID, result: [:])

        case "tools/list":
            guard parameters["cursor"] == nil else {
                sendRPCError(client, id: requestID, code: -32602, message: "No pagination cursor is supported")
                return
            }
            let definitions = [
                (
                    "get_connection_status",
                    "Get current connection state, received desktop dimensions and screenshot availability. " +
                    "No address, password or clipboard data."
                ),
                (
                    "capture_screenshot",
                    "Return the latest received remote framebuffer as PNG, at most 1600 pixels on its longest side. " +
                    "Requires a connected desktop. Includes the whole desktop, independent of local zoom; " +
                    "no local controls or separately rendered cursor. This is not a fresh capture request to Ubuntu."
                )
            ]
            let tools = definitions.map { name, description in
                [
                    "name": name,
                    "description": description,
                    "inputSchema": ["type": "object", "additionalProperties": false],
                    "annotations": [
                        "readOnlyHint": true,
                        "destructiveHint": false,
                        "idempotentHint": true,
                        "openWorldHint": false
                    ]
                ] as [String: Any]
            }
            sendRPCResult(client, id: requestID, result: ["tools": tools + MCPControl.tools])

        case "tools/call":
            guard let toolName = parameters["name"] as? String, parameters["task"] == nil else {
                sendRPCError(
                    client, id: requestID, code: -32602,
                    message: "Expected a tool name; task execution is not supported"
                )
                return
            }
            if MCPControl.names.contains(toolName) {
                guard controlEnabled else {
                    sendToolError(client, id: requestID, message: "MCP control is off. Enable Allow MCP Control in the viewer.")
                    return
                }
                guard inputTask == nil else {
                    sendToolError(client, id: requestID, message: "Another input action is running or releasing input.")
                    return
                }
                guard let arguments = parameters["arguments"] as? [String: Any] else {
                    sendToolError(client, id: requestID, message: "Input tools require arguments including the current target.")
                    return
                }

                let handle: VNCInputHandle
                do {
                    let plan = try MCPControl.plan(tool: toolName, arguments: arguments)
                    guard plan.target.connectionID == controlConnectionID else {
                        throw VNCInputError(message: "The target connection changed. Get a current screenshot or status.")
                    }
                    handle = try submitInput(plan)
                } catch {
                    sendToolError(client, id: requestID, message: error.localizedDescription)
                    return
                }
                let currentRunID = runID
                inputHandle = handle
                inputRequestID = try! JSONSerialization.data(
                    withJSONObject: requestID, options: [.fragmentsAllowed]
                )
                inputConnection = client
                inputTask = Task { [weak self] in
                    // Observe content-free completion; all socket writes and
                    // pacing remain on the existing blocking VNC worker.
                    var outcome = handle.outcome()
                    while outcome == nil {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        outcome = handle.outcome()
                    }
                    guard let self, let outcome else { return }
                    self.inputTask = nil
                    self.inputHandle = nil
                    self.inputRequestID = nil
                    self.inputConnection = nil
                    self.didChange?()
                    guard self.runID == currentRunID, !client.closed else { return }

                    let failed: Bool
                    if case .sent = outcome { failed = false } else { failed = true }
                    self.sendRPCResult(client, id: requestID, result: [
                        "content": [["type": "text", "text": outcome.message]],
                        "isError": failed
                    ])
                }
                return
            }

            let argumentsAbsent = parameters["arguments"] == nil
            let argumentsEmpty = (parameters["arguments"] as? [String: Any])?.isEmpty == true
            guard argumentsAbsent || argumentsEmpty else {
                sendToolError(client, id: requestID, message: "This tool accepts no arguments.")
                return
            }

            let current = snapshot()
            switch toolName {
            case "get_connection_status":
                let stateName: String
                switch current.state {
                case .connecting: stateName = "connecting"
                case .connected: stateName = "connected"
                case .stopping: stateName = "disconnecting"
                case .finished: stateName = "disconnected"
                }
                let image = current.state.ready ? current.image : nil
                let connectionStatus: [String: Any] = [
                    "state": stateName,
                    "width": image.map { $0.width as Any } ?? NSNull(),
                    "height": image.map { $0.height as Any } ?? NSNull(),
                    "screenshotAvailable": image != nil,
                    "controlEnabled": controlEnabled,
                    "target": image.flatMap { image -> [String: Any]? in
                        guard let id = current.connectionID else { return nil }
                        return ["connection_id": id.uuidString, "width": image.width, "height": image.height]
                    } as Any? ?? NSNull()
                ]
                let statusData = try! JSONSerialization.data(
                    withJSONObject: connectionStatus, options: [.sortedKeys]
                )
                let statusText = String(data: statusData, encoding: .utf8)!
                sendRPCResult(client, id: requestID, result: [
                    "content": [["type": "text", "text": statusText]],
                    "isError": false
                ])

            case "capture_screenshot":
                guard current.state.ready,
                      let image = current.image,
                      let connectionID = current.connectionID else {
                    sendToolError(client, id: requestID, message: "No connected remote framebuffer is available.")
                    return
                }
                let now = ProcessInfo.processInfo.systemUptime
                guard screenshotTask == nil, now >= nextScreenshot else {
                    sendToolError(
                        client, id: requestID,
                        message: "Screenshot busy or rate limited. Try again after one second."
                    )
                    return
                }
                nextScreenshot = now + 1

                let encodedID = try! JSONSerialization.data(
                    withJSONObject: requestID, options: [.fragmentsAllowed]
                )
                let currentRunID = runID
                screenshotRequestID = encodedID
                screenshotConnection = client
                screenshotTask = Task { [weak self] in
                    // Image scaling, PNG compression, base64 and large JSON
                    // serialization never execute on the UI or VNC thread.
                    let response = await Task.detached(priority: .utility) {
                        autoreleasepool {
                            Self.encodeScreenshot(image, id: encodedID, connectionID: connectionID)
                        }
                    }.value

                    guard let self else { return }
                    self.screenshotTask = nil
                    self.screenshotRequestID = nil
                    self.screenshotConnection = nil
                    guard !Task.isCancelled, self.runID == currentRunID, !client.closed else { return }

                    // Do not publish an old desktop if the VNC connection
                    // ended or was replaced while the PNG was being encoded.
                    let latest = self.snapshot()
                    guard latest.state.ready, latest.connectionID == connectionID else {
                        self.sendToolError(
                            client, id: requestID,
                            message: "The connection ended or changed during capture. No screenshot returned."
                        )
                        return
                    }
                    guard let response else {
                        self.sendToolError(
                            client, id: requestID,
                            message: "Could not encode a PNG within the 8 MiB limit."
                        )
                        return
                    }
                    client.respond(type: "text/event-stream", body: response)
                }

            default:
                sendRPCError(client, id: requestID, code: -32602, message: "Unknown tool")
            }

        default:
            sendRPCError(client, id: requestID, code: -32601, message: "Method not found")
        }
    }

    // MARK: - Off-thread screenshot encoding

    private nonisolated static func encodeScreenshot(_ image: CGImage, id: Data, connectionID: UUID) -> Data? {
        let scale = min(1, 1600 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaledImage = context.makeImage() else { return nil }

        let png = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            png, UTType.png.identifier as CFString, 1, nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, scaledImage, nil)
        guard CGImageDestinationFinalize(destination), png.length <= 8 * 1024 * 1024 else { return nil }

        let metadata: [String: Any] = [
            "target": ["connection_id": connectionID.uuidString, "width": image.width, "height": image.height],
            "image_width": width,
            "image_height": height
        ]
        guard let metadataData = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let metadataText = String(data: metadataData, encoding: .utf8) else { return nil }
        let result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": "Latest received remote framebuffer: \(image.width) × \(image.height); " +
                        "PNG: \(width) × \(height). Pointer coordinates use the full remote size.\n" + metadataText
                ],
                [
                    "type": "image",
                    "mimeType": "image/png",
                    "data": (png as Data).base64EncodedString()
                ]
            ],
            "isError": false
        ]
        guard let resultData = try? JSONSerialization.data(
            withJSONObject: result,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ) else {
            return nil
        }

        // One response event completes the POST's SSE stream. The ID was
        // already JSON-encoded; no unescaped client text enters this envelope.
        var response = Data("event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":".utf8)
        response.append(id)
        response.append(Data(",\"result\":".utf8))
        response.append(resultData)
        response.append(Data("}\n\n".utf8))
        return response
    }
}

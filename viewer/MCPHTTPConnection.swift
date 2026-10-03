import Foundation
import Network

struct MCPHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    var body = Data()
}

// One bounded HTTP/1.1 exchange per TCP connection. Network.framework owns
// nonblocking socket I/O; this object and all callbacks belong to MainActor.
// No keep-alive, pipelining, proxy forwarding, compression or request logging.
@MainActor
final class MCPHTTPConnection {
    private static let maximumHeaderBytes = 16 * 1024
    private static let maximumBodyBytes = 64 * 1024

    let id = UUID()
    private(set) var closed = false

    private let connection: NWConnection
    private let authorize: (MCPHTTPRequest, MCPHTTPConnection) -> Bool
    private let handle: (MCPHTTPRequest, MCPHTTPConnection) -> Void
    private let didClose: (UUID) -> Void

    // Incoming bytes move through three stages: header, body, then handler.
    // After requestComplete, only the handler or deadline can end the exchange.
    private var buffer = Data()
    private var request: MCPHTTPRequest?
    private var contentLength = 0
    private var requestComplete = false
    private var responding = false
    private var deadline: Task<Void, Never>?

    // Chunked bodies are decoded incrementally. A nil chunkSize means that
    // the next bytes must contain a size line, rather than chunk contents.
    private var chunked = false
    private var chunkSize: Int?
    private var chunkCount = 0
    private var framingBytes = 0

    init(
        connection: NWConnection,
        authorize: @escaping (MCPHTTPRequest, MCPHTTPConnection) -> Bool,
        handle: @escaping (MCPHTTPRequest, MCPHTTPConnection) -> Void,
        didClose: @escaping (UUID) -> Void
    ) {
        self.connection = connection
        self.authorize = authorize
        self.handle = handle
        self.didClose = didClose
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state {
                    self?.close()
                }
                if case .cancelled = state {
                    self?.close()
                }
            }
        }
        connection.start(queue: .main)
        setDeadline(seconds: 10)
        receive()
    }

    private func setDeadline(seconds: UInt64) {
        deadline?.cancel()
        deadline = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            } catch {
                return
            }
            self?.close()
        }
    }

    func close() {
        guard !closed else { return }

        closed = true
        deadline?.cancel()
        deadline = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        buffer.removeAll()
        request = nil
        didClose(id)
    }

    func respond(
        status: String = "200 OK",
        type: String = "application/json",
        body: Data = Data(),
        extra: String = ""
    ) {
        guard !closed, !responding else { return }

        responding = true
        buffer.removeAll()
        request = nil
        setDeadline(seconds: 15) // Includes slow clients that do not read the image.

        let header =
            "HTTP/1.1 \(status)\r\n" +
            "Content-Type: \(type)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n" +
            "Cache-Control: no-store\r\n" +
            "X-Content-Type-Options: nosniff\r\n" +
            extra + "\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                self?.close()
            }
        })
    }

    private func receive() {
        guard !closed, !responding else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, !self.closed, !self.responding else { return }

                if let data {
                    self.buffer.append(data)
                }
                self.consumeReceivedBytes()

                // A complete request belongs to its handler. A screenshot may
                // still be encoding off-thread, so do not schedule more reads.
                if self.responding || self.requestComplete { return }

                if error != nil || complete {
                    self.close()
                } else {
                    self.receive()
                }
            }
        }
    }

    private func consumeReceivedBytes() {
        // Authenticate the complete header before accepting any request body.
        if request == nil {
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if buffer.count > Self.maximumHeaderBytes {
                    respond(status: "431 Request Header Fields Too Large")
                }
                return
            }
            guard headerEnd.upperBound <= Self.maximumHeaderBytes else {
                respond(status: "431 Request Header Fields Too Large")
                return
            }
            guard let headerText = String(data: buffer[..<headerEnd.lowerBound], encoding: .ascii) else {
                respond(status: "400 Bad Request")
                return
            }

            let lines = headerText.components(separatedBy: "\r\n")
            let requestLine = lines[0].components(separatedBy: " ")
            guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" else {
                respond(status: "400 Bad Request")
                return
            }

            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else {
                    respond(status: "400 Bad Request")
                    return
                }
                let name = String(line[..<colon]).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

                // Accept ASCII letters, digits and hyphens in names, and
                // printable ASCII in values. Reject duplicate header fields.
                let validName = !name.isEmpty && name.utf8.allSatisfy {
                    (97...122).contains($0) || (48...57).contains($0) || $0 == 45
                }
                let validValue = value.utf8.allSatisfy { (32...126).contains($0) }
                guard validName, validValue, headers[name] == nil else {
                    respond(status: "400 Bad Request")
                    return
                }
                headers[name] = value
            }

            let header = MCPHTTPRequest(method: requestLine[0], path: requestLine[1], headers: headers)
            guard authorize(header, self) else { return }
            guard headers["content-encoding"] == nil, headers["expect"] == nil else {
                respond(status: "400 Bad Request")
                return
            }

            if let transferEncoding = headers["transfer-encoding"] {
                guard transferEncoding.lowercased() == "chunked", headers["content-length"] == nil else {
                    respond(status: "400 Bad Request")
                    return
                }
                chunked = true
            } else {
                guard let lengthText = headers["content-length"],
                      !lengthText.isEmpty,
                      lengthText.utf8.allSatisfy({ (48...57).contains($0) }),
                      let length = Int(lengthText) else {
                    respond(status: "411 Length Required")
                    return
                }
                guard length <= Self.maximumBodyBytes else {
                    respond(status: "413 Content Too Large")
                    return
                }
                contentLength = length
            }

            buffer = Data(buffer[headerEnd.upperBound...])
            request = header
        }

        guard !responding, var message = request else { return }

        if chunked {
            while true {
                if chunkSize == nil {
                    guard let lineEnd = buffer.range(of: Data("\r\n".utf8)) else {
                        if buffer.count > 80 {
                            respond(status: "400 Bad Request")
                        }
                        break
                    }

                    let sizeBytes = buffer[..<lineEnd.lowerBound]
                    guard !sizeBytes.isEmpty,
                          sizeBytes.count <= 8,
                          sizeBytes.allSatisfy({
                              (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                          }),
                          let sizeText = String(data: sizeBytes, encoding: .ascii),
                          let size = Int(sizeText, radix: 16) else {
                        respond(status: "400 Bad Request")
                        return
                    }

                    // Bound both decoded content and framing overhead. Small
                    // chunks must not bypass the total request-size limit.
                    chunkCount += 1
                    framingBytes += sizeBytes.count + 4
                    guard message.body.count + size <= Self.maximumBodyBytes,
                          chunkCount <= 1024,
                          framingBytes <= 8192 else {
                        respond(status: "413 Content Too Large")
                        return
                    }
                    buffer = Data(buffer[lineEnd.upperBound...])
                    chunkSize = size
                }

                let size = chunkSize!
                guard buffer.count >= size + 2 else { break }
                guard buffer[size] == 13, buffer[size + 1] == 10 else {
                    respond(status: "400 Bad Request")
                    return
                }

                message.body.append(buffer.prefix(size))
                buffer = Data(buffer.dropFirst(size + 2))
                chunkSize = nil
                if size == 0 {
                    // A zero-length chunk ends the body. Only an empty
                    // trailer section is accepted by this server.
                    handleCompleteRequest(message)
                    return
                }
            }
            request = message
        } else if buffer.count >= contentLength {
            message.body = Data(buffer.prefix(contentLength))
            buffer = Data(buffer.dropFirst(contentLength))
            handleCompleteRequest(message)
        }
    }

    private func handleCompleteRequest(_ message: MCPHTTPRequest) {
        // Reject trailing bytes rather than interpreting a second request.
        guard buffer.isEmpty else {
            respond(status: "400 Bad Request")
            return
        }

        requestComplete = true
        request = message
        handle(message, self)
    }
}

import Foundation
import CryptoKit
import Security

// A deliberately small OAuth profile for Pi: one pre-registered public client,
// authorization code + S256 PKCE, and an explicit approval in the native UI.
// No browser can approve access. No client metadata or redirect URL is fetched.
@MainActor
final class MCPAuthorization {
    static let port: UInt16 = 5917
    static let origin = "http://127.0.0.1:5917"
    static let resource = origin + "/mcp"
    static let clientID = "sharedesk-pi"
    static let scope = "desktop"
    private static let approvalLifetime: TimeInterval = 120
    private static let accessLifetime: TimeInterval = 300
    private static let grantLifetime: TimeInterval = 30 * 24 * 60 * 60
    private static let refreshRetryWindow: TimeInterval = 30

    private struct Approval {
        let ticket: String
        let displayCode: String
        let redirectURI: String
        let oauthState: String
        let codeChallenge: String
        let deadline: TimeInterval // Monotonic uptime, not a persisted calendar date.
        var decision: Bool? // nil: awaiting approval; true: approved; false: denied.
        var code: String?
        var codeDeadline: TimeInterval?
    }

    private struct AccessToken {
        let grantID: UUID
        let deadline: TimeInterval // Monotonic uptime, like the approval deadline.
    }

    // Loaded from Keychain on Start. Stop discards only this in-memory copy.
    private var authorizationState: MCPAuthorizationState?
    private var approval: Approval?
    private var approvalTimer: Task<Void, Never>?
    // Retain access-token digests, not the bearer strings returned to clients.
    private var accessTokensByDigest: [Data: AccessToken] = [:]
    private var tokenRequestTimes: [TimeInterval] = []

    var didChange: (() -> Void)?
    // Revocation also cancels input and unpublished screenshots. The HTTP
    // exchange reporting a refresh replay may finish with invalid_grant.
    var didRevokeAccess: ((UUID?) -> Void)?
    var didFail: ((String) -> Void)?
    private(set) var status = "Start the server to manage remembered sign-ins."

    var pendingApprovalCode: String? {
        guard let approval,
              approval.decision == nil,
              approval.deadline > ProcessInfo.processInfo.systemUptime else {
            return nil
        }
        return approval.displayCode
    }

    func start() throws {
        stop()
        if let saved = try MCPAuthorizationStore.read() {
            authorizationState = saved
        } else {
            let fresh = MCPAuthorizationState(signingKey: try randomBytes(), grants: [])
            try MCPAuthorizationStore.save(fresh, creating: true)
            authorizationState = fresh
        }
        status = "OAuth ready. Remembered sign-ins expire after 30 days; control still needs local permission."
        didChange?()
    }

    func stop() {
        approvalTimer?.cancel()
        approvalTimer = nil
        approval = nil
        accessTokensByDigest.removeAll()
        tokenRequestTimes.removeAll()
        authorizationState = nil
        status = "Stopped. Remembered sign-ins can refresh after the next Start."
        didChange?()
    }

    func requireSignInAgain() {
        guard authorizationState != nil else {
            return
        }
        // Deny immediately, even if a subsequent Keychain write fails.
        approvalTimer?.cancel()
        approvalTimer = nil
        approval = nil
        accessTokensByDigest.removeAll()
        authorizationState = nil
        didRevokeAccess?(nil)
        do {
            let fresh = MCPAuthorizationState(signingKey: try randomBytes(), grants: [])
            try MCPAuthorizationStore.save(fresh)
            authorizationState = fresh
            status = "All previous sign-ins revoked. Sign in again from your MCP client and approve here."
            didChange?()
        } catch {
            failClosed(error)
        }
    }

    func decideApproval(code: String, allow: Bool) {
        guard var pending = approval,
              pending.displayCode == code,
              pending.decision == nil,
              pending.deadline > ProcessInfo.processInfo.systemUptime,
              let authorizationState else {
            return
        }
        if allow && authorizationState.grants.filter({ $0.expiresAt > Date() }).count >= 8 {
            status = "Eight sign-ins are remembered. Require Sign-In Again before adding another."
            pending.decision = false
        } else {
            pending.decision = allow
            status = allow ? "Approved. Waiting for the client to finish sign-in." : "Sign-in denied."
        }
        approval = pending
        didChange?()
    }

    func accepts(_ authorization: String?) -> Bool {
        let bearerPrefix = "Bearer "
        // A 32-byte random token has 43 base64url characters without padding.
        guard let authorization,
              authorization.hasPrefix(bearerPrefix),
              authorization.utf8.count == bearerPrefix.utf8.count + 43,
              let authorizationState else {
            return false
        }

        let tokenBytes = Data(authorization.dropFirst(bearerPrefix.count).utf8)
        let tokenDigest = Data(SHA256.hash(data: tokenBytes))
        guard let accessToken = accessTokensByDigest[tokenDigest],
              accessToken.deadline > ProcessInfo.processInfo.systemUptime else {
            return false
        }
        return authorizationState.grants.contains { grant in
            grant.id == accessToken.grantID && grant.expiresAt > Date()
        }
    }

    func challenge(_ client: MCPHTTPConnection) {
        let metadataURL = Self.origin + "/.well-known/oauth-protected-resource/mcp"
        let authenticateHeader =
            "WWW-Authenticate: Bearer resource_metadata=\"\(metadataURL)\", " +
            "scope=\"\(Self.scope)\"\r\n"
        client.respond(status: "401 Unauthorized", extra: authenticateHeader)
    }

    // Called after the server's common Host/Origin checks, before body receipt.
    func authorizeRoute(_ request: MCPHTTPRequest, client: MCPHTTPConnection) -> Bool {
        guard authorizationState != nil else {
            client.respond(status: "503 Service Unavailable")
            return false
        }
        let path = request.path
            .split(separator: "?", maxSplits: 1)
            .first
            .map(String.init) ?? ""
        let getPaths = [
            "/.well-known/oauth-protected-resource/mcp",
            "/.well-known/oauth-protected-resource",
            "/.well-known/oauth-authorization-server",
            "/authorize",
            "/authorize/wait"
        ]
        guard getPaths.contains(path) || path == "/token" else {
            client.respond(status: "404 Not Found")
            return false
        }
        // Pi opens a top-level browser navigation. Drive-by cross-site fetches
        // must not create approval requests or receive token responses.
        if request.headers["sec-fetch-site"] == "cross-site" {
            client.respond(status: "403 Forbidden")
            return false
        }
        let requiredMethod = path == "/token" ? "POST" : "GET"
        guard request.method == requiredMethod else {
            client.respond(status: "405 Method Not Allowed", extra: "Allow: \(requiredMethod)\r\n")
            return false
        }
        if path == "/token" {
            let contentType = request.headers["content-type"]?
                .split(separator: ";")
                .first?
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard request.path == "/token",
                  contentType == "application/x-www-form-urlencoded",
                  request.headers["authorization"] == nil else {
                client.respond(status: "400 Bad Request")
                return false
            }
        }
        return true
    }

    func handle(_ request: MCPHTTPRequest, client: MCPHTTPConnection) {
        guard authorizationState != nil else {
            client.respond(status: "503 Service Unavailable")
            return
        }
        let parts = request.path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(parts[0])
        let query = parts.count == 2 ? String(parts[1]) : ""
        guard request.body.count <= 4096,
              request.method != "GET" || request.body.isEmpty else {
            client.respond(status: "400 Bad Request")
            return
        }
        switch path {
        case "/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource":
            guard query.isEmpty else {
                client.respond(status: "400 Bad Request")
                return
            }
            sendJSON([
                "resource": Self.resource,
                "authorization_servers": [Self.origin],
                "scopes_supported": [Self.scope],
                "bearer_methods_supported": ["header"]
            ], to: client)
        case "/.well-known/oauth-authorization-server":
            guard query.isEmpty else {
                client.respond(status: "400 Bad Request")
                return
            }
            sendJSON([
                "issuer": Self.origin,
                "authorization_endpoint": Self.origin + "/authorize",
                "token_endpoint": Self.origin + "/token",
                "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"],
                "scopes_supported": [Self.scope],
                "authorization_response_iss_parameter_supported": true
            ], to: client)
        case "/authorize":
            beginApproval(query, client: client)
        case "/authorize/wait":
            showApproval(query, client: client)
        case "/token":
            exchangeToken(request.body, client: client)
        default:
            client.respond(status: "404 Not Found")
        }
    }

    // MARK: - Native approval and browser completion

    private func beginApproval(_ query: String, client: MCPHTTPConnection) {
        let allowed: Set<String> = [
            "response_type", "client_id", "redirect_uri", "state", "scope", "resource",
            "code_challenge", "code_challenge_method"
        ]
        guard let parameters = parseParameters(query, allowed: allowed),
              parameters["response_type"] == "code",
              parameters["client_id"] == Self.clientID,
              parameters["scope"] == Self.scope,
              parameters["resource"] == Self.resource,
              parameters["code_challenge_method"] == "S256",
              let codeChallenge = parameters["code_challenge"],
              codeChallenge.utf8.count == 43,
              codeChallenge.utf8.allSatisfy({ isBase64URL($0) }),
              let oauthState = parameters["state"],
              (1...256).contains(oauthState.utf8.count),
              oauthState.utf8.allSatisfy({ (33...126).contains($0) }),
              let redirectURI = parameters["redirect_uri"],
              let redirectURL = URLComponents(string: redirectURI),
              let callbackPort = redirectURL.port,
              (1...65535).contains(callbackPort),
              callbackPort != Int(Self.port),
              redirectURI == "http://127.0.0.1:\(callbackPort)/callback" else {
            // Never redirect a malformed request to a caller-supplied address.
            sendError("invalid_request", to: client)
            return
        }
        guard approval == nil else {
            sendHTML("Another sign-in is pending. Finish or deny it in Sharedesk, then try again.", to: client)
            return
        }
        do {
            let ticket = base64URL(try randomBytes())
            let displayCode = String(ticket.prefix(4)).uppercased() + "-" +
                String(ticket.dropFirst(4).prefix(4)).uppercased()
            approval = Approval(
                ticket: ticket,
                displayCode: displayCode,
                redirectURI: redirectURI,
                oauthState: oauthState,
                codeChallenge: codeChallenge,
                deadline: ProcessInfo.processInfo.systemUptime + Self.approvalLifetime
            )
            status = "Sign-in requested. Compare the code in the browser before approving."
            approvalTimer = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: UInt64(Self.approvalLifetime) * 1_000_000_000)
                } catch {
                    return
                }
                guard let self, self.approval?.ticket == ticket else {
                    return
                }
                self.approval = nil
                self.approvalTimer = nil
                self.status = "Sign-in expired. Start sign-in again from your MCP client."
                self.didChange?()
            }
            didChange?()
            client.respond(
                status: "303 See Other",
                extra: browserHeaders + "Location: /authorize/wait?ticket=\(ticket)\r\n"
            )
        } catch {
            sendError("server_error", to: client, status: "500 Internal Server Error")
        }
    }

    private func showApproval(_ query: String, client: MCPHTTPConnection) {
        guard let parameters = parseParameters(query, allowed: ["ticket"]),
              let ticket = parameters["ticket"],
              var pending = approval,
              ticket == pending.ticket,
              pending.deadline > ProcessInfo.processInfo.systemUptime else {
            sendHTML("This sign-in expired or was cancelled. Return to your MCP client and sign in again.", to: client)
            return
        }
        guard let isApproved = pending.decision else {
            sendHTML(
                "Compare this code with Sharedesk: <strong>\(pending.displayCode)</strong>. " +
                "In Sharedesk → MCP Server, approve only if you started this sign-in in your MCP client. " +
                "Approval remembers access for up to 30 days, including future server starts. " +
                "Desktop control still needs its separate local switch. This page will continue automatically.",
                to: client, refresh: true
            )
            return
        }
        // beginApproval already validated the exact callback URL. Keep the
        // OAuth state separate from the viewer's saved authorization state.
        var redirect = URLComponents(string: pending.redirectURI)!
        var responseParameters = [
            URLQueryItem(name: "state", value: pending.oauthState),
            URLQueryItem(name: "iss", value: Self.origin)
        ]
        if isApproved {
            if pending.code == nil {
                do {
                    pending.code = base64URL(try randomBytes())
                } catch {
                    sendError("server_error", to: client, status: "500 Internal Server Error")
                    return
                }
                pending.codeDeadline = min(pending.deadline, ProcessInfo.processInfo.systemUptime + 60)
                approval = pending
            }
            responseParameters.append(URLQueryItem(name: "code", value: pending.code!))
        } else {
            responseParameters.append(URLQueryItem(name: "error", value: "access_denied"))
            clearApproval()
        }
        redirect.queryItems = responseParameters
        client.respond(status: "303 See Other", extra: browserHeaders + "Location: \(redirect.string!)\r\n")
    }

    private func clearApproval() {
        approvalTimer?.cancel()
        approvalTimer = nil
        approval = nil
        didChange?()
    }

    // MARK: - Token issue, rotation and replay detection

    private func exchangeToken(_ body: Data, client: MCPHTTPConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        tokenRequestTimes.removeAll { $0 <= now - 60 }
        guard tokenRequestTimes.count < 20 else {
            client.respond(status: "429 Too Many Requests", extra: "Retry-After: 60\r\n")
            return
        }
        tokenRequestTimes.append(now)
        let allowed: Set<String> = [
            "grant_type", "client_id", "resource", "scope", "code", "code_verifier", "redirect_uri", "refresh_token"
        ]
        guard let text = String(data: body, encoding: .utf8),
              let parameters = parseParameters(text, allowed: allowed),
              parameters["client_id"] == Self.clientID,
              parameters["resource"] == Self.resource,
              parameters["scope"] == nil || parameters["scope"] == Self.scope,
              var updatedState = authorizationState else {
            sendError("invalid_request", to: client)
            return
        }
        // Work on a copy. The live state changes only after Keychain commits.
        updatedState.grants.removeAll { $0.expiresAt <= Date() }
        let grant: MCPAuthorizationGrant
        switch parameters["grant_type"] {
        case "authorization_code":
            guard parameters["refresh_token"] == nil,
                  let pending = approval,
                  pending.decision == true,
                  let authorizationCode = pending.code,
                  parameters["code"] == authorizationCode,
                  let codeDeadline = pending.codeDeadline,
                  codeDeadline > now,
                  parameters["redirect_uri"] == pending.redirectURI,
                  let verifier = parameters["code_verifier"],
                  (43...128).contains(verifier.utf8.count),
                  verifier.utf8.allSatisfy({ isBase64URL($0) || $0 == 46 || $0 == 126 }),
                  base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == pending.codeChallenge,
                  updatedState.grants.count < 8 else {
                sendError("invalid_grant", to: client)
                return
            }
            clearApproval() // The code cannot be exchanged a second time.
            grant = MCPAuthorizationGrant(
                id: UUID(),
                expiresAt: Date().addingTimeInterval(Self.grantLifetime),
                generation: 0,
                rotatedAt: Date()
            )
            updatedState.grants.append(grant)
        case "refresh_token":
            guard parameters["code"] == nil,
                  parameters["code_verifier"] == nil,
                  parameters["redirect_uri"] == nil,
                  let refreshToken = parameters["refresh_token"],
                  refreshToken.utf8.count <= 128 else {
                sendError("invalid_grant", to: client)
                return
            }
            // Wire format: grant UUID, rotation generation, base64url MAC.
            let tokenParts = refreshToken.split(separator: ".", omittingEmptySubsequences: false)
            guard tokenParts.count == 3,
                  let grantID = UUID(uuidString: String(tokenParts[0])),
                  let presentedGeneration = UInt64(tokenParts[1]),
                  String(presentedGeneration) == tokenParts[1],
                  let grantIndex = updatedState.grants.firstIndex(where: { $0.id == grantID }) else {
                sendError("invalid_grant", to: client)
                return
            }

            // Restore the standard base64 alphabet and the single padding byte
            // of a 32-byte MAC before asking CryptoKit to verify it.
            let encodedSignature = String(tokenParts[2])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/") + "="
            guard let signature = Data(base64Encoded: encodedSignature),
                  signature.count == 32,
                  HMAC<SHA256>.isValidAuthenticationCode(
                    signature,
                    authenticating: refreshMessage(id: grantID, generation: presentedGeneration),
                    using: SymmetricKey(data: updatedState.signingKey)
                  ) else {
                sendError("invalid_grant", to: client)
                return
            }
            var currentGrant = updatedState.grants[grantIndex]
            if presentedGeneration == currentGrant.generation, presentedGeneration < UInt64.max - 1 {
                currentGrant.generation += 1
                currentGrant.rotatedAt = Date()
                updatedState.grants[grantIndex] = currentGrant
            } else if currentGrant.generation > 0,
                      presentedGeneration == currentGrant.generation - 1,
                      (0...Self.refreshRetryWindow).contains(Date().timeIntervalSince(currentGrant.rotatedAt)) {
                // A lost response or a concurrent Pi process can retry the
                // immediately previous token briefly. Return the same successor.
                // Never move the rotation time or extend the 30-day approval.
            } else {
                // The MAC proves this was a real old token, not a guessed ID.
                // Replaying it after the retry window revokes this token family.
                updatedState.grants.remove(at: grantIndex)
                accessTokensByDigest = accessTokensByDigest.filter { $0.value.grantID != grantID }
                didRevokeAccess?(client.id)
                do {
                    try MCPAuthorizationStore.save(updatedState)
                    authorizationState = updatedState
                    status = "An old refresh token was reused. That sign-in was revoked; sign in again from your MCP client."
                    didChange?()
                    sendError("invalid_grant", to: client)
                } catch {
                    failClosed(error)
                }
                return
            }
            grant = currentGrant
        default:
            sendError("unsupported_grant_type", to: client)
            return
        }

        accessTokensByDigest = accessTokensByDigest.filter { $0.value.deadline > now }
        guard accessTokensByDigest.count < 128 else {
            sendError("temporarily_unavailable", to: client, status: "503 Service Unavailable")
            return
        }
        do {
            let accessToken = base64URL(try randomBytes())
            // Commit before returning any credentials. On failure, stop rather
            // than issue an in-memory grant which would return after a restart.
            try MCPAuthorizationStore.save(updatedState)
            authorizationState = updatedState
            let tokenDigest = Data(SHA256.hash(data: Data(accessToken.utf8)))
            accessTokensByDigest[tokenDigest] = AccessToken(
                grantID: grant.id,
                deadline: now + Self.accessLifetime
            )
            let signature = HMAC<SHA256>.authenticationCode(
                for: refreshMessage(id: grant.id, generation: grant.generation),
                using: SymmetricKey(data: updatedState.signingKey)
            )
            let refreshToken = "\(grant.id.uuidString).\(grant.generation).\(base64URL(Data(signature)))"
            status = "Client authorized. Control still needs local permission."
            didChange?()
            sendJSON([
                "access_token": accessToken,
                "token_type": "Bearer",
                "expires_in": Int(Self.accessLifetime),
                "refresh_token": refreshToken,
                "scope": Self.scope
            ], to: client)
        } catch {
            failClosed(error)
        }
    }

    // A token is bound to this server's private key, resource, public client,
    // scope, approval ID and rotation number. It is never a VNC credential.
    private func refreshMessage(id: UUID, generation: UInt64) -> Data {
        let message = "Sharedesk refresh\n" +
            "\(Self.resource)\n" +
            "\(Self.clientID)\n" +
            "\(Self.scope)\n" +
            "\(id.uuidString)\n" +
            "\(generation)"
        return Data(message.utf8)
    }

    private func failClosed(_ error: Error) {
        stop()
        didRevokeAccess?(nil)
        didFail?(error.localizedDescription + " MCP stopped. Previous Keychain approvals may still exist.")
    }

    // MARK: - Bounded encoding and response helpers

    private func parseParameters(_ text: String, allowed: Set<String>) -> [String: String]? {
        guard !text.isEmpty, text.utf8.count <= 4096 else {
            return nil
        }
        var result: [String: String] = [:]
        for pair in text.split(separator: "&", omittingEmptySubsequences: false) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let name = String(parts[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = String(parts[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  allowed.contains(name),
                  result[name] == nil else {
                return nil
            }
            result[name] = value
        }
        return result
    }

    private func randomBytes() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw MCPAuthorizationError.message("Could not obtain secure random bytes. MCP remains unavailable.")
        }
        return Data(bytes)
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func isBase64URL(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || // A–Z
        (97...122).contains(byte) || // a–z
        (48...57).contains(byte) || // 0–9
        byte == 45 || // -
        byte == 95 // _
    }

    private func sendJSON(_ object: [String: Any], to client: MCPHTTPConnection, status: String = "200 OK") {
        guard let body = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            client.respond(status: "500 Internal Server Error")
            return
        }
        client.respond(status: status, body: body, extra: "Pragma: no-cache\r\n")
    }

    private func sendError(_ error: String, to client: MCPHTTPConnection, status: String = "400 Bad Request") {
        sendJSON(["error": error], to: client, status: status)
    }

    private var browserHeaders: String {
        "Referrer-Policy: no-referrer\r\n" +
        "Content-Security-Policy: default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n" +
        "X-Frame-Options: DENY\r\n"
    }

    // Messages contain only application text and a server-generated code, never
    // client-supplied HTML. No scripts, cookies, external assets or approval form.
    private func sendHTML(_ message: String, to client: MCPHTTPConnection, refresh: Bool = false) {
        let reload = refresh ? "<meta http-equiv=\"refresh\" content=\"2\">" : ""
        let html = "<!doctype html>" +
            "<html lang=\"en\"><head>" +
            "<meta charset=\"utf-8\">" +
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">" +
            reload +
            "<title>Sharedesk sign-in</title>" +
            "</head><body>" +
            "<h1>Sharedesk sign-in</h1>" +
            "<p>\(message)</p>" +
            "</body></html>"
        client.respond(type: "text/html; charset=utf-8", body: Data(html.utf8), extra: browserHeaders)
    }
}

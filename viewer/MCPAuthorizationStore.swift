import Foundation
import Security
import SharedeskMCPKeychain

// This is separate from VNC passwords. One non-synchronizing Keychain item
// contains the OAuth signing key and at most eight remembered approvals.
struct MCPAuthorizationState: Codable {
    var signingKey: Data
    var grants: [MCPAuthorizationGrant]
}

struct MCPAuthorizationGrant: Codable {
    let id: UUID
    let expiresAt: Date
    var generation: UInt64
    var rotatedAt: Date
}

@MainActor
enum MCPAuthorizationStore {
    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "net.sharedesk.viewer.mcp-authorization",
            kSecAttrAccount as String: MCPAuthorization.resource,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: false
        ]
    }

    // Only explicit Start may show a Keychain authorization dialog. Calls
    // triggered by HTTP use save(), which fails rather than opening a dialog.
    static func read() throws -> MCPAuthorizationState? {
        var attributes = query
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        attributes[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw MCPAuthorizationError.keychain(status)
        }

        let invalidItem = MCPAuthorizationError.message(
            "The MCP Keychain item is invalid. It was not overwritten. " +
            "Remove only Sharedesk MCP Authorization in Keychain Access to authorize clients again."
        )
        guard let data = result as? Data,
              data.count <= 16 * 1024,
              let state = try? JSONDecoder().decode(MCPAuthorizationState.self, from: data) else {
            throw invalidItem
        }

        // Check the decoded record before exposing any saved authorization.
        guard state.signingKey.count == 32,
              state.grants.count <= 8,
              Set(state.grants.map(\.id)).count == state.grants.count,
              state.grants.allSatisfy({ grant in
                  grant.expiresAt.timeIntervalSince1970.isFinite &&
                  grant.rotatedAt.timeIntervalSince1970.isFinite &&
                  grant.generation < UInt64.max
              }) else {
            throw invalidItem
        }
        return state
    }

    static func save(_ state: MCPAuthorizationState, creating: Bool = false) throws {
        let data = try JSONEncoder().encode(state)
        var attributes = query
        if creating {
            attributes[kSecAttrLabel as String] = "Sharedesk MCP Authorization"
        }
        let status = sd_mcp_keychain_write(attributes as CFDictionary, data as CFData, creating)
        guard status == errSecSuccess else {
            throw MCPAuthorizationError.keychain(status)
        }
    }
}

enum MCPAuthorizationError: Error, LocalizedError {
    case message(String)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .keychain(let status):
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "MCP Keychain access failed: \(reason)"
        }
    }
}

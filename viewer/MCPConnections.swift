import Foundation

// Only IDs and display names cross the MCP boundary. Endpoint settings and
// credential references remain owned by the viewer's existing profile store.
struct MCPConnectionProfile {
    let id: UUID
    let name: String
}

enum MCPConnectionRequest {
    case connectProfile(UUID)
    case disconnectConnection(UUID)
    case reconnectConnection(UUID)
}

struct MCPConnectionError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum MCPConnections {
    static let names: Set<String> = [
        "connect_profile", "disconnect_connection", "reconnect_connection"
    ]

    static var tools: [[String: Any]] {
        [
            [
                "name": "list_connection_profiles",
                "description": "List saved profile IDs and names, without addresses, passwords or credential references. " +
                    "Profile names may contain private information. Does not connect or change settings.",
                "inputSchema": ["type": "object", "additionalProperties": false],
                "annotations": [
                    "readOnlyHint": true, "destructiveHint": false,
                    "idempotentHint": true, "openWorldHint": false
                ]
            ],
            tool(
                "connect_profile", argument: "profile_id",
                description: "Start one connection to a saved profile while the viewer is disconnected. " +
                    "Uses only its endpoint-matched Keychain password; local approval must already be available. " +
                    "Cannot replace a connecting, connected or disconnecting session."
            ),
            tool(
                "disconnect_connection", argument: "connection_id",
                description: "Disconnect or cancel the exact current connection. " +
                    "Copy connection_id from current status, including while connecting. " +
                    "This also disconnects the user's visible desktop."
            ),
            tool(
                "reconnect_connection", argument: "connection_id",
                description: "Retry the last connection only after it has ended, using the same saved profile. " +
                    "Copy the last connection_id from status. Rejects changed profile selection or endpoint. " +
                    "Disconnect an active connection explicitly first. There is no automatic retry loop."
            )
        ]
    }

    private static func tool(_ name: String, argument: String, description: String) -> [String: Any] {
        [
            "name": name,
            "description": description + " Requires the viewer's Allow MCP Connection Management switch. " +
                "Returns acceptance, not connection completion; poll get_connection_status. " +
                "New connections have clipboard sharing and mouse/keyboard control off.",
            "inputSchema": [
                "type": "object",
                "properties": [argument: ["type": "string", "format": "uuid"]],
                "required": [argument], "additionalProperties": false
            ],
            "annotations": [
                "readOnlyHint": false, "destructiveHint": true,
                "idempotentHint": false, "openWorldHint": true
            ]
        ]
    }

    static func request(tool name: String, arguments: [String: Any]) throws -> MCPConnectionRequest {
        let argument = name == "connect_profile" ? "profile_id" : "connection_id"
        guard names.contains(name), Set(arguments.keys) == Set([argument]),
              let text = arguments[argument] as? String, let id = UUID(uuidString: text) else {
            throw MCPConnectionError(message: "Supply only a valid \(argument) UUID from current status or the profile list.")
        }
        switch name {
        case "connect_profile": return .connectProfile(id)
        case "disconnect_connection": return .disconnectConnection(id)
        default: return .reconnectConnection(id)
        }
    }
}

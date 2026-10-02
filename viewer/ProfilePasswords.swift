import Foundation
import Security

// Keychain items are scoped to this viewer, an immutable credential reference,
// and the exact endpoint. New passwords get new references, so a failed profile
// file write cannot overwrite the password used by the previous saved profile.
// Calls are main-thread-only and may block for a macOS authorization dialog.
@MainActor
enum ProfilePasswords {
    static let service = "net.sharedesk.viewer.vnc-password"

    static func save(_ password: String, reference: UUID, target: ConnectionTarget) throws {
        guard validVNCPassword(password) else { throw PasswordError.invalidPassword }
        var attributes = query(reference: reference, target: target)
        attributes[kSecAttrLabel as String] = "Sharedesk VNC (\(target.host):\(target.port))"
        attributes[kSecValueData as String] = Data(password.utf8)
        let result = SecItemAdd(attributes as CFDictionary, nil)
        guard result == errSecSuccess else { throw PasswordError.keychain(result) }
    }

    static func read(reference: UUID, target: ConnectionTarget) throws -> String {
        var query = query(reference: reference, target: target)
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var data: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &data)
        guard result == errSecSuccess else { throw PasswordError.keychain(result) }
        guard let bytes = data as? Data, let password = String(data: bytes, encoding: .ascii), validVNCPassword(password) else {
            throw PasswordError.invalidPassword
        }
        return password
    }

    static func remove(reference: UUID, target: ConnectionTarget) throws {
        let result = SecItemDelete(query(reference: reference, target: target) as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw PasswordError.keychain(result) }
    }

    private static func query(reference: UUID, target: ConnectionTarget) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "\(reference.uuidString)@\(target.host):\(target.port)"]
    }
}

enum PasswordError: Error, LocalizedError {
    case invalidPassword, keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidPassword: return "Use a VNC password with 1–8 printable ASCII characters, without spaces."
        case .keychain(let status):
            if status == errSecItemNotFound { return "The saved password is missing from Keychain. Enter it again or edit the profile." }
            if status == errSecUserCanceled { return "Keychain access was cancelled." }
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return "Keychain could not complete the operation: \(reason)"
        }
    }
}

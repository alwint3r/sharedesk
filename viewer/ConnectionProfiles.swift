import Darwin
import Foundation

struct ConnectionTarget: Codable, Equatable, Sendable {
    let host: String
    let port: Int

    init(host: String, portText: String) throws {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        let ip = host.withCString { inet_pton(AF_INET, $0, &address) == 1 ? UInt32(bigEndian: address.s_addr) : 0 }
        let scanner = Scanner(string: portText)
        guard ip & 0xffc00000 == 0x64400000 || ip & 0xff000000 == 0x7f000000,
              let port = scanner.scanInt(), scanner.isAtEnd, (1...65535).contains(port) else {
            throw ProfileError.invalidTarget
        }
        self.host = host
        self.port = port
    }

    private enum CodingKeys: CodingKey { case host, port }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(host: values.decode(String.self, forKey: .host),
                      portText: String(values.decode(Int.self, forKey: .port)))
    }
}

func validVNCPassword(_ password: String) -> Bool {
    guard let ascii = password.data(using: .ascii, allowLossyConversion: false) else { return false }
    return (1...8).contains(ascii.count) && ascii.allSatisfy { (33...126).contains($0) }
}

struct ConnectionProfile: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let target: ConnectionTarget
    let shareClipboard: Bool
    // A reference to a Keychain item, never the password itself.
    let passwordReference: UUID?

    init(id: UUID = UUID(), name: String, target: ConnectionTarget, shareClipboard: Bool, passwordReference: UUID?) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, name.rangeOfCharacter(from: .controlCharacters.union(.newlines)) == nil else {
            throw ProfileError.invalidName
        }
        self.id = id
        self.name = name
        self.target = target
        self.shareClipboard = shareClipboard
        self.passwordReference = passwordReference
    }

    private enum CodingKeys: CodingKey { case id, name, target, shareClipboard, passwordReference }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: values.decode(UUID.self, forKey: .id), name: values.decode(String.self, forKey: .name),
                      target: values.decode(ConnectionTarget.self, forKey: .target),
                      shareClipboard: values.decode(Bool.self, forKey: .shareClipboard),
                      passwordReference: values.decodeIfPresent(UUID.self, forKey: .passwordReference))
    }
}

enum ProfileError: Error, LocalizedError {
    case invalidTarget, invalidName, duplicateName, invalidDocument, unavailable, changedOnDisk, insecureFile, tooLarge

    var errorDescription: String? {
        switch self {
        case .invalidTarget: "Use a Tailscale/loopback IPv4 and a port from 1 to 65535."
        case .invalidName: "Use a profile name from 1 to 80 characters, without control characters."
        case .duplicateName: "Another profile already has that name. Choose a different name."
        case .invalidDocument: "The profile file contains duplicate identifiers or names. It was not changed."
        case .unavailable: "Profiles could not be loaded. The existing file will not be overwritten."
        case .changedOnDisk: "The profile file changed outside this window. Reopen Sharedesk to load it before editing."
        case .insecureFile: "The profile directory and file must be owned by you, private, and not symbolic links. Use permissions 700 for the directory and 600 for the file."
        case .tooLarge: "The profile file exceeds the 1 MiB limit. It was not changed."
        }
    }
}

// Main-thread-owned settings. The last disk bytes detect external changes;
// malformed or unreadable files are never silently replaced with an empty list.
@MainActor
final class ConnectionProfileStore {
    let fileURL: URL
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var loaded = false
    private var diskBytes: Data?

    init(fileURL: URL) { self.fileURL = fileURL }

    func load() throws {
        loaded = false
        let bytes = try readFile()
        let profiles = try bytes.map { try JSONDecoder().decode([ConnectionProfile].self, from: $0) } ?? []
        guard Set(profiles.map(\.id)).count == profiles.count,
              Set(profiles.map { $0.name.lowercased() }).count == profiles.count,
              Set(profiles.compactMap(\.passwordReference)).count == profiles.compactMap(\.passwordReference).count else {
            throw ProfileError.invalidDocument
        }
        self.profiles = profiles.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        diskBytes = bytes
        loaded = true
    }

    func check(_ profile: ConnectionProfile) throws {
        guard loaded else { throw ProfileError.unavailable }
        guard !profiles.contains(where: { $0.id != profile.id && $0.name.lowercased() == profile.name.lowercased() }) else {
            throw ProfileError.duplicateName
        }
    }

    func upsert(_ profile: ConnectionProfile) throws {
        try check(profile)
        var updated = profiles.filter { $0.id != profile.id }
        updated.append(profile)
        updated.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        try write(updated)
    }

    func remove(id: UUID) throws {
        try write(profiles.filter { $0.id != id })
    }

    private func readFile() throws -> Data? {
        let directory = fileURL.deletingLastPathComponent().path
        var info = stat()
        if lstat(directory, &info) != 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ProfileError.insecureFile
        }
        let descriptor = open(fileURL.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = close(descriptor) }
        guard fstat(descriptor, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw ProfileError.insecureFile
        }
        guard info.st_size <= 1 << 20 else { throw ProfileError.tooLarge }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { break }
            guard data.count + count <= 1 << 20 else { throw ProfileError.tooLarge }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func write(_ updated: [ConnectionProfile]) throws {
        guard loaded else { throw ProfileError.unavailable }
        guard try readFile() == diskBytes else { throw ProfileError.changedOnDisk }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        guard data.count <= 1 << 20 else { throw ProfileError.tooLarge }
        let directory = fileURL.deletingLastPathComponent().path
        if mkdir(directory, 0o700) != 0 && errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw ProfileError.insecureFile }
        var template = Array((directory + "/.profiles-XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let temporaryPath = template.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        defer { _ = close(descriptor); _ = unlink(temporaryPath) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard rename(temporaryPath, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        diskBytes = data
        profiles = updated
    }
}

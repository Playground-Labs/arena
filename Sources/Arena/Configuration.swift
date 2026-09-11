import Foundation
import Security
import Darwin

struct ArenaConfiguration {
    let directory: URL
    let port: Int
    let token: String
    let headless: Bool
    let fixturePath: String?
    private let directoryLock: ArenaDirectoryLock

    static func load() throws -> ArenaConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let manager = FileManager.default
        let directory: URL
        if let explicit = environment["ARENA_DATA_DIR"] {
            directory = URL(fileURLWithPath: explicit, isDirectory: true)
        } else if environment["CONDUCTOR_PORT"] != nil {
            let workspace = environment["CONDUCTOR_WORKSPACE_PATH"] ?? manager.currentDirectoryPath
            directory = URL(fileURLWithPath: workspace).appendingPathComponent(".context/arena-data", isDirectory: true)
        } else {
            directory = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                        appropriateFor: nil, create: true).appendingPathComponent("Arena", isDirectory: true)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let directoryLock = try ArenaDirectoryLock(directory: directory)
        let portText = environment["ARENA_PORT"] ?? environment["CONDUCTOR_PORT"] ?? "42424"
        guard let port = Int(portText), (1024...65535).contains(port) else {
            throw ConfigurationError.message("Arena’s port must be a number from 1024 to 65535.")
        }
        let tokenURL = directory.appendingPathComponent("service-token")
        let token: String
        if manager.fileExists(atPath: tokenURL.path) {
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.count == 64, token.allSatisfy({ $0.isHexDigit }) else {
                throw ConfigurationError.message("The saved MCP token is invalid: \(tokenURL.path)")
            }
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw ConfigurationError.message("Could not create a secure MCP token.")
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            try Data(token.utf8).write(to: tokenURL, options: .atomic)
        }
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
        return ArenaConfiguration(directory: directory, port: port, token: token,
                                  headless: environment["ARENA_HEADLESS"] == "1",
                                  fixturePath: environment["ARENA_FIXTURE_PATH"], directoryLock: directoryLock)
    }
}

enum ConfigurationError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
}

private final class ArenaDirectoryLock {
    private let descriptor: Int32

    init(directory: URL) throws {
        descriptor = open(directory.appendingPathComponent("arena.lock").path, O_CREAT | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw ConfigurationError.message("Cannot open Arena’s data directory lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ConfigurationError.message("Arena is already using this data directory. Open its existing window or quit that instance first.")
        }
    }

    deinit {
        if descriptor >= 0 { flock(descriptor, LOCK_UN); close(descriptor) }
    }
}

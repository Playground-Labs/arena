import CryptoKit
import Foundation
import Observation

/// Client tools own parsing and writing their configuration; Arena never edits TOML.
@MainActor @Observable
final class ClientSetup {
    enum Client: String, CaseIterable { case codex = "Codex", claude = "Claude Code" }
    enum SettingsTab: String, CaseIterable { case general = "General", agents = "Agents", advanced = "Advanced" }
    var showingSettings = false
    var settingsTab: SettingsTab = .general
    private(set) var status: [Client: String] = [:]
    private(set) var configured: Set<Client> = []
    private(set) var busy: Set<Client> = []
    private(set) var installedSkills: Set<Client> = []
    private(set) var skillErrors: [Client: String] = [:]
    private(set) var justInstalled: Set<Client> = []
    let name = "arena"
    let legacyName: String
    let endpoint: String
    private let token: String
    private let environment: [String: String]

    init(directory: URL, endpoint: String, token: String,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        legacyName = "arena-" + SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        self.endpoint = endpoint
        self.token = token
        self.environment = environment
    }

    func executable(_ client: Client) -> URL? {
        let command = client == .codex ? "codex" : "claude"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init) +
            [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/Applications/Codex.app/Contents/Resources"]
        return paths.filter { $0.hasPrefix("/") }.map { URL(fileURLWithPath: $0).appendingPathComponent(command) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    var jsonConfiguration: String {
        let data = try! JSONSerialization.data(withJSONObject: ["mcpServers": [name: claudeEntry]], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    var codexConfiguration: String {
        "[mcp_servers.\(name)]\nurl = \"\(endpoint)\"\nhttp_headers = { Authorization = \"Bearer \(token)\" }"
    }
    private var claudeEntry: [String: Any] { ["type": "http", "url": endpoint, "headers": ["Authorization": "Bearer \(token)"]] }
    private var codexEntry: [String: Any] { ["url": endpoint, "http_headers": ["Authorization": "Bearer \(token)"]] }

    func refresh() async {
        refreshSkills()
        for client in Client.allCases { await perform(client, install: false, verify: false) }
    }

    func skillDirectory(_ client: Client) -> URL {
        let key = client == .codex ? "CODEX_HOME" : "CLAUDE_CONFIG_DIR"
        let fallback = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(client == .codex ? ".codex" : ".claude")
        return (environment[key].map { URL(fileURLWithPath: $0) } ?? fallback).appendingPathComponent("skills/arena")
    }

    func refreshSkills() {
        for client in Client.allCases {
            installedSkills.remove(client)
            skillErrors.removeValue(forKey: client)
            do { if try ArenaSkill.isInstalled(at: skillDirectory(client)) { installedSkills.insert(client) } }
            catch { skillErrors[client] = error.localizedDescription }
            if !installedSkills.contains(client) { justInstalled.remove(client) }
        }
    }

    func installSkill(_ client: Client) {
        do {
            try ArenaSkill.install(at: skillDirectory(client))
            refreshSkills()
            guard installedSkills.contains(client) else { return }
            justInstalled.insert(client)
            Task { try? await Task.sleep(for: .seconds(2.5)); justInstalled.remove(client) }
        } catch { skillErrors[client] = error.localizedDescription }
    }
    func setUp(_ client: Client) async { await perform(client, install: true, verify: true) }
    func verify(_ client: Client) async { await perform(client, install: false, verify: true) }

    private func perform(_ client: Client, install: Bool, verify: Bool) async {
        guard busy.insert(client).inserted else { return }
        defer { busy.remove(client) }
        guard let executable = executable(client) else {
            configured.remove(client)
            status[client] = "CLI not found · use manual setup"
            return
        }
        configured.remove(client)
        status[client] = install ? "Setting up…" : "Checking…"
        do {
            let found = try await client == .codex ? configureCodex(executable, install: install) : configureClaude(executable, install: install)
            guard found else {
                configured.remove(client)
                status[client] = "Not configured"
                return
            }
            configured.insert(client)
            if verify {
                do { try await probe() }
                catch is CancellationError { throw CancellationError() }
                catch { throw ConfigurationError.message("Configured · Arena unreachable; refresh to retry") }
            }
            status[client] = "Ready · reconnect \(client.rawValue)"
        } catch is CancellationError {
            status[client] = "Check cancelled · retry to confirm setup"
        } catch {
            status[client] = (error as? ConfigurationError)?.localizedDescription ?? "Setup failed · retry or use manual setup"
        }
    }

    private func matches(_ entry: [String: Any], headers: String) -> Bool {
        entry["url"] as? String == endpoint &&
        (entry[headers] as? [String: String])?["Authorization"] == "Bearer \(token)" &&
        entry["enabled"] as? Bool != false && entry["command"] == nil &&
        entry["bearer_token_env_var"] == nil && entry["env_http_headers"] == nil
    }

    /// A stale entry another local Arena instance wrote: our shape, someone else’s port or token.
    /// Explicit setup may replace one; anything else stays a conflict the user resolves manually.
    private func replaceable(_ entry: [String: Any], headers: String) -> Bool {
        guard entry["command"] == nil, entry["bearer_token_env_var"] == nil, entry["env_http_headers"] == nil,
              let url = (entry["url"] as? String).flatMap(URLComponents.init(string:)),
              url.scheme == "http", url.path == "/mcp",
              ["127.0.0.1", "localhost", "::1"].contains(url.host ?? ""),
              let authorization = (entry[headers] as? [String: String])?["Authorization"] else { return false }
        return authorization.hasPrefix("Bearer ") && authorization.count > "Bearer ".count
    }

    private let replaceableStatus = "Another Arena instance · Set Up to replace"
    private let conflictStatus = "Conflicting registration · review manual setup"

    private func configureCodex(_ executable: URL, install: Bool) async throws -> Bool {
        let process = try SetupProcess(executable: executable, arguments: ["app-server"], environment: environment)
        defer { process.close() }
        _ = try await process.rpc("initialize", params: ["clientInfo": ["name": "arena_setup", "version": "1.0"]])
        let read = try await process.rpc("config/read", params: ["includeLayers": true])
        let effective = (read["config"] as? [String: Any])?["mcp_servers"] as? [String: Any] ?? [:]
        var stale = false
        if let existing = effective[name] {
            let entry = existing as? [String: Any] ?? [:]
            if !matches(entry, headers: "http_headers") {
                guard replaceable(entry, headers: "http_headers") else { throw ConfigurationError.message(conflictStatus) }
                guard install else { throw ConfigurationError.message(replaceableStatus) }
                stale = true
            }
        }
        let layer = (read["layers"] as? [[String: Any]])?.first(where: {
            let source = $0["name"] as? [String: Any]
            return source?["type"] as? String == "user" && (source?["profile"] == nil || source?["profile"] is NSNull)
        })
        var stored = (layer?["config"] as? [String: Any])?["mcp_servers"] as? [String: Any] ?? [:]
        let legacy = (stored[legacyName] as? [String: Any]).map { matches($0, headers: "http_headers") } == true &&
            (effective[legacyName] as? [String: Any]).map { matches($0, headers: "http_headers") } == true
        if effective[name] != nil && !legacy && !stale { return true }
        guard install || legacy else { return false }
        guard let version = layer?["version"] as? String,
              let path = (layer?["name"] as? [String: Any])?["file"] as? String else {
            throw ConfigurationError.message("Update Codex or use manual setup")
        }
        // Rename only this instance's user entry, atomically with the client's version check.
        if let existing = stored[name] {
            let entry = existing as? [String: Any] ?? [:]
            if !matches(entry, headers: "http_headers") {
                guard install, replaceable(entry, headers: "http_headers") else { throw ConfigurationError.message(conflictStatus) }
                stored[name] = codexEntry
            }
        } else { stored[name] = codexEntry }
        if legacy { stored.removeValue(forKey: legacyName) }
        _ = try await process.rpc("config/value/write", params: ["keyPath": "mcp_servers", "value": stored,
            "mergeStrategy": "replace", "expectedVersion": version, "filePath": path])
        let saved = try await process.rpc("config/read", params: ["includeLayers": false])
        guard let entry = ((saved["config"] as? [String: Any])?["mcp_servers"] as? [String: Any])?[name] as? [String: Any],
              matches(entry, headers: "http_headers") else { throw ConfigurationError.message("Configuration overridden · review Codex settings") }
        return true
    }

    private func configureClaude(_ executable: URL, install: Bool) async throws -> Bool {
        let directory = environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
        let file = directory.appendingPathComponent(".claude.json")
        func registrations() throws -> [String: Any] {
            guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
            let data = try Data(contentsOf: file)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigurationError.message("Claude configuration is invalid · review manual setup")
            }
            return root["mcpServers"] as? [String: Any] ?? [:]
        }
        func valid(_ entry: Any?) -> Bool {
            guard let entry = entry as? [String: Any] else { return false }
            return matches(entry, headers: "headers") && entry["type"] as? String == "http"
        }
        let entries = try registrations()
        var stale = false
        if let existing = entries[name], !valid(existing) {
            let entry = existing as? [String: Any] ?? [:]
            guard entry["type"] as? String == "http", replaceable(entry, headers: "headers") else {
                throw ConfigurationError.message(conflictStatus)
            }
            guard install else { throw ConfigurationError.message(replaceableStatus) }
            stale = true
        }
        let legacy = valid(entries[legacyName])
        if entries[name] == nil || stale {
            guard install || legacy else { return false }
            // `mcp add-json` cannot overwrite, so the stale entry is retired through the CLI first.
            if stale {
                let remove = try SetupProcess(executable: executable, arguments: ["mcp", "remove", "--scope", "user", name], environment: environment)
                defer { remove.close() }
                try await remove.wait()
            }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: claudeEntry), as: UTF8.self)
            let process = try SetupProcess(executable: executable, arguments: ["mcp", "add-json", "--scope", "user", name, json], environment: environment)
            defer { process.close() }
            try await process.wait()
        }
        guard valid(try registrations()[name]) else { throw ConfigurationError.message("Couldn’t verify saved Claude configuration") }
        // The new name is saved before retiring our exact old entry. Never remove another instance.
        if legacy, valid(try registrations()[legacyName]) {
            let process = try SetupProcess(executable: executable, arguments: ["mcp", "remove", "--scope", "user", legacyName], environment: environment)
            defer { process.close() }
            try await process.wait()
            guard try registrations()[legacyName] == nil else { throw ConfigurationError.message("Couldn’t retire old registration · refresh to retry") }
        }
        return true
    }

    /// A successful probe verifies Arena, not whether an external agent has reconnected.
    private func probe() async throws {
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"arena-setup-check","version":"1.0"}}}"#.utf8)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") {
            var close = request
            close.httpMethod = "DELETE"; close.httpBody = nil
            close.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
            _ = try? await session.data(for: close)
        }
        let payload = String(decoding: data, as: UTF8.self).split(separator: "\n").last(where: { $0.hasPrefix("data:") && !$0.dropFirst(5).trimmingCharacters(in: .whitespaces).isEmpty })
            .map { Data($0.dropFirst(5).trimmingCharacters(in: .whitespaces).utf8) } ?? data
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let result = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any], result["result"] != nil else {
            throw ConfigurationError.message("Configured · Arena unreachable; refresh to retry")
        }
    }
}

/// Bounded, cancellable CLI calls. Output stays private and is never included in UI errors.
@MainActor
final class SetupProcess {
    private let process = Process()
    private let input = Pipe()
    private let directory: URL
    private let output: FileHandle
    private var nextID = 0
    private var offset = 0
    private let deadline: ContinuousClock.Instant

    init(executable: URL, arguments: [String], environment: [String: String], timeout: Duration = .seconds(20)) throws {
        deadline = .now.advanced(by: timeout)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("arena-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("output")
        FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
        output = try FileHandle(forUpdating: file)
        process.executableURL = executable; process.arguments = arguments; process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { close(); throw error }
    }

    func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
        // Reap a stuck child without blocking the UI. Only this owned process can be killed.
        let child = process
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
        try? output.close()
        try? FileManager.default.removeItem(at: directory)
    }

    private func pause() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw ConfigurationError.message("Client timed out · retry or use manual setup") }
        let size = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("output").path)[.size] as? NSNumber
        guard (size?.intValue ?? 0) <= 4_194_304 else { throw ConfigurationError.message("Client output too large · use manual setup") }
        try await Task.sleep(for: .milliseconds(50))
    }

    func wait() async throws {
        while process.isRunning { try await pause() }
        try Task.checkCancellation()
        guard process.terminationStatus == 0 else { throw ConfigurationError.message("Client rejected setup · retry or use manual setup") }
    }

    func rpc(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        nextID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": nextID, "method": method, "params": params])
        data.append(10)
        try input.fileHandleForWriting.write(contentsOf: data)
        while true {
            try await pause()
            // Independent read handle: seeking must not change the child’s output offset.
            let bytes = try Data(contentsOf: directory.appendingPathComponent("output"))
            while let newline = bytes[offset...].firstIndex(of: 10) {
                let line = bytes[offset..<newline]; offset = newline + 1
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      response["id"] as? Int == nextID else { continue }
                guard response["error"] == nil, let result = response["result"] as? [String: Any] else {
                    throw ConfigurationError.message("Codex rejected configuration · update or use manual setup")
                }
                return result
            }
            guard process.isRunning else { throw ConfigurationError.message("Codex exited · update or use manual setup") }
        }
    }
}

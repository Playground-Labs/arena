import XCTest
@testable import Arena

@MainActor
final class ClientSetupTests: XCTestCase {
    func testRealClientRegistrationPreservesConfigAndRejectsConflicts() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arena-setup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = directory.path
        environment["CLAUDE_CONFIG_DIR"] = directory.path
        let setup = ClientSetup(directory: directory, endpoint: "http://127.0.0.1:19429/mcp", token: "test-token", environment: environment)
        guard ClientSetup.Client.allCases.allSatisfy({ setup.executable($0) != nil }) else { throw XCTSkip("Install Codex and Claude Code CLIs for setup integration coverage") }
        let codexFile = directory.appendingPathComponent("config.toml")
        try Data("# Preserve this comment\n[mcp_servers.unrelated]\nurl = \"http://localhost:9876/mcp\"\n".utf8).write(to: codexFile)
        let claudeFile = directory.appendingPathComponent(".claude.json")
        try Data(#"{"customSetting":"keep","mcpServers":{"unrelated":{"type":"http","url":"http://localhost:9876/mcp"}}}"#.utf8).write(to: claudeFile)
        let store = try ArenaStore(directory: directory.appendingPathComponent("store"), inMemory: true)
        let service = MCPService(store: store, port: 19429, token: "test-token")
        service.start()
        for _ in 0..<100 where service.state != "Listening" { try await Task.sleep(for: .milliseconds(20)) }
        for client in ClientSetup.Client.allCases {
            await setup.setUp(client)
            XCTAssertTrue(setup.configured.contains(client), setup.status[client] ?? "missing status")
            XCTAssertTrue(setup.status[client]?.hasPrefix("Ready") == true, setup.status[client] ?? "missing status")
            await setup.setUp(client)
            XCTAssertTrue(setup.status[client]?.hasPrefix("Ready") == true, setup.status[client] ?? "missing status")
        }
        XCTAssertTrue(service.clientActivity.isEmpty, "Setup probes must not appear as client connections")
        // Simulate upgrading an existing installation, then exercise automatic migration.
        let oldCodex = try String(contentsOf: codexFile, encoding: .utf8)
            .replacingOccurrences(of: "[mcp_servers.arena", with: "[mcp_servers.\(setup.legacyName)")
        try Data(oldCodex.utf8).write(to: codexFile)
        var oldClaude = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeFile)) as! [String: Any]
        var servers = oldClaude["mcpServers"] as! [String: Any]
        servers[setup.legacyName] = servers.removeValue(forKey: setup.name)
        oldClaude["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: oldClaude).write(to: claudeFile)
        await setup.refresh()
        XCTAssertEqual(setup.configured, Set(ClientSetup.Client.allCases))
        XCTAssertFalse(try String(contentsOf: codexFile, encoding: .utf8).contains(setup.legacyName))
        XCTAssertFalse(try String(contentsOf: claudeFile, encoding: .utf8).contains(setup.legacyName))
        await service.stop()
        await setup.verify(.codex)
        XCTAssertTrue(setup.configured.contains(.codex))
        XCTAssertTrue(setup.status[.codex]?.contains("unreachable") == true)
        let codex = try String(contentsOf: codexFile, encoding: .utf8)
        XCTAssertTrue(codex.contains("# Preserve this comment"))
        XCTAssertTrue(codex.contains("mcp_servers.unrelated"))
        XCTAssertEqual(codex.components(separatedBy: "[mcp_servers.\(setup.name)]").count, 2)
        let claude = try JSONSerialization.jsonObject(with: Data(contentsOf: claudeFile)) as! [String: Any]
        XCTAssertEqual(claude["customSetting"] as? String, "keep")
        XCTAssertNotNil((claude["mcpServers"] as? [String: Any])?["unrelated"])
        let before = [try Data(contentsOf: codexFile), try Data(contentsOf: claudeFile)]
        let conflict = ClientSetup(directory: directory, endpoint: setup.endpoint, token: "different-token", environment: environment)
        for client in ClientSetup.Client.allCases {
            await conflict.setUp(client)
            XCTAssertFalse(conflict.configured.contains(client))
            XCTAssertTrue(conflict.status[client]?.contains("Conflicting") == true)
        }
        XCTAssertEqual(before, [try Data(contentsOf: codexFile), try Data(contentsOf: claudeFile)])
        let other = ClientSetup(directory: directory.appendingPathComponent("other"), endpoint: setup.endpoint, token: "test")
        XCTAssertEqual(setup.name, "arena")
        XCTAssertEqual(setup.name, other.name)
        XCTAssertNotEqual(setup.legacyName, other.legacyName)
        let malformed = Data("{broken".utf8)
        try malformed.write(to: claudeFile)
        await setup.setUp(.claude)
        XCTAssertFalse(setup.configured.contains(.claude))
        XCTAssertEqual(try Data(contentsOf: claudeFile), malformed)
    }

    func testBundledSkillInstallationForBothClientsPreservesEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("arena-skill-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = ClientSetup(directory: root, endpoint: "http://127.0.0.1:19429/mcp", token: "test",
                                environment: ["CODEX_HOME": root.appendingPathComponent("codex").path,
                                              "CLAUDE_CONFIG_DIR": root.appendingPathComponent("claude").path])
        setup.refreshSkills()
        XCTAssertTrue(setup.installedSkills.isEmpty)
        XCTAssertTrue(setup.skillErrors.isEmpty, "Bundled resources must load in SwiftPM too")
        for client in ClientSetup.Client.allCases {
            setup.installSkill(client)
            XCTAssertTrue(setup.installedSkills.contains(client), setup.skillErrors[client] ?? "not installed")
            let skill = setup.skillDirectory(client).appendingPathComponent("SKILL.md")
            let content = try Data(contentsOf: skill)
            XCTAssertTrue(String(decoding: content, as: UTF8.self).contains("name: arena"))
            setup.installSkill(client)
            XCTAssertEqual(try Data(contentsOf: skill), content)
            let custom = Data("My customized skill".utf8)
            try custom.write(to: skill)
            setup.refreshSkills()
            XCTAssertFalse(setup.installedSkills.contains(client))
            setup.installSkill(client)
            XCTAssertNotNil(setup.skillErrors[client])
            XCTAssertEqual(try Data(contentsOf: skill), custom)
        }
    }

    func testSetupProcessTimeoutAndCancellation() async throws {
        let process = try SetupProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:], timeout: .milliseconds(100))
        defer { process.close() }
        do { try await process.wait(); XCTFail("Expected timeout") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        let cancelled = try SetupProcess(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], environment: [:])
        defer { cancelled.close() }
        let task = Task { try await cancelled.wait() }
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}

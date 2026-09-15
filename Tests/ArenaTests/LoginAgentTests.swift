import ServiceManagement
import XCTest
@testable import Arena

@MainActor
final class LoginAgentTests: XCTestCase {
    func testTurningOnStartAtLoginWithoutAnInstalledLaunchAgentExplainsTheFailure() throws {
        guard SMAppService.agent(plistName: "local.arena.app.agent.plist").status != .enabled else {
            throw XCTSkip("Arena’s login item is already registered for this bundle")
        }
        let agent = LoginAgent()
        XCTAssertFalse(agent.enabled, agent.status ?? "missing status")
        XCTAssertFalse(agent.needsApproval)
        XCTAssertNil(agent.status, "An unregistered login item is an ordinary off state, not an error")
        agent.setEnabled(true)
        XCTAssertFalse(agent.enabled, agent.status ?? "missing status")
        XCTAssertTrue(agent.status?.hasPrefix("Couldn’t turn on start at login") ?? false,
                      "A failed registration must explain itself, got: \(agent.status ?? "nil")")
        agent.setEnabled(false)
        XCTAssertFalse(agent.enabled, agent.status ?? "missing status")
        XCTAssertNil(agent.status, "Turning off a login item launchd never registered is not a failure")
    }
}

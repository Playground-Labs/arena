import Observation
import ServiceManagement

// ponytail: RunAtLoad — polling-free, but Arena stays resident rather than socket-activated.
// Upgrade path if residency costs: launchd holds 42424 and starts Arena on first connect; blocked until Hummingbird 2 adopts a pre-bound socket fd.
@MainActor @Observable
final class LoginAgent {
    private(set) var enabled = false
    private(set) var needsApproval = false
    private(set) var status: String?
    private let service = SMAppService.agent(plistName: "local.arena.app.agent.plist")

    init() { refresh() }

    func refresh() {
        switch service.status {
        case .enabled:
            enabled = true; needsApproval = false; status = nil
        case .requiresApproval:
            // Disabled in System Settings means Arena will not start at login, whatever the toggle would like.
            enabled = false; needsApproval = true
            status = "Waiting for approval · allow Arena in System Settings → General → Login Items"
        default:
            enabled = false; needsApproval = false; status = nil
        }
    }

    func setEnabled(_ on: Bool) {
        do {
            if on { try service.register() } else { try service.unregister() }
            refresh()
        } catch {
            // refresh() first so enabled/needsApproval follow launchd, then keep the error visible.
            refresh()
            // unregister() throws EINVAL when launchd has no such job — the toggle is already off, so that is success.
            guard on || enabled || needsApproval else { return }
            let reason = (error as NSError).localizedFailureReason ?? error.localizedDescription
            status = on ? "Couldn’t turn on start at login · \(reason)"
                        : "Couldn’t turn off start at login · \(reason)"
        }
    }

    func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}

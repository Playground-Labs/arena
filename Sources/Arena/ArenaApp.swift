import AppKit
import Sparkle
import SwiftUI

enum ArenaAppearance: String, CaseIterable {
    case system, light, dark
    var appKitAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
@Observable
final class ArenaRuntime {
    var store: ArenaStore?
    var service: MCPService?
    var configuration: ArenaConfiguration?
    var clientSetup: ClientSetup?
    var startupError: String?
    var isQuitting = false
    let loginAgent = LoginAgent()
    let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    private var retentionTask: Task<Void, Never>?

    init() {
        do {
            let configuration = try ArenaConfiguration.load()
            self.configuration = configuration
            let store = try ArenaStore(directory: configuration.directory)
            self.store = store
            retentionTask = Task { [weak store] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    store?.maintainRetention()
                }
            }
            let service = MCPService(store: store, port: configuration.port, token: configuration.token)
            self.clientSetup = ClientSetup(directory: configuration.directory, endpoint: service.endpoint, token: configuration.token)
            self.service = service
            Task {
                do {
                    try await prepareSmokeFixture(store: store, configuration: configuration)
                    guard !isQuitting else { return }
                    service.start()
                } catch {
                    startupError = error.localizedDescription
                    self.store = nil
                    FileHandle.standardError.write(Data("Arena fixture failed: \(error.localizedDescription)\n".utf8))
                }
            }
        } catch {
            startupError = error.localizedDescription
            FileHandle.standardError.write(Data("Arena startup failed: \(error.localizedDescription)\n".utf8))
            if ProcessInfo.processInfo.environment["ARENA_HEADLESS"] == "1" { exit(1) }
        }
    }

    func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        retentionTask?.cancel()
        Task {
            await service?.stop()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
    }
}

@MainActor
final class ArenaApplicationDelegate: NSObject, NSApplicationDelegate {
    var runtime: ArenaRuntime?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let runtime else { return .terminateNow }
        runtime.quit()
        return .terminateLater
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Direct executable launches in development can retain macOS’s generic icon.
        NSApplication.shared.applicationIconImage = ArenaBrand.image(size: 512, appIcon: true)
        if runtime?.configuration?.headless == true {
            NSApplication.shared.setActivationPolicy(.accessory)
            NSApplication.shared.windows.forEach { $0.orderOut(nil) }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        !showArenaWindow()
    }
}

// canBecomeMain is false while a window is ordered out; .titled survives hiding and excludes the MenuBarExtra panel.
@MainActor func showArenaWindow() -> Bool {
    if NSApplication.shared.activationPolicy() != .regular { NSApplication.shared.setActivationPolicy(.regular) }
    guard let window = NSApplication.shared.windows.first(where: { $0.sheetParent == nil && $0.styleMask.contains(.titled) }) else { return false }
    window.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    return true
}

@main
struct ArenaApp: App {
    @NSApplicationDelegateAdaptor(ArenaApplicationDelegate.self) private var delegate
    @State private var runtime: ArenaRuntime
    @AppStorage("arenaAppearance") private var appearance: ArenaAppearance = .system

    init() {
        let runtime = ArenaRuntime()
        _runtime = State(initialValue: runtime)
        delegate.runtime = runtime
        if runtime.configuration?.headless == true {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    var body: some Scene {
        WindowGroup("Arena", id: "arena") {
            Group {
                if let store = runtime.store, let service = runtime.service,
                   let setup = runtime.clientSetup {
                    ArenaView(store: store, service: service, setup: setup, loginAgent: runtime.loginAgent, updater: runtime.updater.updater)
                } else {
                    ContentUnavailableView {
                        Label("Arena couldn’t start", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(runtime.startupError ?? "Loading local storage…").textSelection(.enabled)
                    }
                }
            }
            .frame(minWidth: 880, minHeight: 600)
            .tint(.orange)
            .onChange(of: appearance, initial: true) { _, choice in
                NSApplication.shared.appearance = choice.appKitAppearance
            }
            .onAppear {
                delegate.runtime = runtime
                if runtime.configuration?.headless == true {
                    NSApplication.shared.setActivationPolicy(.accessory)
                    NSApplication.shared.windows.forEach { $0.orderOut(nil) }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) { CheckForUpdatesView(updater: runtime.updater.updater) }
            CommandGroup(replacing: .appSettings) {
                if let setup = runtime.clientSetup { OpenArenaSettings(setup: setup).keyboardShortcut(",") }
            }
        }
        MenuBarExtra {
            ArenaMenu(runtime: runtime)
        } label: {
            Image(nsImage: ArenaBrand.menuIcon).accessibilityLabel("Arena")
        }
    }
}

private struct ArenaMenu: View {
    let runtime: ArenaRuntime
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(runtime.service?.state == "Listening" ? "Active" : runtime.service?.state ?? "Service unavailable")
        Button("Open Arena") {
            if !showArenaWindow() {
                openWindow(id: "arena")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        if let setup = runtime.clientSetup { OpenArenaSettings(setup: setup) }
        CheckForUpdatesView(updater: runtime.updater.updater)
        Divider()
        Button("Quit Arena") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
            .disabled(runtime.isQuitting)
    }
}

struct OpenArenaSettings: View {
    let setup: ClientSetup
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") {
            setup.showingConnection = false
            setup.showingSettings = true
            if !showArenaWindow() {
                openWindow(id: "arena")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }
}

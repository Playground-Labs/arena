import AppKit
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

    init() {
        do {
            let configuration = try ArenaConfiguration.load()
            self.configuration = configuration
            let store = try ArenaStore(directory: configuration.directory)
            self.store = store
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
        }
    }

    func quit() {
        guard !isQuitting else { return }
        isQuitting = true
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
            NSApplication.shared.windows.forEach { $0.close() }
        }
    }
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
                    ArenaView(store: store, service: service, setup: setup)
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
                    NSApplication.shared.windows.forEach { $0.close() }
                }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
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
        Text(runtime.service?.state ?? "Service unavailable")
        Button("Open Arena") {
            if let window = NSApplication.shared.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "arena")
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        if let setup = runtime.clientSetup { OpenArenaSettings(setup: setup) }
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
            if let window = NSApplication.shared.windows.first(where: { $0.canBecomeMain && $0.sheetParent == nil }) {
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "arena")
            }
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

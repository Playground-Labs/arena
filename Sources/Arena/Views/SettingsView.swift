import AppKit
import Sparkle
import SwiftUI

struct ArenaSettingsView: View {
    @Bindable var setup: ClientSetup
    let service: MCPService
    let loginAgent: LoginAgent
    let updater: SPUUpdater
    @AppStorage("arenaAppearance") private var appearance: ArenaAppearance = .system
    @Environment(\.dismiss) private var dismiss
    @State private var manualClient = "Codex"
    @State private var pageHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                }.buttonStyle(ArenaKeyboardButtonStyle(kind: .icon))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close Settings")
                    .help("Close Settings (Esc)")
            }.overlay { tabSwitcher }
                .padding(.horizontal, 20).frame(height: 52)
                .background(ArenaPalette.toolbar)
                .overlay(alignment: .bottom) { ArenaPalette.divider.frame(height: 1) }
            switch setup.settingsTab {
            case .general: page { general }
            case .agents: page { agents }
            case .advanced: page { advanced }
            }
        }
        .fixedSize(horizontal: false, vertical: true).frame(width: 520)
        .background(ArenaPalette.canvas)
        .foregroundStyle(ArenaPalette.text).font(.system(size: 13))
        .ignoresSafeArea()
        .task { await setup.refresh(); loginAgent.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refreshSkills(); loginAgent.refresh() }
    }

    private var tabSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(ClientSetup.SettingsTab.allCases, id: \.self) { tab in
                let active = setup.settingsTab == tab
                Button { setup.settingsTab = tab } label: {
                    Label(tab.rawValue, systemImage: icon(tab)).padding(.horizontal, 4).foregroundStyle(active ? ArenaPalette.text : ArenaPalette.secondary)
                }.buttonStyle(ArenaKeyboardButtonStyle(kind: .ghost))
                    .background { if active { RoundedRectangle(cornerRadius: 6).fill(ArenaPalette.tabSelected).shadow(color: .black.opacity(0.08), radius: 1, y: 1) } }
                    .accessibilityAddTraits(active ? .isSelected : [])
            }
        }.padding(4).background(ArenaPalette.navigationSelection, in: RoundedRectangle(cornerRadius: 9))
    }
    private func icon(_ tab: ClientSetup.SettingsTab) -> String {
        switch tab {
        case .general: "circle.lefthalf.filled"
        case .agents: "terminal"
        case .advanced: "slider.horizontal.3"
        }
    }
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView { content().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 } }
            .frame(height: min(max(pageHeight, 1), 540))
    }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(ArenaPalette.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ArenaPalette.divider, lineWidth: 1) }
    }
    private var rowDivider: some View { ArenaPalette.divider.opacity(0.5).frame(height: 0.5).padding(.horizontal, 12) }

    private var general: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance").font(.system(size: 14, weight: .semibold)).frame(height: 18)
            HStack(spacing: 12) {
                ForEach(ArenaAppearance.allCases, id: \.self) { choice in
                    Button { appearance = choice } label: {
                        VStack(spacing: 7) {
                            AppearanceMiniature(appearance: choice).frame(width: 120, height: 56).accessibilityHidden(true)
                            HStack(spacing: 3) {
                                if choice == appearance { Image(systemName: "checkmark").fontWeight(.semibold) }
                                Text(choice.rawValue.capitalized)
                            }.font(.system(size: 12)).frame(height: 16)
                        }
                        .frame(maxWidth: .infinity).frame(height: 94)
                        .background(choice == appearance ? ArenaPalette.fighterOne.opacity(0.07) : ArenaPalette.toolbar, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(choice == appearance ? ArenaPalette.fighterOne : .clear, lineWidth: 1) }
                        .foregroundStyle(choice == appearance ? ArenaPalette.fighterOne : ArenaPalette.text)
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 10))
                        .accessibilityLabel("\(choice.rawValue.capitalized) appearance")
                        .accessibilityAddTraits(choice == appearance ? .isSelected : [])
                }
            }
            Text("System follows your Mac’s appearance. Changes apply immediately.")
                .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).frame(height: 16)
            card {
                loginRow
                rowDivider
                updatesRow
            }
        }.padding(20)
    }

    private var agents: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agents").font(.system(size: 14, weight: .semibold))
                    Text("Connect a client, then install the Arena skill.")
                        .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                }
                Spacer(minLength: 8)
                Circle().fill(service.state == "Listening" ? ArenaPalette.consensus : ArenaPalette.secondary).frame(width: 5, height: 5)
                Text(service.state == "Listening" ? "Running on this Mac" : service.state)
                    .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
            }
            card {
                clientRow(.codex)
                rowDivider
                clientRow(.claude)
                rowDivider
                HStack(spacing: 12) {
                    clientIcon("network")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Other client").fontWeight(.semibold)
                        Text("Use any MCP-compatible client").font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { copy(setup.jsonConfiguration) } label: { Text("Copy Setup") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary))
                        .accessibilityLabel("Copy setup for another MCP client")
                        .frame(width: 96, alignment: .trailing)
                }.padding(.horizontal, 12).padding(.vertical, 14)
            }
        }.padding(20)
    }

    private func clientRow(_ client: ClientSetup.Client) -> some View {
        let busy = setup.busy.contains(client)
        let configured = setup.configured.contains(client)
        let lastActivity = service.lastActivity(for: client)
        let status = setup.status[client] ?? "Checking…"
        let skillError = setup.skillErrors[client]
        return HStack(spacing: 12) {
            clientIcon(client == .codex ? "terminal" : "asterisk")
            VStack(alignment: .leading, spacing: 4) {
                Text(client.rawValue).fontWeight(.semibold)
                VStack(alignment: .leading, spacing: 3) {
                    connectionStatus(lastActivity, status: status, busy: busy)
                    skillStatus(client)
                }
            }
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                if configured {
                    Button { Task { await setup.verify(client) } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .icon)).disabled(busy)
                        .accessibilityLabel("Refresh \(client.rawValue) connection status")
                        .help("Refresh connection status. Reconnect from \(client.rawValue) if needed.")
                }
                if !configured && setup.executable(client) != nil {
                    Button { Task { await setup.setUp(client) } } label: { Text(busy ? "Checking…" : "Set Up") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .primary)).disabled(busy)
                        .accessibilityLabel("Set up \(client.rawValue)")
                        .help("Register arena in \(client.rawValue)’s user configuration")
                } else if skillError != nil {
                    Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: setup.skillDirectory(client).path) } label: { Text("Show Folder") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary))
                        .accessibilityLabel("Show Skill Folder for \(client.rawValue)")
                } else if !setup.installedSkills.contains(client) {
                    Button { setup.installSkill(client) } label: { Text("Install Skill") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .primary))
                        .accessibilityLabel("Install Arena skill for \(client.rawValue)")
                        .help("Install in \(setup.skillDirectory(client).path). Open a new chat after installing.")
                } else if setup.justInstalled.contains(client) {
                    Label("Installed", systemImage: "checkmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ArenaPalette.consensus).padding(.horizontal, 12).frame(height: 28)
                        .background(ArenaPalette.statusConsensusFill, in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel("Arena skill installed for \(client.rawValue)")
                }
            }.frame(width: 136, alignment: .trailing)
        }.padding(.horizontal, 12).padding(.vertical, 14)
    }

    @ViewBuilder private func connectionStatus(_ lastActivity: Date?, status: String, busy: Bool) -> some View {
        if let lastActivity {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if context.date.timeIntervalSince(lastActivity) < 120 {
                    HStack(spacing: 6) {
                        Circle().frame(width: 5, height: 5).accessibilityHidden(true)
                        Text("Connected")
                    }.foregroundStyle(ArenaPalette.consensus)
                } else {
                    (Text("Last seen ") + Text(lastActivity, style: .relative) + Text(" ago"))
                        .foregroundStyle(ArenaPalette.secondary)
                }
            }.font(.system(size: 12))
        }
        if lastActivity == nil || (!busy && !status.hasPrefix("Ready")) {
            HStack(spacing: 6) {
                if lastActivity == nil { Circle().fill(ArenaPalette.secondary).frame(width: 5, height: 5).accessibilityHidden(true) }
                Text(status).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
        }
    }

    private func skillStatus(_ client: ClientSetup.Client) -> some View {
        let error = setup.skillErrors[client]
        let installed = setup.installedSkills.contains(client)
        let just = setup.justInstalled.contains(client)
        let color = error != nil ? ArenaPalette.pendingProposal : (installed ? ArenaPalette.consensus : ArenaPalette.secondary)
        let text = error != nil ? "Skill needs attention"
            : installed && just ? "Skill installed just now · use \(client == .codex ? "$arena" : "/arena")"
            : installed ? "Skill installed" : "Skill not installed"
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(text).foregroundStyle((installed && just) || error != nil ? color : ArenaPalette.secondary)
        }.font(.system(size: 12)).help(error ?? text)
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Manual setup").font(.system(size: 14, weight: .semibold))
                Text("For clients without a Set Up button. Setup includes your local service token · keep it out of session messages.")
                    .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
            card {
                HStack(spacing: 12) {
                    Text("Registration").fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(setup.name).font(.system(size: 12, design: .monospaced)).foregroundStyle(ArenaPalette.secondary).textSelection(.enabled)
                }.padding(.horizontal, 12).padding(.vertical, 12)
                rowDivider
                HStack(spacing: 12) {
                    Text("Endpoint").fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(setup.endpoint).font(.system(size: 12, design: .monospaced)).foregroundStyle(ArenaPalette.secondary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Button { copy(setup.endpoint) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .icon))
                        .accessibilityLabel("Copy endpoint")
                        .help("Copy endpoint")
                }.padding(.horizontal, 12).padding(.vertical, 8)
                rowDivider
                HStack(spacing: 12) {
                    Text("Configuration").fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Picker("Client format", selection: $manualClient) {
                        Text("Codex").tag("Codex"); Text("Other · Claude Code").tag("Other")
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                    Button { copy(manualClient == "Codex" ? setup.codexConfiguration : setup.jsonConfiguration) } label: { Text("Copy Config") }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary))
                        .accessibilityLabel("Copy \(manualClient) configuration")
                }.padding(.horizontal, 12).padding(.vertical, 10)
            }
            Text(manualClient == "Codex" ? "Merge into ~/.codex/config.toml (or your CODEX_HOME config)." : "Merge mcpServers into your client’s MCP configuration.")
                .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).fixedSize(horizontal: false, vertical: true)
            Text("HOW CONNECTION STATUS WORKS").font(.system(size: 11, weight: .semibold)).tracking(0.66).foregroundStyle(ArenaPalette.secondary)
            Text("Green means this client completed an MCP handshake and was active within the last two minutes; idle sessions show their last activity. Refresh re-checks configuration and Arena’s reachability — it cannot restart an external client, so reconnect from the client’s MCP controls or restart it. Set Up adds arena to the client’s user configuration, renaming matching older Arena registrations and preserving any others.")
                .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.padding(20)
    }

    private var loginRow: some View {
        HStack(spacing: 12) {
            clientIcon("power")
            VStack(alignment: .leading, spacing: 4) {
                Text("Start Arena at login").fontWeight(.semibold)
                Text("Keeps the server up so a client starting later finds Arena running.")
                    .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let status = loginAgent.status {
                    Text(status).font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if loginAgent.needsApproval {
                    Button("Open Login Items") { loginAgent.openLoginItems() }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .ghost))
                        .help("Allow Arena in System Settings → General → Login Items")
                }
            }
            Spacer(minLength: 4)
            Toggle("Start Arena at login", isOn: Binding(get: { loginAgent.enabled }, set: { loginAgent.setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Start Arena at login")
                .help("Keep Arena running from login so agent clients can connect without opening it")
                .frame(width: 96, alignment: .trailing)
        }.padding(.horizontal, 12).padding(.vertical, 14)
    }
    private var updatesRow: some View {
        HStack(spacing: 12) {
            clientIcon("arrow.triangle.2.circlepath")
            VStack(alignment: .leading, spacing: 4) {
                Text("Check for updates automatically").fontWeight(.semibold)
                Text("Arena looks for new releases in the background and offers to install them.")
                    .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecksForUpdates }, set: { updater.automaticallyChecksForUpdates = $0 }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Check for updates automatically")
                .help("Let Arena look for new releases in the background")
                .frame(width: 96, alignment: .trailing)
        }.padding(.horizontal, 12).padding(.vertical, 14)
    }
    private func clientIcon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 22, weight: .light)).foregroundStyle(ArenaPalette.secondary)
            .frame(width: 36, height: 36).background(ArenaPalette.canvas, in: RoundedRectangle(cornerRadius: 9)).accessibilityHidden(true)
    }
    private func copy(_ value: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string) }
}

private struct AppearanceMiniature: View {
    let appearance: ArenaAppearance
    var body: some View {
        Canvas { context, size in
            func draw(_ dark: Bool, in context: inout GraphicsContext) {
                func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ color: Color, _ radius: CGFloat = 1) {
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerRadius: radius), with: .color(color))
                }
                rect(0, 0, 120, 56, dark ? Color(white: 0.12) : .white, 4)
                rect(0, 0, 29, 56, Color(white: dark ? 0.19 : 0.91), 4)
                for x in [5, 9, 13] { rect(CGFloat(x), 5, 2, 2, .gray) }
                rect(5, 14, 20, 8, .blue, 2)
                rect(7, 28, 16, 2, .gray); rect(7, 34, 11, 2, .gray)
                rect(35, 6, 15, 4, .orange.opacity(0.5), 2); rect(53, 6, 12, 4, .purple.opacity(0.4), 2)
                for y in [17, 34] {
                    rect(35, CGFloat(y), 7, 7, (y == 17 ? Color.orange : .purple).opacity(0.3), 2)
                    rect(47, CGFloat(y), 65, 12, Color(white: dark ? 0.2 : 0.96), 2)
                    rect(50, CGFloat(y + 3), 56, 1.5, Color(white: dark ? 0.45 : 0.7))
                    rect(50, CGFloat(y + 7), 47, 1.5, Color(white: dark ? 0.38 : 0.8))
                }
            }
            draw(appearance == .dark, in: &context)
            if appearance == .system {
                context.clip(to: Path(CGRect(x: 76, y: 0, width: 44, height: size.height)))
                draw(true, in: &context)
            }
        }.clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

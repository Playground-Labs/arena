import AppKit
import SwiftUI

struct ArenaSettingsView: View {
    @Bindable var setup: ClientSetup
    let service: MCPService
    let loginAgent: LoginAgent
    @AppStorage("arenaAppearance") private var appearance: ArenaAppearance = .system
    @Environment(\.dismiss) private var dismiss
    @State private var manual = false
    @State private var manualClient = "Codex"
    private let accent = Color(red: 242/255, green: 117/255, blue: 15/255)

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if setup.showingConnection {
                    Button { setup.showingConnection = false } label: {
                        Label("Settings", systemImage: "chevron.left").font(.system(size: 12))
                            .padding(.horizontal, 8).frame(height: 28)
                            .background(ArenaPalette.badge, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(ArenaKeyboardButtonStyle())
                    Text("Agent connection").fontWeight(.semibold)
                } else {
                    Text("Settings").fontWeight(.semibold)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ArenaPalette.secondary)
                        .frame(width: 28, height: 28).contentShape(Circle())
                }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 14))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close Settings")
                    .help("Close Settings (Esc)")
            }.padding(.horizontal, 20).frame(height: 44)
                .background(ArenaPalette.toolbar)
                .overlay(alignment: .bottom) { ArenaPalette.divider.frame(height: 1) }
            if setup.showingConnection {
                ViewThatFits(in: .vertical) {
                    connection
                    ScrollView { connection }
                }.frame(maxHeight: 540)
            } else {
                ViewThatFits(in: .vertical) {
                    appearanceSettings
                    ScrollView { appearanceSettings }
                }.frame(maxHeight: 540)
            }
        }
        .frame(width: 520)
        .background(ArenaPalette.canvas)
        .foregroundStyle(ArenaPalette.text).font(.system(size: 13))
        .tint(accent)
        .ignoresSafeArea()
        .task { await setup.refresh(); loginAgent.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in setup.refreshSkills(); loginAgent.refresh() }
    }

    private var appearanceSettings: some View {
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
                        .background(choice == appearance ? accent.opacity(0.07) : ArenaPalette.toolbar, in: RoundedRectangle(cornerRadius: 10))
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
            ArenaPalette.divider.opacity(0.6).frame(height: 1)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Agent connection").fontWeight(.semibold)
                    Text("Set up Codex, Claude Code, or another client.").font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                }
                Spacer()
                Button { setup.showingConnection = true } label: {
                    Text("Set Up…").padding(.horizontal, 12).frame(height: 28)
                        .background(ArenaPalette.badge.opacity(0.7), in: Capsule())
                }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 14))
            }.padding(.top, 4)
            ArenaPalette.divider.frame(height: 1)
            skillInstallation
        }.padding(20)
    }

    private var skillInstallation: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Arena skill").font(.system(size: 14, weight: .semibold))
            Text("Start sessions and spar from your agent. Open a new chat after installing.")
                .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(ClientSetup.Client.allCases, id: \.self) { client in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(client.rawValue).fontWeight(.semibold)
                            Text(client == .codex ? "Use $arena" : "Use /arena")
                                .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                        }
                        Spacer(minLength: 4)
                        if setup.installedSkills.contains(client) {
                            Label("Installed", systemImage: "checkmark").font(.system(size: 12))
                                .foregroundStyle(ArenaPalette.consensus).frame(width: 90, height: 28)
                                .background(ArenaPalette.toolbar, in: Capsule())
                                .accessibilityLabel("Arena skill installed for \(client.rawValue)")
                        } else {
                            Button { setup.installSkill(client) } label: {
                                Text("Install").font(.system(size: 12)).frame(width: 90, height: 28)
                                    .background(ArenaPalette.toolbar, in: Capsule())
                            }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 14))
                                .accessibilityLabel("Install Arena skill for \(client.rawValue)")
                                .help("Install in \(setup.skillDirectory(client).path)")
                        }
                    }.frame(minHeight: 36)
                    if let error = setup.skillErrors[client] {
                        Text(error).font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Show Skill Folder") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: setup.skillDirectory(client).path)
                        }.modifier(ArenaHoverFeedback())
                    }
                }
            }
        }
    }

    private var connection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect your agents").font(.system(size: 15, weight: .semibold))
                Spacer()
                Circle().fill(service.state == "Listening" ? ArenaPalette.consensus : ArenaPalette.secondary).frame(width: 5, height: 5)
                Text(service.state == "Listening" ? "Running on this Mac" : service.state)
                    .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
            }.frame(minHeight: 20)
            Text("Register as arena, then reconnect your client and paste a session invitation.")
                .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 0) {
                ForEach(ClientSetup.Client.allCases, id: \.self) { client in
                    clientRow(client)
                    ArenaPalette.divider.opacity(0.5).frame(height: 0.5).padding(.horizontal, 12)
                }
                HStack(spacing: 12) {
                    clientIcon("network")
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Other client").fontWeight(.semibold)
                        Text("Use any MCP-compatible client").font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                    }
                    Spacer(minLength: 4)
                    Button { copy(setup.jsonConfiguration) } label: {
                        Text("Copy Setup").frame(width: 90, height: 28).background(ArenaPalette.toolbar, in: Capsule())
                    }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 14))
                        .accessibilityLabel("Copy setup for another MCP client")
                }.padding(.horizontal, 12).padding(.vertical, 14)
                ArenaPalette.divider.opacity(0.5).frame(height: 0.5).padding(.horizontal, 12)
                loginRow
            }
            .background(ArenaPalette.panel, in: RoundedRectangle(cornerRadius: 10))
            .padding(4).background(ArenaPalette.divider.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
            DisclosureGroup("Manual setup & connection details", isExpanded: $manual) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Registration: \(setup.name)\nEndpoint: \(setup.endpoint)").textSelection(.enabled)
                    Picker("Client format", selection: $manualClient) {
                        Text("Codex").tag("Codex"); Text("Other / Claude Code").tag("Other")
                    }.pickerStyle(.segmented)
                    Text("Setup includes your local service token. Keep it out of session messages.")
                    Button("Copy \(manualClient) Configuration") { copy(manualClient == "Codex" ? setup.codexConfiguration : setup.jsonConfiguration) }.modifier(ArenaHoverFeedback())
                    Text(manualClient == "Codex" ? "Merge into ~/.codex/config.toml (or your CODEX_HOME config)." : "Merge mcpServers into your client’s MCP configuration.")
                    Text("Set Up adds arena to the client’s user configuration. Matching older Arena registrations are renamed automatically. Other registrations are preserved.")
                    Text("Green means this client completed an MCP handshake and was active within the last two minutes. Idle sessions show their last activity. Refresh checks configuration and Arena’s reachability; it cannot restart an external client. To reconnect, use the client’s MCP controls or restart it.")
                }.padding(.top, 10).fixedSize(horizontal: false, vertical: true)
            }.font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
        }.padding(20)
    }

    private func clientRow(_ client: ClientSetup.Client) -> some View {
        let busy = setup.busy.contains(client)
        let configured = setup.configured.contains(client)
        let lastActivity = service.lastActivity(for: client)
        let status = setup.status[client] ?? "Checking…"
        return HStack(spacing: 12) {
            clientIcon(client == .codex ? "terminal" : "asterisk")
            VStack(alignment: .leading, spacing: 4) {
                Text(client.rawValue).fontWeight(.semibold)
                if let lastActivity {
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        if context.date.timeIntervalSince(lastActivity) < 120 {
                            HStack(spacing: 6) {
                                Circle().frame(width: 6, height: 6).accessibilityHidden(true)
                                Text("Connected")
                            }.foregroundStyle(ArenaPalette.consensus)
                        } else {
                            (Text("Last seen ") + Text(lastActivity, style: .relative) + Text(" ago"))
                                .foregroundStyle(ArenaPalette.secondary)
                        }
                    }.font(.system(size: 12))
                }
                if lastActivity == nil || (!busy && !status.hasPrefix("Ready")) {
                    Text(status).font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Button {
                Task { if configured { await setup.verify(client) } else { await setup.setUp(client) } }
            } label: {
                Group {
                    if configured { Image(systemName: "arrow.clockwise").font(.system(size: 13)) }
                    else { Text(busy ? "Checking…" : "Set Up") }
                }
                    .frame(width: configured ? 28 : 90, height: 28)
                    .background(configured ? ArenaPalette.toolbar : accent, in: Capsule())
                    .foregroundStyle(configured ? ArenaPalette.text : Color(red: 20/255, green: 20/255, blue: 20/255))
            }.buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 14, accent: !configured)).disabled(busy || setup.executable(client) == nil)
                .accessibilityLabel(configured ? "Refresh \(client.rawValue) connection status" : "Set up \(client.rawValue)")
                .help(configured ? "Refresh connection status. Reconnect from \(client.rawValue) if needed." : "Register arena in \(client.rawValue)’s user configuration")
                .frame(width: 90, alignment: .trailing)
        }.padding(.horizontal, 12).padding(.vertical, 14)
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
                        .modifier(ArenaHoverFeedback())
                        .help("Allow Arena in System Settings → General → Login Items")
                }
            }
            Spacer(minLength: 4)
            Toggle("Start Arena at login", isOn: Binding(get: { loginAgent.enabled }, set: { loginAgent.setEnabled($0) }))
                .labelsHidden().toggleStyle(.switch)
                .accessibilityLabel("Start Arena at login")
                .help("Keep Arena running from login so agent clients can connect without opening it")
                .frame(width: 90, alignment: .trailing)
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

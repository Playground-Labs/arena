import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ArenaView: View {
    let store: ArenaStore
    let service: MCPService
    @Bindable var setup: ClientSetup
    @State private var selection: String?
    @State private var showingDetails = false
    @State private var showingActivity = false
    @FocusState private var sessionListFocused: Bool
    @State private var showingNewSession = false
    @State private var editingSession: ArenaSession?
    @State private var errorMessage: String?
    @State private var preview: AttachmentSelection?

    private var selected: ArenaSession? { store.sessions.first { $0.id == selection } }

    var body: some View {
        ArenaColumns(sidebar: AnyView(sidebarColumn), content: AnyView(conversationColumn),
                     details: showingDetails && selected != nil ? AnyView(detailsColumn) : nil)
        .ignoresSafeArea()
        .font(.system(size: 13)).foregroundStyle(ArenaPalette.text)
        .navigationTitle(selected?.name ?? "Arena")
        .sheet(isPresented: $showingActivity) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session activity").font(.title2.bold())
                List(selected?.events.filter { $0.kind != "message" && $0.kind != "proposed" } ?? []) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.text).textSelection(.enabled)
                        Text(event.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                HStack { Spacer(); Button("Done") { showingActivity = false }.keyboardShortcut(.defaultAction).modifier(ArenaHoverFeedback()) }
            }.padding(24).frame(width: 520, height: 440)
        }
        .sheet(isPresented: $showingNewSession) {
            SessionEditor(session: nil) { name, brief, count, files in
                selection = try await store.createSession(name: name, brief: brief, agentCount: count, files: files)
                showingDetails = true
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditor(session: session) { name, brief, count, _ in
                try store.editSession(session.id, name: name, brief: brief, agentCount: count)
            }
        }
        .sheet(isPresented: $setup.showingSettings) {
            ArenaSettingsView(setup: setup, service: service)
        }
        .sheet(item: $preview) { item in
            AttachmentPreview(store: store, selection: item)
        }
        .alert("Arena couldn’t complete that action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onAppear { if selection == nil { selection = store.sessions.first?.id } }
    }

    private var sidebarColumn: some View {
        VStack(spacing: 0) {
            HStack { WindowControls().frame(width: 80); Spacer() }
                .padding(.leading, 20).frame(height: 44)
                .background(ArenaPalette.toolbar)
                .background(WindowDragArea())
                .overlay(alignment: .bottom) { ArenaPalette.divider.frame(height: 1) }
            sidebar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ArenaPalette.sidebar)
        .ignoresSafeArea()
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            windowHeader
            if let session = selected {
                ConversationView(session: session) { attachment in
                    preview = AttachmentSelection(sessionID: session.id, attachment: attachment)
                }
            } else {
                ContentUnavailableView {
                    Label { Text("A place for ideas to spar") } icon: { ArenaLogo(size: 64) }
                } description: {
                    Text("Create a session, invite your agents, and watch them work toward a shared assessment.")
                        .frame(maxWidth: 370)
                } actions: {
                    Button("New Session") { showingNewSession = true }
                        .buttonStyle(.borderedProminent).modifier(ArenaHoverFeedback(accent: true))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ArenaPalette.canvas)
        .ignoresSafeArea()
    }

    @ViewBuilder private var detailsColumn: some View {
        if let session = selected {
            VStack(spacing: 0) {
                HStack(spacing: 10) { Spacer(); sessionActions; detailsToggle }
                    .padding(.horizontal, 20).frame(height: 44)
                    .background(ArenaPalette.toolbar)
                    .background(WindowDragArea())
                    .overlay(alignment: .bottom) { ArenaPalette.divider.frame(height: 1) }
                SessionInspector(session: session, endpoint: service.endpoint) { attachment in
                    preview = AttachmentSelection(sessionID: session.id, attachment: attachment)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ArenaPalette.panel)
            .ignoresSafeArea()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ArenaLogo(size: 24)
                Text("ARENA").font(.system(size: 15, weight: .black)).tracking(2)
                Spacer(minLength: 0)
                Text("\(store.sessions.count)").font(.system(size: 10)).foregroundStyle(ArenaPalette.secondary)
                    .accessibilityLabel("\(store.sessions.count) sessions")
            }
            .padding(.horizontal, 16).frame(height: 56)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(sortedSessions) { session in
                        Button {
                            selection = session.id
                            sessionListFocused = true
                        } label: {
                            SessionRow(session: session, isSelected: selection == session.id)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10).padding(.vertical, 9)
                                .background(selection == session.id ? ArenaPalette.selection : .clear,
                                            in: RoundedRectangle(cornerRadius: 7))
                                .contentShape(RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(ArenaButtonStyle(cornerRadius: 7))
                        .accessibilityAddTraits(selection == session.id ? .isSelected : [])
                        .contextMenu {
                            Button("Edit Session…") { editingSession = session }
                            lifecycleButton(session)
                        }
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            .focusable().focused($sessionListFocused).focusEffectDisabled()
            .onMoveCommand { direction in
                guard direction == .up || direction == .down, !sortedSessions.isEmpty else { return }
                let current = sortedSessions.firstIndex { $0.id == selection } ?? 0
                selection = sortedSessions[min(max(current + (direction == .up ? -1 : 1), 0), sortedSessions.count - 1)].id
            }
            .accessibilityLabel("Sessions")
            VStack(spacing: 0) {
                ArenaPalette.divider.frame(height: 1)
                HStack(spacing: 0) {
                    Button { setup.showingConnection = true; setup.showingSettings = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "link").font(.system(size: 16)).foregroundStyle(ArenaPalette.secondary)
                                .frame(width: 16, height: 16)
                            Text("Agent connection").font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).frame(height: 28).contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(ArenaKeyboardButtonStyle()).help("Set up agent connections")
                    .accessibilityLabel("Agent connection")
                    Button { setup.showingConnection = false; setup.showingSettings = true } label: {
                        Image(systemName: "gearshape").frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(ArenaKeyboardButtonStyle()).foregroundStyle(ArenaPalette.secondary)
                        .help("Settings (⌘,)").accessibilityLabel("Settings")
                }.padding(.leading, 8).padding(.trailing, 12).frame(height: 39)
            }
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 10) {
            Text(selected?.name ?? "Arena").font(.system(size: 13, weight: .semibold)).foregroundStyle(ArenaPalette.text).lineLimit(1)
            Spacer(minLength: 12)
            if !showingDetails || selected == nil {
                sessionActions
                if selected != nil { detailsToggle }
            }
        }
        .buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(.secondary)
        .padding(.leading, 16).padding(.trailing, 12).frame(height: 44)
        .background(ArenaPalette.toolbar)
        .background(WindowDragArea())
        .overlay(alignment: .bottom) { ArenaPalette.divider.frame(height: 1) }
    }

    private var sortedSessions: [ArenaSession] { store.sessions.sorted { $0.updatedAt > $1.updatedAt } }

    private var sessionActions: some View {
        HStack(spacing: 10) {
            Button { showingNewSession = true } label: { Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle()) }
                .buttonStyle(ArenaKeyboardButtonStyle())
                .keyboardShortcut("n").help("New Session").accessibilityLabel("New Session")
            if let session = selected {
                Menu {
                    Button("Edit Session…") { editingSession = session }
                    Button("View Session Activity…") { showingActivity = true }
                    lifecycleButton(session)
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .modifier(ArenaHoverFeedback())
                .menuIndicator(.hidden).help("Session Actions").accessibilityLabel("Session Actions")
            }
        }.buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(ArenaPalette.secondary)
    }

    private var detailsToggle: some View {
        Button { showingDetails.toggle() } label: {
            Image(systemName: "sidebar.right").frame(width: 28, height: 28).contentShape(Rectangle())
        }
            .buttonStyle(ArenaKeyboardButtonStyle()).font(.system(size: 16)).foregroundStyle(ArenaPalette.secondary)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Session Details").accessibilityLabel("Session Details")
    }

    @ViewBuilder private func lifecycleButton(_ session: ArenaSession) -> some View {
        if session.status.isClosed {
            Button("Reopen Discussion", systemImage: "arrow.counterclockwise") { perform { try store.reopenSession(session.id) } }
        } else {
            Button("Stop Discussion", systemImage: "stop.circle", role: .destructive) { perform { try store.stopSession(session.id) } }
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }
}

struct SessionRow: View {
    let session: ArenaSession
    let isSelected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(isSelected ? .white : ArenaPalette.text).lineLimit(2)
            HStack {
                StatusBadge(status: session.status, compact: true, isSelected: isSelected)
                Spacer(minLength: 3)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(session.updatedAt.arenaRelativeTime(to: context.date))
                        .font(.system(size: 10)).foregroundStyle(isSelected ? Color(red: 0.88, green: 0.93, blue: 1) : ArenaPalette.secondary).lineLimit(1)
                }
                    .accessibilityLabel("Last activity \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }

        }
        .accessibilityElement(children: .combine)
    }
}

struct StatusBadge: View {
    let status: SessionStatus
    var compact = false
    var isSelected = false
    var body: some View {
        HStack(spacing: compact ? 5 : 6) {
            Group {
                Image(systemName: status.symbol)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
            }.frame(width: compact ? 10 : nil, height: compact ? 14 : nil)
            Text(status.title)
        }
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(isSelected ? ArenaPalette.selection : status.badgeForeground)
            .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 3 : 6)
            .background(isSelected ? .white : status.badgeFill, in: Capsule())
            .overlay { Capsule().strokeBorder(isSelected ? .clear : status.badgeForeground.opacity(0.35), lineWidth: 1) }
            .accessibilityLabel("Session status: \(status.title)")
    }
}

extension SessionStatus {
    var badgeForeground: Color {
        self == .waiting || self == .stopped ? ArenaPalette.statusNeutralText : color
    }
    var badgeFill: Color {
        switch self {
        case .waiting, .stopped: ArenaPalette.statusNeutralFill
        case .active: ArenaPalette.statusActiveFill
        case .consensus: ArenaPalette.statusConsensusFill
        case .impasse: ArenaPalette.statusImpasseFill
        }
    }
    var symbol: String {
        switch self {
        case .waiting: "clock"
        case .active: "bolt.fill"
        case .consensus: "checkmark"
        case .impasse: "arrow.triangle.branch"
        case .stopped: "stop.circle.fill"
        }
    }
    var color: Color {
        switch self {
        case .waiting: ArenaPalette.secondary
        case .active: ArenaPalette.fighterOne
        case .consensus: ArenaPalette.consensus
        case .impasse: ArenaPalette.fighterTwo
        case .stopped: ArenaPalette.secondary
        }
    }
}

func fighterColor(_ index: Int) -> Color {
    if index == 0 { return ArenaPalette.fighterOne }
    if index == 1 { return ArenaPalette.fighterTwo }
    let hue = (0.08 + Double(index) * 0.61803398875).truncatingRemainder(dividingBy: 1)
    return arenaColor(hue: hue)
}

private func arenaColor(hue: Double) -> Color {
    return Color(nsColor: NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return NSColor(calibratedHue: hue, saturation: dark ? 0.55 : 0.82,
                       brightness: dark ? 0.95 : 0.50, alpha: 1)
    })
}

struct FighterAvatar: View {
    let participant: Participant
    var size: CGFloat = 38
    var body: some View {
        Text(String(participant.name.prefix(2)).uppercased())
            .font(.system(size: size * 0.35, weight: .black))
            .foregroundStyle(fighterColor(participant.index))
            .frame(width: size, height: size)
            .background(participant.index == 0 ? ArenaPalette.fighterOneFill : participant.index == 1 ? ArenaPalette.fighterTwoFill : fighterColor(participant.index).opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.30))
            .accessibilityHidden(true)
    }
}

struct SessionEditor: View {
    let session: ArenaSession?
    let save: (String, String, Int, [URL]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var brief = ""
    @State private var count = 2
    @State private var files: [URL] = []
    @State private var importing = false
    @State private var saving = false
    @State private var error: String?
    private var setupEditable: Bool { session?.participants.allSatisfy { $0.joinedAt == nil } ?? true }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                ArenaLogo(size: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(session == nil ? "Open a new arena" : "Session setup").font(.title2.bold())
                    Text("Give your agents something worth debating.").foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Session name").font(.headline)
                TextField("e.g. Review the authentication proposal", text: $name).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Review brief").font(.headline); Spacer(); Text("Markdown supported").font(.caption).foregroundStyle(.secondary) }
                TextEditor(text: $brief).font(.body).padding(6).frame(height: 170)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .disabled(!setupEditable).accessibilityLabel("Review brief")
                Stepper("\(count) peer agents", value: $count, in: 2...32).disabled(!setupEditable)
                if !setupEditable { Label("The brief and roster lock when the first agent joins.", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
            }
            if session == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Add Brief Attachments…", systemImage: "paperclip") { importing = true }.modifier(ArenaHoverFeedback())
                    Text("Text, Markdown, PNG, JPEG, or PDF · up to 20 MiB each").font(.caption).foregroundStyle(.secondary)
                    ForEach(files, id: \.self) { file in
                        HStack {
                            Text(file.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { files.removeAll { $0 == file } } label: { Image(systemName: "xmark.circle.fill").frame(width: 24, height: 24) }
                                .buttonStyle(ArenaKeyboardButtonStyle()).accessibilityLabel("Remove \(file.lastPathComponent)")
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).modifier(ArenaHoverFeedback())
                Button(session == nil ? "Create Session" : "Save Changes") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(name, brief, count, files); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(.borderedProminent).modifier(ArenaHoverFeedback(accent: true)).keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 550).disabled(saving).interactiveDismissDisabled(saving)
        .onAppear { if let session { name = session.name; brief = session.brief; count = session.participants.count } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .png, .jpeg, .pdf], allowsMultipleSelection: true) { result in
            do { files = Array(Set(files + (try result.get()))).sorted { $0.lastPathComponent < $1.lastPathComponent } }
            catch { self.error = error.localizedDescription }
        }
    }
}

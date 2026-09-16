import AppKit
import Sparkle
import SwiftUI
import UniformTypeIdentifiers

struct ArenaView: View {
    let store: ArenaStore
    let service: MCPService
    @Bindable var setup: ClientSetup
    let loginAgent: LoginAgent
    let updater: SPUUpdater
    @State private var selection: String?
    @State private var folder: SessionFolder = .sessions
    @State private var search = ""
    @State private var statusFilter: SessionStatus?
    @State private var showingSearch = false
    @FocusState private var searchFocused: Bool
    @State private var showingDetails = false
    @State private var showingActivity = false
    @FocusState private var sessionListFocused: Bool
    @State private var showingNewSession = false
    @State private var editingSession: ArenaSession?
    @State private var errorMessage: String?
    @State private var preview: AttachmentSelection?

    private var selected: ArenaSession? { store.sessions.first { $0.id == selection } }
    private var isDashboard: Bool { selection == nil && folder == .sessions }

    var body: some View {
        ArenaColumns(sidebar: AnyView(sidebarColumn), content: AnyView(conversationColumn),
                     details: showingDetails && selected != nil ? AnyView(detailsColumn) : nil)
        .ignoresSafeArea()
        .font(.system(size: 13)).foregroundStyle(ArenaPalette.text)
        .navigationTitle(selected?.name ?? (isDashboard ? "Dashboard" : folder.title))
        .sheet(isPresented: $showingActivity) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session activity").font(.title2.bold())
                List(selected?.events.filter { $0.kind != "message" && $0.kind != "proposed" } ?? []) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(event.text).textSelection(.enabled)
                        Text(event.createdAt, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
                HStack { Spacer(); Button("Done") { showingActivity = false }.keyboardShortcut(.defaultAction).buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary)) }
            }.padding(24).frame(width: 520, height: 440)
        }
        .sheet(isPresented: $showingNewSession) {
            SessionEditor(session: nil) { name, brief, files in
                selection = try await store.createSession(name: name, brief: brief, files: files)
                folder = .sessions
                clearFilters()
                showingDetails = true
            }
        }
        .sheet(item: $editingSession) { session in
            SessionEditor(session: session) { name, brief, _ in
                try store.editSession(session.id, name: name, brief: brief)
            }
        }
        .sheet(isPresented: $setup.showingSettings) {
            ArenaSettingsView(setup: setup, service: service, loginAgent: loginAgent, updater: updater)
        }
        .sheet(item: $preview) { item in
            AttachmentPreview(store: store, selection: item)
        }
        .alert("Arena couldn’t complete that action", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: store.sessions.filter { folder.contains($0) }.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
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
            if isDashboard {
                SessionDashboard(sessions: store.sessions, search: search, status: statusFilter,
                                 open: { selection = $0.id }, actions: { sessionMenuItems($0) })
            } else if let session = selected {
                if session.isStoredAway { retentionBanner(session) }
                ConversationView(session: session, accept: { eventID in
                    perform { try store.acceptAnswer(session.id, eventID: eventID) }
                }) { attachment in
                    preview = AttachmentSelection(sessionID: session.id, attachment: attachment)
                }.id(session.id)
            } else {
                ContentUnavailableView {
                    Label { Text(ArenaBrand.tagline) } icon: { ArenaLogo(size: 64) }
                } description: {
                    Text(folder == .sessions ? "Create a session, invite your agents, and watch them work toward a shared assessment." : folder == .archive ? "Archived discussions appear here for 90 days before moving to Recently Deleted." : "Deleted discussions can be recovered here for 7 days.")
                        .frame(maxWidth: 370)
                } actions: {
                    Button("New Session") { showingNewSession = true }
                        .buttonStyle(ArenaKeyboardButtonStyle(kind: .primary))
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("ARENA").font(.system(size: 15, weight: .black)).tracking(2)
                    Text(ArenaBrand.tagline).font(.system(size: 10)).foregroundStyle(ArenaPalette.secondary)
                }.fixedSize()
                Spacer(minLength: 0)
                Text("\(sortedSessions.count)").font(.system(size: 10)).foregroundStyle(ArenaPalette.secondary)
                    .accessibilityLabel("\(sortedSessions.count) \(sortedSessions.count == 1 ? "session" : "sessions")")
            }
            .padding(.horizontal, 16).frame(height: 56)
            sidebarNavigation
            sessionListHeader
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
                            sessionMenuItems(session)
                        }
                    }
                    if sortedSessions.isEmpty {
                        Text(search.isEmpty && statusFilter == nil ? "No sessions" : "No matching sessions")
                            .font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                }.padding(.horizontal, 8).padding(.vertical, 4)
            }
            .focusable().focused($sessionListFocused).focusEffectDisabled()
            .onMoveCommand { direction in
                guard direction == .up || direction == .down, !sortedSessions.isEmpty else { return }
                if let current = sortedSessions.firstIndex(where: { $0.id == selection }) {
                    selection = sortedSessions[min(max(current + (direction == .up ? -1 : 1), 0), sortedSessions.count - 1)].id
                } else { selection = (direction == .up ? sortedSessions.last : sortedSessions.first)?.id }
            }
            .accessibilityLabel(folder.title)
            if let error = store.retentionError {
                Text(error).font(.caption).foregroundStyle(.red).padding(12).textSelection(.enabled)
            }
            Button { selectFolder(.deleted) } label: {
                sidebarLabel("Recently Deleted", icon: "trash")
                    .font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary)
                    .frame(height: 36)
                    .background(folder == .deleted ? ArenaPalette.navigationSelection : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(ArenaKeyboardButtonStyle()).padding(.horizontal, 8)
            .accessibilityAddTraits(folder == .deleted ? .isSelected : [])
            VStack(spacing: 0) {
                ArenaPalette.divider.frame(height: 1)
                HStack(spacing: 0) {
                    let ready = service.state == "Listening", starting = service.state == "Starting"
                    Button { setup.settingsTab = .agents; setup.showingSettings = true } label: {
                        HStack(spacing: 7) {
                            Circle().fill(ready ? ArenaPalette.consensus : starting ? ArenaPalette.pendingProposal : ArenaPalette.statusStoppedText)
                                .frame(width: 6, height: 6).accessibilityHidden(true)
                            Text(ready ? "MCP ready" : starting ? "MCP starting" : "MCP unavailable").font(.system(size: 11))
                                .foregroundStyle(ArenaPalette.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(ArenaKeyboardButtonStyle(kind: .ghost)).help(ready ? "MCP server running on this Mac. Open Agents settings." : service.state)
                    .accessibilityLabel("MCP status: \(service.state). Open Agents settings")
                    Button { setup.settingsTab = .general; setup.showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }.buttonStyle(ArenaKeyboardButtonStyle(kind: .icon))
                        .help("Settings (⌘,)").accessibilityLabel("Settings")
                }.padding(.leading, 8).padding(.trailing, 12).frame(height: 39)
            }
        }
    }

    private var sidebarNavigation: some View {
        VStack(spacing: 2) {
            Button { folder = .sessions; selection = nil; clearFilters() } label: {
                sidebarLabel("Dashboard", icon: "square.grid.2x2")
                    .frame(height: 32)
                    .background(isDashboard ? ArenaPalette.navigationSelection : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .accessibilityAddTraits(isDashboard ? .isSelected : [])
            Button { showingNewSession = true } label: {
                sidebarLabel("Create session", icon: "plus", shortcut: "⌘N").frame(height: 32)
            }.keyboardShortcut("n")
            Button {
                showingSearch = true
                searchFocused = true
            } label: {
                sidebarLabel("Search sessions", icon: "magnifyingglass", shortcut: "⌘F").frame(height: 32)
            }.keyboardShortcut("f")
            if showingSearch {
                HStack(spacing: 6) {
                    TextField("Name or brief", text: $search)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .onAppear { searchFocused = true }
                        .accessibilityLabel("Search sessions by name or brief")
                        .onExitCommand { search = ""; showingSearch = false; searchFocused = false }
                    Button { search = ""; showingSearch = false; searchFocused = false } label: {
                        Image(systemName: "xmark").frame(width: 20, height: 24)
                    }.accessibilityLabel("Close search").help("Close search (Escape)")
                }
                .padding(.horizontal, 8).frame(height: 32)
                .background(ArenaPalette.panel, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? ArenaPalette.dashboardAccent : ArenaPalette.divider) }
            }
        }
        .font(.system(size: 12)).buttonStyle(ArenaKeyboardButtonStyle())
        .padding(.horizontal, 8).padding(.bottom, 12)
    }

    private func sidebarLabel(_ title: String, icon: String, shortcut: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(ArenaPalette.secondary)
                .frame(width: 16, height: 16).accessibilityHidden(true)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if let shortcut {
                Text(shortcut).font(.system(size: 10)).foregroundStyle(ArenaPalette.secondary)
                    .frame(width: 24).accessibilityHidden(true)
            }
        }.padding(.horizontal, 10).contentShape(Rectangle())
    }

    private var sessionListHeader: some View {
        HStack(spacing: 2) {
            Text(folder.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
            Spacer(minLength: 0)
            Menu {
                Picker("Session status", selection: $statusFilter) {
                    Text("All statuses").tag(nil as SessionStatus?)
                    ForEach([SessionStatus.waiting, .active, .consensus, .impasse, .stopped], id: \.self) { status in
                        Text(status.title).tag(Optional(status))
                    }
                }.pickerStyle(.inline)
            } label: {
                Image(systemName: "line.3.horizontal.decrease").frame(width: 26, height: 28)
                    .foregroundStyle(statusFilter == nil ? ArenaPalette.secondary : ArenaPalette.dashboardAccent)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .tint(statusFilter == nil ? ArenaPalette.secondary : ArenaPalette.dashboardAccent)
            .modifier(ArenaHoverFeedback()).help("Filter sessions by status")
            .accessibilityLabel("Filter sessions").accessibilityValue(statusFilter?.title ?? "All statuses")
            Button { selectFolder(folder == .archive ? .sessions : .archive) } label: {
                Image(systemName: "archivebox").frame(width: 26, height: 28)
                    .foregroundStyle(folder == .archive ? ArenaPalette.dashboardAccent : ArenaPalette.secondary)
                    .background(folder == .archive ? ArenaPalette.navigationSelection : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(ArenaKeyboardButtonStyle())
            .accessibilityLabel(folder == .archive ? "Show sessions" : "Show archived sessions")
            .accessibilityAddTraits(folder == .archive ? .isSelected : [])
            .help(folder == .archive ? "Show sessions" : "Show archived sessions")
        }
        .font(.system(size: 14)).foregroundStyle(ArenaPalette.secondary)
        .padding(.leading, 18).padding(.trailing, 12).frame(height: 36)
    }

    private var windowHeader: some View {
        HStack(spacing: 10) {
            Text(selected?.name ?? (isDashboard ? "Dashboard" : folder.title)).font(.system(size: 13, weight: .semibold)).foregroundStyle(ArenaPalette.text).lineLimit(1)
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

    private var sortedSessions: [ArenaSession] {
        folder.sessions(in: store.sessions, search: search, status: statusFilter)
    }

    private func clearFilters() { search = ""; statusFilter = nil }

    private func selectFolder(_ destination: SessionFolder) {
        folder = destination
        clearFilters()
        selection = sortedSessions.first?.id
    }

    private var sessionActions: some View {
        HStack(spacing: 10) {
            if let session = selected {
                Menu {
                    sessionMenuItems(session)
                    Button("View Session Activity…") { showingActivity = true }
                } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
                .modifier(ArenaHoverFeedback())
                .menuIndicator(.hidden).help("Session Actions").accessibilityLabel("Session Actions")
            }
        }.buttonStyle(.plain).font(.system(size: 16)).foregroundStyle(ArenaPalette.secondary)
    }

    private var detailsToggle: some View {
        Button { showingDetails.toggle() } label: {
            Image(systemName: "sidebar.right")
        }
            .buttonStyle(ArenaKeyboardButtonStyle(kind: .icon)).font(.system(size: 16))
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Session Details").accessibilityLabel("Session Details")
    }

    @ViewBuilder private func sessionMenuItems(_ session: ArenaSession) -> some View {
        Button("Copy Name", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(session.name, forType: .string)
        }
        if session.isStoredAway {
            Button("Restore Session", systemImage: "arrow.uturn.backward") { restore(session) }
        } else {
            Button("Edit Session…") { editingSession = session }
            lifecycleButton(session)
            Divider()
            Button("Archive Session", systemImage: "archivebox") { perform { try store.archiveSession(session.id) } }
        }
        if session.deletedAt == nil {
            Button("Delete Session", systemImage: "trash", role: .destructive) { perform { try store.deleteSession(session.id) } }
        }
    }

    private func restore(_ session: ArenaSession) {
        perform { try store.restoreSession(session.id); folder = .sessions; clearFilters(); selection = session.id }
    }

    private func retentionBanner(_ session: ArenaSession) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.deletedAt == nil ? "Archived" : "Recently Deleted").fontWeight(.semibold)
                if let deadline = session.retentionDeadline {
                    Text("\(session.deletedAt == nil ? "Moves to Recently Deleted" : "Recover by") \(deadline.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(ArenaPalette.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Restore Session") { restore(session) }
                .buttonStyle(ArenaKeyboardButtonStyle()).foregroundStyle(ArenaPalette.consensus)
                .help("Return to Sessions. Reopen separately to resume discussion.")
        }.padding(.horizontal, 16).padding(.vertical, 14).background(ArenaPalette.panel)
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

enum SessionFolder: String, CaseIterable {
    case sessions = "Sessions", archive = "Archive", deleted = "Recently Deleted"
    var title: String { self == .archive ? "Archived sessions" : rawValue }
    func contains(_ session: ArenaSession) -> Bool {
        switch self {
        case .sessions: !session.isStoredAway
        case .archive: session.archivedAt != nil && session.deletedAt == nil
        case .deleted: session.deletedAt != nil
        }
    }

    func sessions(in sessions: [ArenaSession], search: String = "", status: SessionStatus? = nil) -> [ArenaSession] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return sessions.filter {
            contains($0) && (status == nil || $0.status == status) &&
            (query.isEmpty || $0.name.localizedStandardContains(query) || $0.brief.localizedStandardContains(query))
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
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
        let usesSelectionFill = isSelected && status != .stopped
        HStack(spacing: compact ? 5 : 6) {
            Group {
                Image(systemName: status.symbol)
                    .font(.system(size: compact ? 10 : 12, weight: .semibold))
            }.frame(width: compact ? 10 : nil, height: compact ? 14 : nil)
            Text(status.title)
        }
            .font(.system(size: compact ? 11 : 12, weight: .semibold))
            .foregroundStyle(usesSelectionFill ? ArenaPalette.selection : status.badgeForeground)
            .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 3 : 6)
            .background(usesSelectionFill ? .white : status.badgeFill, in: Capsule())
            .overlay { Capsule().strokeBorder(usesSelectionFill ? .clear : status.badgeForeground.opacity(0.35), lineWidth: 1) }
            .accessibilityLabel("Session status: \(status.title)")
    }
}

extension SessionStatus {
    var badgeForeground: Color {
        self == .waiting ? ArenaPalette.statusNeutralText : color
    }
    var badgeFill: Color {
        switch self {
        case .waiting: ArenaPalette.statusNeutralFill
        case .stopped: ArenaPalette.statusStoppedFill
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
        case .stopped: ArenaPalette.statusStoppedText
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
    let save: (String, String, [URL]) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var suggestedName = SessionNames.locations.randomElement() ?? "Asgard"
    @State private var brief = ""
    @State private var files: [URL] = []
    @State private var importing = false
    @State private var saving = false
    @State private var error: String?
    private var setupEditable: Bool { session?.participants.allSatisfy { $0.joinedAt == nil } ?? true }

    private var nameToSave: String { session == nil ? SessionNames.resolve(name, default: suggestedName) : name }

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
                TextField("Session name", text: $name, prompt: Text(session == nil ? suggestedName : "Session name"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Session name")
                    .accessibilityHint(session == nil ? "Leave blank to use \(suggestedName), or enter your own name." : "")
                if session == nil {
                    Text("A fictional starting point. Rename it anytime.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Review brief").font(.headline); Spacer(); Text("Markdown supported").font(.caption).foregroundStyle(.secondary) }
                TextEditor(text: $brief).font(.body).padding(6).frame(height: 170)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                    .disabled(!setupEditable).accessibilityLabel("Review brief")
                if !setupEditable { Label("The brief locks when the first agent joins.", systemImage: "lock").font(.caption).foregroundStyle(.secondary) }
            }
            if session == nil {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Add Brief Attachments…", systemImage: "paperclip") { importing = true }.buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary))
                    Text("Text, Markdown, PNG, JPEG, or PDF · up to 20 MiB each").font(.caption).foregroundStyle(.secondary)
                    ForEach(files, id: \.self) { file in
                        HStack {
                            Text(file.lastPathComponent).lineLimit(1)
                            Spacer()
                            Button { files.removeAll { $0 == file } } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(ArenaKeyboardButtonStyle(kind: .icon)).accessibilityLabel("Remove \(file.lastPathComponent)")
                        }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(ArenaKeyboardButtonStyle(kind: .secondary))
                Button(session == nil ? "Create Session" : "Save Changes") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await save(nameToSave, brief, files); dismiss() } catch { self.error = error.localizedDescription }
                    }
                }
                .buttonStyle(ArenaKeyboardButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
                .disabled(nameToSave.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28).frame(width: 550).disabled(saving).interactiveDismissDisabled(saving)
        .onAppear {
            if let session { name = session.name; brief = session.brief }
            else if name.isEmpty { name = suggestedName }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .png, .jpeg, .pdf], allowsMultipleSelection: true) { result in
            do { files = Array(Set(files + (try result.get()))).sorted { $0.lastPathComponent < $1.lastPathComponent } }
            catch { self.error = error.localizedDescription }
        }
    }
}

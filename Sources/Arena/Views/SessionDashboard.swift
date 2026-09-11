import SwiftUI

struct SessionSummary {
    let total: Int
    let open: Int
    let closed: Int
    let archived: Int
    let active: Int
    let waiting: Int

    init(sessions: [ArenaSession]) {
        let current = sessions.filter { !$0.isStoredAway }
        total = sessions.filter { $0.deletedAt == nil }.count
        archived = sessions.filter { SessionFolder.archive.contains($0) }.count
        open = current.filter { !$0.status.isClosed }.count
        closed = current.filter { $0.status.isClosed }.count
        active = current.filter { $0.status == .active }.count
        waiting = current.filter { $0.status == .waiting }.count
    }
}

struct SessionDashboard<Actions: View>: View {
    let sessions: [ArenaSession]
    let search: String
    let status: SessionStatus?
    let open: (ArenaSession) -> Void
    let actions: (ArenaSession) -> Actions

    var body: some View {
        let summary = SessionSummary(sessions: sessions)
        let visible = SessionFolder.sessions.sessions(in: sessions, search: search, status: status)
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Your Arenas").font(.system(size: 24, weight: .semibold))
                            .frame(height: 29)
                            .accessibilityAddTraits(.isHeader)
                        Text("All your discussions, at a glance.")
                            .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                            .frame(height: 17)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                             count: geometry.size.width >= 844 ? 4 : 2), spacing: 12) {
                        summaryCard("Total sessions", count: summary.total, note: "Excludes Recently Deleted")
                        summaryCard("Open", count: summary.open, note: "\(summary.active) active · \(summary.waiting) waiting",
                                    color: ArenaPalette.dashboardAccent)
                        summaryCard("Closed", count: summary.closed, note: "Consensus · Impasse · Stopped")
                        summaryCard("Archived", count: summary.archived, note: "Retained for 90 days", color: ArenaPalette.secondary)
                    }
                    HStack {
                        Text(search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status == nil ? "Recent sessions" : "Matching sessions")
                            .font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("Most recent first").font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary)
                    }.frame(height: 18)
                    if visible.isEmpty {
                        Text(summary.total == 0 ? "Create a session to give your agents a place to meet." :
                                search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && status == nil ?
                                "No current sessions. Use the archive button to browse stored discussions, or create a session." :
                                "No matching sessions. Adjust the search or status filter in the sidebar.")
                            .font(.system(size: 13)).foregroundStyle(ArenaPalette.secondary)
                            .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12),
                                                 count: geometry.size.width >= 784 ? 2 : 1), spacing: 12) {
                            ForEach(visible) { session in
                                Button { open(session) } label: { SessionCard(session: session) }
                                    .buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 10))
                                    .contextMenu { actions(session) }
                                    .help("Open \(session.name)")
                            }
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .foregroundStyle(ArenaPalette.text).background(ArenaPalette.canvas)
    }

    private func summaryCard(_ title: String, count: Int, note: String, color: Color = ArenaPalette.text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(ArenaPalette.secondary)
            Text(count, format: .number).font(.system(size: 32, weight: .semibold)).monospacedDigit().foregroundStyle(color)
            Text(note).font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).frame(height: 108)
        .background(ArenaPalette.dashboardCard, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ArenaPalette.dashboardBorder, lineWidth: 1) }
        .accessibilityElement(children: .combine)
        .help(note)
    }
}

private struct SessionCard: View {
    let session: ArenaSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(session.status.title).font(.system(size: 11))
                        .foregroundStyle(session.status.badgeForeground)
                        .frame(height: 16)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(session.status.badgeFill, in: Capsule())
                    Spacer(minLength: 8)
                    Text(session.updatedAt.arenaRelativeTime(to: context.date))
                        .font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary)
                        .accessibilityLabel("Last activity \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name).font(.system(size: 14, weight: .semibold)).foregroundStyle(ArenaPalette.text)
                        .frame(height: 18)
                    Text(session.brief).font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary)
                        .frame(height: 16)
                        .help(session.brief)
                }.lineLimit(1)
                HStack(spacing: 8) {
                    Text(session.joinedParticipants.isEmpty ? "No agents yet" : session.joinedParticipants.map(\.name).joined(separator: " · "))
                        .foregroundStyle(ArenaPalette.secondary)
                    Spacer(minLength: 0)
                    Text(session.dashboardActivity(at: context.date)).foregroundStyle(session.status.badgeForeground)
                }.font(.system(size: 11)).lineLimit(1).frame(height: 16)
            }
            .padding(16).frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
            .background(ArenaPalette.dashboardCard, in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(ArenaPalette.dashboardBorder, lineWidth: 1) }
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        }
    }
}

extension ArenaSession {
    func dashboardActivity(at date: Date) -> String {
        switch status {
        case .consensus: return "Final answer reached"
        case .impasse: return "No shared solution"
        case .stopped: return "Stopped by you"
        case .waiting: return joinedParticipants.isEmpty ? "Waiting for agents" : "Waiting for another agent"
        case .active: break
        }
        guard let turn, let participant = joinedParticipants.first(where: { $0.id == turn.participantID }) else {
            return "Ready for the next turn"
        }
        if turn.phase == .offered { return "Waiting for \(participant.name)" }
        return turn.isThinking(at: date) ? "\(participant.name) is thinking…" : "\(participant.name) holds the turn"
    }
}

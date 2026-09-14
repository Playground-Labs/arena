import AppKit
import SwiftUI

struct ConversationView: View {
    let session: ArenaSession
    let accept: (String) -> Void
    let preview: (Attachment) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var initialCursor: Int

    init(session: ArenaSession, accept: @escaping (String) -> Void, preview: @escaping (Attachment) -> Void) {
        self.session = session; self.accept = accept; self.preview = preview
        _initialCursor = State(initialValue: session.latestCursor)
    }

    var body: some View {
        let rightSpeakers = session.rightAlignedParticipantIDs
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.joinedParticipants) { participant in
                            let identity = participant.joinedAt == nil ? "Awaiting arrival" : [participant.client, participant.model].compactMap { $0 }.joined(separator: " · ")
                            HStack(spacing: 6) {
                                Circle().frame(width: 5, height: 5)
                                Text(participant.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            }
                            .foregroundStyle(fighterColor(participant.index))
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(participant.index == 0 ? ArenaPalette.fighterOneFill : participant.index == 1 ? ArenaPalette.fighterTwoFill : fighterColor(participant.index).opacity(0.13), in: Capsule())
                            .help(identity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(participant.name), \(identity)")
                        }
                    }
                }
                StatusBadge(status: session.status, compact: true).fixedSize()
            }
            .padding(.horizontal, 16).frame(height: 47).background(ArenaPalette.panel)
            ArenaPalette.divider.frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if session.events.isEmpty || !session.events.contains(where: { $0.kind == "message" }) {
                            VStack(spacing: 10) {
                                Image(systemName: session.status.isClosed ? session.status.symbol : session.status == .waiting ? "person.2.wave.2" : "bubble.left.and.bubble.right")
                                    .font(.system(size: 30, weight: .light)).foregroundStyle(.orange)
                                Text(session.status.isClosed ? "Discussion \(session.status.title.lowercased())" : session.status == .waiting ? "The arena is ready" : "The floor is open").font(.headline)
                                Text(session.status.isClosed ? "Reopen from Session Actions to resume." : session.status == .waiting ? "Agents can join through MCP and post immediately. Copy the session instructions from Details to bring them here." : "Your agents can now exchange critiques, evidence, and ideas.")
                                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 350)
                            }.frame(maxWidth: .infinity).padding(.vertical, 34)
                        }
                        ForEach(session.events.filter { $0.kind == "message" || $0.kind == "proposed" }) { event in
                            if event.kind == "message", let participant = session.participants.first(where: { $0.id == event.participantID }) {
                                MessageBubble(event: event, participant: participant, session: session, isRightAligned: rightSpeakers.contains(participant.id), preview: preview)
                                    .modifier(MessageArrival(animate: event.cursor > initialCursor, right: rightSpeakers.contains(participant.id)))
                                    .id(event.id)
                            } else if event.kind == "proposed" {
                                DisclosureGroup {
                                    MarkdownText(text: event.text).font(.callout).padding(.top, 8)
                                    if !session.status.isClosed {
                                        HStack { Spacer(); AcceptProposalButton { accept(event.id) } }.padding(.top, 8)
                                    }
                                } label: {
                                    Text("\(session.participants.first(where: { $0.id == event.participantID })?.name ?? "Agent") · \(event.text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "Proposed assessment")")
                                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(session.status.isClosed ? ArenaPalette.toolbar : ArenaPalette.pendingProposalFill, in: RoundedRectangle(cornerRadius: 10))
                                .modifier(MessageArrival(animate: event.cursor > initialCursor))
                                .id(event.id)
                                .contextMenu {
                                    if !session.status.isClosed {
                                        Button("Accept as Final Answer", systemImage: "checkmark.seal") { accept(event.id) }
                                    }
                                }
                            }
                        }
                        if let proposal = session.proposal {
                            OutcomeCard(proposal: proposal, session: session, accept: accept, showSource: { id in proxy.scrollTo(id, anchor: .center) })
                                .modifier(MessageArrival(animate: session.events.last(where: { $0.kind == "proposed" })?.cursor ?? 0 > initialCursor))
                                .id(proposal.id)
                        }
                        if let turn = session.turn, !session.status.isClosed,
                           let participant = session.joinedParticipants.first(where: { $0.id == turn.participantID }) {
                            TurnActivityView(turn: turn, name: participant.name)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(24)
                }
                .background(ArenaPalette.canvas)
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: session.events.count) { _, _ in
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: session.id) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            ArenaPalette.divider.frame(height: 1)
            HStack(spacing: 7) {
                Image(systemName: "eye")
                Text(session.isStoredAway ? "Stored history · Restore the session before reopening" : session.status.isClosed ? "Discussion \(session.status.title.lowercased()) · Reopen from Session Actions" : "Observer mode · Only agents post · You can accept a final answer")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
    }
}

/// New events animate once; loading old history or switching sessions stays still.
private struct MessageArrival: ViewModifier {
    let animate: Bool
    var right = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private var entering: Bool { animate && !reduceMotion && !appeared }
    func body(content: Content) -> some View {
        content
            .opacity(entering ? 0 : 1)
            .offset(y: entering ? 10 : 0)
            .scaleEffect(entering ? 0.97 : 1, anchor: right ? .bottomTrailing : .bottomLeading)
            .onAppear {
                withAnimation(animate && !reduceMotion ? .easeOut(duration: 0.25) : nil) { appeared = true }
            }
    }
}

private struct TurnActivityView: View {
    let turn: DiscussionTurn
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 15 : 0.4)) { context in
            let thinking = turn.isThinking(at: context.date)
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    if thinking {
                        ForEach(0..<3) { index in
                            Circle().frame(width: 5, height: 5)
                                .opacity(reduceMotion ? 1 : (Int(context.date.timeIntervalSince1970 / 0.4) % 3 == index ? 1 : 0.4))
                        }
                    } else {
                        Image(systemName: turn.phase == .offered ? "arrow.right" : "ellipsis")
                    }
                }.frame(width: 30).accessibilityHidden(true)
                if thinking {
                    Text("\(name) is formulating a response…")
                } else if turn.phase == .offered {
                    Text("Waiting for \(name) to take the turn")
                } else {
                    (Text("\(name) holds the turn · Last update ") + Text(turn.updatedAt, style: .relative) + Text(" ago"))
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).frame(minHeight: 32)
            .accessibilityElement(children: .combine)
            .help("Activity is reported by the agent. The turn stays assigned until the agent passes or releases it. Stop and reopen the discussion to clear an abandoned turn.")
        }
    }
}

private struct MessageBubble: View {
    let event: ArenaEvent
    let participant: Participant
    let session: ArenaSession
    let isRightAligned: Bool
    let preview: (Attachment) -> Void

    var body: some View {
        HStack(spacing: 0) {
            if isRightAligned { Spacer(minLength: 64) }
            message.frame(maxWidth: 680)
            if !isRightAligned { Spacer(minLength: 64) }
        }
    }

    private var message: some View {
        HStack(alignment: .top, spacing: 11) {
            if !isRightAligned { FighterAvatar(participant: participant, size: 34) }
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if isRightAligned {
                        timestamp
                        Spacer(minLength: 8)
                        modelLabel
                        nameLabel
                    } else {
                        nameLabel
                        modelLabel
                        Spacer(minLength: 8)
                        timestamp
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    if let replyID = event.replyTo,
                       let reply = session.events.first(where: { $0.id == replyID }) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 2).fill(fighterColor(participant.index)).frame(width: 3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Reply to \(session.participants.first(where: { $0.id == reply.participantID })?.name ?? "message")").font(.caption.bold())
                                Text(reply.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }.fixedSize(horizontal: false, vertical: true)
                    }
                    if !event.mentions.isEmpty {
                        Text(event.mentions.compactMap { id in session.participants.first { $0.id == id }.map { "@\($0.name)" } }.joined(separator: "  "))
                            .font(.caption.weight(.medium)).foregroundStyle(fighterColor(participant.index))
                    }
                    if !event.text.isEmpty { MarkdownText(text: event.text) }
                    ForEach(session.attachments.filter { event.attachmentIDs.contains($0.id) }) { attachment in
                        AttachmentButton(attachment: attachment) { preview(attachment) }
                    }
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(ArenaPalette.panel, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(ArenaPalette.bubbleBorder))
            }
            if isRightAligned { FighterAvatar(participant: participant, size: 34) }
        }
    }

    private var nameLabel: some View {
        Text(participant.name).font(.system(size: 13, weight: .bold)).foregroundStyle(fighterColor(participant.index))
    }

    private var modelLabel: some View {
        let model = Text(participant.model ?? "Agent").lineLimit(1)
        let type = Text(event.messageType == "rebuttal" ? "Rebuttal" : "Comment").fixedSize()
        return HStack(spacing: 4) {
            if isRightAligned { type; Text("·"); model } else { model; Text("·"); type }
        }.font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary)
    }

    private var timestamp: some View {
        Text(event.createdAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
            .help(event.createdAt.formatted(date: .abbreviated, time: .standard))
    }
}

extension ArenaSession {
    /// Stable sides follow first discussion messages, independent of roster and join order.
    var rightAlignedParticipantIDs: Set<String> {
        var speakers = Set<String>()
        var right = Set<String>()
        for event in events where event.kind == "message" {
            if let id = event.participantID, speakers.insert(id).inserted, speakers.count.isMultiple(of: 2) {
                right.insert(id)
            }
        }
        return right
    }
}

struct MarkdownText: View {
    let text: String
    var body: some View {
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .font(.system(size: 13, weight: .regular)).foregroundStyle(ArenaPalette.text).textSelection(.enabled).lineSpacing(5).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                ["https", "http"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
            })
    }
}

private struct AcceptProposalButton: View {
    let accept: () -> Void
    var body: some View {
        Button(action: accept) {
            Text("Accept").font(.system(size: 12, weight: .semibold)).foregroundStyle(ArenaPalette.consensus)
                .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
        }
            .buttonStyle(ArenaKeyboardButtonStyle(cornerRadius: 5))
            .help("Accept this proposal as the final answer and end the discussion")
            .accessibilityLabel("Accept this proposal as final answer")
    }
}

private struct OutcomeCard: View {
    let proposal: OutcomeProposal
    let session: ArenaSession
    let accept: (String) -> Void
    let showSource: (String) -> Void
    private var proposingAuthor: String {
        let eventID = proposal.sourceEventID ?? session.events.last(where: { $0.kind == "proposed" })?.id
        let participantID = session.events.first { $0.id == eventID }?.participantID
        return session.participants.first { $0.id == participantID }?.name ?? "Agent"
    }
    private var source: ArenaEvent? { session.events.first { $0.id == proposal.acceptedEventID } }

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            card
            if !session.status.isClosed, let eventID = proposal.sourceEventID ?? session.events.last(where: { $0.kind == "proposed" })?.id {
                AcceptProposalButton { accept(eventID) }
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(proposal.acceptedEventID != nil ? "Final answer" : session.status == proposal.outcome ? proposal.outcome.title : "Proposed \(proposal.outcome.title.lowercased()) · \(proposingAuthor)", systemImage: proposal.outcome.symbol)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(session.status.isClosed ? proposal.outcome.color : ArenaPalette.pendingProposal)
                Spacer()
                if proposal.acceptedEventID != nil {
                    Text("Chosen by you").font(.caption).foregroundStyle(.secondary)
                } else if session.status.isClosed {
                    Text("Agent agreement: \(proposal.confirmations.count) of \(session.joinedParticipants.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !proposal.assessment.isEmpty { MarkdownText(text: proposal.assessment) }
            if let source {
                Button("\(session.participants.first { $0.id == source.participantID }?.name ?? "Agent") · Selected answer") { showSource(source.id) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary).modifier(ArenaHoverFeedback())
                    .accessibilityLabel("View selected answer in conversation")
            } else {
                if !session.status.isClosed {
                    Text("Agent agreement: \(proposal.confirmations.count) of \(session.joinedParticipants.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if session.status.isClosed {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 18) { confirmations }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 10) { confirmations }
                    }
                }
            }
        }
        .padding(20).background(!session.status.isClosed ? ArenaPalette.pendingProposalFill : proposal.outcome == .consensus ? ArenaPalette.consensusFill : proposal.outcome.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(!session.status.isClosed ? ArenaPalette.pendingProposalBorder : proposal.outcome == .consensus ? ArenaPalette.consensusBorder : proposal.outcome.color.opacity(0.2)))
        .contextMenu {
            if !session.status.isClosed, let eventID = proposal.sourceEventID ?? session.events.last(where: { $0.kind == "proposed" })?.id {
                Button("Accept as Final Answer", systemImage: "checkmark.seal") { accept(eventID) }
            }
        }
    }

    private var confirmations: some View {
        ForEach(session.joinedParticipants) { participant in
            Label(participant.name, systemImage: proposal.confirmations.contains(participant.id) ? "checkmark" : "circle")
                .accessibilityLabel("\(participant.name): \(proposal.confirmations.contains(participant.id) ? "Confirmed" : "Pending confirmation")")
                .font(.caption).foregroundStyle(proposal.confirmations.contains(participant.id) ? SessionStatus.consensus.color : .secondary)
        }
    }
}

struct SessionInspector: View {
    let session: ArenaSession
    let endpoint: String
    let preview: (Attachment) -> Void
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    inspectorHeading("REVIEW BRIEF")
                    MarkdownText(text: session.brief).font(.callout)
                    ForEach(session.attachments.filter(\.isBrief)) { attachment in
                        AttachmentButton(attachment: attachment) { preview(attachment) }
                    }
                }
                ArenaPalette.divider.frame(height: 1)
                VStack(alignment: .leading, spacing: 20) {
                    inspectorHeading("AGENTS")
                    if !session.status.isClosed {
                        CopyButton(title: "Copy Join Instructions", text: joinInstructions).font(.caption)
                    }
                    if session.joinedParticipants.isEmpty {
                        Text("No agents have joined yet.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(session.joinedParticipants) { participant in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack(spacing: 9) {
                                FighterAvatar(participant: participant, size: 32)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(participant.name).font(.headline)
                                    Text(participant.joinedAt == nil ? "Invitation ready" : [participant.client, participant.model].compactMap { $0 }.joined(separator: " · "))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if participant.joinedAt != nil {
                                    Image(systemName: "checkmark").foregroundStyle(ArenaPalette.consensus).help("Joined").accessibilityLabel("Joined")
                                }
                            }
                            Text("Identity saved for reconnection").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Text("Client and model labels are supplied by each agent.").font(.caption2).foregroundStyle(.secondary)
                }
                ArenaPalette.divider.frame(height: 1)
                VStack(alignment: .leading, spacing: 20) {
                    inspectorHeading("HOW THIS ENDS")
                    Text("Choose Accept or right-click → Accept as Final Answer on a specific proposal to end the discussion. Agents can also close it through unanimous confirmation. A new message or new agent clears pending confirmations.")
                        .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).lineSpacing(4)
                }
            }.padding(24)
        }.background(ArenaPalette.panel)
    }

    private func inspectorHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(ArenaPalette.secondary)
    }

    private var joinInstructions: String {
        """
        Use the Arena skill to join session "\(session.id)" (\(session.name)) through Arena MCP at \(endpoint).
        Register once with register_client and privately retain client_token. Call join_session with session_id, client_token, your client/model labels, and a fresh request_id. Save participant_token and use it to reconnect; keep all credentials private.
        Read the brief and attachments, then claim a turn before posting your opening comment. Use post_message with message_type comment for observations and tentative ideas, or rebuttal with reply_to for a targeted challenge. Agents may join at any time while the session is open. Keep reading read_events with the last cursor and wait_seconds 25, responding when you have a substantive critique or improvement.
        Aim to earn the author's approval through the strongest supported proposal: explain the recommendation, trade-offs, evidence, and remaining risks. Exchange comments and targeted rebuttals with a peer before presenting a concrete solution through propose_outcome so the author can accept that specific proposal and close the session immediately. Agents may also propose Consensus or Impasse and unanimously confirm it once at least two agents have joined. New messages or new arrivals invalidate pending assessments. Stop when status is consensus, impasse, or stopped.
        \(MCPTools.turnInstructions)
        Arena hosts the discussion; it does not launch or keep external agents running.
        """
    }
}

struct CopyButton: View {
    let title: String
    let text: String
    @State private var copied = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
        } label: { Label(copied ? "Copied" : title, systemImage: copied ? "checkmark" : "doc.on.doc") }
        .modifier(ArenaHoverFeedback())
        .onChange(of: text) { _, _ in copied = false }
    }
}

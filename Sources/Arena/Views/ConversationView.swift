import AppKit
import SwiftUI

struct ConversationView: View {
    let session: ArenaSession
    let preview: (Attachment) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.participants) { participant in
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
                                Text(session.status.isClosed ? "Reopen from Session Actions to resume." : session.status == .waiting ? "Copy each invitation from Session Details and give it to an agent. Discussion opens when everyone joins." : "Your agents can now exchange critiques, evidence, and ideas.")
                                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 350)
                            }.frame(maxWidth: .infinity).padding(.vertical, 34)
                        }
                        ForEach(session.events.filter { $0.kind == "message" || $0.kind == "proposed" }) { event in
                            if event.kind == "message", let participant = session.participants.first(where: { $0.id == event.participantID }) {
                                MessageBubble(event: event, participant: participant, session: session, preview: preview)
                                    .id(event.id)
                            } else if event.kind == "proposed" {
                                DisclosureGroup {
                                    MarkdownText(text: event.text).font(.callout).padding(.top, 8)
                                } label: {
                                    Text("\(session.participants.first(where: { $0.id == event.participantID })?.name ?? "Agent") · \(event.text.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "Proposed assessment")")
                                        .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 12).padding(.vertical, 10)
                                .background(ArenaPalette.toolbar, in: RoundedRectangle(cornerRadius: 10))
                                .id(event.id)

                            }
                        }
                        if let proposal = session.proposal {
                            OutcomeCard(proposal: proposal, session: session)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(24)
                }
                .background(ArenaPalette.canvas)
                .onAppear { proxy.scrollTo("latest", anchor: .bottom) }
                .onChange(of: session.events.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("latest", anchor: .bottom) }
                }
                .onChange(of: session.id) { _, _ in proxy.scrollTo("latest", anchor: .bottom) }
            }
            ArenaPalette.divider.frame(height: 1)
            HStack(spacing: 7) {
                Image(systemName: "eye")
                Text(session.status.isClosed ? "Discussion \(session.status.title.lowercased()) · Reopen from Session Actions" : "Observer mode · Only agents can join the conversation")
                Spacer()
            }
            .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 12)
        }
    }
}

private struct MessageBubble: View {
    let event: ArenaEvent
    let participant: Participant
    let session: ArenaSession
    let preview: (Attachment) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            FighterAvatar(participant: participant, size: 34)
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(participant.name).font(.system(size: 13, weight: .bold)).foregroundStyle(fighterColor(participant.index))
                    Text(participant.model ?? "Agent").font(.system(size: 11)).foregroundStyle(ArenaPalette.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(event.createdAt, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
                        .help(event.createdAt.formatted(date: .abbreviated, time: .standard))
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
        }
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

private struct OutcomeCard: View {
    let proposal: OutcomeProposal
    let session: ArenaSession
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(session.status == proposal.outcome ? proposal.outcome.title : "Proposed \(proposal.outcome.title.lowercased())", systemImage: proposal.outcome.symbol)
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(proposal.outcome.color)
                Spacer()
                Text("\(proposal.confirmations.count)/\(session.participants.count) confirmed").font(.caption).foregroundStyle(.secondary)
            }
            MarkdownText(text: proposal.assessment)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { confirmations }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), alignment: .leading)], alignment: .leading, spacing: 10) { confirmations }
            }
        }
        .padding(20).background(proposal.outcome == .consensus ? ArenaPalette.consensusFill : proposal.outcome.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(proposal.outcome == .consensus ? ArenaPalette.consensusBorder : proposal.outcome.color.opacity(0.2)))
    }

    private var confirmations: some View {
        Group {
                ForEach(session.participants) { participant in
                    Label(participant.name, systemImage: proposal.confirmations.contains(participant.id) ? "checkmark" : "circle")
                        .font(.caption).foregroundStyle(proposal.confirmations.contains(participant.id) ? SessionStatus.consensus.color : .secondary)
                }
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
                    inspectorHeading("FIGHTERS")
                    ForEach(session.participants) { participant in
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
                            if participant.joinedAt == nil {
                                CopyButton(title: "Copy Invitation", text: invitation(for: participant)).font(.caption)
                            } else {
                                Text("Identity saved for reconnection").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Client and model labels are supplied by each agent.").font(.caption2).foregroundStyle(.secondary)
                }
                ArenaPalette.divider.frame(height: 1)
                VStack(alignment: .leading, spacing: 20) {
                    inspectorHeading("HOW THIS ENDS")
                    Text("Every fighter must confirm the same assessment. A new message clears pending confirmations. Agreement and unresolved disagreement are both valid outcomes.")
                        .font(.system(size: 12)).foregroundStyle(ArenaPalette.secondary).lineSpacing(4)
                }
            }.padding(24)
        }.background(ArenaPalette.panel)
    }

    private func inspectorHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .bold)).tracking(1).foregroundStyle(ArenaPalette.secondary)
    }

    private func invitation(for participant: Participant) -> String {
        """
        Join the Arena session “\(session.name)” as a peer reviewer using the configured Arena MCP server at \(endpoint).
        Call join_session with invitation "\(participant.invitation)", your client and model labels, and a unique request_id. Save the returned participant_token; use it for every subsequent tool call and reconnection. Never share credentials in chat.
        Read the brief, roster, attachments, status, and revision using read_session. Wait for all \(session.participants.count) participants to join before posting. Read ordered updates using read_events with after_cursor set to your last cursor, limit 50, and wait_seconds 25. Continue the read/respond/wait loop, catching up while has_more is true. External client execution must remain running; Arena does not launch or wake you.
        Discuss through post_message, with optional reply_to, mentions (participant IDs), and attachment_ids. Use attach_file for an explicitly chosen local file, and read_attachment for text, images, or a PDF page. Use a fresh request_id per mutation; reuse it only when retrying the identical call.
        When ready, propose_outcome with outcome "consensus" or "impasse", assessment, based_on_revision from the current session, and request_id. Every participant, including the proposer, must call confirm_outcome with the current proposal_id. New messages invalidate pending confirmations. Stop when the status is consensus, impasse, or stopped. Do not manufacture agreement; record unresolved disagreement honestly.
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

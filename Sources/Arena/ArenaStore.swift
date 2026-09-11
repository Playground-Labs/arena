import CryptoKit
import Foundation
import Observation
import SwiftData

@Model
final class StoredArena {
    var key: String
    var payload: Data
    init(payload: Data) { self.key = "arena"; self.payload = payload }
}
private struct MutationReceipt: Codable {
    var fingerprint: String
    var result: ArenaToolResult
}
private struct ArenaSnapshot: Codable {
    var sessions: [ArenaSession] = []
    var receipts: [String: MutationReceipt] = [:]
    var clientTokens: Set<String>?
}

@MainActor @Observable
final class ArenaStore {
    private(set) var sessions: [ArenaSession]
    private let directory: URL
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let saveContext: (ModelContext) throws -> Void
    @ObservationIgnored private var snapshot: ArenaSnapshot
    @ObservationIgnored private var waiters: [UUID: (session: String, continuation: CheckedContinuation<Void, any Error>, timer: Task<Void, Never>)] = [:]
    var pendingWaitCount: Int { waiters.count }
    private static let names = ["Thor", "Athena", "Kratos", "Storm", "Hercules", "Wonder Woman", "Doom Slayer", "Achilles", "Samus", "Wolverine", "Artemis", "Goku", "Black Panther", "Ares", "Ripley", "Dante", "Hulk", "Perseus", "She-Ra", "Zeus", "Link", "Superman", "Freya", "Spawn", "Captain Marvel", "Odin", "Chun-Li", "Batman", "Hades", "Lara Croft", "Beowulf", "Saitama"]

    init(directory: URL, inMemory: Bool = false, save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws {
        self.saveContext = save
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configuration = inMemory ? ModelConfiguration(isStoredInMemoryOnly: true) : ModelConfiguration(url: directory.appendingPathComponent("Arena.sqlite"))
        let container = try ModelContainer(for: StoredArena.self, configurations: configuration)
        context = ModelContext(container); context.autosaveEnabled = false
        if let stored = try context.fetch(FetchDescriptor<StoredArena>()).first {
            snapshot = try JSONDecoder().decode(ArenaSnapshot.self, from: stored.payload)
        } else { snapshot = ArenaSnapshot() }
        sessions = snapshot.sessions
    }

    private func commit(_ next: ArenaSnapshot, observerControl: Bool = false) throws {
        // ponytail: bounded snapshot rewrites suit a local MVP; normalize rows when large histories make saves slow.
        // Observer controls remain available at the agent history ceiling. Receipts are never evicted: old retries must not execute again.
        guard observerControl || (next.sessions.count <= 200 && next.sessions.reduce(0, { $0 + $1.events.count }) <= 100_000 && next.receipts.count <= 100_000) else { throw ArenaError.invalid("Local history capacity reached (200 sessions / 100,000 events or operations).") }
        do {
            let payload = try JSONEncoder().encode(next)
            guard observerControl || payload.count <= 128 * 1024 * 1024 else { throw ArenaError.invalid("Local history exceeds 128 MiB; start a fresh Arena data directory.") }
            if let row = try context.fetch(FetchDescriptor<StoredArena>()).first { row.payload = payload }
            else { context.insert(StoredArena(payload: payload)) }
            try saveContext(context)
        } catch { context.rollback(); throw error }
        let changed = next.sessions.filter { item in snapshot.sessions.first(where: { $0.id == item.id })?.latestCursor != item.latestCursor }.map(\.id)
        snapshot = next
        sessions = next.sessions
        for (id, waiter) in waiters where changed.contains(waiter.session) { finishWait(id) }
    }
    private func index(_ id: String) throws -> Int {
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { throw ArenaError.invalid("Session not found.") }; return index
    }
    private func clean(_ value: String, label: String, max: Int) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= max else { throw ArenaError.invalid("\(label) is required and must be at most \(max) UTF-8 bytes.") }; return value
    }
    private func participants(_ count: Int) throws -> [Participant] {
        guard (2...32).contains(count) else { throw ArenaError.invalid("Choose 2 to 32 agents.") }
        return Self.names.shuffled().prefix(count).enumerated().map { index, name in
            Participant(id: UUID().uuidString, name: name, invitation: Self.secret(), credential: Self.secret(), index: index)
        }
    }
    private static func secret() -> String { UUID().uuidString + UUID().uuidString }
    private func event(_ session: inout ArenaSession, kind: String, text: String, participant: String? = nil, reply: String? = nil, mentions: [String] = [], attachments: [String] = []) -> ArenaEvent {
        let event = ArenaEvent(cursor: session.latestCursor + 1, kind: kind, text: text, participantID: participant, replyTo: reply, mentions: mentions, attachmentIDs: attachments)
        session.events.append(event); session.updatedAt = event.createdAt
        return event
    }
    func createSession(name: String, brief: String, agentCount: Int, files: [URL] = [], requestID: String? = nil, clientToken: String? = nil) async throws -> String {
        let key: String?
        if let requestID {
            guard let clientToken, snapshot.clientTokens?.contains(clientToken) == true else { throw ArenaError.invalid("Call register_client and retain its private client_token before creating a session.") }
            key = receiptKey(scope: "create_session:" + clientToken, request: try clean(requestID, label: "request_id", max: 200))
        } else { key = nil }
        let hash = try fingerprint(tool: "create_session", args: ["name": .string(name), "brief": .string(brief), "agent_count": .int(agentCount), "files": .array(files.map { .string($0.path) })])
        if let key, let receipt = try replay(key, hash: hash), let id = receipt.data.objectValue?["session_id"]?.stringValue { return id }
        let id = UUID().uuidString
        var session = ArenaSession(id: id, name: try clean(name, label: "Session name", max: 200), brief: try clean(brief, label: "Brief", max: 100_000), status: .waiting, revision: 0, createdAt: .now, updatedAt: .now, participants: try participants(agentCount), events: [], attachments: [])
        guard files.count <= 32 else { throw ArenaError.invalid("At most 32 brief attachments are supported.") }
        let attachmentDirectory = directory.appendingPathComponent("Attachments").appendingPathComponent(id)
        do {
            for file in files { session.attachments.append(try await AttachmentFiles.shared.importFile(file, directory: attachmentDirectory, isBrief: true)) }
            try Task.checkCancellation()
            if let key, let receipt = try replay(key, hash: hash), let previousID = receipt.data.objectValue?["session_id"]?.stringValue {
                try? FileManager.default.removeItem(at: attachmentDirectory)
                return previousID
            }
            _ = event(&session, kind: "setup", text: "Session created. Waiting for \(agentCount) agents.")
            var next = snapshot; next.sessions.insert(session, at: 0)
            if let key { next.receipts[key] = MutationReceipt(fingerprint: hash, result: ArenaToolResult(data: .object(["session_id": .string(id)]))) }
            try commit(next)
        } catch { try? FileManager.default.removeItem(at: attachmentDirectory); throw error }
        return id
    }
    func editSession(_ id: String, name: String, brief: String, agentCount: Int) throws {
        let i = try index(id)
        let name = try clean(name, label: "Session name", max: 200)
        let brief = try clean(brief, label: "Brief", max: 100_000)
        let session = snapshot.sessions[i]
        let setupChanged = brief != session.brief || agentCount != session.participants.count
        guard setupChanged || name != session.name else { return }
        if setupChanged {
            guard session.status == .waiting, session.participants.allSatisfy({ $0.joinedAt == nil }) else {
                throw ArenaError.invalid("Setup is locked after joining begins or while the session is closed.")
            }
        }
        var next = snapshot
        if setupChanged {
            next.sessions[i].brief = brief
            if agentCount != session.participants.count { next.sessions[i].participants = try participants(agentCount) }
            _ = event(&next.sessions[i], kind: "setup", text: "Brief and participant slots updated.")
        }
        if name != session.name {
            next.sessions[i].name = name
            _ = event(&next.sessions[i], kind: "renamed", text: "Session renamed to \(name).")
        }
        try commit(next, observerControl: true)
    }
    func stopSession(_ id: String) throws {
        let i = try index(id); var next = snapshot
        guard !next.sessions[i].status.isClosed else { throw ArenaError.invalid("Session is already closed.") }
        next.sessions[i].status = .stopped; next.sessions[i].proposal = nil
        _ = event(&next.sessions[i], kind: "stopped", text: "Observer stopped the session."); try commit(next, observerControl: true)
    }
    func reopenSession(_ id: String) throws {
        let i = try index(id); var next = snapshot
        guard next.sessions[i].status.isClosed else { throw ArenaError.invalid("Only closed sessions can be reopened.") }
        next.sessions[i].status = next.sessions[i].participants.allSatisfy { $0.joinedAt != nil } ? .active : .waiting
        next.sessions[i].proposal = nil; next.sessions[i].revision += 1
        _ = event(&next.sessions[i], kind: "reopened", text: "Observer reopened the session."); try commit(next, observerControl: true)
    }
    func attachmentURL(sessionID: String, attachmentID: String) throws -> URL {
        let session = snapshot.sessions[try index(sessionID)]
        guard let attachment = session.attachments.first(where: { $0.id == attachmentID }) else { throw ArenaError.invalid("Attachment not found in this session.") }
        return directory.appendingPathComponent("Attachments").appendingPathComponent(session.id).appendingPathComponent(attachment.storedName)
    }

    private func identity(_ token: String) throws -> (Int, Int) {
        for (i, session) in snapshot.sessions.enumerated() {
            if let p = session.participants.firstIndex(where: { $0.credential == token && $0.joinedAt != nil }) { return (i, p) }
        }
        throw ArenaError.invalid("Invalid participant credential.")
    }
    private func string(_ args: [String: JSONValue], _ key: String, max: Int = 100_000) throws -> String {
        guard let value = args[key]?.stringValue else { throw ArenaError.invalid("\(key) must be a string.") }; return try clean(value, label: key, max: max)
    }
    private func integer(_ args: [String: JSONValue], _ key: String, default fallback: Int? = nil) throws -> Int {
        if let value = args[key]?.intValue { return value }
        if args[key] == nil, let fallback { return fallback }
        throw ArenaError.invalid("\(key) must be an integer.")
    }
    private func strings(_ args: [String: JSONValue], _ key: String) throws -> [String] {
        guard let value = args[key] else { return [] }
        guard case .array(let items) = value, items.count <= 32 else { throw ArenaError.invalid("\(key) must be an array with at most 32 strings.") }
        return try items.map { item in guard let value = item.stringValue else { throw ArenaError.invalid("\(key) must contain strings.") }; return value }
    }
    private func receiptKey(scope: String, request: String) -> String { scope + ":" + request }
    private func fingerprint(tool: String, args: [String: JSONValue]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(JSONValue.object(["tool": .string(tool), "args": .object(args)]))).map { String(format: "%02x", $0) }.joined()
    }
    private func replay(_ key: String, hash: String) throws -> ArenaToolResult? {
        guard let receipt = snapshot.receipts[key] else { return nil }
        guard receipt.fingerprint == hash else { throw ArenaError.invalid("request_id was already used with different input.") }
        return receipt.result
    }
    private func clientToken(_ args: [String: JSONValue]) throws -> String {
        let token = try string(args, "client_token", max: 200)
        guard snapshot.clientTokens?.contains(token) == true else { throw ArenaError.invalid("Invalid client_token; call register_client once and retain its private token across reconnects.") }
        return token
    }
    func execute(tool: String, arguments args: [String: JSONValue]) async throws -> ArenaToolResult {
        try Task.checkCancellation()
        if tool == "register_client" {
            guard (snapshot.clientTokens?.count ?? 0) < 10_000 else { throw ArenaError.invalid("Client registration capacity reached; reuse your saved client_token.") }
            let token = Self.secret()
            var next = snapshot
            next.clientTokens = (next.clientTokens ?? []).union([token])
            try commit(next)
            return ArenaToolResult(data: .object(["client_token": .string(token)]))
        }
        if tool == "list_sessions" {
            let offset = try integer(args, "offset", default: 0), limit = try integer(args, "limit", default: 20)
            guard offset >= 0, (1...50).contains(limit) else { throw ArenaError.invalid("Invalid offset or limit (1–50).") }
            let query = try args["query"].map { _ in try string(args, "query", max: 200) }
            let matches = snapshot.sessions.filter { session in
                query == nil || session.id == query || session.name.localizedCaseInsensitiveContains(query!)
            }
            let page = matches.dropFirst(offset).prefix(limit)
            let data: [JSONValue] = try page.map { session in
                .object(["id": .string(session.id), "name": .string(session.name), "brief_preview": .string(String(session.brief.prefix(240))),
                         "status": .string(session.status.rawValue), "agent_count": .int(session.participants.count),
                         "joined_count": .int(session.participants.filter { $0.joinedAt != nil }.count), "updated_at": try JSONValue.encode(session.updatedAt)])
            }
            return ArenaToolResult(data: .object(["sessions": .array(data), "next_offset": .int(min(offset, matches.count) + data.count), "has_more": .bool(page.count < matches.count - min(offset, matches.count))]))
        }
        if tool == "create_session" {
            let paths = try strings(args, "attachment_paths")
            guard paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }) else { throw ArenaError.invalid("Attachment paths must be absolute and at most 4096 UTF-8 bytes.") }
            let id = try await createSession(name: string(args, "name", max: 200), brief: string(args, "brief"),
                                       agentCount: integer(args, "agent_count", default: 2), files: paths.map { URL(fileURLWithPath: $0) },
                                       requestID: string(args, "request_id", max: 200), clientToken: clientToken(args))
            return ArenaToolResult(data: .object(["session_id": .string(id)]))
        }
        if tool == "join_session" { return try join(args) }
        let token = try string(args, "participant_token", max: 200)
        let (i, p) = try identity(token)
        if tool == "read_session" { return ArenaToolResult(data: try snapshot.sessions[i].publicValue(participant: snapshot.sessions[i].participants[p])) }
        if tool == "read_events" {
            let after = try integer(args, "after_cursor", default: 0), limit = try integer(args, "limit", default: 50), seconds = try integer(args, "wait_seconds", default: 0)
            guard after >= 0, after <= snapshot.sessions[i].latestCursor, (1...100).contains(limit), (0...25).contains(seconds) else { throw ArenaError.invalid("Invalid event cursor, limit (1–100), or wait_seconds (0–25).") }
            let id = snapshot.sessions[i].id
            if after == snapshot.sessions[i].latestCursor, !snapshot.sessions[i].status.isClosed, seconds > 0 { try await wait(session: id, seconds: seconds) }
            try Task.checkCancellation()
            let session = snapshot.sessions[try index(id)]
            let events = Array(session.events.filter { $0.cursor > after }.prefix(limit))
            let cursor = events.last?.cursor ?? after
            return ArenaToolResult(data: .object(["events": try JSONValue.encode(events), "next_cursor": .int(cursor), "has_more": .bool(cursor < session.latestCursor), "status": .string(session.status.rawValue), "revision": .int(session.revision)]))
        }
        if tool == "read_attachment" {
            let session = snapshot.sessions[i], id = try string(args, "attachment_id", max: 100)
            guard let attachment = session.attachments.first(where: { $0.id == id }) else { throw ArenaError.invalid("Attachment not found in this session.") }
            let representation = args["representation"] == nil ? (attachment.mimeType.hasPrefix("image/") ? "image" : "text") : try string(args, "representation", max: 20)
            return try await AttachmentFiles.shared.read(attachment, url: attachmentURL(sessionID: session.id, attachmentID: id), representation: representation, page: integer(args, "page", default: 1), offset: integer(args, "offset", default: 0), limit: integer(args, "limit", default: 20_000))
        }
        guard ["post_message", "attach_file", "propose_outcome", "confirm_outcome"].contains(tool) else { throw ArenaError.invalid("Unknown tool: \(tool).") }
        let request = try string(args, "request_id", max: 200), key = receiptKey(scope: token, request: request), hash = try fingerprint(tool: tool, args: args)
        if let result = try replay(key, hash: hash) { return result }
        if tool == "attach_file" { return try await attach(args, token: token, key: key, hash: hash) }
        var next = snapshot; var session = next.sessions[i]; let participant = session.participants[p]
        guard !session.status.isClosed else { throw ArenaError.invalid("Session is closed; ask an observer to reopen it.") }
        let data: JSONValue
        switch tool {
        case "post_message":
            guard session.status == .active else { throw ArenaError.invalid("Wait until every participant has joined before posting.") }
            let attachments = try strings(args, "attachment_ids"), mentions = try strings(args, "mentions")
            let text: String
            if args["text"] == nil || args["text"] == .string("") { text = "" } else { text = try string(args, "text") }
            guard !text.isEmpty || !attachments.isEmpty else { throw ArenaError.invalid("Message requires text or attachments.") }
            guard attachments.allSatisfy({ id in session.attachments.contains { $0.id == id } }), mentions.allSatisfy({ id in session.participants.contains { $0.id == id } }) else { throw ArenaError.invalid("Message references a participant or attachment outside this session.") }
            let reply = try args["reply_to"].map { _ in try string(args, "reply_to", max: 100) }
            guard reply == nil || session.events.contains(where: { $0.id == reply && $0.kind == "message" }) else { throw ArenaError.invalid("reply_to must reference a message in this session.") }
            session.revision += 1; session.proposal = nil
            data = try JSONValue.encode(event(&session, kind: "message", text: text, participant: participant.id, reply: reply, mentions: mentions, attachments: attachments))
        case "propose_outcome":
            guard session.status == .active else { throw ArenaError.invalid("Outcomes require every participant to join.") }
            let revision = try integer(args, "based_on_revision")
            guard revision == session.revision else { throw ArenaError.invalid("Stale discussion revision; read the session again.") }
            let raw = try string(args, "outcome", max: 20)
            guard let outcome = SessionStatus(rawValue: raw), outcome == .consensus || outcome == .impasse else { throw ArenaError.invalid("outcome must be consensus or impasse.") }
            session.proposal = OutcomeProposal(id: UUID().uuidString, outcome: outcome, assessment: try string(args, "assessment"), revision: revision, confirmations: [])
            _ = event(&session, kind: "proposed", text: "Proposed \(outcome.title): \(session.proposal!.assessment)", participant: participant.id)
            data = .object(["id": .string(session.proposal!.id), "outcome": .string(outcome.rawValue), "revision": .int(revision)])
        default:
            let proposalID = try string(args, "proposal_id", max: 100)
            guard var proposal = session.proposal, proposal.id == proposalID, proposal.revision == session.revision else { throw ArenaError.invalid("Stale assessment; read the session again.") }
            if !proposal.confirmations.contains(participant.id) {
                proposal.confirmations.append(participant.id)
                _ = event(&session, kind: "confirmed", text: "\(participant.name) confirmed \(proposal.outcome.title).", participant: participant.id)
            }
            session.proposal = proposal
            if proposal.confirmations.count == session.participants.count {
                session.status = proposal.outcome
                _ = event(&session, kind: "closed", text: "All participants confirmed \(proposal.outcome.title).")
            }
            data = .object(["id": .string(session.id), "proposal_id": .string(proposal.id), "status": .string(session.status.rawValue), "revision": .int(session.revision), "confirmations": .array(proposal.confirmations.map(JSONValue.string))])
        }
        let result = ArenaToolResult(data: data)
        next.sessions[i] = session; next.receipts[key] = MutationReceipt(fingerprint: hash, result: result)
        try commit(next)
        return result
    }
    private func attach(_ args: [String: JSONValue], token: String, key: String, hash: String) async throws -> ArenaToolResult {
        let (initialIndex, _) = try identity(token)
        let initial = snapshot.sessions[initialIndex]
        guard !initial.status.isClosed, initial.attachments.count < 1_000 else { throw ArenaError.invalid("Session is closed or attachment capacity reached (1,000 files).") }
        let path = try string(args, "path", max: 4_096)
        guard path.hasPrefix("/") else { throw ArenaError.invalid("Attachment path must be absolute.") }
        let destination = directory.appendingPathComponent("Attachments").appendingPathComponent(initial.id)
        let attachment = try await AttachmentFiles.shared.importFile(URL(fileURLWithPath: path), directory: destination, isBrief: false)
        var saved = false
        defer { if !saved { try? FileManager.default.removeItem(at: destination.appendingPathComponent(attachment.storedName)) } }
        try Task.checkCancellation()
        // The worker suspended this actor: recheck receipt, identity, and lifecycle against fresh state before committing.
        if let result = try replay(key, hash: hash) { return result }
        let (i, p) = try identity(token)
        var next = snapshot
        guard !next.sessions[i].status.isClosed, next.sessions[i].attachments.count < 1_000 else { throw ArenaError.invalid("Session is closed or attachment capacity reached (1,000 files).") }
        next.sessions[i].attachments.append(attachment)
        _ = event(&next.sessions[i], kind: "attached", text: "Added attachment: " + attachment.name, participant: next.sessions[i].participants[p].id, attachments: [attachment.id])
        let result = ArenaToolResult(data: attachment.publicValue)
        next.receipts[key] = MutationReceipt(fingerprint: hash, result: result)
        try commit(next)
        saved = true
        return result
    }
    private func join(_ args: [String: JSONValue]) throws -> ArenaToolResult {
        let invitation = try args["invitation"].map { _ in try string(args, "invitation", max: 200) }
        let sessionID = try args["session_id"].map { _ in try string(args, "session_id", max: 100) }
        guard (invitation == nil) != (sessionID == nil) else { throw ArenaError.invalid("Supply exactly one of invitation or session_id.") }
        let request = try string(args, "request_id", max: 200)
        let scope = try invitation ?? ("join_session:" + clientToken(args))
        let key = receiptKey(scope: scope, request: request), hash = try fingerprint(tool: "join_session", args: args)
        if let receipt = snapshot.receipts[key] {
            guard receipt.fingerprint == hash else { throw ArenaError.invalid("request_id was already used with different input.") }; return receipt.result
        }
        let i: Int
        let p: Int
        if let sessionID {
            i = try index(sessionID)
            guard let available = snapshot.sessions[i].participants.firstIndex(where: { $0.joinedAt == nil }) else {
                throw ArenaError.invalid("Session is full; resume with your participant_token or choose another session.")
            }
            p = available
        } else {
            guard let found = snapshot.sessions.firstIndex(where: { $0.participants.contains { $0.invitation == invitation } }),
                  let slot = snapshot.sessions[found].participants.firstIndex(where: { $0.invitation == invitation }) else { throw ArenaError.invalid("Invalid invitation.") }
            i = found; p = slot
        }
        guard snapshot.sessions[i].participants[p].joinedAt == nil else { throw ArenaError.invalid("Invitation already redeemed; resume using the original participant credential and request_id.") }
        guard !snapshot.sessions[i].status.isClosed else { throw ArenaError.invalid("Session is closed.") }
        var next = snapshot
        next.sessions[i].participants[p].client = try string(args, "client", max: 100)
        next.sessions[i].participants[p].model = try string(args, "model", max: 100)
        next.sessions[i].participants[p].joinedAt = .now
        let participant = next.sessions[i].participants[p]
        if next.sessions[i].participants.allSatisfy({ $0.joinedAt != nil }) { next.sessions[i].status = .active }
        _ = event(&next.sessions[i], kind: "joined", text: "\(participant.name) joined.", participant: participant.id)
        var projection = try next.sessions[i].publicValue(participant: participant).objectValue!
        projection["participant_token"] = .string(participant.credential)
        let result = ArenaToolResult(data: .object(projection))
        next.receipts[key] = MutationReceipt(fingerprint: hash, result: result)
        try commit(next); return result
    }
    private func wait(session: String, seconds: Int) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let timer = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    self?.finishWait(id)
                }
                waiters[id] = (session, continuation, timer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishWait(id, error: CancellationError()) }
        }
    }
    private func finishWait(_ id: UUID, error: (any Error)? = nil) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timer.cancel()
        if let error { waiter.continuation.resume(throwing: error) } else { waiter.continuation.resume() }
    }
}

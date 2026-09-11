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
    var sessionID: String?
}
private struct ArenaSnapshot: Codable {
    var sessions: [ArenaSession] = []
    var receipts: [String: MutationReceipt] = [:]
    var clientTokens: Set<String>?
    var retiredRequests: Set<String>?
}

@MainActor @Observable
final class ArenaStore {
    private(set) var sessions: [ArenaSession]
    private(set) var retentionError: String?
    private let directory: URL
    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private let saveContext: (ModelContext) throws -> Void
    @ObservationIgnored private var importingSessions = Set<String>()
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
        var migrated = snapshot
        for i in migrated.sessions.indices where migrated.sessions[i].status == .waiting && migrated.sessions[i].joinedParticipants.count >= 2 {
            migrated.sessions[i].status = .active
            migrated.sessions[i].proposal = nil
            migrated.sessions[i].revision += 1
            _ = event(&migrated.sessions[i], kind: "opened", text: "Session now accepts agents without a preset roster.")
        }
        if migrated.sessions.map(\.latestCursor) != snapshot.sessions.map(\.latestCursor) { try commit(migrated, observerControl: true) }
        maintainRetention()
    }

    private func commit(_ next: ArenaSnapshot, observerControl: Bool = false) throws {
        // ponytail: bounded snapshot rewrites suit a local MVP; normalize rows when large histories make saves slow.
        // Observer controls remain available at the agent history ceiling. Receipts are never evicted: old retries must not execute again.
        guard observerControl || (next.sessions.count <= 200 && next.sessions.reduce(0, { $0 + $1.events.count }) <= 100_000 && (next.receipts.count + (next.retiredRequests?.count ?? 0)) <= 100_000) else { throw ArenaError.invalid("Local history capacity reached (200 sessions / 100,000 events or operations).") }
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
        for (id, waiter) in waiters where changed.contains(waiter.session) || !next.sessions.contains(where: { $0.id == waiter.session }) { finishWait(id) }
    }
    private func index(_ id: String) throws -> Int {
        guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { throw ArenaError.invalid("Session not found.") }; return index
    }
    private func clean(_ value: String, label: String, max: Int) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= max else { throw ArenaError.invalid("\(label) is required and must be at most \(max) UTF-8 bytes.") }; return value
    }
    private func newParticipant(in session: ArenaSession) throws -> Participant {
        guard session.participants.count < 100 else { throw ArenaError.invalid("Local session capacity reached (100 identities).") }
        let index = session.participants.count
        let unused = Self.names.filter { name in !session.participants.contains { $0.name == name } }
        let name = unused.randomElement() ?? "\(Self.names[index % Self.names.count]) \(index / Self.names.count + 1)"
        return Participant(id: UUID().uuidString, name: name, invitation: Self.secret(), credential: Self.secret(), index: index)
    }
    private static func secret() -> String { UUID().uuidString + UUID().uuidString }
    private func event(_ session: inout ArenaSession, kind: String, text: String, participant: String? = nil, reply: String? = nil, mentions: [String] = [], attachments: [String] = [], messageType: String? = nil) -> ArenaEvent {
        let event = ArenaEvent(cursor: session.latestCursor + 1, kind: kind, text: text, participantID: participant, replyTo: reply, mentions: mentions, attachmentIDs: attachments, messageType: messageType)
        session.events.append(event); session.updatedAt = event.createdAt
        return event
    }
    func createSession(name: String, brief: String, legacyAgentCount: Int = 2, files: [URL] = [], requestID: String? = nil, clientToken: String? = nil) async throws -> String {
        let key: String?
        if let requestID {
            guard let clientToken, snapshot.clientTokens?.contains(clientToken) == true else { throw ArenaError.invalid("Call register_client and retain its private client_token before creating a session.") }
            key = receiptKey(scope: "create_session:" + clientToken, request: try clean(requestID, label: "request_id", max: 200))
        } else { key = nil }
        // Preserve legacy creation retry fingerprints; agent_count no longer reserves identities.
        let hash = try fingerprint(tool: "create_session", args: ["name": .string(name), "brief": .string(brief), "agent_count": .int(legacyAgentCount), "files": .array(files.map { .string($0.path) })])
        if let key, let receipt = try replay(key, hash: hash), let id = receipt.data.objectValue?["session_id"]?.stringValue { return id }
        let id = UUID().uuidString
        var session = ArenaSession(id: id, name: try clean(name, label: "Session name", max: 200), brief: try clean(brief, label: "Brief", max: 100_000), status: .waiting, revision: 0, createdAt: .now, updatedAt: .now, participants: [], events: [], attachments: [])
        guard files.count <= 32 else { throw ArenaError.invalid("At most 32 brief attachments are supported.") }
        let attachmentDirectory = directory.appendingPathComponent("Attachments").appendingPathComponent(id)
        importingSessions.insert(id)
        defer { importingSessions.remove(id) }
        do {
            for file in files { session.attachments.append(try await AttachmentFiles.shared.importFile(file, directory: attachmentDirectory, isBrief: true)) }
            try Task.checkCancellation()
            if let key, let receipt = try replay(key, hash: hash), let previousID = receipt.data.objectValue?["session_id"]?.stringValue {
                try? FileManager.default.removeItem(at: attachmentDirectory)
                return previousID
            }
            _ = event(&session, kind: "setup", text: "Session created. Open for agents to join.")
            var next = snapshot; next.sessions.insert(session, at: 0)
            if let key { next.receipts[key] = MutationReceipt(fingerprint: hash, result: ArenaToolResult(data: .object(["session_id": .string(id)])), sessionID: id) }
            try commit(next)
        } catch { try? FileManager.default.removeItem(at: attachmentDirectory); throw error }
        return id
    }
    func editSession(_ id: String, name: String, brief: String) throws {
        let i = try index(id)
        let name = try clean(name, label: "Session name", max: 200)
        let brief = try clean(brief, label: "Brief", max: 100_000)
        let session = snapshot.sessions[i]
        guard !session.isStoredAway else { throw ArenaError.invalid("Restore this session before editing it.") }
        let setupChanged = brief != session.brief
        guard setupChanged || name != session.name else { return }
        if setupChanged {
            guard session.status == .waiting, session.participants.allSatisfy({ $0.joinedAt == nil }) else {
                throw ArenaError.invalid("Setup is locked after joining begins or while the session is closed.")
            }
        }
        var next = snapshot
        if setupChanged {
            next.sessions[i].brief = brief
            _ = event(&next.sessions[i], kind: "setup", text: "Brief updated.")
        }
        if name != session.name {
            next.sessions[i].name = name
            _ = event(&next.sessions[i], kind: "renamed", text: "Session renamed to \(name).")
        }
        try commit(next, observerControl: true)
    }
    func acceptAnswer(_ id: String, eventID: String) throws {
        let i = try index(id)
        var next = snapshot
        var session = next.sessions[i]
        guard !session.status.isClosed else { throw ArenaError.invalid("Session is already closed.") }
        guard let source = session.events.first(where: { $0.id == eventID && $0.kind == "proposed" }),
              let author = session.joinedParticipants.first(where: { $0.id == source.participantID }) else {
            throw ArenaError.invalid("Choose an explicit agent proposal from this session.")
        }
        let assessment = String(source.text.split(separator: ":", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
        session.proposal = OutcomeProposal(id: UUID().uuidString, outcome: .consensus, assessment: assessment,
                                          revision: session.revision, confirmations: [], acceptedEventID: source.id)
        session.status = .consensus
        session.turn = nil
        _ = event(&session, kind: "accepted", text: "Observer accepted \(author.name)’s answer. Discussion closed.", participant: author.id, reply: source.id)
        next.sessions[i] = session
        try commit(next, observerControl: true)
    }
    func stopSession(_ id: String) throws {
        let i = try index(id); var next = snapshot
        guard !next.sessions[i].status.isClosed else { throw ArenaError.invalid("Session is already closed.") }
        next.sessions[i].turn = nil
        next.sessions[i].status = .stopped; next.sessions[i].proposal = nil
        _ = event(&next.sessions[i], kind: "stopped", text: "Observer stopped the session."); try commit(next, observerControl: true)
    }
    func reopenSession(_ id: String) throws {
        let i = try index(id); var next = snapshot
        guard next.sessions[i].status.isClosed, !next.sessions[i].isStoredAway else { throw ArenaError.invalid("Restore archived or deleted sessions before reopening them.") }
        next.sessions[i].status = next.sessions[i].joinedParticipants.count >= 2 ? .active : .waiting
        next.sessions[i].turn = nil
        next.sessions[i].proposal = nil; next.sessions[i].revision += 1
        _ = event(&next.sessions[i], kind: "reopened", text: "Observer reopened the session."); try commit(next, observerControl: true)
    }
    func archiveSession(_ id: String, now: Date = .now) throws {
        try applyRetention(now: now)
        let i = try index(id)
        guard !snapshot.sessions[i].isStoredAway else { throw ArenaError.invalid("Session is already archived or deleted.") }
        var next = snapshot
        stopForStorage(&next.sessions[i])
        next.sessions[i].archivedAt = now
        _ = event(&next.sessions[i], kind: "archived", text: "Observer archived the session. Moves to Recently Deleted after 90 days.")
        try commit(next, observerControl: true)
    }

    func deleteSession(_ id: String, now: Date = .now) throws {
        try applyRetention(now: now)
        let i = try index(id)
        guard snapshot.sessions[i].deletedAt == nil else { throw ArenaError.invalid("Session is already deleted.") }
        var next = snapshot
        stopForStorage(&next.sessions[i])
        next.sessions[i].deletedAt = now
        _ = event(&next.sessions[i], kind: "deleted", text: "Observer deleted the session. Recoverable for 7 days.")
        try commit(next, observerControl: true)
    }

    func restoreSession(_ id: String, now: Date = .now) throws {
        try applyRetention(now: now)
        let i = try index(id)
        guard snapshot.sessions[i].isStoredAway else { throw ArenaError.invalid("Session is not archived or deleted.") }
        var next = snapshot
        next.sessions[i].archivedAt = nil; next.sessions[i].deletedAt = nil
        _ = event(&next.sessions[i], kind: "restored", text: "Observer restored the session. Reopen separately to resume discussion.")
        try commit(next, observerControl: true)
    }

    private func stopForStorage(_ session: inout ArenaSession) {
        session.turn = nil
        if !session.status.isClosed {
            session.status = .stopped; session.proposal = nil
            _ = event(&session, kind: "stopped", text: "Observer stopped the discussion by archiving or deleting it.")
        }
    }

    func maintainRetention(now: Date = .now) {
        do { try applyRetention(now: now); retentionError = nil }
        catch { retentionError = "Session cleanup failed: " + error.localizedDescription }
    }

    private func retiredKey(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func applyRetention(now: Date = .now) throws {
        var next = snapshot
        var changed = false
        for i in next.sessions.indices {
            if let archived = next.sessions[i].archivedAt, next.sessions[i].deletedAt == nil,
               now >= archived.addingTimeInterval(ArenaSession.archiveLifetime) {
                stopForStorage(&next.sessions[i])
                next.sessions[i].deletedAt = archived.addingTimeInterval(ArenaSession.archiveLifetime)
                _ = event(&next.sessions[i], kind: "deleted", text: "Archive retention ended. Moved to Recently Deleted for 7 days.")
                changed = true
            }
        }
        let expired = next.sessions.filter { $0.deletedAt.map { now >= $0.addingTimeInterval(ArenaSession.deletionLifetime) } ?? false }
        if !expired.isEmpty {
            let ids = Set(expired.map(\.id))
            let scopes = expired.flatMap { $0.participants.flatMap { [$0.credential + ":", $0.invitation + ":"] } }
            let keys = next.receipts.filter { key, receipt in
                receipt.sessionID.map(ids.contains) == true || scopes.contains(where: key.hasPrefix) ||
                receipt.result.data.objectValue?["session_id"]?.stringValue.map(ids.contains) == true ||
                (key.hasPrefix("join_session:") && receipt.result.data.objectValue?["id"]?.stringValue.map(ids.contains) == true)
            }.map(\.key)
            for key in keys { next.receipts.removeValue(forKey: key) }
            // Keep only hashes of retired request keys, never transcript payloads. Old retries cannot recreate deleted sessions.
            next.retiredRequests = (next.retiredRequests ?? []).union(keys.map(retiredKey))
            next.sessions.removeAll { ids.contains($0.id) }
            changed = true
        }
        if changed { try commit(next, observerControl: true) }
        // Delete copies only after the database save. Retrying also removes files left by an interrupted cleanup.
        let attachments = directory.appendingPathComponent("Attachments")
        if FileManager.default.fileExists(atPath: attachments.path) {
            let live = Set(snapshot.sessions.map(\.id)).union(importingSessions)
            for folder in try FileManager.default.contentsOfDirectory(at: attachments, includingPropertiesForKeys: nil)
                where UUID(uuidString: folder.lastPathComponent) != nil && !live.contains(folder.lastPathComponent) {
                try FileManager.default.removeItem(at: folder)
            }
        }
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
        guard snapshot.retiredRequests?.contains(retiredKey(key)) != true else { throw ArenaError.invalid("This request belongs to a permanently deleted session and cannot be replayed.") }
        guard let receipt = snapshot.receipts[key] else { return nil }
        if let id = receipt.sessionID ?? receipt.result.data.objectValue?["session_id"]?.stringValue ?? receipt.result.data.objectValue?["id"]?.stringValue,
           snapshot.sessions.contains(where: { $0.id == id && $0.deletedAt != nil }) {
            throw ArenaError.invalid("Session was deleted by the observer. Stop the discussion.")
        }
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
                !session.isStoredAway && (query == nil || session.id == query || session.name.localizedCaseInsensitiveContains(query!))
            }
            let page = matches.dropFirst(offset).prefix(limit)
            let data: [JSONValue] = try page.map { session in
                .object(["id": .string(session.id), "name": .string(session.name), "brief_preview": .string(String(session.brief.prefix(240))),
                         "status": .string(session.status.rawValue), "agent_count": .int(session.joinedParticipants.count),
                         "joined_count": .int(session.participants.filter { $0.joinedAt != nil }.count), "updated_at": try JSONValue.encode(session.updatedAt)])
            }
            return ArenaToolResult(data: .object(["sessions": .array(data), "next_offset": .int(min(offset, matches.count) + data.count), "has_more": .bool(page.count < matches.count - min(offset, matches.count))]))
        }
        if tool == "create_session" {
            let paths = try strings(args, "attachment_paths")
            guard paths.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 }) else { throw ArenaError.invalid("Attachment paths must be absolute and at most 4096 UTF-8 bytes.") }
            let id = try await createSession(name: string(args, "name", max: 200), brief: string(args, "brief"),
                                       legacyAgentCount: integer(args, "agent_count", default: 2), files: paths.map { URL(fileURLWithPath: $0) },
                                       requestID: string(args, "request_id", max: 200), clientToken: clientToken(args))
            return ArenaToolResult(data: .object(["session_id": .string(id)]))
        }
        if tool == "join_session" { return try join(args) }
        let token = try string(args, "participant_token", max: 200)
        let (i, p) = try identity(token)
        guard snapshot.sessions[i].deletedAt == nil else { throw ArenaError.invalid("Session was deleted by the observer. Stop the discussion; only the observer can restore it.") }
        if tool == "read_session" { return ArenaToolResult(data: try snapshot.sessions[i].publicValue(participant: snapshot.sessions[i].participants[p])) }
        if tool == "read_events" {
            let after = try integer(args, "after_cursor", default: 0), limit = try integer(args, "limit", default: 50), seconds = try integer(args, "wait_seconds", default: 0)
            guard after >= 0, after <= snapshot.sessions[i].latestCursor, (1...100).contains(limit), (0...25).contains(seconds) else { throw ArenaError.invalid("Invalid event cursor, limit (1–100), or wait_seconds (0–25).") }
            let id = snapshot.sessions[i].id
            if after == snapshot.sessions[i].latestCursor, !snapshot.sessions[i].status.isClosed, seconds > 0 { try await wait(session: id, seconds: seconds) }
            try Task.checkCancellation()
            let session = snapshot.sessions[try index(id)]
            let events = session.deletedAt == nil ? Array(session.events.filter { $0.cursor > after }.prefix(limit)) : []
            let cursor = session.deletedAt == nil ? (events.last?.cursor ?? after) : session.latestCursor
            return ArenaToolResult(data: .object(["events": try JSONValue.encode(events), "next_cursor": .int(cursor), "has_more": .bool(cursor < session.latestCursor), "status": .string(session.status.rawValue), "revision": .int(session.revision), "turn": try session.turn.map(JSONValue.encode) ?? .null]))
        }
        if tool == "read_attachment" {
            let session = snapshot.sessions[i], id = try string(args, "attachment_id", max: 100)
            guard let attachment = session.attachments.first(where: { $0.id == id }) else { throw ArenaError.invalid("Attachment not found in this session.") }
            let representation = args["representation"] == nil ? (attachment.mimeType.hasPrefix("image/") ? "image" : "text") : try string(args, "representation", max: 20)
            return try await AttachmentFiles.shared.read(attachment, url: attachmentURL(sessionID: session.id, attachmentID: id), representation: representation, page: integer(args, "page", default: 1), offset: integer(args, "offset", default: 0), limit: integer(args, "limit", default: 20_000))
        }
        guard ["start_turn", "finish_turn", "post_message", "attach_file", "propose_outcome", "confirm_outcome"].contains(tool) else { throw ArenaError.invalid("Unknown tool: \(tool).") }
        let request = try string(args, "request_id", max: 200), key = receiptKey(scope: token, request: request), hash = try fingerprint(tool: tool, args: args)
        if let result = try replay(key, hash: hash) { return result }
        if tool == "attach_file" { return try await attach(args, token: token, key: key, hash: hash) }
        var next = snapshot; var session = next.sessions[i]; let participant = session.participants[p]
        guard !session.status.isClosed else { throw ArenaError.invalid("Session is closed; ask an observer to reopen it.") }
        if ["post_message", "propose_outcome", "finish_turn"].contains(tool) {
            let turnID = try string(args, "turn_id", max: 100)
            guard let turn = session.turn, turn.id == turnID, turn.participantID == participant.id,
                  turn.phase != .offered else {
                throw ArenaError.invalid("You do not hold this turn. Read the session, wait for the handoff, then call start_turn before posting.")
            }
        }
        let data: JSONValue
        switch tool {
        case "start_turn":
            if let turn = session.turn, turn.participantID != participant.id {
                let owner = session.participants.first { $0.id == turn.participantID }?.name ?? "Another agent"
                throw ArenaError.invalid("\(owner) holds the turn. Wait with read_events until it is passed to you or released.")
            }
            // Ownership survives disconnects; a timeout must never steal an unfinished turn.
            var turn = session.turn ?? DiscussionTurn(participantID: participant.id)
            turn.phase = .thinking; turn.updatedAt = .now
            session.turn = turn
            _ = event(&session, kind: "turn_started", text: "\(participant.name) is formulating a response.", participant: participant.id)
            data = try JSONValue.encode(turn)
        case "finish_turn":
            let recipient = try args["next_participant_id"].map { _ in try string(args, "next_participant_id", max: 100) }
            if let recipient {
                guard recipient != participant.id, let peer = session.joinedParticipants.first(where: { $0.id == recipient }) else {
                    throw ArenaError.invalid("Pass to a different joined participant in this session, or omit next_participant_id to release the turn.")
                }
                session.turn = DiscussionTurn(participantID: recipient, phase: .offered)
                _ = event(&session, kind: "turn_passed", text: "\(participant.name) passed the turn to \(peer.name).", participant: participant.id, mentions: [recipient])
            } else {
                session.turn = nil
                _ = event(&session, kind: "turn_released", text: "\(participant.name) finished. The turn is open.", participant: participant.id)
            }
            data = .object(["turn": try session.turn.map(JSONValue.encode) ?? .null])
        case "post_message":
            let attachments = try strings(args, "attachment_ids"), mentions = try strings(args, "mentions")
            let text: String
            if args["text"] == nil || args["text"] == .string("") { text = "" } else { text = try string(args, "text") }
            guard !text.isEmpty || !attachments.isEmpty else { throw ArenaError.invalid("Message requires text or attachments.") }
            guard attachments.allSatisfy({ id in session.attachments.contains { $0.id == id } }), mentions.allSatisfy({ id in session.participants.contains { $0.id == id } }) else { throw ArenaError.invalid("Message references a participant or attachment outside this session.") }
            let messageType = args["message_type"] == nil ? "comment" : try string(args, "message_type", max: 20)
            guard ["comment", "rebuttal"].contains(messageType) else { throw ArenaError.invalid("message_type must be comment or rebuttal; use propose_outcome for an explicit proposal.") }
            let reply = try args["reply_to"].map { _ in try string(args, "reply_to", max: 100) }
            guard messageType != "rebuttal" || reply != nil else { throw ArenaError.invalid("A rebuttal must reply_to the comment or proposal it challenges.") }
            guard reply == nil || session.events.contains(where: { $0.id == reply && ["message", "proposed"].contains($0.kind) }) else { throw ArenaError.invalid("reply_to must reference a message or proposal in this session.") }
            session.turn?.phase = .speaking; session.turn?.updatedAt = .now
            session.revision += 1; session.proposal = nil
            data = try JSONValue.encode(event(&session, kind: "message", text: text, participant: participant.id, reply: reply, mentions: mentions, attachments: attachments, messageType: messageType))
        case "propose_outcome":
            let revision = try integer(args, "based_on_revision")
            guard revision == session.revision else { throw ArenaError.invalid("Stale discussion revision; read the session again.") }
            let raw = try string(args, "outcome", max: 20)
            guard let outcome = SessionStatus(rawValue: raw), outcome == .consensus || outcome == .impasse else { throw ArenaError.invalid("outcome must be consensus or impasse.") }
            session.turn?.phase = .speaking; session.turn?.updatedAt = .now
            session.proposal = OutcomeProposal(id: UUID().uuidString, outcome: outcome, assessment: try string(args, "assessment"), revision: revision, confirmations: [])
            let proposed = event(&session, kind: "proposed", text: "Proposed \(outcome.title): \(session.proposal!.assessment)", participant: participant.id)
            session.proposal!.sourceEventID = proposed.id
            data = .object(["id": .string(session.proposal!.id), "event_id": .string(proposed.id), "outcome": .string(outcome.rawValue), "revision": .int(revision)])
        default:
            let proposalID = try string(args, "proposal_id", max: 100)
            guard var proposal = session.proposal, proposal.id == proposalID, proposal.revision == session.revision else { throw ArenaError.invalid("Stale assessment; read the session again.") }
            if !proposal.confirmations.contains(participant.id) {
                proposal.confirmations.append(participant.id)
                _ = event(&session, kind: "confirmed", text: "\(participant.name) confirmed \(proposal.outcome.title).", participant: participant.id)
            }
            session.proposal = proposal
            if session.joinedParticipants.count >= 2 && Set(proposal.confirmations) == Set(session.joinedParticipants.map(\.id)) {
                session.status = proposal.outcome
                session.turn = nil
                _ = event(&session, kind: "closed", text: "All participants confirmed \(proposal.outcome.title).")
            }
            data = .object(["id": .string(session.id), "proposal_id": .string(proposal.id), "status": .string(session.status.rawValue), "revision": .int(session.revision), "confirmations": .array(proposal.confirmations.map(JSONValue.string))])
        }
        let result = ArenaToolResult(data: data)
        next.sessions[i] = session; next.receipts[key] = MutationReceipt(fingerprint: hash, result: result, sessionID: session.id)
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
        next.receipts[key] = MutationReceipt(fingerprint: hash, result: result, sessionID: next.sessions[i].id)
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
        if let result = try replay(key, hash: hash) { return result }
        var next = snapshot
        let i: Int
        let p: Int
        let registration: String?
        if let sessionID {
            i = try index(sessionID)
            let registered = try clientToken(args)
            registration = registered
            // Older versions saved the client binding only in private join receipts.
            let priorCredential = snapshot.receipts.first {
                $0.key.hasPrefix("join_session:\(registered):") && $0.value.result.data.objectValue?["id"]?.stringValue == sessionID
            }?.value.result.data.objectValue?["participant_token"]?.stringValue
            if let existing = next.sessions[i].participants.firstIndex(where: { ($0.registrationToken == registered || $0.credential == priorCredential) && $0.joinedAt != nil }) {
                p = existing
            } else {
                guard !next.sessions[i].status.isClosed else { throw ArenaError.invalid("Session is closed.") }
                if let available = next.sessions[i].participants.firstIndex(where: { $0.joinedAt == nil }) { p = available }
                else {
                    p = next.sessions[i].participants.count
                    next.sessions[i].participants.append(try newParticipant(in: next.sessions[i]))
                }
            }
        } else {
            registration = nil
            guard let found = snapshot.sessions.firstIndex(where: { $0.participants.contains { $0.invitation == invitation } }),
                  let slot = snapshot.sessions[found].participants.firstIndex(where: { $0.invitation == invitation }) else { throw ArenaError.invalid("Invalid invitation.") }
            i = found; p = slot
            guard next.sessions[i].participants[p].joinedAt == nil else { throw ArenaError.invalid("Invitation already redeemed; resume using the original participant credential and request_id.") }
            guard !next.sessions[i].status.isClosed else { throw ArenaError.invalid("Session is closed.") }
        }
        guard next.sessions[i].deletedAt == nil else { throw ArenaError.invalid("Session was deleted by the observer. Stop the discussion.") }
        if let registration { next.sessions[i].participants[p].registrationToken = registration }
        if next.sessions[i].participants[p].joinedAt == nil {
            next.sessions[i].participants[p].client = try string(args, "client", max: 100)
            next.sessions[i].participants[p].model = try string(args, "model", max: 100)
            next.sessions[i].participants[p].joinedAt = .now
            next.sessions[i].status = next.sessions[i].joinedParticipants.count >= 2 ? .active : .waiting
            next.sessions[i].revision += 1
            next.sessions[i].proposal = nil
            _ = event(&next.sessions[i], kind: "joined", text: "\(next.sessions[i].participants[p].name) joined.", participant: next.sessions[i].participants[p].id)
        }
        let participant = next.sessions[i].participants[p]
        var projection = try next.sessions[i].publicValue(participant: participant).objectValue!
        projection["participant_token"] = .string(participant.credential)
        let result = ArenaToolResult(data: .object(projection))
        next.receipts[key] = MutationReceipt(fingerprint: hash, result: result, sessionID: next.sessions[i].id)
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

import Foundation
import SwiftData
import XCTest
@testable import Arena

@MainActor
final class TurnRetentionTests: XCTestCase {
    private var directories: [URL] = []
    private func makeStore(save: @escaping (ModelContext) throws -> Void = { try $0.save() }) throws -> (ArenaStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ArenaTurns-" + UUID().uuidString)
        directories.append(directory)
        return (try ArenaStore(directory: directory, save: save), directory)
    }
    override func tearDown() async throws { for directory in directories { try? FileManager.default.removeItem(at: directory) } }
    private func call(_ store: ArenaStore, _ name: String, _ token: String, _ args: [String: JSONValue] = [:], request: String = UUID().uuidString) async throws -> JSONValue {
        var args = args; args["participant_token"] = .string(token); args["request_id"] = .string(request)
        return try await store.execute(tool: name, arguments: args).data
    }
    private func join(_ store: ArenaStore, _ id: String) async throws -> String {
        let registration = try await store.execute(tool: "register_client", arguments: [:]).data.objectValue!["client_token"]!
        let result = try await store.execute(tool: "join_session", arguments: ["client_token": registration, "session_id": .string(id), "request_id": .string(UUID().uuidString), "client": .string("test"), "model": .string("test")])
        return try XCTUnwrap(result.data.objectValue?["participant_token"]?.stringValue)
    }
    private func rejected(_ operation: () async throws -> Void) async {
        do { try await operation(); XCTFail("Expected rejection") } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
    }

    func testExclusiveTurnsHandoffRetriesAndRestart() async throws {
        let (store, directory) = try makeStore()
        let id = try await store.createSession(name: "Turns", brief: "Review")
        let a = try await join(store, id), b = try await join(store, id), c = try await join(store, id)
        let revision = store.sessions[0].revision
        let started = try await call(store, "start_turn", a, request: "start")
        let turn = try XCTUnwrap(started.objectValue?["id"]?.stringValue)
        let cursor = store.sessions[0].latestCursor
        let duplicate = try await call(store, "start_turn", a, request: "start")
        XCTAssertEqual(duplicate, started)
        XCTAssertEqual(store.sessions[0].latestCursor, cursor)
        await rejected { _ = try await self.call(store, "start_turn", b) }
        await rejected { _ = try await self.call(store, "post_message", b, ["turn_id": .string(turn), "text": .string("Interrupt")]) }
        _ = try await call(store, "post_message", a, ["turn_id": .string(turn), "text": .string("Part one")], request: "message")
        _ = try await call(store, "start_turn", a)
        XCTAssertTrue(store.sessions[0].turn!.isThinking(at: .now))
        _ = try await call(store, "post_message", a, ["turn_id": .string(turn), "text": .string("Part two")])
        XCTAssertEqual(store.sessions[0].revision, revision + 2)
        let restored = try ArenaStore(directory: directory)
        XCTAssertEqual(restored.sessions[0].turn?.id, turn)
        let waiting = Task { try await self.call(store, "read_events", b, ["after_cursor": .int(store.sessions[0].latestCursor), "wait_seconds": .int(25)]) }
        for _ in 0..<100 where store.pendingWaitCount == 0 { await Task.yield() }
        let recipient = store.sessions[0].participants[1].id
        let passed = try await call(store, "finish_turn", a, ["turn_id": .string(turn), "next_participant_id": .string(recipient)], request: "pass")
        let wake = try await waiting.value
        XCTAssertEqual(wake.objectValue?["turn"]?.objectValue?["participantID"], .string(recipient))
        XCTAssertEqual(store.pendingWaitCount, 0)
        let offered = store.sessions[0].turn!.id
        await rejected { _ = try await self.call(store, "start_turn", c) }
        await rejected { _ = try await self.call(store, "post_message", b, ["turn_id": .string(offered), "text": .string("Must take the turn first")]) }
        _ = try await call(store, "start_turn", b)
        _ = try await call(store, "finish_turn", b, ["turn_id": .string(offered)])
        _ = try await call(store, "start_turn", a)
        let newTurn = store.sessions[0].turn!.id
        XCTAssertNotEqual(turn, newTurn)
        let replayed = try await call(store, "finish_turn", a, ["turn_id": .string(turn), "next_participant_id": .string(recipient)], request: "pass")
        XCTAssertEqual(replayed, passed)
        XCTAssertEqual(store.sessions[0].turn?.id, newTurn)
        await rejected { _ = try await self.call(store, "post_message", a, ["turn_id": .string(turn), "text": .string("Delayed old write")]) }
        _ = try await call(store, "post_message", a, ["turn_id": .string(turn), "text": .string("Part one")], request: "message")
        XCTAssertEqual(store.sessions[0].events.filter { $0.kind == "message" }.count, 2)
        await rejected { _ = try await self.call(store, "finish_turn", a, ["turn_id": .string(newTurn), "next_participant_id": .string("foreign")]) }
        try store.stopSession(id)
        XCTAssertNil(store.sessions[0].turn)
        try store.reopenSession(id)
        XCTAssertNil(store.sessions[0].turn)
    }

    func testConcurrentClaimsAndOutcomeConfirmationDuringTurn() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createSession(name: "Race", brief: "Review")
        let a = try await join(store, id), b = try await join(store, id)
        let claims = [a, b].map { token in Task { try? await self.call(store, "start_turn", token) } }
        var successes = 0
        for claim in claims { if await claim.value != nil { successes += 1 } }
        XCTAssertEqual(successes, 1)
        let turn = store.sessions[0].turn!
        let owner = store.sessions[0].participants.first { $0.id == turn.participantID }!.credential
        let proposal = try await call(store, "propose_outcome", owner, ["turn_id": .string(turn.id), "outcome": .string("consensus"), "assessment": .string("Bounded waits"), "based_on_revision": .int(store.sessions[0].revision)])
        let pid = proposal.objectValue!["id"]!
        _ = try await call(store, "confirm_outcome", a, ["proposal_id": pid])
        _ = try await call(store, "confirm_outcome", b, ["proposal_id": pid])
        XCTAssertEqual(store.sessions[0].status, .consensus)
        XCTAssertNil(store.sessions[0].turn)
        await rejected { _ = try await self.call(store, "start_turn", owner) }
        var stale = turn; stale.phase = .thinking
        XCTAssertFalse(stale.isThinking(at: stale.updatedAt.addingTimeInterval(120)))
    }

    func testArchiveDeleteRestoreAndExactRetentionBoundaries() async throws {
        let (store, directory) = try makeStore()
        let id = try await store.createSession(name: "Keep", brief: "Review")
        let token = try await join(store, id)
        _ = try await call(store, "start_turn", token)
        let now = Date()
        try store.archiveSession(id, now: now)
        XCTAssertEqual(store.sessions[0].status, .stopped)
        XCTAssertNil(store.sessions[0].turn)
        XCTAssertTrue(SessionFolder.archive.contains(store.sessions[0]))
        XCTAssertThrowsError(try store.reopenSession(id))
        let listing = try await store.execute(tool: "list_sessions", arguments: [:]).data.objectValue!["sessions"]!
        XCTAssertEqual(listing, .array([]))
        try store.restoreSession(id, now: now.addingTimeInterval(1))
        XCTAssertEqual(store.sessions[0].status, .stopped)
        XCTAssertTrue(SessionFolder.sessions.contains(store.sessions[0]))
        try store.reopenSession(id)
        try store.archiveSession(id, now: now)
        let archiveDeadline = now.addingTimeInterval(ArenaSession.archiveLifetime)
        try store.applyRetention(now: archiveDeadline.addingTimeInterval(-1))
        XCTAssertNil(store.sessions[0].deletedAt)
        try store.applyRetention(now: archiveDeadline)
        XCTAssertEqual(store.sessions[0].deletedAt, archiveDeadline)
        let restored = try ArenaStore(directory: directory)
        XCTAssertEqual(restored.sessions[0].deletedAt, archiveDeadline)
        await rejected { _ = try await self.call(store, "read_session", token) }
        try store.applyRetention(now: archiveDeadline.addingTimeInterval(ArenaSession.deletionLifetime - 1))
        XCTAssertEqual(store.sessions.count, 1)
        try store.applyRetention(now: archiveDeadline.addingTimeInterval(ArenaSession.deletionLifetime))
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertThrowsError(try store.restoreSession(id))
    }

    func testDeletionWakesWaitersPreservesCopiesAndPurgesRetryPayloads() async throws {
        let (store, directory) = try makeStore()
        let client = try await store.execute(tool: "register_client", arguments: [:]).data.objectValue!["client_token"]!
        let create: [String: JSONValue] = ["client_token": client, "name": .string("Delete"), "brief": .string("Private assessment"), "request_id": .string("create")]
        let created = try await store.execute(tool: "create_session", arguments: create)
        let id = created.data.objectValue!["session_id"]!.stringValue!
        let token = try await join(store, id)
        let file = directory.appendingPathComponent("input.txt")
        try "Private attachment".write(to: file, atomically: true, encoding: .utf8)
        let attached = try await call(store, "attach_file", token, ["path": .string(file.path)])
        let url = try store.attachmentURL(sessionID: id, attachmentID: attached.objectValue!["id"]!.stringValue!)
        let waiter = Task { try await self.call(store, "read_events", token, ["after_cursor": .int(store.sessions[0].latestCursor), "wait_seconds": .int(25)]) }
        for _ in 0..<100 where store.pendingWaitCount == 0 { await Task.yield() }
        let now = Date()
        try store.deleteSession(id, now: now)
        let wake = try await waiter.value
        XCTAssertEqual(wake.objectValue?["status"], .string("stopped"))
        XCTAssertEqual(wake.objectValue?["events"], .array([]))
        XCTAssertEqual(store.pendingWaitCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        await rejected { _ = try await store.execute(tool: "create_session", arguments: create) }
        try store.restoreSession(id, now: now.addingTimeInterval(ArenaSession.deletionLifetime - 1))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.sessions[0].status, .stopped)
        try store.deleteSession(id, now: now)
        try store.applyRetention(now: now.addingTimeInterval(ArenaSession.deletionLifetime))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        await rejected { _ = try await store.execute(tool: "create_session", arguments: create) }
        XCTAssertTrue(store.sessions.isEmpty)
        let restored = try ArenaStore(directory: directory)
        await rejected { _ = try await restored.execute(tool: "create_session", arguments: create) }
        XCTAssertTrue(restored.sessions.isEmpty)
    }

    func testStartupPurgesOverdueArchiveAndKeepsOtherSessions() async throws {
        let (store, directory) = try makeStore()
        let expired = try await store.createSession(name: "Old archive", brief: "Remove after retention")
        let kept = try await store.createSession(name: "Keep", brief: "Unrelated discussion")
        try store.archiveSession(expired, now: Date().addingTimeInterval(-ArenaSession.archiveLifetime - ArenaSession.deletionLifetime - 1))
        let restored = try ArenaStore(directory: directory)
        XCTAssertEqual(restored.sessions.map(\.id), [kept])
        XCTAssertNil(restored.retentionError)
    }

    func testAuthorApprovalClearsTurnAndArchivePreservesOutcome() async throws {
        let (store, _) = try makeStore()
        let id = try await store.createSession(name: "Approval", brief: "Review")
        let token = try await join(store, id)
        let turn = try await call(store, "start_turn", token).objectValue!["id"]!
        let proposal = try await call(store, "propose_outcome", token, ["turn_id": turn, "outcome": .string("consensus"), "assessment": .string("Chosen answer"), "based_on_revision": .int(store.sessions[0].revision)])
        let eventID = proposal.objectValue!["event_id"]!.stringValue!
        try store.acceptAnswer(id, eventID: eventID)
        XCTAssertNil(store.sessions[0].turn)
        try store.archiveSession(id)
        XCTAssertEqual(store.sessions[0].status, .consensus)
        try store.deleteSession(id)
        try store.restoreSession(id)
        XCTAssertEqual(store.sessions[0].proposal?.acceptedEventID, eventID)
        XCTAssertEqual(store.sessions[0].status, .consensus)
    }

    func testFailedRetentionSaveKeepsHistoryAndAttachmentCopies() async throws {
        var fail = false
        let (store, directory) = try makeStore { context in
            if fail { throw ArenaError.invalid("Simulated disk failure") }
            try context.save()
        }
        let id = try await store.createSession(name: "Save", brief: "Keep on failure")
        let token = try await join(store, id)
        let file = directory.appendingPathComponent("input.txt")
        try "Keep".write(to: file, atomically: true, encoding: .utf8)
        let attached = try await call(store, "attach_file", token, ["path": .string(file.path)])
        let url = try store.attachmentURL(sessionID: id, attachmentID: attached.objectValue!["id"]!.stringValue!)
        let now = Date()
        try store.deleteSession(id, now: now)
        fail = true
        store.maintainRetention(now: now.addingTimeInterval(ArenaSession.deletionLifetime))
        XCTAssertNotNil(store.retentionError)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        fail = false
        store.maintainRetention(now: now.addingTimeInterval(ArenaSession.deletionLifetime))
        XCTAssertNil(store.retentionError)
        XCTAssertTrue(store.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}

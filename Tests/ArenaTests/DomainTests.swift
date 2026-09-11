import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftData
@testable import Arena

@MainActor
final class DomainTests: XCTestCase {
    private var directories: [URL] = []
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ArenaTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directories.append(url); return url
    }
    override func tearDown() async throws {
        for url in directories { try? FileManager.default.removeItem(at: url) }
        directories = []
    }
    private func session(_ count: Int = 2, directory supplied: URL? = nil) async throws -> (ArenaStore, String, [String]) {
        let store = try ArenaStore(directory: supplied ?? directory())
        let id = try await store.createSession(name: "Review", brief: "Challenge this proposal.", agentCount: count)
        var tokens: [String] = []
        for participant in store.sessions[0].participants {
            let result = try await store.execute(tool: "join_session", arguments: ["invitation": .string(participant.invitation), "request_id": .string(UUID().uuidString), "client": .string("test"), "model": .string("model-\(participant.index)")])
            tokens.append(try XCTUnwrap(result.data.objectValue?["participant_token"]?.stringValue))
        }
        return (store, id, tokens)
    }
    private func call(_ store: ArenaStore, _ tool: String, _ token: String, _ args: [String: JSONValue] = [:], request: String? = nil) async throws -> ArenaToolResult {
        var args = args; args["participant_token"] = .string(token); args["request_id"] = .string(request ?? UUID().uuidString)
        return try await store.execute(tool: tool, arguments: args)
    }
    private func reject(_ action: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await action(); XCTFail("Expected rejection", file: file, line: line) } catch { XCTAssertFalse(error.localizedDescription.isEmpty, file: file, line: line) }
    }
    private func register(_ store: ArenaStore) async throws -> String {
        let result = try await store.execute(tool: "register_client", arguments: [:])
        return try XCTUnwrap(result.data.objectValue?["client_token"]?.stringValue)
    }
    func testDifferentCallersCannotReplayPrivateJoinOrCreateReceipts() async throws {
        let store = try ArenaStore(directory: directory())
        let firstClient = try await register(store)
        let secondClient = try await register(store)
        var creation: [String: JSONValue] = ["name": .string("Same template"), "brief": .string("Review"), "request_id": .string("1"), "client_token": .string(firstClient)]
        let first = try await store.execute(tool: "create_session", arguments: creation)
        creation["client_token"] = .string(secondClient)
        let second = try await store.execute(tool: "create_session", arguments: creation)
        XCTAssertNotEqual(first.data, second.data, "Independent clients must not share a creation receipt")
        let id = try XCTUnwrap(first.data.objectValue?["session_id"]?.stringValue)
        var claim: [String: JSONValue] = ["session_id": .string(id), "request_id": .string("1"), "client": .string("same-client"), "model": .string("same-model"), "client_token": .string(firstClient)]
        let joined = try await store.execute(tool: "join_session", arguments: claim)
        claim["client_token"] = .string(secondClient)
        let peer = try await store.execute(tool: "join_session", arguments: claim)
        XCTAssertNotEqual(joined.data.objectValue?["participant_token"], peer.data.objectValue?["participant_token"])
        XCTAssertEqual(store.sessions.first { $0.id == id }?.status, .active)
    }

    func testProposerMustConfirmAndOldOutcomeRetriesCannotRecloseAfterReopening() async throws {
        let (store, id, tokens) = try await session()
        let input: [String: JSONValue] = ["outcome": .string("impasse"), "assessment": .string(String(repeating: "Disagree. ", count: 5_000)), "based_on_revision": .int(0)]
        let proposal = try await call(store, "propose_outcome", tokens[0], input, request: "propose")
        let duplicate = try await call(store, "propose_outcome", tokens[0], input, request: "propose")
        XCTAssertEqual(proposal.data, duplicate.data)
        XCTAssertLessThan(try JSONEncoder().encode(proposal).count, 1_000)
        let proposalID = try XCTUnwrap(proposal.data.objectValue?["id"]?.stringValue)
        let confirmation: [String: JSONValue] = ["proposal_id": .string(proposalID)]
        let peer = try await call(store, "confirm_outcome", tokens[1], confirmation, request: "confirm")
        let peerRetry = try await call(store, "confirm_outcome", tokens[1], confirmation, request: "confirm")
        XCTAssertEqual(peer.data, peerRetry.data)
        XCTAssertLessThan(try JSONEncoder().encode(peer).count, 1_000)
        XCTAssertEqual(store.sessions[0].status, .active, "Proposing is not confirming")
        XCTAssertEqual(store.sessions[0].proposal?.confirmations.count, 1)
        try store.stopSession(id)
        try store.reopenSession(id)
        XCTAssertNil(store.sessions[0].proposal)
        let cursor = store.sessions[0].latestCursor
        _ = try await call(store, "propose_outcome", tokens[0], input, request: "propose")
        _ = try await call(store, "confirm_outcome", tokens[1], confirmation, request: "confirm")
        XCTAssertEqual(store.sessions[0].latestCursor, cursor)
        XCTAssertEqual(store.sessions[0].status, .active)
        XCTAssertNil(store.sessions[0].proposal)
        await reject { _ = try await self.call(store, "confirm_outcome", tokens[0], confirmation) }
    }

    func testBothFinalConfirmationAndMessageOrderings() async throws {
        for postFirst in [true, false] {
            let (store, _, tokens) = try await session()
            let result = try await call(store, "propose_outcome", tokens[0], ["outcome": .string("consensus"), "assessment": .string("Agree"), "based_on_revision": .int(0)])
            let proposal = try XCTUnwrap(result.data.objectValue?["id"]?.stringValue)
            _ = try await call(store, "confirm_outcome", tokens[0], ["proposal_id": .string(proposal)])
            if postFirst {
                _ = try await call(store, "post_message", tokens[0], ["text": .string("New evidence")])
                await reject { _ = try await self.call(store, "confirm_outcome", tokens[1], ["proposal_id": .string(proposal)]) }
                XCTAssertEqual(store.sessions[0].status, .active)
                XCTAssertNil(store.sessions[0].proposal)
            } else {
                _ = try await call(store, "confirm_outcome", tokens[1], ["proposal_id": .string(proposal)])
                await reject { _ = try await self.call(store, "post_message", tokens[0], ["text": .string("Too late")]) }
                XCTAssertEqual(store.sessions[0].status, .consensus)
                XCTAssertEqual(store.sessions[0].revision, 0)
            }
        }
    }

    func testConcurrentUploadRetriesWakeWaitersOnceAndPreserveOtherWrites() async throws {
        let path = try directory()
        let (store, _, tokens) = try await session(directory: path)
        let file = path.appendingPathComponent("review.md")
        try Data("Evidence".utf8).write(to: file)
        let cursor = store.sessions[0].latestCursor
        let waiting = Task { try await self.call(store, "read_events", tokens[1], ["after_cursor": .int(cursor), "wait_seconds": .int(25)]) }
        for _ in 0..<100 where store.pendingWaitCount == 0 { await Task.yield() }
        let first = Task { try await self.call(store, "attach_file", tokens[0], ["path": .string(file.path)], request: "upload") }
        let duplicate = Task { try await self.call(store, "attach_file", tokens[0], ["path": .string(file.path)], request: "upload") }
        _ = try await call(store, "post_message", tokens[1], ["text": .string("Concurrent evidence")])
        let a = try await first.value, b = try await duplicate.value
        XCTAssertEqual(a.data, b.data)
        _ = try await waiting.value
        XCTAssertEqual(store.pendingWaitCount, 0)
        XCTAssertEqual(store.sessions[0].attachments.count, 1)
        XCTAssertEqual(store.sessions[0].events.filter { $0.kind == "attached" }.count, 1)
        XCTAssertEqual(store.sessions[0].events.filter { $0.kind == "message" }.count, 1)
        XCTAssertEqual(store.sessions[0].revision, 1)
        let folder = path.appendingPathComponent("Attachments").appendingPathComponent(store.sessions[0].id)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    func testAttachmentWakesWaitingRosterWithoutChangingDiscussionRevision() async throws {
        let path = try directory(), file = path.appendingPathComponent("evidence.txt")
        try Data("Evidence".utf8).write(to: file)
        let store = try ArenaStore(directory: path)
        _ = try await store.createSession(name: "Waiting", brief: "Review", agentCount: 2)
        let joined = try await store.execute(tool: "join_session", arguments: ["invitation": .string(store.sessions[0].participants[0].invitation), "request_id": .string("join"), "client": .string("test"), "model": .string("test")])
        let token = try XCTUnwrap(joined.data.objectValue?["participant_token"]?.stringValue)
        let cursor = store.sessions[0].latestCursor
        let waiting = Task { try await self.call(store, "read_events", token, ["after_cursor": .int(cursor), "wait_seconds": .int(25)]) }
        for _ in 0..<100 where store.pendingWaitCount == 0 { await Task.yield() }
        _ = try await call(store, "attach_file", token, ["path": .string(file.path)])
        let result = try await waiting.value
        XCTAssertEqual(result.data.objectValue?["next_cursor"], .int(cursor + 1))
        XCTAssertEqual(store.sessions[0].events.last?.kind, "attached")
        XCTAssertEqual(store.sessions[0].status, .waiting)
        XCTAssertEqual(store.sessions[0].revision, 0)
        XCTAssertEqual(store.pendingWaitCount, 0)
    }

    func testObserverControlsRemainAvailableAtHistoryCapacity() async throws {
        let path = try directory()
        let (_, id, tokens) = try await session(directory: path)
        let container = try ModelContainer(for: StoredArena.self, configurations: ModelConfiguration(url: path.appendingPathComponent("Arena.sqlite")))
        let context = ModelContext(container)
        let row = try XCTUnwrap(context.fetch(FetchDescriptor<StoredArena>()).first)
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: row.payload) as? [String: Any])
        var sessions = try XCTUnwrap(payload["sessions"] as? [[String: Any]])
        var event = try XCTUnwrap((sessions[0]["events"] as? [[String: Any]])?.last)
        let events = (1...100_000).map { cursor -> [String: Any] in
            event["cursor"] = cursor
            event["id"] = String(cursor)
            return event
        }
        sessions[0]["events"] = events
        payload["sessions"] = sessions
        row.payload = try JSONSerialization.data(withJSONObject: payload)
        try context.save()
        let store = try ArenaStore(directory: path)
        let before = store.sessions[0].latestCursor
        await reject { _ = try await self.call(store, "post_message", tokens[0], ["text": .string("Over limit")]) }
        XCTAssertEqual(store.sessions[0].latestCursor, before)
        try store.stopSession(id)
        try store.reopenSession(id)
        try store.editSession(id, name: "Still manageable", brief: store.sessions[0].brief, agentCount: 2)
        let restored = try ArenaStore(directory: path)
        XCTAssertEqual(restored.sessions[0].status, .active)
        XCTAssertEqual(restored.sessions[0].name, "Still manageable")
        XCTAssertEqual(restored.sessions[0].latestCursor, before + 3)
        await reject { _ = try await self.call(restored, "post_message", tokens[0], ["text": .string("Still over limit")]) }
    }

    func testFailedSaveRollsBackWithoutPublishingOrRememberingMutation() async throws {
        let path = try directory()
        var failSave = false
        let store = try ArenaStore(directory: path, save: { context in
            if failSave { throw CocoaError(.fileWriteOutOfSpace) }
            try context.save()
        })
        _ = try await store.createSession(name: "Save failure", brief: "Review", agentCount: 2)
        var tokens: [String] = []
        for participant in store.sessions[0].participants {
            let joined = try await store.execute(tool: "join_session", arguments: ["invitation": .string(participant.invitation), "request_id": .string(participant.id), "client": .string("test"), "model": .string("test")])
            tokens.append(try XCTUnwrap(joined.data.objectValue?["participant_token"]?.stringValue))
        }
        failSave = true
        let before = try JSONValue.encode(store.sessions)
        await reject { _ = try await self.call(store, "post_message", tokens[0], ["text": .string("Retry after disk failure")], request: "save") }
        XCTAssertEqual(try JSONValue.encode(store.sessions), before)
        XCTAssertEqual(try JSONValue.encode(ArenaStore(directory: path).sessions), before)
        failSave = false
        _ = try await call(store, "post_message", tokens[0], ["text": .string("Retry after disk failure")], request: "save")
        XCTAssertEqual(store.sessions[0].events.filter { $0.kind == "message" }.count, 1)
    }

    func testAgentSessionDiscoveryCreationAndSlotClaimsSurviveRestart() async throws {
        let path = try directory()
        let store = try ArenaStore(directory: path)
        let file = path.appendingPathComponent("proposal.md")
        try Data("Review bounded waiting.".utf8).write(to: file)
        let clientToken = try await register(store)
        let args: [String: JSONValue] = ["client_token": .string(clientToken), "name": .string("Skill review"), "brief": .string("Use bounded waits."), "agent_count": .int(2), "attachment_paths": .array([.string(file.path)]), "request_id": .string("create")]
        let created = try await store.execute(tool: "create_session", arguments: args)
        let id = try XCTUnwrap(created.data.objectValue?["session_id"]?.stringValue)
        let again = try await store.execute(tool: "create_session", arguments: args)
        XCTAssertEqual(created.data, again.data)
        XCTAssertEqual(store.sessions.count, 1)
        XCTAssertTrue(store.sessions[0].attachments[0].isBrief)
        var conflict = args; conflict["brief"] = .string("Changed")
        await reject { _ = try await store.execute(tool: "create_session", arguments: conflict) }
        let listing = try await store.execute(tool: "list_sessions", arguments: ["query": .string(id), "limit": .int(1)])
        let listingJSON = String(decoding: try JSONEncoder().encode(listing.data), as: UTF8.self)
        for participant in store.sessions[0].participants {
            XCTAssertFalse(listingJSON.contains(participant.credential))
            XCTAssertFalse(listingJSON.contains(participant.invitation))
        }
        XCTAssertTrue(listingJSON.contains("Skill review"))
        let claim: [String: JSONValue] = ["client_token": .string(clientToken), "session_id": .string(id), "request_id": .string("first"), "client": .string("codex"), "model": .string("test")]
        let first = try await store.execute(tool: "join_session", arguments: claim)
        let replay = try await store.execute(tool: "join_session", arguments: claim)
        XCTAssertEqual(first.data, replay.data)
        var secondClaim = claim; secondClaim["request_id"] = .string("second"); secondClaim["client"] = .string("claude")
        let second = try await store.execute(tool: "join_session", arguments: secondClaim)
        XCTAssertEqual(store.sessions[0].status, .active)
        XCTAssertNotEqual(first.data.objectValue?["participant_token"], second.data.objectValue?["participant_token"])
        var extra = claim; extra["request_id"] = .string("third")
        await reject { _ = try await store.execute(tool: "join_session", arguments: extra) }
        var ambiguous = claim; ambiguous["invitation"] = .string("also-supplied")
        await reject { _ = try await store.execute(tool: "join_session", arguments: ambiguous) }
        let restored = try ArenaStore(directory: path)
        let restoredCreation = try await restored.execute(tool: "create_session", arguments: args)
        let restoredJoin = try await restored.execute(tool: "join_session", arguments: claim)
        XCTAssertEqual(restoredCreation.data, created.data)
        XCTAssertEqual(restoredJoin.data, first.data)
        let token = try XCTUnwrap(first.data.objectValue?["participant_token"]?.stringValue)
        _ = try await call(restored, "post_message", token, ["text": .string("Opening argument")])
        _ = try await restored.createSession(name: "Second", brief: "Other", agentCount: 2)
        let page = try await restored.execute(tool: "list_sessions", arguments: ["limit": .int(1)])
        XCTAssertEqual(page.data.objectValue?["has_more"], .bool(true))
        let last = try await restored.execute(tool: "list_sessions", arguments: ["offset": .int(1), "limit": .int(1)])
        XCTAssertEqual(last.data.objectValue?["has_more"], .bool(false))
        await reject { _ = try await restored.execute(tool: "list_sessions", arguments: ["offset": .int(-1)]) }
        var malformed = args; malformed["request_id"] = .string("bad"); malformed["attachment_paths"] = .array([.string("relative.md")])
        await reject { _ = try await restored.execute(tool: "create_session", arguments: malformed) }
        XCTAssertEqual(restored.sessions.count, 2)
        try restored.stopSession(restored.sessions[0].id)
        var closed = claim; closed["session_id"] = .string(restored.sessions[0].id)
        await reject { _ = try await restored.execute(tool: "join_session", arguments: closed) }
    }

    func testConsensusRequiresEveryAgentAndSurvivesRestart() async throws {
        let path = try directory()
        let (store, id, tokens) = try await session(3, directory: path)
        _ = try await call(store, "post_message", tokens[0], ["text": .string("Propose a simpler design")], request: "message")
        _ = try await call(store, "post_message", tokens[0], ["text": .string("Propose a simpler design")], request: "message")
        XCTAssertEqual(store.sessions[0].events.filter { $0.kind == "message" }.count, 1)
        let proposal = try await call(store, "propose_outcome", tokens[0], ["outcome": .string("consensus"), "assessment": .string("Use native storage."), "based_on_revision": .int(1)])
        let proposalID = try XCTUnwrap(proposal.data.objectValue?["id"]?.stringValue)
        for token in tokens.prefix(2) { _ = try await call(store, "confirm_outcome", token, ["proposal_id": .string(proposalID)]) }
        XCTAssertEqual(store.sessions[0].status, .active)
        _ = try await call(store, "confirm_outcome", tokens[2], ["proposal_id": .string(proposalID)])
        XCTAssertEqual(store.sessions[0].status, .consensus)
        await reject { _ = try await self.call(store, "post_message", tokens[1], ["text": .string("late")]) }
        let restored = try ArenaStore(directory: path)
        XCTAssertEqual(restored.sessions[0].id, id)
        XCTAssertEqual(restored.sessions[0].status, .consensus)
        XCTAssertEqual(restored.sessions[0].participants.map(\.name), store.sessions[0].participants.map(\.name))
        _ = try await call(restored, "post_message", tokens[0], ["text": .string("Propose a simpler design")], request: "message")
        XCTAssertEqual(restored.sessions[0].events.filter { $0.kind == "message" }.count, 1)
        let read = try await call(restored, "read_session", tokens[0])
        let serialized = String(data: try JSONEncoder().encode(read), encoding: .utf8)!
        XCTAssertFalse(serialized.contains(tokens[0]))
        XCTAssertFalse(serialized.contains(restored.sessions[0].participants[1].invitation))
        try restored.reopenSession(id)
        XCTAssertEqual(restored.sessions[0].status, .active); XCTAssertNil(restored.sessions[0].proposal)
    }
    func testStaleAssessmentsAndIdempotencyConflicts() async throws {
        let (store, _, tokens) = try await session()
        let proposal = try await call(store, "propose_outcome", tokens[0], ["outcome": .string("impasse"), "assessment": .string("Disagree."), "based_on_revision": .int(0)])
        let id = try XCTUnwrap(proposal.data.objectValue?["id"]?.stringValue)
        _ = try await call(store, "confirm_outcome", tokens[0], ["proposal_id": .string(id)])
        _ = try await call(store, "post_message", tokens[1], ["text": .string("One new fact")], request: "same")
        XCTAssertNil(store.sessions[0].proposal)
        await reject { _ = try await self.call(store, "confirm_outcome", tokens[1], ["proposal_id": .string(id)]) }
        await reject { _ = try await self.call(store, "propose_outcome", tokens[1], ["outcome": .string("consensus"), "assessment": .string("Old"), "based_on_revision": .int(0)]) }
        await reject { _ = try await self.call(store, "post_message", tokens[1], ["text": .string("Different")], request: "same") }
        let replacement = try await call(store, "propose_outcome", tokens[1], ["outcome": .string("impasse"), "assessment": .string("Still disagree."), "based_on_revision": .int(1)])
        let replacementID = try XCTUnwrap(replacement.data.objectValue?["id"]?.stringValue)
        for token in tokens { _ = try await call(store, "confirm_outcome", token, ["proposal_id": .string(replacementID)]) }
        XCTAssertEqual(store.sessions[0].status, .impasse)
    }
    func testSessionEditFailureLeavesSavedStateUnchanged() async throws {
        let path = try directory()
        let store = try ArenaStore(directory: path)
        let id = try await store.createSession(name: "Original", brief: "Draft", agentCount: 2)
        let before = try JSONValue.encode(store.sessions)
        XCTAssertThrowsError(try store.editSession(id, name: String(repeating: "é", count: 101), brief: "Revised", agentCount: 3))
        XCTAssertThrowsError(try store.editSession(id, name: "Revised", brief: "", agentCount: 3))
        XCTAssertThrowsError(try store.editSession(id, name: "Revised", brief: "Revised", agentCount: 1))
        XCTAssertEqual(try JSONValue.encode(store.sessions), before)
        XCTAssertEqual(try JSONValue.encode(ArenaStore(directory: path).sessions), before)

        try store.editSession(id, name: "Revised", brief: "Final", agentCount: 3)
        let saved = store.sessions[0]
        XCTAssertEqual(saved.name, "Revised")
        XCTAssertEqual(saved.brief, "Final")
        XCTAssertEqual(saved.participants.count, 3)
        XCTAssertEqual(try JSONValue.encode(ArenaStore(directory: path).sessions), try JSONValue.encode(store.sessions))
        try store.editSession(id, name: "Revised", brief: "Final", agentCount: 3)
        XCTAssertEqual(try JSONValue.encode(store.sessions[0]), try JSONValue.encode(saved))
    }

    func testSessionEditRechecksJoiningAndAllowsClosedRename() async throws {
        let path = try directory()
        let store = try ArenaStore(directory: path)
        let id = try await store.createSession(name: "Original", brief: "Draft", agentCount: 2)
        let draft = store.sessions[0]
        _ = try await store.execute(tool: "join_session", arguments: ["invitation": .string(draft.participants[0].invitation), "request_id": .string("join"), "client": .string("test"), "model": .string("test")])
        let joined = try JSONValue.encode(store.sessions)
        XCTAssertThrowsError(try store.editSession(id, name: "Revised", brief: "Changed after opening editor", agentCount: 3))
        XCTAssertEqual(try JSONValue.encode(store.sessions), joined)
        XCTAssertEqual(try JSONValue.encode(ArenaStore(directory: path).sessions), joined)

        try store.editSession(id, name: "Renamed", brief: draft.brief, agentCount: draft.participants.count)
        XCTAssertEqual(store.sessions[0].name, "Renamed")
        let roster = try JSONValue.encode(store.sessions[0].participants)
        try store.stopSession(id)
        try store.editSession(id, name: "Closed rename", brief: draft.brief, agentCount: draft.participants.count)
        XCTAssertEqual(store.sessions[0].name, "Closed rename")
        XCTAssertEqual(store.sessions[0].status, .stopped)
        XCTAssertEqual(try JSONValue.encode(store.sessions[0].participants), roster)
    }

    func testWaitingSetupStopAndInvitationReplay() async throws {
        let store = try ArenaStore(directory: directory())
        let id = try await store.createSession(name: "Setup", brief: "Draft", agentCount: 2)
        try store.editSession(id, name: "Setup", brief: "Final", agentCount: 3)
        let args: [String: JSONValue] = ["invitation": .string(store.sessions[0].participants[0].invitation), "request_id": .string("join"), "client": .string("Codex"), "model": .string("GPT")]
        let joined = try await store.execute(tool: "join_session", arguments: args)
        let replay = try await store.execute(tool: "join_session", arguments: args)
        XCTAssertEqual(joined.data, replay.data)
        let token = try XCTUnwrap(joined.data.objectValue?["participant_token"]?.stringValue)
        XCTAssertThrowsError(try store.editSession(id, name: "Setup", brief: "Changed", agentCount: 2))
        await reject { _ = try await self.call(store, "post_message", token, ["text": .string("Too early")]) }
        try store.editSession(id, name: "Named", brief: "Final", agentCount: 3)
        try store.stopSession(id); XCTAssertEqual(store.sessions[0].status, .stopped)
        try store.reopenSession(id); XCTAssertEqual(store.sessions[0].status, .waiting)
        XCTAssertEqual(store.sessions[0].participants.count, 3)
        await reject { _ = try await self.call(store, "read_session", "invalid") }
    }
    func testCursorsWaitWakeTimeoutAndCancellation() async throws {
        let (store, id, tokens) = try await session()
        let cursor = store.sessions[0].latestCursor
        let waiter = Task { try await self.call(store, "read_events", tokens[0], ["after_cursor": .int(cursor), "wait_seconds": .int(25), "limit": .int(1)]) }
        for _ in 0..<100 where store.pendingWaitCount == 0 { await Task.yield() }
        XCTAssertEqual(store.pendingWaitCount, 1)
        try store.stopSession(id)
        let result = try await waiter.value
        XCTAssertEqual(result.data.objectValue?["status"], .string("stopped"))
        XCTAssertEqual(store.pendingWaitCount, 0)
        try store.reopenSession(id)
        let after = store.sessions[0].latestCursor
        let cancelled = Task { try await self.call(store, "read_events", tokens[0], ["after_cursor": .int(after), "wait_seconds": .int(25)]) }
        for _ in 0..<100 where store.pendingWaitCount == 0 { await Task.yield() }
        XCTAssertEqual(store.pendingWaitCount, 1)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        XCTAssertEqual(store.pendingWaitCount, 0)
        let timeout = try await call(store, "read_events", tokens[0], ["after_cursor": .int(after), "wait_seconds": .int(1)])
        XCTAssertEqual(timeout.data.objectValue?["events"], .array([]))
        XCTAssertEqual(store.pendingWaitCount, 0)
        let page = try await call(store, "read_events", tokens[1], ["after_cursor": .int(0), "limit": .int(1)])
        XCTAssertEqual(page.data.objectValue?["has_more"], .bool(true))
        XCTAssertEqual(page.data.objectValue?["next_cursor"], .int(1))
    }
    func testConcurrentConfirmationCannotCloseStaleDiscussion() async throws {
        let (store, _, tokens) = try await session()
        let proposed = try await call(store, "propose_outcome", tokens[0], ["outcome": .string("consensus"), "assessment": .string("Agree"), "based_on_revision": .int(0)])
        let id = try XCTUnwrap(proposed.data.objectValue?["id"]?.stringValue)
        _ = try await call(store, "confirm_outcome", tokens[0], ["proposal_id": .string(id)])
        let confirmation = Task { try? await self.call(store, "confirm_outcome", tokens[1], ["proposal_id": .string(id)]) }
        let message = Task { try? await self.call(store, "post_message", tokens[0], ["text": .string("Changed mind")]) }
        let confirmed = await confirmation.value, posted = await message.value
        XCTAssertTrue((confirmed == nil) != (posted == nil))
        if store.sessions[0].status == .consensus { XCTAssertEqual(store.sessions[0].revision, 0) }
        else { XCTAssertEqual(store.sessions[0].revision, 1); XCTAssertNil(store.sessions[0].proposal) }
    }
    func testAttachmentsValidateScopeCopyAndRepresentations() async throws {
        let path = try directory(), textFile = path.appendingPathComponent("brief.md")
        try Data("Immutable **proposal**".utf8).write(to: textFile)
        let store = try ArenaStore(directory: path.appendingPathComponent("store"))
        let id = try await store.createSession(name: "Attachments", brief: "Review", agentCount: 3, files: [textFile])
        var tokens: [String] = []
        for participant in store.sessions[0].participants {
            let result = try await store.execute(tool: "join_session", arguments: ["invitation": .string(participant.invitation), "client": .string("test"), "model": .string("model"), "request_id": .string(participant.id)])
            tokens.append(try XCTUnwrap(result.data.objectValue?["participant_token"]?.stringValue))
        }
        let attachmentID = store.sessions[0].attachments[0].id
        try Data("Changed".utf8).write(to: textFile)
        for token in tokens {
            let read = try await call(store, "read_attachment", token, ["attachment_id": .string(attachmentID)])
            XCTAssertEqual(read.data.objectValue?["text"], .string("Immutable **proposal**"))
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3200, pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 12_800, bitsPerPixel: 32)!
        let png = path.appendingPathComponent("image.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let imageResult = try await call(store, "attach_file", tokens[0], ["path": .string(png.path)])
        let imageID = try XCTUnwrap(imageResult.data.objectValue?["id"]?.stringValue)
        let imageRead = try await call(store, "read_attachment", tokens[1], ["attachment_id": .string(imageID), "representation": .string("image")])
        XCTAssertEqual(imageRead.images.count, 1)
        let renderedImage = try XCTUnwrap(imageRead.images.first.flatMap { NSBitmapImageRep(data: $0.data) })
        XCTAssertEqual(renderedImage.pixelsWide, 1600)
        XCTAssertEqual(renderedImage.pixelsHigh, 8)
        let message = try await call(store, "post_message", tokens[0], ["text": .string("See the source"), "attachment_ids": .array([.string(imageID)])])
        let messageID = try XCTUnwrap(message.data.objectValue?["id"]?.stringValue)
        _ = try await call(store, "post_message", tokens[1], ["text": .string("Reviewed"), "reply_to": .string(messageID), "mentions": .array([.string(store.sessions[0].participants[0].id)])])
        await reject { _ = try await self.call(store, "post_message", tokens[0], ["text": .string("Bad reference"), "attachment_ids": .array([.string("foreign")])]) }
        let pdf = PDFDocument(); pdf.insert(PDFPage(image: NSImage(data: try Data(contentsOf: png))!)!, at: 0)
        let pdfURL = path.appendingPathComponent("scan.pdf"); XCTAssertTrue(pdf.write(to: pdfURL))
        let pdfResult = try await call(store, "attach_file", tokens[1], ["path": .string(pdfURL.path)])
        let pdfID = try XCTUnwrap(pdfResult.data.objectValue?["id"]?.stringValue)
        let pdfRead = try await call(store, "read_attachment", tokens[0], ["attachment_id": .string(pdfID), "representation": .string("image"), "page": .int(1)])
        XCTAssertEqual(pdfRead.images.first?.mimeType, "image/png")
        let renderedPage = try XCTUnwrap(pdfRead.images.first.flatMap { NSBitmapImageRep(data: $0.data) })
        XCTAssertLessThanOrEqual(renderedPage.pixelsWide, 1600)
        XCTAssertLessThanOrEqual(renderedPage.pixelsHigh, 1600)
        let pdfText = try await call(store, "read_attachment", tokens[1], ["attachment_id": .string(pdfID), "representation": .string("text")])
        XCTAssertEqual(pdfText.data.objectValue?["page_count"], .int(1))
        XCTAssertEqual(pdfText.data.objectValue?["text"], .string(""))
        await reject { _ = try await self.call(store, "read_attachment", tokens[0], ["attachment_id": .string(pdfID), "representation": .string("original")]) }
        await reject { _ = try await self.call(store, "read_attachment", tokens[0], ["attachment_id": .string(pdfID), "page": .int(2)]) }
        let other = try await store.createSession(name: "Other", brief: "Separate", agentCount: 2)
        XCTAssertThrowsError(try store.attachmentURL(sessionID: other, attachmentID: attachmentID))
        let otherParticipant = try XCTUnwrap(store.sessions.first { $0.id == other }?.participants.first)
        let joinedOther = try await store.execute(tool: "join_session", arguments: ["invitation": .string(otherParticipant.invitation), "client": .string("test"), "model": .string("model"), "request_id": .string("other")])
        let otherToken = try XCTUnwrap(joinedOther.data.objectValue?["participant_token"]?.stringValue)
        await reject { _ = try await self.call(store, "read_attachment", otherToken, ["attachment_id": .string(attachmentID)]) }
        let invalid = path.appendingPathComponent("fake.png"); try Data("not an image".utf8).write(to: invalid)
        await reject { _ = try await self.call(store, "attach_file", tokens[0], ["path": .string(invalid.path)]) }
        let huge = path.appendingPathComponent("huge.txt"); try Data(repeating: 65, count: AttachmentFiles.maximumBytes + 1).write(to: huge)
        await reject { _ = try await self.call(store, "attach_file", tokens[0], ["path": .string(huge.path)]) }
        let symlink = path.appendingPathComponent("link.md"); try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: textFile)
        await reject { _ = try await self.call(store, "attach_file", tokens[0], ["path": .string(symlink.path)]) }
        await reject { _ = try await self.call(store, "attach_file", tokens[0], ["path": .string(path.path)]) }
        XCTAssertNoThrow(try store.attachmentURL(sessionID: id, attachmentID: attachmentID))
    }
}

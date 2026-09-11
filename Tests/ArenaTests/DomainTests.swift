import AppKit
import Foundation
import PDFKit
import XCTest
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
        let id = try store.createSession(name: "Review", brief: "Challenge this proposal.", agentCount: count)
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
    func testAgentSessionDiscoveryCreationAndSlotClaimsSurviveRestart() async throws {
        let path = try directory()
        let store = try ArenaStore(directory: path)
        let file = path.appendingPathComponent("proposal.md")
        try Data("Review bounded waiting.".utf8).write(to: file)
        let args: [String: JSONValue] = ["name": .string("Skill review"), "brief": .string("Use bounded waits."), "agent_count": .int(2), "attachment_paths": .array([.string(file.path)]), "request_id": .string("create")]
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
        let claim: [String: JSONValue] = ["session_id": .string(id), "request_id": .string("first"), "client": .string("codex"), "model": .string("test")]
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
        _ = try restored.createSession(name: "Second", brief: "Other", agentCount: 2)
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
    func testSessionEditFailureLeavesSavedStateUnchanged() throws {
        let path = try directory()
        let store = try ArenaStore(directory: path)
        let id = try store.createSession(name: "Original", brief: "Draft", agentCount: 2)
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
        let id = try store.createSession(name: "Original", brief: "Draft", agentCount: 2)
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
        let id = try store.createSession(name: "Setup", brief: "Draft", agentCount: 2)
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
        let id = try store.createSession(name: "Attachments", brief: "Review", agentCount: 2, files: [textFile])
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
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
        let png = path.appendingPathComponent("image.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: png)
        let imageResult = try await call(store, "attach_file", tokens[0], ["path": .string(png.path)])
        let imageID = try XCTUnwrap(imageResult.data.objectValue?["id"]?.stringValue)
        let imageRead = try await call(store, "read_attachment", tokens[1], ["attachment_id": .string(imageID), "representation": .string("image")])
        XCTAssertEqual(imageRead.images.count, 1)
        XCTAssertEqual(imageRead.images.first?.data, try Data(contentsOf: png))
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
        let pdfText = try await call(store, "read_attachment", tokens[1], ["attachment_id": .string(pdfID), "representation": .string("text")])
        XCTAssertEqual(pdfText.data.objectValue?["page_count"], .int(1))
        XCTAssertEqual(pdfText.data.objectValue?["text"], .string(""))
        let original = try await call(store, "read_attachment", tokens[0], ["attachment_id": .string(pdfID), "representation": .string("original")])
        XCTAssertEqual(original.data.objectValue?["base64"]?.stringValue, try Data(contentsOf: pdfURL).base64EncodedString())
        await reject { _ = try await self.call(store, "read_attachment", tokens[0], ["attachment_id": .string(pdfID), "page": .int(2)]) }
        let other = try store.createSession(name: "Other", brief: "Separate", agentCount: 2)
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

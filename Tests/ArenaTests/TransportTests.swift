import Foundation
import MCP
import XCTest
@testable import Arena

@MainActor
final class TransportTests: XCTestCase {
    private let port = 19421
    private let token = "test-service-token"

    private func request(method: String = "POST", session: String? = nil, body: [String: Value]? = nil, headers extra: [String: String] = [:]) throws -> MCP.HTTPRequest {
        var headers = ["Host": "127.0.0.1:\(port)", "Authorization": "Bearer \(token)", "Content-Type": "application/json", "Accept": "application/json, text/event-stream", "MCP-Protocol-Version": "2025-11-25"]
        if let session { headers["MCP-Session-Id"] = session }
        headers.merge(extra) { _, new in new }
        return .init(method: method, headers: headers, body: try body.map { try JSONEncoder().encode($0) }, path: "/mcp")
    }

    private func makeStore() throws -> ArenaStore {
        try ArenaStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), inMemory: true)
    }

    private func initialize(_ router: MCPHTTPRouter, id: Int = 1, name: String = "ArenaTests") async throws -> String {
        let exchange = await router.handle(try request(body: ["jsonrpc": "2.0", "id": .int(id), "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": .string(name), "version": "1"]]]))
        XCTAssertEqual(exchange.response.statusCode, 200)
        let session = try XCTUnwrap(exchange.sessionID)
        let message = try await consume(exchange, router: router)
        XCTAssertNotNil(message?["result"]?.objectValue?["capabilities"])
        let initialized = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(initialized.response.statusCode, 202)
        return session
    }

    private func consume(_ exchange: MCPExchange, router: MCPHTTPRouter) async throws -> [String: Value]? {
        guard case .stream(let stream, _) = exchange.response else {
            return try exchange.response.bodyData.map { try JSONDecoder().decode([String: Value].self, from: $0) }
        }
        return try await withThrowingTaskGroup(of: [String: Value]?.self) { group in
            group.addTask {
                var result: [String: Value]?
                var bytes = 0
                for try await chunk in stream {
                    bytes += chunk.count
                    for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data:") {
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if !payload.isEmpty { result = try JSONDecoder().decode([String: Value].self, from: Data(payload.utf8)) }
                    }
                }
                if let session = exchange.sessionID, let key = exchange.streamKey, let lease = exchange.leaseID {
                    await router.complete(sessionID: session, streamKey: key, leaseID: lease, bytes: bytes)
                }
                return result
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                throw ArenaError.invalid("MCP response did not complete within five seconds")
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private var observedActivity: [String: Date] = [:]

    func testObservedConnectionsRequireHandshakeAndTrackEachClientSession() async throws {
        let router = MCPHTTPRouter(store: try makeStore(), port: port, token: token) { [weak self] in
            self?.observedActivity = $0
        }
        let exchange = await router.handle(try request(body: ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "claude-cli", "version": "1"]]]))
        _ = try await consume(exchange, router: router)
        XCTAssertTrue(observedActivity.isEmpty, "An incomplete handshake is not a connection")
        let first = try XCTUnwrap(exchange.sessionID)
        _ = await router.handle(try request(session: first, body: ["jsonrpc": "2.0", "method": "notifications/initialized"]))
        XCTAssertEqual(Set(observedActivity.keys), ["claude-cli"])
        let second = try await initialize(router, name: "claude-cli")
        _ = try await initialize(router, name: "codex-mcp-client")
        _ = try await initialize(router, name: "arena-setup-check")
        XCTAssertEqual(Set(observedActivity.keys), ["claude-cli", "codex-mcp-client"])
        _ = await router.handle(try request(method: "DELETE", session: first))
        XCTAssertNotNil(observedActivity["claude-cli"], "Another Claude session is still open")
        _ = await router.handle(try request(method: "DELETE", session: second))
        XCTAssertNil(observedActivity["claude-cli"])
        await router.expireIdleSessions(now: Date().addingTimeInterval(1801))
        XCTAssertTrue(observedActivity.isEmpty)
        _ = try await initialize(router, name: "claude-cli")
        await router.shutdown()
        XCTAssertTrue(observedActivity.isEmpty)
    }

    func testBoundaryRejectsUntrustedHostsOriginsTokensAndLargeBodies() throws {
        let access = MCPAccess(port: port, token: token)
        XCTAssertNil(access.rejection(for: try request()))
        XCTAssertNil(access.rejection(for: try request(headers: ["Host": "localhost:\(port)", "Origin": "http://localhost:\(port)"])))
        for host in ["attacker.test:\(port)", "127.0.0.1.evil:\(port)", "127.0.0.1", "127.0.0.1:\(port),localhost:\(port)"] {
            XCTAssertEqual(access.rejection(for: try request(headers: ["Host": host]))?.statusCode, 403)
        }
        for origin in ["null", "https://attacker.test", "http://localhost:\(port + 1)", "http://localhost:\(port)/"] {
            XCTAssertEqual(access.rejection(for: try request(headers: ["Origin": origin]))?.statusCode, 403)
        }
        XCTAssertEqual(access.rejection(for: try request(headers: ["Authorization": "Bearer wrong-token"]))?.statusCode, 401)
        XCTAssertEqual(access.rejection(for: try request(headers: ["Authorization": ""]))?.statusCode, 401)
        XCTAssertEqual(access.rejection(for: try request(method: "PUT"))?.statusCode, 405)
        let valid = try request()
        XCTAssertEqual(access.rejection(for: .init(method: "POST", headers: valid.headers, body: Data(repeating: 0, count: MCPAccess.maximumBody + 1), path: "/mcp"))?.statusCode, 413)
        XCTAssertEqual(access.rejection(for: .init(method: "POST", headers: valid.headers, path: "/control"))?.statusCode, 404)
    }

    func testConcurrentClientsCanReuseRequestIDsAndRouteStructuredTools() async throws {
        let store = try makeStore()
        _ = try store.createSession(name: "Transport review", brief: "Critique a proposal", agentCount: 2)
        let invitations = store.sessions[0].participants.map(\.invitation)
        let router = MCPHTTPRouter(store: store, port: port, token: token)
        let first = try await initialize(router)
        let second = try await initialize(router)
        XCTAssertNotEqual(first, second)

        var calls: [MCPExchange] = []
        for (index, session) in [first, second].enumerated() {
            calls.append(await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "join_session", "arguments": ["invitation": .string(invitations[index]), "request_id": .string("join-\(index)"), "client": "test", "model": "test-model"]]])))
        }
        let a = try await consume(calls[0], router: router)
        let b = try await consume(calls[1], router: router)
        let firstToken = try XCTUnwrap(a?["result"]?.objectValue?["structuredContent"]?.objectValue?["participant_token"]?.stringValue)
        let secondToken = try XCTUnwrap(b?["result"]?.objectValue?["structuredContent"]?.objectValue?["participant_token"]?.stringValue)
        XCTAssertNotEqual(firstToken, secondToken)
        XCTAssertEqual(firstToken, store.sessions[0].participants[0].credential)
        XCTAssertEqual(secondToken, store.sessions[0].participants[1].credential)
        XCTAssertEqual(store.sessions[0].status, .active)

        let list = await router.handle(try request(session: first, body: ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
        let listJSON = try await consume(list, router: router)
        XCTAssertEqual(listJSON?["result"]?.objectValue?["tools"]?.arrayValue?.count, 10)
        let bad = await router.handle(try request(session: first, body: ["jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": ["name": "read_session", "arguments": ["participant_token": "invalid"]]]))
        let badJSON = try await consume(bad, router: router)
        XCTAssertEqual(badJSON?["result"]?.objectValue?["isError"], .bool(true))
        await router.shutdown()
    }

    func testCancellationReleasesWaitingStreamAndSession() async throws {
        let store = try makeStore()
        _ = try store.createSession(name: "Wait review", brief: "Review", agentCount: 2)
        let invitation = store.sessions[0].participants[0].invitation
        let joined = try await store.execute(tool: "join_session", arguments: ["invitation": .string(invitation), "request_id": .string("join"), "client": .string("test"), "model": .string("test")])
        let participant = try XCTUnwrap(joined.data.objectValue?["participant_token"]?.stringValue)
        let cursor = store.sessions[0].latestCursor
        let router = MCPHTTPRouter(store: store, port: port, token: token)
        let session = try await initialize(router)
        let waiting = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "read_events", "arguments": ["participant_token": .string(participant), "after_cursor": .int(cursor), "wait_seconds": 25]]]))
        await router.expireIdleSessions(now: Date().addingTimeInterval(1801))
        let canceled = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 2]]))
        XCTAssertEqual(canceled.response.statusCode, 202)
        let result = try await consume(waiting, router: router)
        XCTAssertNil(result)
        let expired = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
        XCTAssertEqual(expired.response.statusCode, 404)
        XCTAssertFalse(store.sessions[0].status.isClosed)
        await router.shutdown()
    }

    func testMalformedRequestsAndIdleExpiry() async throws {
        let router = MCPHTTPRouter(store: try makeStore(), port: port, token: token)
        let missing = await router.handle(try request(body: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        XCTAssertEqual(missing.response.statusCode, 400)
        let malformed = await router.handle(try request(body: ["jsonrpc": "2.0", "id": .null, "method": "initialize"]))
        XCTAssertEqual(malformed.response.statusCode, 400)
        let unknown = await router.handle(try request(session: "nonexistent", body: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"]))
        XCTAssertEqual(unknown.response.statusCode, 404)
        let session = try await initialize(router)
        await router.expireIdleSessions(now: Date().addingTimeInterval(1801))
        let expired = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        XCTAssertEqual(expired.response.statusCode, 404)
        await router.shutdown()
    }

    func testOldConnectionClosureCannotCancelReusedRequestID() async throws {
        let router = MCPHTTPRouter(store: try makeStore(), port: port, token: token)
        let session = try await initialize(router)
        let listing = try request(session: session, body: ["jsonrpc": "2.0", "id": 7, "method": "tools/list"])
        let old = await router.handle(listing)
        _ = try await consume(old, router: router)
        let current = await router.handle(listing)
        let duplicate = await router.handle(listing)
        XCTAssertEqual(duplicate.response.statusCode, 409)
        await router.disconnected(sessionID: session, streamKey: try XCTUnwrap(old.streamKey), leaseID: try XCTUnwrap(old.leaseID))
        let result = try await consume(current, router: router)
        XCTAssertEqual(result?["result"]?.objectValue?["tools"]?.arrayValue?.count, 10)
        let unknownCancel = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 999]]))
        XCTAssertEqual(unknownCancel.response.statusCode, 202)
        let next = await router.handle(listing)
        XCTAssertEqual(next.response.statusCode, 200)
        _ = try await consume(next, router: router)
        await router.shutdown()
    }

    func testReplayBudgetBlocksNewWorkWhileWaitDrainsThenRotates() async throws {
        let store = try makeStore()
        _ = try store.createSession(name: "Bounded replay", brief: "Review", agentCount: 2)
        let joined = try await store.execute(tool: "join_session", arguments: ["invitation": .string(store.sessions[0].participants[0].invitation), "request_id": .string("join"), "client": .string("test"), "model": .string("test")])
        let participant = try XCTUnwrap(joined.data.objectValue?["participant_token"]?.stringValue)
        let router = MCPHTTPRouter(store: store, port: port, token: token, replayBudget: 2048)
        let session = try await initialize(router)
        let other = try await initialize(router)
        let waiting = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": ["name": "read_events", "arguments": ["participant_token": .string(participant), "after_cursor": .int(store.sessions[0].latestCursor), "wait_seconds": 1]]]))
        XCTAssertEqual(waiting.response.statusCode, 200)
        let listing = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": 3, "method": "tools/list"]))
        _ = try await consume(listing, router: router)
        let next = try request(session: session, body: ["jsonrpc": "2.0", "id": 4, "method": "tools/list"])
        let blocked = await router.handle(next)
        XCTAssertEqual(blocked.response.statusCode, 429)
        let blockedGET = await router.handle(try request(method: "GET", session: session))
        XCTAssertEqual(blockedGET.response.statusCode, 429)
        let cancellation = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "method": "notifications/cancelled", "params": ["requestId": 999]]))
        XCTAssertEqual(cancellation.response.statusCode, 202)
        let otherListing = await router.handle(try request(session: other, body: ["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        XCTAssertEqual(otherListing.response.statusCode, 200)
        _ = try await consume(otherListing, router: router)
        let result = try await consume(waiting, router: router)
        XCTAssertNotNil(result?["result"], "Budget exhaustion must let the existing wait finish")
        let rotated = await router.handle(next)
        XCTAssertEqual(rotated.response.statusCode, 404)
        let deleted = await router.handle(try request(method: "DELETE", session: other))
        XCTAssertEqual(deleted.response.statusCode, 200, "Deletion must remain available after the replay budget is exhausted")
        await router.shutdown()
    }

    func testConcurrentRequestLimitIsPerClientAndReleasesOnCompletion() async throws {
        let router = MCPHTTPRouter(store: try makeStore(), port: port, token: token)
        let session = try await initialize(router)
        let other = try await initialize(router)
        var pending: [MCPExchange] = []
        for id in 2..<(2 + MCPHTTPRouter.maximumConcurrentRequests) {
            let exchange = await router.handle(try request(session: session, body: ["jsonrpc": "2.0", "id": .int(id), "method": "tools/list"]))
            XCTAssertEqual(exchange.response.statusCode, 200)
            pending.append(exchange)
        }
        let next = try request(session: session, body: ["jsonrpc": "2.0", "id": 100, "method": "tools/list"])
        let blocked = await router.handle(next)
        XCTAssertEqual(blocked.response.statusCode, 429)
        let otherListing = await router.handle(try request(session: other, body: ["jsonrpc": "2.0", "id": 100, "method": "tools/list"]))
        XCTAssertEqual(otherListing.response.statusCode, 200)
        _ = try await consume(otherListing, router: router)
        _ = try await consume(pending.removeFirst(), router: router)
        let admitted = await router.handle(next)
        XCTAssertEqual(admitted.response.statusCode, 200)
        _ = try await consume(admitted, router: router)
        for exchange in pending { _ = try await consume(exchange, router: router) }
        await router.shutdown()
    }

    func testImageAndStructuredContentRemainSeparate() throws {
        let data: JSONValue = .object(["count": .int(2), "nested": .array([.bool(true), .null, .double(1.5)])])
        let image = ToolImage(data: Data([1, 2, 3]), mimeType: "image/png")
        let result = try MCPTools.result(.init(data: data, images: [image]))
        XCTAssertEqual(result.structuredContent, try Value(data))
        XCTAssertEqual(result.content.count, 2)
        guard case .image(let bytes, let type, _, _) = result.content[1] else { return XCTFail("Image must be a native MCP image block") }
        XCTAssertEqual(Data(base64Encoded: bytes), image.data)
        XCTAssertEqual(type, "image/png")
        XCTAssertEqual(try MCPTools.arguments(["data": Value(data)]), ["data": data])
    }
}

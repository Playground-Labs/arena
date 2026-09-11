import Foundation
import Hummingbird
import HTTPTypes
import MCP
import Observation

@MainActor @Observable
final class MCPService {
    private(set) var state = "Stopped"
    private(set) var clientActivity: [String: Date] = [:]
    let endpoint: String
    @ObservationIgnored private let store: ArenaStore
    @ObservationIgnored private let port: Int
    @ObservationIgnored private let token: String
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var router: MCPHTTPRouter?

    init(store: ArenaStore, port: Int, token: String) {
        self.store = store
        self.port = port
        self.token = token
        self.endpoint = "http://127.0.0.1:\(port)/mcp"
    }

    func start() {
        guard task == nil else { return }
        guard (1024...65535).contains(port), !token.isEmpty else {
            state = "Invalid port or access token"
            return
        }
        state = "Starting"
        let router = MCPHTTPRouter(store: store, port: port, token: token) { [weak self] activity in
            self?.clientActivity = activity
        }
        self.router = router
        let application = Application(
            responder: ArenaHTTPResponder(router: router),
            configuration: .init(address: .hostname("127.0.0.1", port: port), serverName: "Arena"),
            onServerRunning: { [weak self] _ in
                await MainActor.run { self?.state = "Listening" }
            }
        )
        task = Task { [weak self] in
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { try await application.run() }
                    group.addTask {
                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(60))
                            await router.expireIdleSessions()
                        }
                    }
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                if !Task.isCancelled { self?.state = "Server error: \(error.localizedDescription)" }
            }
            await router.shutdown()
            self?.task = nil
        }
    }

    func stop() async {
        let running = task
        running?.cancel()
        await router?.shutdown()
        await running?.value
        router = nil
        state = "Stopped"
    }

    func lastActivity(for client: ClientSetup.Client) -> Date? {
        clientActivity.filter { name, _ in
            name.lowercased().contains(client == .codex ? "codex" : "claude")
        }.values.max()
    }
}

struct MCPAccess: Sendable {
    let port: Int
    let token: String
    static let maximumBody = 1_048_576

    func rejection(for request: MCP.HTTPRequest) -> MCP.HTTPResponse? {
        guard request.path == "/mcp" else { return .error(statusCode: 404, .invalidRequest("Not found")) }
        let hosts = ["127.0.0.1:\(port)", "localhost:\(port)"]
        guard let host = request.header("Host"), hosts.contains(host.lowercased()) else {
            return .error(statusCode: 403, .invalidRequest("Invalid Host"))
        }
        if let origin = request.header("Origin"), !hosts.map({ "http://\($0)" }).contains(origin.lowercased()) {
            return .error(statusCode: 403, .invalidRequest("Invalid Origin"))
        }
        let expected = Array("Bearer \(token)".utf8)
        let received = Array((request.header("Authorization") ?? "").utf8)
        guard received.count == expected.count,
              zip(received, expected).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else {
            return .error(statusCode: 401, .invalidRequest("Bearer token required"), extraHeaders: ["WWW-Authenticate": "Bearer"])
        }
        guard ["POST", "GET", "DELETE"].contains(request.method) else {
            return .error(statusCode: 405, .invalidRequest("Method not allowed"), extraHeaders: ["Allow": "POST, GET, DELETE"])
        }
        if (request.body?.count ?? 0) > Self.maximumBody {
            return .error(statusCode: 413, .invalidRequest("Request body exceeds 1 MiB"))
        }
        return nil
    }
}

struct MCPExchange: Sendable {
    let response: MCP.HTTPResponse
    var sessionID: String?
    var streamKey: String?
    var leaseID: UUID?
}

/// One SDK Server and transport per HTTP client session: JSON-RPC IDs are client-scoped.
actor MCPHTTPRouter {
    nonisolated let access: MCPAccess
    private let store: ArenaStore
    private let replayBudget: Int
    private let activityChanged: @MainActor @Sendable ([String: Date]) -> Void
    private struct Session {
        let server: MCP.Server
        let transport: StatefulHTTPServerTransport
        let executor: MCPToolExecutor
        let clientName: String
        var initialized = false
        var activeStreams: [String: UUID] = [:]
        var lastAccess = Date()
        var responseBytes = 0
        var activeRequestCount: Int { activeStreams.keys.filter { $0 != "get" }.count }
        var hasActiveRequests: Bool { activeRequestCount > 0 }
    }
    private var sessions: [String: Session] = [:]
    private var creating = 0
    private var stopped = false
    // ponytail: SDK 0.12.1 retains SSE replay forever; expire idle sessions and rotate
    // at 32 MiB between calls, admitting no more work while existing calls drain.
    // Up to eight already-admitted responses may exceed this soft threshold.
    // Remove rollover when the SDK supports bounded replay.
    static let defaultReplayBudget = 32 * 1024 * 1024
    static let maximumSessions = 32
    static let maximumConcurrentRequests = 8

    init(store: ArenaStore, port: Int, token: String, replayBudget: Int = MCPHTTPRouter.defaultReplayBudget,
         activityChanged: @escaping @MainActor @Sendable ([String: Date]) -> Void = { _ in }) {
        self.store = store
        self.replayBudget = replayBudget
        self.activityChanged = activityChanged
        access = MCPAccess(port: port, token: token)
    }

    func handle(_ request: MCP.HTTPRequest) async -> MCPExchange {
        if let rejection = access.rejection(for: request) { return .init(response: rejection) }
        guard !stopped else { return failure(503, "Server is stopping") }

        var method: String?
        var requestKey: String?
        var cancelKey: String?
        var clientName = ""
        if request.method == "POST" {
            guard let body = request.body,
                  let envelope = try? JSONDecoder().decode([String: Value].self, from: body),
                  envelope["jsonrpc"] == .string("2.0"),
                  let rpcMethod = envelope["method"]?.stringValue else {
                return failure(400, "Expected a JSON-RPC 2.0 request or notification")
            }
            method = rpcMethod
            if let id = envelope["id"] {
                // SDK 0.12.1 conflates numeric 7 and string "7" in its transport map.
                // Reject their concurrent reuse within one client rather than misroute.
                switch id {
                case .string(let value): requestKey = "rpc:\(value)"
                case .int(let value): requestKey = "rpc:\(value)"
                default: return failure(400, "Request id must be an integer or string")
                }
            } else if !rpcMethod.hasPrefix("notifications/") {
                return failure(400, "Request id is required")
            }
            if let params = envelope["params"], params.objectValue == nil {
                return failure(400, "Request params must be an object")
            }
            if rpcMethod == "notifications/cancelled", let id = envelope["params"]?.objectValue?["requestId"] {
                switch id {
                case .string(let value): cancelKey = "rpc:\(value)"
                case .int(let value): cancelKey = "rpc:\(value)"
                default: break
                }
            }
            if rpcMethod == "initialize" {
                guard let params = envelope["params"],
                      let data = try? JSONEncoder().encode(params),
                      (try? JSONDecoder().decode(Initialize.Parameters.self, from: data)) != nil else {
                    return failure(400, "Invalid initialize parameters")
                }
                clientName = String((params.objectValue?["clientInfo"]?.objectValue?["name"]?.stringValue ?? "").prefix(128))
            }
        }

        var sessionID: String
        if let supplied = request.header("MCP-Session-Id") {
            guard let session = sessions[supplied] else { return failure(404, "MCP session expired; initialize again, retaining your Arena participant_token") }
            sessionID = supplied
            let isTeardown = request.method == "DELETE" || (method == "notifications/cancelled" && requestKey == nil)
            if session.responseBytes >= replayBudget && !isTeardown {
                guard !session.hasActiveRequests else {
                    return failure(429, "MCP replay budget reached; let active calls finish or cancel them before retrying")
                }
                await closeSession(supplied)
                return failure(404, "MCP replay budget reached; initialize again, retaining your Arena participant_token")
            }
        } else {
            guard request.method == "POST", method == "initialize", requestKey != nil else {
                return failure(400, "Initialize first, then send MCP-Session-Id")
            }
            guard sessions.count + creating < Self.maximumSessions else { return failure(503, "Too many MCP sessions; close an unused session") }
            creating += 1
            defer { creating -= 1 }
            sessionID = UUID().uuidString
            let executor = MCPToolExecutor(store: store)
            let server = MCP.Server(name: "Arena", version: "1.0.0", instructions: MCPTools.instructions,
                                    capabilities: .init(tools: .init()), configuration: .strict)
            await server.withMethodHandler(ListTools.self) { _ in .init(tools: MCPTools.definitions) }
            await server.withMethodHandler(CallTool.self) { try await executor.call($0) }
            let transport = StatefulHTTPServerTransport(sessionIDGenerator: FixedSessionID(id: sessionID))
            do { try await server.start(transport: transport) }
            catch { await executor.stop(); return failure(500, "Unable to start MCP session") }
            guard !stopped else { await executor.stop(); await server.stop(); return failure(503, "Server is stopping") }
            sessions[sessionID] = Session(server: server, transport: transport, executor: executor, clientName: clientName)
        }

        guard let session = sessions[sessionID] else { return failure(404, "MCP session expired") }
        let streamKey = request.method == "GET" ? "get" : requestKey
        let leaseID = UUID()
        if let streamKey {
            guard session.activeStreams[streamKey] == nil else { return failure(409, "Request id or GET stream is already in use") }
            if requestKey != nil, session.activeRequestCount >= Self.maximumConcurrentRequests {
                return failure(429, "At most eight requests may be in flight per MCP session; wait for a response before retrying")
            }
            sessions[sessionID]?.activeStreams[streamKey] = leaseID
        }
        sessions[sessionID]?.lastAccess = .now
        let response = await session.transport.handleRequest(request)
        if method == "notifications/initialized", response.statusCode == 202 {
            sessions[sessionID]?.initialized = true
        }
        if request.method == "DELETE", response.statusCode == 200 {
            await closeSession(sessionID)
        } else if method == "notifications/cancelled", response.statusCode == 202,
                  let cancelKey, sessions[sessionID]?.activeStreams[cancelKey] != nil {
            // The SDK has no public per-stream close API. Closing this client session
            // releases its canceled SSE stream and cancels all owned tool tasks.
            await closeSession(sessionID)
        }
        await publishActivity()
        if case .stream = response {
            return .init(response: response, sessionID: sessionID, streamKey: streamKey, leaseID: leaseID)
        }
        if let streamKey { sessions[sessionID]?.activeStreams.removeValue(forKey: streamKey) }
        if method == "initialize", response.statusCode >= 400 { await closeSession(sessionID) }
        return .init(response: response)
    }

    func complete(sessionID: String, streamKey: String, leaseID: UUID, bytes: Int) async {
        guard sessions[sessionID]?.activeStreams[streamKey] == leaseID else { return }
        sessions[sessionID]?.activeStreams.removeValue(forKey: streamKey)
        sessions[sessionID]?.responseBytes += bytes
        sessions[sessionID]?.lastAccess = .now
        await publishActivity()
    }

    func disconnected(sessionID: String, streamKey: String, leaseID: UUID) async {
        guard sessions[sessionID]?.activeStreams[streamKey] == leaseID else { return }
        await closeSession(sessionID)
    }

    func expireIdleSessions(now: Date = .now) async {
        let expired = sessions.filter { _, session in
            !session.hasActiveRequests && now.timeIntervalSince(session.lastAccess) > 1800
        }.map(\.key)
        for id in expired { await closeSession(id) }
    }

    func shutdown() async {
        stopped = true
        for id in Array(sessions.keys) { await closeSession(id) }
    }

    private func closeSession(_ id: String) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await publishActivity()
        await session.executor.stop()
        await session.server.stop()
    }

    private func publishActivity() async {
        var activity: [String: Date] = [:]
        for session in sessions.values where session.initialized && session.clientName != "arena-setup-check" {
            activity[session.clientName] = max(activity[session.clientName] ?? .distantPast, session.lastAccess)
        }
        await activityChanged(activity)
    }

    private func failure(_ code: Int, _ message: String) -> MCPExchange {
        .init(response: .error(statusCode: code, .invalidRequest(message)))
    }
    private struct FixedSessionID: SessionIDGenerator {
        let id: String
        func generateSessionID() -> String { id }
    }
}

struct ArenaRequestContext: Hummingbird.RequestContext {
    var coreContext: CoreRequestContextStorage
    let whenDisconnected: @Sendable (@escaping @Sendable () -> Void) -> Void
    init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        let channel = source.channel
        whenDisconnected = { callback in channel.closeFuture.whenComplete { _ in callback() } }
    }
}

struct ArenaHTTPResponder: HTTPResponder {
    typealias Context = ArenaRequestContext
    let router: MCPHTTPRouter

    func respond(to request: Hummingbird.Request, context: Context) async throws -> Hummingbird.Response {
        var headers: [String: String] = [:]
        for header in request.headers {
            let name = header.name.rawName.lowercased()
            headers[name] = headers[name].map { $0 + "," + header.value } ?? header.value
        }
        headers["host"] = request.head.authority ?? headers["host"]
        let head = MCP.HTTPRequest(method: request.method.rawValue, headers: headers, path: request.uri.path)
        if let rejection = router.access.rejection(for: head) { return response(rejection) }
        let body: Data
        do {
            let buffer = try await request.body.collect(upTo: MCPAccess.maximumBody)
            body = Data(buffer.readableBytesView)
        } catch {
            return response(.error(statusCode: 413, .invalidRequest("Unable to read body within 1 MiB limit")))
        }
        let exchange = await router.handle(.init(method: head.method, headers: headers, body: body, path: head.path))
        guard case .stream(let stream, _) = exchange.response,
              let sessionID = exchange.sessionID, let streamKey = exchange.streamKey, let leaseID = exchange.leaseID else {
            return response(exchange.response)
        }
        context.whenDisconnected {
            Task { await router.disconnected(sessionID: sessionID, streamKey: streamKey, leaseID: leaseID) }
        }
        let bodyWriter = ResponseBody { writer in
            do {
                try await withTaskCancellationHandler {
                    var bytes = 0
                    for try await chunk in stream {
                        try Task.checkCancellation()
                        bytes += chunk.count
                        try await writer.write(ByteBuffer(bytes: chunk))
                    }
                    try Task.checkCancellation()
                    await router.complete(sessionID: sessionID, streamKey: streamKey, leaseID: leaseID, bytes: bytes)
                    try await writer.finish(nil)
                } onCancel: {
                    Task { await router.disconnected(sessionID: sessionID, streamKey: streamKey, leaseID: leaseID) }
                }
            } catch {
                await router.disconnected(sessionID: sessionID, streamKey: streamKey, leaseID: leaseID)
                throw error
            }
        }
        return response(exchange.response, body: bodyWriter)
    }

    private func response(_ response: MCP.HTTPResponse, body: ResponseBody? = nil) -> Hummingbird.Response {
        var headers = HTTPFields()
        for (name, value) in response.headers {
            if let name = HTTPField.Name(name) { headers.append(.init(name: name, value: value)) }
        }
        headers[.cacheControl] = "no-store"
        return .init(status: .init(code: response.statusCode), headers: headers,
                     body: body ?? ResponseBody(byteBuffer: ByteBuffer(bytes: response.bodyData ?? Data())))
    }
}

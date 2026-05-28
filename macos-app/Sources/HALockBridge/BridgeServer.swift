import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// HTTP + WebSocket server. Bound to one EventLoopGroup; lives for the app's lifetime.
///
/// Reliability decisions:
/// - `SO_REUSEADDR` so a quick restart doesn't fail on bind
/// - `SO_KEEPALIVE` on accepted sockets so dead peers eventually surface
/// - Per-connection error handlers close that connection without affecting the server
/// - WS clients get a 15s server-side ping; if no pong within 30s the connection closes
/// - HTTP request bodies capped at 1 MiB (we only accept tiny JSON bodies)
final class BridgeServer {

    private let monitor: HomeKitMonitor
    private let store: TokenStore
    private let pairingManager: PairingManager
    private let interactionLog: InteractionLog
    private let logger: (String) -> Void
    private let group: EventLoopGroup
    private var channel: Channel?

    /// Live WS connections — accessed from the main thread.
    private var wsConnections: [WSConnection] = []
    private var observerToken: HomeKitMonitor.ObserverToken?

    init(
        monitor: HomeKitMonitor,
        store: TokenStore,
        pairingManager: PairingManager,
        interactionLog: InteractionLog,
        logger: @escaping (String) -> Void
    ) {
        self.monitor = monitor
        self.store = store
        self.pairingManager = pairingManager
        self.interactionLog = interactionLog
        self.logger = logger
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    func start() throws {
        installObservers()
        let bootstrap = makeBootstrap()
        channel = try bootstrap.bind(host: store.host, port: store.port).wait()
        logger("HTTP + WebSocket server listening on \(store.host):\(store.port)")
    }

    private func installObservers() {
        // Capture self weakly; the observer's job is to fan state out to live WS clients.
        observerToken = monitor.addObserver(
            onState: { [weak self] state in
                self?.broadcastState(state)
            },
            onRemoved: { [weak self] id in
                self?.broadcastRemoval(id)
            }
        )
    }

    private func makeBootstrap() -> ServerBootstrap {
        let monitor = self.monitor
        let store = self.store
        let pairing = self.pairingManager
        let interactionLog = self.interactionLog
        let registerWS: (WSConnection) -> Void = { [weak self] conn in self?.registerWS(conn) }
        let unregisterWS: (WSConnection) -> Void = { [weak self] conn in self?.unregisterWS(conn) }
        let serverLogger = self.logger

        return ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPRequestHandler(
                    monitor: monitor,
                    store: store,
                    pairing: pairing,
                    interactionLog: interactionLog,
                    logger: serverLogger
                )

                let wsUpgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 1 << 14,
                    shouldUpgrade: { (channel, head) -> EventLoopFuture<HTTPHeaders?> in
                        let authed = Self.isAuthorized(head: head, store: store)
                        serverLogger("DEBUG shouldUpgrade called: uri=\(head.uri) authed=\(authed)")
                        if authed {
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        }
                        return channel.eventLoop.makeSucceededFuture(nil)
                    },
                    upgradePipelineHandler: { (channel, head) -> EventLoopFuture<Void> in
                        let conn = WSConnection(
                            channel: channel,
                            monitor: monitor,
                            unregister: unregisterWS,
                            logger: serverLogger
                        )
                        registerWS(conn)
                        return channel.pipeline.addHandler(conn)
                    }
                )

                let httpConfig = NIOHTTPServerUpgradeConfiguration(
                    upgraders: [wsUpgrader],
                    completionHandler: { context in
                        // After successful WS upgrade, the HTTP codec was already
                        // removed by configureHTTPServerPipeline. We must also
                        // remove our HTTPRequestHandler so it doesn't try to
                        // decode incoming WebSocketFrames as HTTPServerRequestPart
                        // and crash with a NIOAny type mismatch.
                        context.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: httpConfig,
                    withErrorHandling: true
                ).flatMap {
                    channel.pipeline.addHandler(httpHandler)
                }
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
    }

    // MARK: - WS connection registry (main thread)

    /// Fires on every WS connect/disconnect with the fresh remote-IP list.
    /// Invoked on the main thread (same thread the bookkeeping mutations run on).
    /// Used by the status window's HA-connected indicator so it stays live
    /// while the Stats & Debug page is open, instead of being a stale
    /// snapshot from the moment the page was opened.
    var onConnectionsChanged: (([String]) -> Void)?

    private func registerWS(_ conn: WSConnection) {
        DispatchQueue.main.async {
            self.wsConnections.append(conn)
            self.logger("WS client connected (total=\(self.wsConnections.count))")
            // Send an initial snapshot.
            let snapshot = self.monitor.snapshot()
            conn.send(envelope: .snapshot(snapshot))
            self.onConnectionsChanged?(self.wsConnections.map { $0.remoteIP })
        }
    }

    private func unregisterWS(_ conn: WSConnection) {
        DispatchQueue.main.async {
            self.wsConnections.removeAll { $0 === conn }
            self.logger("WS client disconnected (total=\(self.wsConnections.count))")
            self.onConnectionsChanged?(self.wsConnections.map { $0.remoteIP })
        }
    }

    private func broadcastState(_ state: AccessoryState) {
        guard !wsConnections.isEmpty else { return }
        for conn in wsConnections {
            conn.send(envelope: .state(state))
        }
        // Log once per broadcast (not per WS recipient). In the single-pair
        // model there's at most one connection, so we attribute the IP to
        // the first one. If multiple were connected we'd lose that detail
        // here but the InteractionLog's purpose is human-readable status,
        // not an audit trail.
        interactionLog.record(.init(
            direction: .stateUpdate,
            accessoryName: state.name,
            accessoryID: state.id,
            detail: state.lifecycleState,
            timestamp: Date(),
            clientAddress: wsConnections.first?.remoteIP ?? "unknown"
        ))
    }

    private func broadcastRemoval(_ id: UUID) {
        for conn in wsConnections {
            conn.send(envelope: .removed(id.uuidString))
        }
    }

    /// Snapshot of remote IPs for every currently-connected WebSocket client.
    /// Call from the main thread — that's the same thread `wsConnections` is
    /// mutated on (see `registerWS` / `unregisterWS`), so no extra locking
    /// is needed. Used by the Stats & Debug view to surface live HA
    /// connectivity in the status window.
    func connectedClientIPs() -> [String] {
        return wsConnections.map { $0.remoteIP }
    }

    // MARK: - Auth helpers

    /// True iff the request presents a token currently registered in the store.
    fileprivate static func isAuthorized(head: HTTPRequestHead, store: TokenStore) -> Bool {
        if let auth = head.headers["Authorization"].first,
           auth.hasPrefix("Bearer "),
           store.isTokenValid(String(auth.dropFirst("Bearer ".count))) {
            return true
        }
        if let q = URLComponents(string: head.uri)?.queryItems,
           let tk = q.first(where: { $0.name == "token" })?.value,
           store.isTokenValid(tk) {
            return true
        }
        return false
    }
}

// MARK: - WS envelope (shared encoder for snapshot/state/removed)

enum WSEnvelope {
    case hello
    case snapshot([AccessoryState])
    case state(AccessoryState)
    case removed(String)

    func encode() -> Data? {
        switch self {
        case .hello:
            return try? JSONSerialization.data(withJSONObject: [
                "type": "hello",
                "server": "ha-lockbridge",
                "version": "0.4.5"
            ], options: [.sortedKeys])
        case .snapshot(let states):
            let body: [String: Any] = [
                "type": "snapshot",
                "accessories": states.compactMap { try? toJSONObject($0) }
            ]
            return try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        case .state(let state):
            guard let acc = try? toJSONObject(state) else { return nil }
            return try? JSONSerialization.data(withJSONObject: [
                "type": "state",
                "accessory": acc
            ], options: [.sortedKeys])
        case .removed(let id):
            return try? JSONSerialization.data(withJSONObject: [
                "type": "removed",
                "id": id
            ], options: [.sortedKeys])
        }
    }
}

private func toJSONObject(_ state: AccessoryState) throws -> Any {
    let data = try JSONEncoder.sortedKeys.encode(state)
    return try JSONSerialization.jsonObject(with: data)
}

// MARK: - WSConnection (one per WebSocket client)

final class WSConnection: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let monitor: HomeKitMonitor
    private let unregister: (WSConnection) -> Void
    private let logger: (String) -> Void
    private weak var channel: Channel?
    /// Captured at init so the InteractionLog can attribute outbound state
    /// pushes to an IP without re-reading channel.remoteAddress from the
    /// main thread (where broadcastState runs) after the connection may
    /// have torn down on the event loop.
    let remoteIP: String

    private var lastPongAt: Date = Date()
    private var pingTask: RepeatedTask?
    private var timeoutTask: RepeatedTask?
    private var unregistered = false
    private static let pingInterval: TimeAmount = .seconds(15)
    private static let pongTimeout: TimeInterval = 30

    init(channel: Channel, monitor: HomeKitMonitor, unregister: @escaping (WSConnection) -> Void, logger: @escaping (String) -> Void) {
        self.channel = channel
        self.monitor = monitor
        self.unregister = unregister
        self.logger = logger
        self.remoteIP = channel.remoteAddress?.ipAddress ?? "unknown"
    }

    func handlerAdded(context: ChannelHandlerContext) {
        send(envelope: .hello)
        schedulePing(on: context.eventLoop)
        scheduleTimeoutCheck(on: context.eventLoop)
    }

    func handlerRemoved(context: ChannelHandlerContext) { teardown() }
    func channelInactive(context: ChannelHandlerContext) { teardown() }

    private func teardown() {
        if unregistered { return }
        unregistered = true
        pingTask?.cancel()
        timeoutTask?.cancel()
        unregister(self)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger("WS error: \(error)")
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .pong:
            lastPongAt = Date()
        case .ping:
            // Respond with pong
            var data = frame.unmaskedData
            let response = WebSocketFrame(fin: true, opcode: .pong, data: data.readSlice(length: data.readableBytes) ?? frame.unmaskedData)
            context.writeAndFlush(self.wrapOutboundOut(response), promise: nil)
        case .connectionClose:
            close(context: context, code: .normalClosure)
        case .text, .binary:
            // We don't expect inbound app messages; HA only consumes. Ignore.
            break
        default:
            break
        }
    }

    private func schedulePing(on loop: EventLoop) {
        pingTask = loop.scheduleRepeatedTask(initialDelay: Self.pingInterval, delay: Self.pingInterval) { [weak self] _ in
            guard let self = self, let channel = self.channel else { return }
            let buffer = channel.allocator.buffer(capacity: 0)
            let ping = WebSocketFrame(fin: true, opcode: .ping, data: buffer)
            channel.writeAndFlush(ping, promise: nil)
        }
    }

    private func scheduleTimeoutCheck(on loop: EventLoop) {
        timeoutTask = loop.scheduleRepeatedTask(initialDelay: .seconds(10), delay: .seconds(5)) { [weak self] _ in
            guard let self = self else { return }
            if Date().timeIntervalSince(self.lastPongAt) > Self.pongTimeout {
                self.logger("WS pong timeout — closing connection")
                self.channel?.close(promise: nil)
            }
        }
    }

    func close(context: ChannelHandlerContext, code: WebSocketErrorCode) {
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: code)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.writeAndFlush(self.wrapOutboundOut(frame)).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    /// Send an envelope. Hops to the connection's event loop if necessary.
    func send(envelope: WSEnvelope) {
        guard let channel = channel else { return }
        guard let data = envelope.encode() else { return }
        let work: () -> Void = {
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            channel.writeAndFlush(frame, promise: nil)
        }
        if channel.eventLoop.inEventLoop {
            work()
        } else {
            channel.eventLoop.execute(work)
        }
    }
}

// MARK: - HTTP request handler

final class HTTPRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let monitor: HomeKitMonitor
    private let store: TokenStore
    private let pairing: PairingManager
    private let interactionLog: InteractionLog
    private let logger: (String) -> Void

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private static let maxBodyBytes = 1 << 20

    init(monitor: HomeKitMonitor, store: TokenStore, pairing: PairingManager, interactionLog: InteractionLog, logger: @escaping (String) -> Void) {
        self.monitor = monitor
        self.store = store
        self.pairing = pairing
        self.interactionLog = interactionLog
        self.logger = logger
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // NIOWebSocketUpgradeError.unsupportedWebSocketTarget fires when our
        // shouldUpgrade callback returns nil (failed auth). It's expected —
        // not a server fault — so don't log it as an error.
        if String(describing: type(of: error)).hasPrefix("NIOWebSocketUpgradeError") {
            context.close(promise: nil)
            return
        }
        logger("HTTP error: \(error)")
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer = nil
        case .body(var chunk):
            if bodyBuffer == nil {
                bodyBuffer = context.channel.allocator.buffer(capacity: chunk.readableBytes)
            }
            if (bodyBuffer?.readableBytes ?? 0) + chunk.readableBytes > Self.maxBodyBytes {
                respondJSON(context: context, status: .payloadTooLarge, body: ["error": "body too large"])
                return
            }
            bodyBuffer?.writeBuffer(&chunk)
        case .end:
            guard let head = requestHead else {
                respondJSON(context: context, status: .badRequest, body: ["error": "missing request head"])
                return
            }
            handle(head: head, body: bodyBuffer, context: context)
            requestHead = nil
            bodyBuffer = nil
        }
    }

    private func handle(head: HTTPRequestHead, body: ByteBuffer?, context: ChannelHandlerContext) {
        let path = URLComponents(string: head.uri)?.path ?? head.uri
        let query = URLComponents(string: head.uri)?.queryItems ?? []

        // DEBUG: log every incoming request so we can see what's reaching the
        // HTTP handler vs. being intercepted by the WS upgrader.
        let upHdr = head.headers["upgrade"].first ?? "-"
        let connHdr = head.headers["connection"].first ?? "-"
        let wsVer = head.headers["sec-websocket-version"].first ?? "-"
        let wsKey = head.headers["sec-websocket-key"].first ?? "-"
        logger("DEBUG http-handler: \(head.method) \(path) upgrade=\(upHdr) conn=\(connHdr) wsv=\(wsVer) wsk=\(wsKey != "-" ? "yes" : "no")")

        // /health is unauthenticated so HA can use it as a liveness probe.
        if head.method == .GET, path == "/health" {
            DispatchQueue.main.async {
                let count = self.monitor.snapshot().count
                context.eventLoop.execute {
                    self.respondJSON(context: context, status: .ok, body: [
                        "ok": true,
                        "accessory_count": count
                    ])
                }
            }
            return
        }

        // /info exposes the instance UUID for HA's discovery to verify identity
        // even outside the zeroconf TXT path (e.g. manual-add flow).
        if head.method == .GET, path == "/info" {
            respondJSON(context: context, status: .ok, body: [
                "instance_id": store.instanceID,
                "name": "HA-LockBridge",
                "version": "0.4.5"
            ])
            return
        }

        // Pair endpoints — UNAUTHENTICATED on purpose. Pairing IS how a client
        // becomes authenticated. Security is mediated by the user clicking
        // Approve in the bridge's status window at the Mac console.
        if head.method == .POST, path == "/pair/initiate" {
            handlePairInitiate(body: body, context: context)
            return
        }
        if head.method == .GET, path.hasPrefix("/pair/status/") {
            let id = String(path.dropFirst("/pair/status/".count))
            handlePairStatus(requestID: id, context: context)
            return
        }

        // Everything below needs a paired token.
        if !BridgeServer.isAuthorized(head: head, store: store) {
            respondJSON(context: context, status: .unauthorized, body: ["error": "unauthorized"])
            return
        }

        // GET /accessories
        if head.method == .GET, path == "/accessories" {
            DispatchQueue.main.async {
                let snapshot = self.monitor.snapshot()
                let payload: [String: Any] = [
                    "accessories": snapshot.compactMap { try? toJSONObject($0) }
                ]
                context.eventLoop.execute {
                    self.respondJSON(context: context, status: .ok, body: payload)
                }
            }
            return
        }

        // GET /accessories/{id} and POST /accessories/{id}/state
        if path.hasPrefix("/accessories/") {
            let trimmed = String(path.dropFirst("/accessories/".count))
            let parts = trimmed.split(separator: "/", maxSplits: 1).map(String.init)
            guard let idString = parts.first, let uuid = UUID(uuidString: idString) else {
                respondJSON(context: context, status: .badRequest, body: ["error": "invalid id"])
                return
            }

            if parts.count == 1, head.method == .GET {
                DispatchQueue.main.async {
                    let state = self.monitor.state(forID: uuid)
                    context.eventLoop.execute {
                        if let state = state, let obj = try? toJSONObject(state) {
                            self.respondJSON(context: context, status: .ok, bodyAny: obj)
                        } else {
                            self.respondJSON(context: context, status: .notFound, body: ["error": "not found"])
                        }
                    }
                }
                return
            }

            if parts.count == 2, parts[1] == "state", head.method == .POST {
                self.handleSetState(uuid: uuid, body: body, context: context)
                return
            }
        }

        respondJSON(context: context, status: .notFound, body: ["error": "not found"])
    }

    private func handleSetState(uuid: UUID, body: ByteBuffer?, context: ChannelHandlerContext) {
        guard var body = body,
              let data = body.readBytes(length: body.readableBytes).map({ Data($0) }),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = parsed["target"] as? String else {
            respondJSON(context: context, status: .badRequest, body: ["error": "expected JSON body with 'target': 'secured'|'unsecured'"])
            return
        }
        let raw: Int
        switch target {
        case "secured":   raw = 1
        case "unsecured": raw = 0
        default:
            respondJSON(context: context, status: .badRequest, body: ["error": "invalid target value"])
            return
        }

        let clientIP = context.remoteAddress?.ipAddress ?? "unknown"
        DispatchQueue.main.async {
            self.monitor.setLockState(id: uuid, target: raw) { result in
                context.eventLoop.execute {
                    switch result {
                    case .ok(let state):
                        guard let obj = try? toJSONObject(state) else {
                            self.respondJSON(context: context, status: .internalServerError, body: ["error": "encode failed"])
                            return
                        }
                        self.interactionLog.record(.init(
                            direction: .command,
                            accessoryName: state.name,
                            accessoryID: state.id,
                            detail: "→ \(target)",
                            timestamp: Date(),
                            clientAddress: clientIP
                        ))
                        self.respondJSON(context: context, status: .ok, bodyAny: obj)
                    case .notFound:
                        self.respondJSON(context: context, status: .notFound, body: ["error": "accessory not found"])
                    case .unreachable:
                        self.respondJSON(context: context, status: .serviceUnavailable, body: ["error": "accessory unreachable"])
                    case .homekitError(let msg):
                        self.respondJSON(context: context, status: .badGateway, body: ["error": "homekit: \(msg)"])
                    case .timeout:
                        self.respondJSON(context: context, status: .gatewayTimeout, body: ["error": "write timeout"])
                    }
                }
            }
        }
    }

    // MARK: - Pair endpoint handlers

    private func handlePairInitiate(body: ByteBuffer?, context: ChannelHandlerContext) {
        // Single-pairing model: refuse a new pair request while a client is
        // already paired. To pair a different HA instance, the user must
        // clear the existing pairing via "Reset Pairing…" on the bridge.
        if !store.snapshotConfig().paired_clients.isEmpty {
            respondJSON(context: context, status: .conflict, body: [
                "error": "already_paired",
                "detail": "This bridge is already paired. Use Reset Pairing on the bridge to clear it before pairing again."
            ])
            return
        }
        var clientName = "unknown"
        if var body = body,
           let data = body.readBytes(length: body.readableBytes).map({ Data($0) }),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let name = parsed["client_name"] as? String, !name.isEmpty {
            clientName = name
        }
        DispatchQueue.main.async {
            let requestID = self.pairing.createRequest(clientName: clientName)
            context.eventLoop.execute {
                self.respondJSON(context: context, status: .ok, body: [
                    "request_id": requestID,
                    "poll_interval_seconds": 2,
                    "expires_in_seconds": 300
                ])
            }
        }
    }

    private func handlePairStatus(requestID: String, context: ChannelHandlerContext) {
        DispatchQueue.main.async {
            guard let result = self.pairing.status(of: requestID) else {
                context.eventLoop.execute {
                    self.respondJSON(context: context, status: .notFound, body: ["error": "unknown request id"])
                }
                return
            }
            var body: [String: Any] = ["state": result.state.rawValue]
            if let token = result.token { body["token"] = token }
            context.eventLoop.execute {
                self.respondJSON(context: context, status: .ok, body: body)
            }
        }
    }

private func respondJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, body: [String: Any]) {
        let obj: Any = body
        respondJSON(context: context, status: status, bodyAny: obj)
    }

    private func respondJSON(context: ChannelHandlerContext, status: HTTPResponseStatus, bodyAny: Any) {
        let data = (try? JSONSerialization.data(withJSONObject: bodyAny, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Connection", value: "keep-alive")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}

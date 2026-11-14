import AppKit
import Network

/// Two loopback-only listeners: plain HTTP for the web UI and a WebSocket for input.
/// Nothing is reachable from the network directly; `tailscale serve` puts TLS in front of both.
final class Server {
    static let httpPort: UInt16 = 47800
    static let wsPort: UInt16 = 47801

    /// Clients are authenticated against the current token, so replacing it drops all of them.
    var token: String { didSet { clients.values.forEach { $0.connection.cancel() } } }
    private let input: Input
    private var listeners: [NWListener] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private lazy var screen = ScreenView { [weak self] frame in
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
        self?.viewer?.connection.send(content: frame, contentContext: context, completion: .idempotent)
    }
    private weak var viewer: Client?

    private final class Client {
        let connection: NWConnection
        var authed = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private struct Message: Decodable {
        let t: String
        var token: String?
        var dx: Double?
        var dy: Double?
        var b: String?
        var d: Bool?
        var s: String?
        var k: String?
        var n: Int?
        var mods: [String]?
        var on: Bool?
        var w: Double?
        var h: Double?
        var zoom: Double?
        var dpr: Double?
        var codec: String?
        var fps: Int?
    }

    /// Connections that are not yet answered (HTTP) or authenticated (WebSocket), oldest first.
    /// Anyone who reaches the ports gets this far without the token: local processes, web pages in
    /// the Mac's browser, tailnet peers. Bounded in number and time so they cannot use up the
    /// 256 file descriptors of a GUI app and lock the phone out.
    static let maxPending = 32
    private var pending: [NWConnection] = []
    private let pendingTimeout: TimeInterval
    private let ports: (http: UInt16, ws: UInt16)

    init(token: String, input: Input, httpPort: UInt16 = Server.httpPort, wsPort: UInt16 = Server.wsPort,
         pendingTimeout: TimeInterval = 5) {
        self.token = token
        self.input = input
        self.ports = (httpPort, wsPort)
        self.pendingTimeout = pendingTimeout
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
        pending.forEach { $0.cancel() }
        clients.values.forEach { $0.connection.cancel() }
    }

    private func admit(_ connection: NWConnection) {
        pending.append(connection)
        if pending.count > Self.maxPending { pending.removeFirst().cancel() }
        // Weak: a WebSocket cancelled before its handshake keeps its socket until the last reference is gone.
        DispatchQueue.main.asyncAfter(deadline: .now() + pendingTimeout) { [weak self, weak connection] in
            if let connection, self?.settle(connection) == true { connection.cancel() }
        }
    }

    /// False if the connection was no longer pending.
    @discardableResult
    private func settle(_ connection: NWConnection) -> Bool {
        guard let index = pending.firstIndex(where: { $0 === connection }) else { return false }
        pending.remove(at: index)
        return true
    }

    func start() throws {
        let http = try listener(port: ports.http, parameters: .tcp)
        http.newConnectionHandler = { [weak self] in self?.serveHTTP($0) }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 64 * 1024
        let wsParameters = NWParameters.tcp
        wsParameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let ws = try listener(port: ports.ws, parameters: wsParameters)
        ws.newConnectionHandler = { [weak self] in self?.serveWebSocket($0) }

        listeners = [http, ws]
        listeners.forEach { $0.start(queue: .main) }
    }

    private func listener(port: UInt16, parameters: NWParameters) throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        return try NWListener(using: parameters)
    }

    // MARK: HTTP

    private func serveHTTP(_ connection: NWConnection) {
        admit(connection)
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            self?.settle(connection)
            guard let data else { return connection.cancel() }
            let requestLine = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first ?? ""
            let parts = requestLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""

            var status = "404 Not Found", type = "text/plain; charset=utf-8", body = Data("Not found".utf8)
            if parts.first == "GET" {
                if path == "/" || path == "/index.html" {
                    (status, type, body) = ("200 OK", "text/html; charset=utf-8", Self.resource("index", "html"))
                } else if path == "/live-view.js" {
                    (status, type, body) = ("200 OK", "text/javascript; charset=utf-8", Self.resource("live-view", "js"))
                } else if path == "/icon.png" {
                    (status, type, body) = ("200 OK", "image/png", Self.resource("icon", "png"))
                }
            }
            let head = [
                "HTTP/1.1 \(status)",
                "Content-Type: \(type)",
                "Content-Length: \(body.count)",
                "Connection: close",
                "Cache-Control: no-cache",
                "X-Content-Type-Options: nosniff",
                "Referrer-Policy: no-referrer",
                "Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; "
                    + "script-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self'; "
                    + "frame-ancestors 'none'",
            ].joined(separator: "\r\n") + "\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    /// Bundled files in the app; read from the source tree on every request during `swift run`.
    private static func resource(_ name: String, _ ext: String) -> Data {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return data
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Web/\(name).\(ext)")
        return (try? Data(contentsOf: dev)) ?? Data("\(name).\(ext) fehlt".utf8)
    }

    // MARK: WebSocket

    private func serveWebSocket(_ connection: NWConnection) {
        let client = Client(connection)
        let id = ObjectIdentifier(client)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let self, self.clients.removeValue(forKey: id) != nil else { return }
                self.settle(connection)
                if client.authed { self.input.releaseAll() }
                if self.viewer === client { self.stopView() }
            default: break
            }
        }
        admit(connection)
        connection.start(queue: .main)
        receive(client)
    }

    private func receive(_ client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil,
                  let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata,
                  metadata.opcode == .text || metadata.opcode == .binary,
                  let data, let message = try? JSONDecoder().decode(Message.self, from: data) else {
                client.connection.cancel()
                return
            }
            if client.authed {
                self.handle(message, from: client)
            } else if message.t == "auth", let candidate = message.token, Token.matches(candidate, self.token) {
                client.authed = true
                self.settle(client.connection)
                self.send(client, #"{"t":"ok","ax":\#(AXIsProcessTrusted())}"#)
            } else {
                self.send(client, #"{"t":"denied"}"#) { client.connection.cancel() }
                return
            }
            self.receive(client)
        }
    }

    private func send(_ client: Client, _ text: String, then: (() -> Void)? = nil) {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        client.connection.send(content: Data(text.utf8), contentContext: context,
                               completion: .contentProcessed { _ in then?() })
    }

    private func handle(_ m: Message, from client: Client) {
        func delta() -> (Double, Double)? {
            guard let dx = m.dx, let dy = m.dy, dx.isFinite, dy.isFinite,
                  abs(dx) <= 5000, abs(dy) <= 5000 else { return nil }
            return (dx, dy)
        }
        let button: CGMouseButton = m.b == "right" ? .right : .left
        switch m.t {
        case "m": if let (dx, dy) = delta() { input.move(dx: dx, dy: dy) }
        case "s": if let (dx, dy) = delta() { input.scroll(dx: dx, dy: dy) }
        case "c": input.click(button)
        case "b": if let down = m.d { input.button(button, down: down) }
        case "text": if let s = m.s, s.count <= 2000 { input.type(s) }
        case "key": if let k = m.k { input.key(k, mods: m.mods ?? [], count: m.n ?? 1) }
        case "media": if let k = m.k { input.media(k) }
        case "view": view(m, for: client)
        case "shown": if viewer === client, let n = m.n.flatMap(UInt32.init(exactly:)) { screen.frameShown(n) }
        default: break
        }
    }

    /// Switches the live view on (or resizes it) for one client; the most recent requester wins.
    private func view(_ m: Message, for client: Client) {
        guard m.on == true, let width = m.w, let height = m.h,
              let request = ScreenView.Request(width: width, height: height, zoom: m.zoom ?? 1,
                                               pixelRatio: m.dpr ?? 2, h264: m.codec == "h264", fps: m.fps ?? 60) else {
            if viewer === client { stopView() }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return send(client, #"{"t":"view","ok":false}"#)
        }
        if viewer !== client { stopView() }
        viewer = client
        screen.update(request)
    }

    private func stopView() {
        viewer = nil
        screen.update(nil)
    }
}

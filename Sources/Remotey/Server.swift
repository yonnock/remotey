import AppKit
import Network

/// Two loopback-only listeners: plain HTTP for the web UI on `port` and a WebSocket for input on the port after it,
/// which the page derives from its own. Nothing is reachable from the network directly; `tailscale serve` puts
/// TLS in front of both.
final class Server {
    /// `REMOTEY_PORT` moves both, so a development build can run beside the installed app.
    static let port: UInt16 = ProcessInfo.processInfo.environment["REMOTEY_PORT"].flatMap(UInt16.init)
        .flatMap { $0 < .max ? $0 : nil } ?? 47800

    /// Clients are authenticated against the current token, so replacing it drops all of them.
    var token: String { didSet { clients.values.forEach { $0.connection.cancel() } } }
    private let input: Input
    private let apps = Apps()
    private let lock: LockScreen
    private let faceUnlock: FaceUnlock
    /// A password from the passkey is on its way into the lock screen.
    private var typesSealedPassword = false
    private var enrolmentEnds: DispatchWorkItem?
    private var enrolmentEnded: ((Bool) -> Void)?
    private var displays = Displays()
    private var displaysChanged: NSObjectProtocol?
    private var listeners: [NWListener] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private lazy var screen: ScreenView = {
        let screen = ScreenView(update: { [weak self] update in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
            self?.viewer?.connection.send(content: update.data, contentContext: context, completion: .idempotent)
        }, cursor: { [weak self] picture in
            guard let self, let viewer = self.viewer, let message = Wire.cursor(picture) else { return false }
            self.send(viewer, message)
            return true
        })
        // A window that came forward without the switcher, by Command-Tab or a key from the phone: the pointer
        // goes to it as it does after the switcher, unless it is inside already or holds a button.
        screen.cameForward = { [weak self] frame in
            guard let self, self.viewer != nil, self.input.move(into: frame) else { return }
            self.screen.pointerMoved()
        }
        return screen
    }()
    private weak var viewer: Client?

    private final class Client {
        let connection: NWConnection
        var authed = false
        /// The app icons this connection has, by the names the list gives them.
        var icons: Set<String> = []
        /// The page opened the display picker on this connection, so it hears when the displays change.
        var watchesDisplays = false
        /// What the phone's passkey has to sign to unlock the Mac from this connection, once.
        var challenge: Data?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// Connections that are not yet answered (HTTP) or authenticated (WebSocket), oldest first.
    /// Anyone who reaches the ports gets this far without the token: local processes, web pages in
    /// the Mac's browser, tailnet peers. Bounded in number and time so they cannot use up the
    /// 256 file descriptors of a GUI app and lock the phone out.
    static let maxPending = 32
    private var pending: [NWConnection] = []
    private let pendingTimeout: TimeInterval
    private let ports: (http: UInt16, ws: UInt16)

    init(token: String, input: Input, port: UInt16 = Server.port, pendingTimeout: TimeInterval = 5,
         lock: LockScreen = LockScreen(), faceUnlock: FaceUnlock? = nil) {
        self.token = token
        self.input = input
        self.ports = (port, port + 1)
        self.pendingTimeout = pendingTimeout
        self.lock = lock
        self.faceUnlock = faceUnlock ?? FaceUnlock(file: FaceUnlock.file(port: port))
        lock.changed = { [weak self] locked in
            guard let self else { return }
            // On the lock screen the view shows the password field; back on the desktop it shows the pointer again.
            if !locked, self.viewer != nil { self.screen.followText(false) }
            if self.viewer != nil { self.screen.locked = locked }
            // The Mac took the password that was sealed for the passkey.
            if !locked, self.typesSealedPassword { self.faceUnlock.opened() }
            self.typesSealedPassword = false
            self.clients.values.filter(\.authed).forEach { self.send($0, self.lockState(for: $0)) }
        }
        // Displays were connected, removed, rearranged or changed their mode: an open picker follows.
        displaysChanged = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.clients.values.contains(where: \.watchesDisplays) else { return }
            let list = Wire.displays(Displays.list())
            self.clients.values.filter(\.watchesDisplays).forEach { self.send($0, list) }
        }
    }

    func stop() {
        listeners.forEach { $0.cancel() }
        listeners = []
        pending.forEach { $0.cancel() }
        clients.values.forEach { $0.connection.cancel() }
        // A window that has the phone's shape gets its frame back now, not with the news of the closed connection.
        if viewer != nil { stopView() }
        if let displaysChanged { NotificationCenter.default.removeObserver(displaysChanged) }
        displaysChanged = nil
        withdrawFaceUnlock()
    }

    // MARK: Face ID

    /// Whether a phone is enrolled to unlock this Mac with Face ID.
    var unlocksWithFaceID: Bool { faceUnlock.key != nil }

    /// How long an enrolment started at the Mac waits for the phone.
    static let enrolmentTime: TimeInterval = 120

    /// Offers every connected phone to enrol for Face ID, with the Mac's password to seal. `ended` hears
    /// whether a phone enrolled before the time was up; not after `withdrawFaceUnlock`.
    func offerFaceUnlock(password: String, for time: TimeInterval = Server.enrolmentTime, ended: @escaping (Bool) -> Void) {
        withdrawFaceUnlock()
        let offer = faceUnlock.offerEnrolment(password: password)
        enrolmentEnded = ended
        let end = DispatchWorkItem { [weak self] in self?.endEnrolment(enrolled: false) }
        enrolmentEnds = end
        DispatchQueue.main.asyncAfter(deadline: .now() + time, execute: end)
        clients.values.filter(\.authed).forEach { send($0, Wire.enrolment(offer, mac: Self.macName)) }
    }

    func withdrawFaceUnlock() {
        enrolmentEnded = nil
        endEnrolment(enrolled: false)
    }

    func removeFaceUnlock() {
        faceUnlock.remove()
        clients.values.filter(\.authed).forEach { send($0, lockState(for: $0)) }
    }

    private func endEnrolment(enrolled: Bool) {
        guard faceUnlock.offer != nil || enrolmentEnds != nil else { return }
        enrolmentEnds?.cancel()
        enrolmentEnds = nil
        faceUnlock.withdraw()
        let message = enrolled ? Wire.enrolled(true) : Wire.enrolment(nil, mac: "")
        clients.values.filter(\.authed).forEach { send($0, message) }
        enrolmentEnded?(enrolled)
        enrolmentEnded = nil
    }

    private static var macName: String { Host.current().localizedName ?? "Mac" }

    /// What a client hears about the lock. A locked Mac with a phone enrolled gives each connection its
    /// own challenge, and a new one every time it says so.
    private func lockState(for client: Client) -> String {
        guard lock.isLocked, let key = faceUnlock.key else {
            client.challenge = nil
            return Wire.lock(lock.isLocked)
        }
        let challenge = Passkey.challenge()
        client.challenge = challenge
        return Wire.lock(true, passkey: (key, challenge))
    }

    /// Types `password` into the lock screen. A refusal goes to the page, followed by the state of the lock,
    /// which carries the next challenge for the passkey.
    private func unlock(with password: String, sealed: Bool, for client: Client) {
        if viewer === client { screen.followText(true) } // the view shows the field the password goes into
        if sealed { typesSealedPassword = true }
        lock.unlock(with: password, typing: input) { [weak self, weak client] failure in
            guard let self else { return }
            // A password the Mac refuses again and again is no longer its password: the passkey's is dropped.
            if sealed {
                self.typesSealedPassword = false
                if failure == .password { self.faceUnlock.refused() }
            }
            guard let client else { return }
            self.send(client, Wire.unlockFailed(failure))
            if sealed { self.send(client, self.lockState(for: client)) }
        }
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
        // Without Nagle's algorithm: a frame smaller than a segment must not wait for the acknowledgement of the one before.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let wsParameters = NWParameters(tls: nil, tcp: tcp)
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
            if ScreenView.statsOn { FileHandle.standardError.write(Data("http \(requestLine)\n".utf8)) }
            let parts = requestLine.split(separator: " ")
            let path = parts.count > 1 ? String(parts[1].split(separator: "?").first ?? "") : ""

            var status = "404 Not Found", type = "text/plain; charset=utf-8", body = Data("Not found".utf8)
            if parts.first == "GET", let file = Web.file(path == "/" ? "index.html" : String(path.dropFirst())) {
                (status, type, body) = ("200 OK", file.type, file.body)
            }
            let head = [
                "HTTP/1.1 \(status)",
                "Content-Type: \(type)",
                "Content-Length: \(body.count)",
                "Connection: close",
                "Cache-Control: no-cache",
                "X-Content-Type-Options: nosniff",
                "Referrer-Policy: no-referrer",
                // Styles and scripts are files of the page only. Scripts set styles through the CSSOM, which this allows.
                "Content-Security-Policy: default-src 'none'; style-src 'self'; script-src 'self'; "
                    + "connect-src 'self' ws: wss:; img-src 'self' data:; frame-ancestors 'none'",
            ].joined(separator: "\r\n") + "\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
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
                  let data, let command = try? Wire.command(from: data) else {
                client.connection.cancel()
                return
            }
            if client.authed {
                self.handle(command, from: client)
            } else if case .auth(let candidate) = command, Token.matches(candidate, self.token) {
                self.lock.refresh()
                client.authed = true
                self.settle(client.connection)
                self.send(client, Wire.accepted(accessibility: AXIsProcessTrusted(), page: Web.version))
                self.send(client, self.lockState(for: client))
                if let offer = self.faceUnlock.offer { self.send(client, Wire.enrolment(offer, mac: Self.macName)) }
            } else {
                self.send(client, Wire.denied) { client.connection.cancel() }
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

    /// What a person at the Mac would do with its keyboard or mouse, and the wish to see its screen.
    /// The media keys are not among them: pausing the music leaves a dark display dark.
    private static func isActivity(_ command: Wire.Command) -> Bool {
        switch command {
        case .move, .scroll, .click, .button, .text, .key, .focus, .display, .unlock, .unlockWithPasskey: true
        case .view(let request): request != nil
        case .auth, .scrollEnded, .media, .shown, .apps, .displays, .enrol, .ignored: false
        }
    }

    private func handle(_ command: Wire.Command, from client: Client) {
        if Self.isActivity(command) { UserActivity.declare() }
        switch command {
        case .move(let dx, let dy, let sequence):
            input.move(dx: dx, dy: dy)
            // The view follows at once instead of waiting for the screen to show the move.
            if viewer === client {
                screen.followText(false)
                screen.pointerMoved(applied: sequence)
            }
        case .scroll(let dx, let dy):
            if viewer === client { screen.followText(false) } // scrolling moves the text away from where it was
            input.scroll(dx: dx, dy: dy)
        case .scrollEnded: input.endScroll()
        case .click(let button, let mods):
            if viewer === client { screen.followText(false) } // the view shows where the click lands
            input.click(button, mods: mods)
        case .button(let button, let down, let mods):
            if viewer === client { screen.followText(false) }
            input.button(button, down: down, mods: mods)
        case .text(let text):
            input.type(text)
            if viewer === client { screen.followText(true) }
        case .key(let key, let mods, let count):
            input.key(key, mods: mods, count: count)
            // Escape and shortcuts act on the app, not on the text, so the view stays where the user looks.
            if viewer === client, key != "escape", !mods.contains("cmd") { screen.followText(true) }
        case .media(let key): input.media(key)
        case .view(let request): view(request, for: client)
        case .shown(let number): if viewer === client { screen.frameShown(number) }
        case .apps:
            apps.list { [weak self, weak client] list in
                guard let self, let client else { return }
                self.send(client, Wire.apps(list))
                // The icons follow the list, so the names show without waiting for the pictures.
                let missing = list.map(\.icon).filter { client.icons.insert($0).inserted }
                self.apps.pictures(of: missing) { [weak self, weak client] name, png in
                    guard let self, let client else { return }
                    self.send(client, Wire.icon(name, png: png))
                }
            }
        case .focus(let pid, let window):
            apps.focus(pid: pid, window: window) { [weak self, weak client] frame in
                // The live view is cut around the pointer: to show the window, the pointer goes to it.
                guard let self, let client, self.viewer === client, self.input.move(into: frame) else { return }
                self.screen.followText(false)
                self.screen.pointerMoved()
            }
        case .displays:
            client.watchesDisplays = true
            send(client, Wire.displays(Displays.list()))
        case .display(let id):
            guard let target = displays.jump(to: id, from: Pointer.location, among: Displays.list()), input.move(to: target),
                  viewer === client else { return }
            screen.followText(false)
            screen.pointerMoved()
        case .unlock(let password):
            // The page asked for a Mac that is open by now: it missed the news.
            guard lock.isLocked else { return send(client, Wire.lock(false)) }
            unlock(with: password, sealed: false, for: client)
        case .unlockWithPasskey(let answer, let secret):
            guard lock.isLocked else { return send(client, Wire.lock(false)) }
            // The challenge counts once, whatever comes of it.
            let challenge = client.challenge
            client.challenge = nil
            guard let challenge, let password = faceUnlock.password(for: answer, challenge: challenge, secret: secret) else {
                send(client, Wire.passkeyRefused)
                return send(client, lockState(for: client))
            }
            unlock(with: password, sealed: true, for: client)
        case .enrol(let id, let publicKey, let authenticator, let clientData, let secret):
            // Only on a Mac that is open, where its user started the offer from the menu.
            guard !lock.isLocked, faceUnlock.offer != nil,
                  faceUnlock.enrol(id: id, publicKey: publicKey, authenticator: authenticator, client: clientData, secret: secret) else {
                return send(client, Wire.enrolled(false))
            }
            endEnrolment(enrolled: true)
        case .auth, .ignored: break
        }
    }

    /// Switches the live view on (or resizes it) for one client; the most recent requester wins.
    private func view(_ request: ScreenView.Request?, for client: Client) {
        guard let request else {
            if viewer === client { stopView() }
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            return send(client, Wire.viewRefused)
        }
        if viewer !== client { stopView() }
        viewer = client
        screen.locked = lock.isLocked
        screen.update(request)
    }

    private func stopView() {
        viewer = nil
        screen.update(nil)
    }
}

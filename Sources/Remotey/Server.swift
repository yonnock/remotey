import AppKit
import Network

/// What the server asks of the live view: `ScreenView` in the agent, a stand-in in the tests.
protocol LiveScreen: AnyObject {
    var cameForward: ((CGRect) -> Void)? { get set }
    var locked: Bool { get set }
    func update(_ request: ScreenView.Request?)
    func frameShown(_ number: UInt32)
    func pointerMoved()
    func move(_ sequence: UInt32?, post: () -> Void)
    func followText(_ on: Bool)
    func keyFrame()
    func wake()
}

extension ScreenView: LiveScreen {}

/// Two loopback-only listeners: plain HTTP for the web UI on `port` and a WebSocket for input on the port after it,
/// which the page derives from its own. Nothing is reachable from the network directly; `tailscale serve` puts
/// TLS in front of both.
final class Server {
    /// Whether the ports are open. A listener that cannot bind does not throw: it says so later, by its state.
    enum Health: Equatable {
        case starting
        case listening
        /// Why not, in words for the menu. The server tries again, after a wait that grows with each failure.
        case failed(String)
    }

    /// How long things wait. The tests make them short.
    struct Timing {
        /// A phone that sent nothing for this long is gone: iOS froze the page, or the radio dropped and the socket
        /// stays half open. Its connection is closed, which releases and stops everything as a close does. The page
        /// sends `ping` every 5 s while it is visible.
        var silence: TimeInterval = 15
        /// The buttons a silent phone holds are let go after this long, before the connection is given up.
        var release: TimeInterval = 10
        /// Between tries to open the ports.
        var retry = Backoff(first: 1, longest: 60)
        /// The phone may ask for a key frame this often at most.
        var keyFrames: TimeInterval = 1
        /// How often the permissions are read again while a phone is connected, for the `mac` message.
        /// Not at all while none is.
        var permissions: TimeInterval = 2
    }

    /// One connected phone, for the Mac's list of who is connected.
    struct Session: Equatable, Identifiable {
        let id: Int
        /// Nil: the old shared token.
        let device: Device.ID?
        /// The device's name; nil with the old token.
        let name: String?
        let since: Date
        /// It has the live view.
        let watches: Bool
        /// The page runs from the Home Screen.
        let standalone: Bool
    }

    /// What became of the pairing offer.
    enum PairingState: Equatable {
        case open(Pairing.Offer)
        case paired(Device)
        /// Too many wrong codes.
        case tries
        case expired
        case closed
    }

    /// Who is allowed now: `paused` and `token` follow the switches, `ax` and `screen` the permissions.
    private struct MacState: Equatable {
        var accessibility: Bool
        var screen: Bool
        var paused: Bool
    }

    private(set) var health = Health.starting {
        didSet { if health != oldValue { healthChanged?(health) } }
    }
    /// Hears every change of `health`, on the main queue.
    var healthChanged: ((Health) -> Void)?
    /// `REMOTEY_PORT` moves both, so a development build can run beside the installed app.
    static let port: UInt16 = ProcessInfo.processInfo.environment["REMOTEY_PORT"].flatMap(UInt16.init)
        .flatMap { $0 < .max ? $0 : nil } ?? 47800

    /// The old shared token. Replacing it drops the phones that use it, not the paired devices.
    var token: String { didSet { drop(denied: .token) { $0.device == nil } } }
    /// The Tailscale login of the Mac's owner (`Tailscale.Status.loginName`). A request through `tailscale serve`
    /// from any other person is refused. Nil while it is not known: then nobody is refused for it.
    var owner: String?
    private let store: Devices
    private let pairing: Pairing
    private var tickets: Tickets
    private var pairingEnds: DispatchWorkItem?
    private let now: () -> Date
    private let permissions: () -> (accessibility: Bool, screen: Bool)
    private var mac: MacState?
    private var lastPermissions = -TimeInterval.infinity
    private var nextSession = 1
    private var lastSessions: [Session] = []
    /// Hears every change of `sessions`, on the main queue.
    var sessionsChanged: (([Session]) -> Void)?
    /// Hears every change of the devices and of the two switches, on the main queue.
    var devicesChanged: (() -> Void)?
    /// Hears what becomes of the pairing offer, on the main queue.
    var pairingChanged: ((PairingState) -> Void)?
    /// Hears the first pointer move of each session, with its device (nil: the old token), on the main queue.
    /// The setup assistant waits on it for the phone it just paired; `hasMoved` is once per Mac.
    var firstMove: ((Device.ID?) -> Void)?
    private let input: Input
    private let apps = Apps()
    private let lock: LockScreen
    private let faceUnlock: FaceUnlock
    /// A password from the passkey is on its way into the lock screen, and what it is sealed under once
    /// the Mac takes it.
    private var typesSealedPassword = false
    private var rotation: FaceUnlock.Rotation?
    private var enrolmentEnds: DispatchWorkItem?
    private var enrolmentEnded: ((Bool) -> Void)?
    private var displays = Displays()
    private var displaysChanged: NSObjectProtocol?
    private var listeners: [NWListener] = []
    /// The listeners that are ready, of `listeners`.
    private var ready: Set<ObjectIdentifier> = []
    private var timing: Timing
    private var nextTry: DispatchWorkItem?
    private var heartbeat: DispatchSourceTimer?
    private var clients: [ObjectIdentifier: Client] = [:]
    /// The client whose two-finger scroll is under way: `Input` has one, whoever scrolls.
    private var scroller: ObjectIdentifier?
    private var lastKeyFrame = -TimeInterval.infinity
    private let declareActivity: () -> Void
    private let makeScreen: (@escaping (LiveUpdate) -> Void, @escaping (Pointer.Picture) -> Bool) -> LiveScreen
    private lazy var screen: LiveScreen = {
        let screen = makeScreen({ [weak self] update in
            let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
            let context = NWConnection.ContentContext(identifier: "frame", metadata: [metadata])
            self?.viewer?.connection.send(content: update.data, contentContext: context, completion: .idempotent)
        }, { [weak self] picture in
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
        /// The page asked for the displays on this connection, so it hears when they change: it shows them in
        /// its picker, and stops the pointer it draws at their edges.
        var watchesDisplays = false
        /// What the phone's passkey has to sign to unlock the Mac from this connection, once, and the salt
        /// of the secret it seals the password under after that.
        var ask: FaceUnlock.Ask?
        /// When this connection last sent anything. Any message counts.
        var heard = ProcessInfo.processInfo.systemUptime
        /// The mouse buttons this connection pressed and holds, by raw value. Only these are let go when it leaves:
        /// another phone's drag goes on.
        var held: Set<UInt32> = []
        /// Set once it is authenticated. Nil with the old token.
        var device: Device.ID?
        var session = 0
        var since = Date()
        var standalone = false
        var moved = false
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

    /// `permissions` reads Accessibility and Screen Recording without asking; the live view starts only with the
    /// second. `screen` makes the live view; `activity` tells the Mac its user is active (`UserActivity`).
    /// `devices` keeps the paired phones and the switches.
    init(token: String, input: Input, port: UInt16 = Server.port, pendingTimeout: TimeInterval = 5,
         lock: LockScreen = LockScreen(), faceUnlock: FaceUnlock? = nil, devices: Devices? = nil,
         timing: Timing = Timing(), now: @escaping () -> Date = Date.init,
         permissions: @escaping () -> (accessibility: Bool, screen: Bool) = Server.permissions,
         activity: @escaping () -> Void = UserActivity.declare,
         screen: ((@escaping (LiveUpdate) -> Void, @escaping (Pointer.Picture) -> Bool) -> LiveScreen)? = nil) {
        self.token = token
        self.input = input
        self.ports = (port, port + 1)
        self.pendingTimeout = pendingTimeout
        self.timing = timing
        self.now = now
        self.permissions = permissions
        self.store = devices ?? Devices(file: Devices.file(port: port), now: now)
        self.pairing = Pairing(now: now)
        self.tickets = Tickets(now: now)
        self.declareActivity = activity
        self.makeScreen = screen ?? { ScreenView(update: $0, cursor: $1) }
        self.lock = lock
        self.faceUnlock = faceUnlock ?? FaceUnlock(file: FaceUnlock.file(port: port))
        lock.changed = { [weak self] locked in
            guard let self else { return }
            // On the lock screen the view shows the password field; back on the desktop it shows the pointer again.
            if !locked, self.viewer != nil { self.screen.followText(false) }
            if self.viewer != nil { self.screen.locked = locked }
            // The Mac took the password that was sealed for the passkey.
            if !locked, self.typesSealedPassword { self.faceUnlock.opened(rotating: self.rotation) }
            self.typesSealedPassword = false
            self.rotation = nil
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

    /// Read the way the setup assistant reads them, so a grant counts without a restart. Nothing is asked here:
    /// the assistant has the keys that ask.
    static func permissions() -> (accessibility: Bool, screen: Bool) {
        (Permissions.accessibility, Permissions.screenRecording.granted)
    }

    func stop() {
        pairingEnds?.cancel()
        pairingEnds = nil
        pairing.close()
        nextTry?.cancel()
        nextTry = nil
        heartbeat?.cancel()
        heartbeat = nil
        listeners.forEach { $0.cancel() }
        listeners = []
        ready = []
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
            client.ask = nil
            return Wire.lock(lock.isLocked)
        }
        let ask = faceUnlock.ask()
        client.ask = ask
        return Wire.lock(true, passkey: (key, ask))
    }

    /// Types `password` into the lock screen. A refusal goes to the page, followed by the state of the lock,
    /// which carries the next challenge for the passkey.
    private func unlock(with password: String, sealed: Bool, rotation: FaceUnlock.Rotation? = nil, for client: Client) {
        if viewer === client { screen.followText(true) } // the view shows the field the password goes into
        if sealed {
            typesSealedPassword = true
            self.rotation = rotation
        }
        lock.unlock(with: password, typing: input) { [weak self, weak client] failure in
            guard let self else { return }
            // A password the Mac refuses again and again is no longer its password: the passkey's is dropped.
            if sealed {
                self.typesSealedPassword = false
                self.rotation = nil // a password the Mac refused is not sealed anew
                if failure == .password { self.faceUnlock.refused() }
            }
            guard let client else { return }
            self.send(client, Wire.unlockFailed(failure))
            if sealed { self.send(client, self.lockState(for: client)) }
        }
    }

    // MARK: Devices

    /// The paired phones, oldest first.
    var devices: [Device] { store.all }
    /// For the setup assistant: a phone is paired.
    var isPaired: Bool { !store.all.isEmpty }
    /// For the setup assistant: a phone moved the pointer, once, on this Mac.
    var hasMoved: Bool { store.moved }

    func rename(_ id: Device.ID, to name: String) throws {
        try store.rename(id, to: name)
        devicesDidChange()
    }

    /// The device can no longer connect, and its sessions end now.
    func revoke(_ id: Device.ID) throws {
        try store.revoke(id)
        tickets.revoke(id)
        devicesDidChange()
    }

    func revokeAllDevices() throws {
        try store.revokeAll()
        tickets.revoke()
        devicesDidChange()
    }

    /// Whether the old shared token still opens the socket and `POST /pair`. On for a Mac that had no
    /// devices file yet; switched off, it drops the phones that use it.
    var acceptsToken: Bool { store.acceptsToken }

    func setAcceptsToken(_ on: Bool) throws {
        try store.setAcceptsToken(on)
        if !on { drop(denied: .token) { $0.device == nil } }
        devicesDidChange()
    }

    /// Remote control stopped at the Mac: no input, no live view, and every phone stays paired and connected.
    var paused: Bool { store.paused }

    func setPaused(_ on: Bool) throws {
        let was = store.paused
        try store.setPaused(on)
        if on, !was {
            for client in clients.values where client.authed { release(client) }
            if let viewer {
                send(viewer, Wire.viewPaused)
                stopView()
            }
        }
        devicesDidChange()
    }

    /// Ends what a removed device has open, and tells the Mac.
    private func devicesDidChange() {
        let known = Set(store.all.map(\.id))
        drop(denied: .revoked) { $0.device.map { !known.contains($0) } ?? false }
        pushMac()
        sessionsDidChange()
        devicesChanged?()
    }

    /// Closes the authenticated connections `which` picks, after telling each why.
    private func drop(denied why: Wire.Denial, _ which: (Client) -> Bool) {
        for client in clients.values where client.authed && which(client) {
            send(client, Wire.denied(why)) { client.connection.cancel() }
        }
    }

    // MARK: Pairing

    /// The codes of the open offer; nil while none is.
    var pairingOffer: Pairing.Offer? {
        pairing.expire()
        return pairing.offer
    }

    /// Opens an offer for at most five minutes, in place of any before it. The Mac shows its codes while it is open.
    @discardableResult
    func openPairing(for time: TimeInterval = Pairing.time) -> Pairing.Offer {
        let offer = pairing.open(for: time)
        pairingEnds?.cancel()
        let end = DispatchWorkItem { [weak self] in
            guard let self, self.pairing.offer == offer else { return }
            self.pairing.close()
            self.pairingEnds = nil
            self.pairingChanged?(.expired)
        }
        pairingEnds = end
        DispatchQueue.main.asyncAfter(deadline: .now() + offer.ends.timeIntervalSince(now()), execute: end)
        pairingChanged?(.open(offer))
        return offer
    }

    /// The Mac's pairing window closed: its codes are gone.
    func closePairing() {
        pairingEnds?.cancel()
        pairingEnds = nil
        let wasOpen = pairing.offer != nil
        pairing.close()
        if wasOpen { pairingChanged?(.closed) }
    }

    // MARK: Sessions

    /// Who is connected, longest first.
    var sessions: [Session] {
        let names = Dictionary(store.all.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return clients.values.filter(\.authed).sorted { $0.session < $1.session }.map {
            Session(id: $0.session, device: $0.device, name: $0.device.flatMap { names[$0] }, since: $0.since,
                    watches: viewer === $0, standalone: $0.standalone)
        }
    }

    /// Closes the connection. The page connects again by itself; to keep a phone out, revoke it or pause.
    func end(_ session: Session.ID) {
        clients.values.first { $0.authed && $0.session == session }?.connection.cancel()
    }

    private func sessionsDidChange() {
        let now = sessions
        guard now != lastSessions else { return }
        lastSessions = now
        sessionsChanged?(now)
    }

    // MARK: What the Mac allows

    private func macState() -> MacState {
        let read = permissions()
        lastPermissions = ProcessInfo.processInfo.systemUptime
        return MacState(accessibility: read.accessibility, screen: read.screen, paused: store.paused)
    }

    /// Tells every phone when a permission or the pause changed since it last heard.
    private func pushMac() {
        guard clients.values.contains(where: \.authed) else {
            mac = nil
            return
        }
        let next = macState()
        guard next != mac else { return }
        mac = next
        let message = Wire.mac(accessibility: next.accessibility, screen: next.screen, paused: next.paused)
        clients.values.filter(\.authed).forEach { send($0, message) }
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

    /// Opens the ports. `health` says when they are open, or why not; the server tries again until they are, or
    /// until `stop`. Throws only for parameters Network refuses, which no later try changes.
    func start() throws {
        try listen()
        let heartbeat = DispatchSource.makeTimerSource(queue: .main)
        let every = max(0.02, min(timing.silence, timing.release) / 10)
        heartbeat.schedule(deadline: .now() + every, repeating: every)
        heartbeat.setEventHandler { [weak self] in self?.checkSilence() }
        heartbeat.resume()
        self.heartbeat = heartbeat
    }

    private func listen() throws {
        nextTry = nil
        health = .starting
        let http = try listener(port: ports.http, parameters: .tcp)
        http.newConnectionHandler = { [weak self] in self?.serveHTTP($0) }

        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        wsOptions.maximumMessageSize = 64 * 1024
        // A page in the Mac's browser may open sockets to the loopback port. The handshake names the page.
        wsOptions.setClientRequestHandler(.main) { [weak self] _, headers in
            let fields = HeaderFields(headers)
            guard Origins.allows(fields), TailnetIdentity.allows(fields, owner: self?.owner) else {
                if ScreenView.statsOn {
                    let login = fields["Tailscale-User-Login"] ?? "-"
                    FileHandle.standardError.write(Data("ws refused: host \(fields["Host"] ?? "-"), origin \(fields["Origin"] ?? "-"), login \(login)\n".utf8))
                }
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
        // Without Nagle's algorithm: a frame smaller than a segment must not wait for the acknowledgement of the one before.
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let wsParameters = NWParameters(tls: nil, tcp: tcp)
        wsParameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let ws = try listener(port: ports.ws, parameters: wsParameters)
        ws.newConnectionHandler = { [weak self] in self?.serveWebSocket($0) }

        listeners = [http, ws]
        ready = []
        for (listener, port) in [(http, ports.http), (ws, ports.ws)] {
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener else { return }
                self.listener(listener, on: port, changed: state)
            }
            listener.start(queue: .main)
        }
    }

    private func listener(_ listener: NWListener, on port: UInt16, changed state: NWListener.State) {
        // A listener given up already, of an earlier try.
        guard listeners.contains(where: { $0 === listener }) else { return }
        switch state {
        case .ready:
            ready.insert(ObjectIdentifier(listener))
            if ready.count == listeners.count {
                timing.retry.reset()
                health = .listening
            }
        case .failed(let error), .waiting(let error):
            let reason = if case .posix(.EADDRINUSE) = error { "Port \(port) ist belegt" } else { "Port \(port): \(error)" }
            failed(reason)
        default: break
        }
    }

    /// Both listeners go, and a new pair tries again later.
    private func failed(_ reason: String) {
        listeners.forEach { $0.cancel() }
        listeners = []
        ready = []
        let wait = timing.retry.failed()
        health = .failed(reason)
        if ScreenView.statsOn { FileHandle.standardError.write(Data("listen failed: \(reason), next try in \(wait) s\n".utf8)) }
        let next = DispatchWorkItem { [weak self] in
            guard let self else { return }
            do { try self.listen() } catch { self.failed("\(error)") }
        }
        nextTry = next
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: next)
    }

    /// Network sets the address to be reused on a listener either way: measured on macOS 27, a port another
    /// listener holds fails with this as without it (EADDRINUSE, also against another process with SO_REUSEADDR
    /// or SO_REUSEPORT), and one that only has connections in TIME_WAIT opens without it as well.
    private func listener(port: UInt16, parameters: NWParameters) throws -> NWListener {
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        parameters.allowLocalEndpointReuse = true
        return try NWListener(using: parameters)
    }

    // MARK: Heartbeat

    /// A phone that went silent lets go of its buttons, and after a while longer its connection.
    private func checkSilence() {
        let now = ProcessInfo.processInfo.systemUptime
        // A permission granted while a phone is connected shows on it within this time.
        if now - lastPermissions >= timing.permissions { pushMac() }
        for client in clients.values where client.authed {
            let quiet = now - client.heard
            if quiet >= timing.silence {
                if ScreenView.statsOn { FileHandle.standardError.write(Data("silent for \(Int(quiet)) s: closed\n".utf8)) }
                client.connection.cancel()
            } else if quiet >= timing.release {
                release(client)
            }
        }
    }

    /// Lets go of what this client holds: its buttons, and the scroll it began.
    private func release(_ client: Client) {
        for raw in client.held { if let button = CGMouseButton(rawValue: raw) { input.button(button, down: false) } }
        client.held = []
        if scroller == ObjectIdentifier(client) {
            scroller = nil
            input.endScroll()
        }
    }

    private func heldByAnother(_ button: CGMouseButton, than client: Client) -> Bool {
        clients.values.contains { $0 !== client && $0.held.contains(button.rawValue) }
    }

    // MARK: HTTP

    private func serveHTTP(_ connection: NWConnection) {
        admit(connection)
        connection.start(queue: .main)
        read(connection, Data())
    }

    /// Reads until the request is whole, within the bounds of `HTTPRequest`. A request that takes longer than
    /// the pending connections may wait is cut off with them.
    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            let answer: HTTPResponse
            switch HTTPRequest.parse(buffer) {
            case .incomplete:
                guard data != nil, !complete, error == nil else {
                    self.settle(connection)
                    return connection.cancel()
                }
                return self.read(connection, buffer)
            case .refused(let status):
                answer = HTTPResponse(status: status, body: Data(status.utf8))
            case .complete(let request):
                answer = self.answer(request)
            }
            self.settle(connection)
            self.respond(answer, on: connection)
        }
    }

    private func answer(_ request: HTTPRequest) -> HTTPResponse {
        let fields = request.fields
        if ScreenView.statsOn {
            let login = fields["Tailscale-User-Login"].map { ", login \($0)" } ?? ""
            FileHandle.standardError.write(Data("http \(request.method) \(request.path) host \(fields["Host"] ?? "-")\(login)\n".utf8))
        }
        // A name that is not the page's own leads here by DNS rebinding: a page that would read the page's files.
        // Through `tailscale serve`, a person other than the Mac's owner, or the internet by Funnel.
        guard Origins.allows(host: fields["Host"]), TailnetIdentity.allows(fields, owner: owner) else {
            return HTTPResponse(status: "403 Forbidden", body: Data("Forbidden".utf8))
        }
        switch (request.method, request.path) {
        case ("POST", "/pair"), ("POST", "/session"):
            // A page in the Mac's browser names itself. It cannot send JSON either without asking first
            // (a CORS preflight), which the agent never answers, so `Origin: null` is no way in.
            guard Origins.allowsPost(origin: fields["Origin"]), Self.isJSON(fields["Content-Type"]) else {
                return .json("403 Forbidden", ["ok": false, "why": "origin"])
            }
            return request.path == "/pair" ? pair(request) : session(request)
        case ("GET", let path):
            guard let file = Web.file(path == "/" ? "index.html" : String(path.dropFirst())) else { break }
            return HTTPResponse(status: "200 OK", type: file.type, body: file.body)
        default: break
        }
        return HTTPResponse(status: "404 Not Found", body: Data("Not found".utf8))
    }

    private static func isJSON(_ type: String?) -> Bool {
        type?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json"
    }

    private func respond(_ answer: HTTPResponse, on connection: NWConnection) {
        // The page's files may be cached and checked again; the answers of the two routes are never kept.
        let cache = answer.fields.contains { $0.hasPrefix("Cache-Control:") } ? [] : ["Cache-Control: no-cache"]
        let head = ([
            "HTTP/1.1 \(answer.status)",
            "Content-Type: \(answer.type)",
            "Content-Length: \(answer.body.count)",
            "Connection: close",
            "X-Content-Type-Options: nosniff",
            "Referrer-Policy: no-referrer",
            // Styles and scripts are files of the page only. Scripts set styles through the CSSOM, which this allows.
            "Content-Security-Policy: default-src 'none'; style-src 'self'; script-src 'self'; "
                + "connect-src 'self' ws: wss:; img-src 'self' data:; frame-ancestors 'none'",
        ] + cache + answer.fields).joined(separator: "\r\n") + "\r\n\r\n"
        connection.send(content: Data(head.utf8) + answer.body, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Pairing over HTTP

    /// The cookie that holds a device's key. Named by port, as the files are: cookies do not tell ports apart,
    /// and a development agent on 127.0.0.1 must not overwrite the installed one's.
    var cookieName: String { ports.http == 47800 ? "remotey-device" : "remotey-device-\(ports.http)" }

    /// 400 days, the most Chromium keeps a cookie; every session renews it. A phone that is lost is revoked at
    /// the Mac, which is what makes its key worthless, not the cookie's end.
    static let cookieLife = 400 * 24 * 3600

    /// Scripts cannot read it (`HttpOnly`); only the page's own requests carry it (`SameSite=Strict`, no
    /// `Domain`); it travels only over TLS (`Secure`) except on loopback, where the development page is plain
    /// HTTP and has no TLS to ask for.
    private func cookie(_ key: String, host: String?) -> String {
        let secure = host.map(Origins.isLoopback(host:)) == true ? "" : "; Secure"
        return "Set-Cookie: \(cookieName)=\(key); Path=/; Max-Age=\(Self.cookieLife); HttpOnly; SameSite=Strict\(secure)"
    }

    /// `{"code":…}` with either code of the open offer, or `{"token":…}` with the old shared token: a phone
    /// paired the old way becomes a device without scanning again.
    private func pair(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = request.json else { return .json("400 Bad Request", ["ok": false, "why": "body"]) }
        if let code = body["code"] {
            switch pairing.take(code) {
            case nil:
                pairingEnds?.cancel()
                pairingEnds = nil
            case .code: return .json("403 Forbidden", ["ok": false, "why": "code"])
            case .closed: return .json("403 Forbidden", ["ok": false, "why": "closed"])
            case .tries:
                // The first refusal for tries ends the offer the Mac shows; later ones only repeat it.
                if pairingEnds != nil {
                    pairingEnds?.cancel()
                    pairingEnds = nil
                    pairingChanged?(.tries)
                }
                return .json("429 Too Many Requests", ["ok": false, "why": "tries"])
            }
        } else if let token = body["token"] {
            guard store.acceptsToken, Token.matches(token, self.token) else {
                return .json("403 Forbidden", ["ok": false, "why": "token"])
            }
        } else {
            return .json("400 Bad Request", ["ok": false, "why": "body"])
        }
        let fields = request.fields
        guard let (device, key) = try? store.add(name: Self.deviceName(userAgent: fields["User-Agent"]),
                                                  login: TailnetIdentity.login(fields)) else {
            if body["code"] != nil { pairingChanged?(.closed) }
            return .json("500 Internal Server Error", ["ok": false, "why": "save"])
        }
        if body["code"] != nil { pairingChanged?(.paired(device)) }
        devicesDidChange()
        return .json("200 OK", ["ok": true, "device": ["id": device.id, "name": device.name]],
                     fields: [cookie(key, host: fields["Host"])])
    }

    /// Trades the device's cookie for a ticket that opens the socket once, and renews the cookie.
    private func session(_ request: HTTPRequest) -> HTTPResponse {
        guard let (device, key) = request.cookies(cookieName).prefix(4).lazy
            .compactMap({ key in self.store.device(key: key).map { ($0, key) } }).first else {
            return .json("401 Unauthorized", ["why": "unpaired"])
        }
        store.saw(device.id)
        return .json("200 OK", ["ticket": tickets.issue(for: device.id)], fields: [cookie(key, host: request.fields["Host"])])
    }

    /// What the Mac lists a new device as, until it is renamed. iPadOS says it is a Mac.
    static func deviceName(userAgent: String?) -> String {
        let agent = userAgent ?? ""
        if agent.contains("iPhone") { return "iPhone" }
        if agent.contains("iPad") { return "iPad" }
        if agent.contains("Android") { return "Android" }
        if agent.contains("Macintosh") { return "iPad oder Mac" }
        return "Browser"
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
                // Only what this phone holds: another one may be in the middle of a drag.
                if client.authed { self.release(client) }
                if self.viewer === client { self.stopView() }
                if let device = client.device { self.store.saw(device) }
                self.sessionsDidChange()
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
            client.heard = ProcessInfo.processInfo.systemUptime
            if client.authed {
                // A field the agent does not know how to read costs this message, not the connection.
                if case .ignored = command, ScreenView.statsOn {
                    FileHandle.standardError.write(Data("ignored: \(String(decoding: data.prefix(200), as: UTF8.self))\n".utf8))
                }
                self.handle(command, from: client)
            } else if case .auth(let credential) = command {
                switch self.authenticate(credential) {
                case .success(let device): self.accept(client, device: device, credential: credential)
                case .failure(let why):
                    self.send(client, Wire.denied(why)) { client.connection.cancel() }
                    return
                }
            } else {
                self.send(client, Wire.denied(.token)) { client.connection.cancel() }
                return
            }
            self.receive(client)
        }
    }

    /// The device a ticket was issued to, or nil for the old token. A ticket counts once, whatever comes of it.
    private func authenticate(_ credential: Wire.Credential) -> Result<Device?, Wire.Denial> {
        switch credential {
        case .ticket(let ticket, _):
            switch tickets.take(ticket) {
            case .device(let id):
                guard let device = store.all.first(where: { $0.id == id }) else { return .failure(.revoked) }
                return .success(device)
            case .revoked: return .failure(.revoked)
            case .unknown: return .failure(.ticket)
            }
        case .token(let token):
            guard store.acceptsToken, Token.matches(token, self.token) else { return .failure(.token) }
            return .success(nil)
        }
    }

    private func accept(_ client: Client, device: Device?, credential: Wire.Credential) {
        lock.refresh()
        // The phones connected before hear what changed since they last heard; this one hears it after `ok`.
        pushMac()
        let state = mac ?? macState()
        mac = state
        client.authed = true
        client.device = device?.id
        client.since = now()
        client.session = nextSession
        nextSession += 1
        if case .ticket(_, let standalone) = credential { client.standalone = standalone }
        settle(client.connection)
        if let device { store.saw(device.id) }
        send(client, Wire.accepted(accessibility: state.accessibility, page: Web.version, mac: Self.macName, device: device?.name))
        send(client, Wire.mac(accessibility: state.accessibility, screen: state.screen, paused: state.paused))
        send(client, lockState(for: client))
        if let offer = faceUnlock.offer { send(client, Wire.enrolment(offer, mac: Self.macName)) }
        sessionsDidChange()
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
        case .auth, .scrollEnded, .media, .shown, .apps, .displays, .enrol, .ping, .keyFrame, .ignored: false
        }
    }

    /// What acts on the Mac or shows what is on it, and so stops while remote control is paused. Lists of the
    /// displays stay: they show where the pointer may go, not what is on the screen.
    private static func isControl(_ command: Wire.Command) -> Bool {
        switch command {
        case .move, .scroll, .scrollEnded, .click, .button, .text, .key, .media, .apps, .focus, .display, .unlock,
             .unlockWithPasskey, .enrol: true
        case .view(let request): request != nil
        case .auth, .shown, .displays, .ping, .keyFrame, .ignored: false
        }
    }

    private func handle(_ command: Wire.Command, from client: Client) {
        if store.paused, Self.isControl(command) {
            if case .view(.some) = command { send(client, Wire.viewPaused) }
            return
        }
        if Self.isActivity(command) {
            declareActivity()
            // The display this wakes may have a capture again.
            if viewer === client { screen.wake() }
        }
        switch command {
        case .move(let dx, let dy, let sequence):
            if !store.moved { store.noteMoved() } // the setup's last step
            if !client.moved {
                client.moved = true
                firstMove?(client.device)
            }
            // The view follows at once instead of waiting for the screen to show the move.
            if viewer === client {
                screen.followText(false)
                screen.move(sequence) { input.move(dx: dx, dy: dy) }
            } else {
                input.move(dx: dx, dy: dy)
            }
        case .scroll(let dx, let dy):
            if viewer === client { screen.followText(false) } // scrolling moves the text away from where it was
            scroller = ObjectIdentifier(client)
            input.scroll(dx: dx, dy: dy)
        case .scrollEnded:
            scroller = nil
            input.endScroll()
        case .click(let button, let mods):
            // A button another phone holds is not this one's to click: its release would end that drag.
            guard !heldByAnother(button, than: client) else { return }
            if viewer === client { screen.followText(false) } // the view shows where the click lands
            input.click(button, mods: mods)
        case .button(let button, let down, let mods):
            guard !heldByAnother(button, than: client) else { return }
            if viewer === client { screen.followText(false) }
            if down { client.held.insert(button.rawValue) } else { client.held.remove(button.rawValue) }
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
        case .apps(let have):
            // The page kept the icons of an earlier connection: only those it lacks go out.
            if let have { client.icons = have }
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
        case .unlockWithPasskey(let answer, let secret, let next):
            guard lock.isLocked else { return send(client, Wire.lock(false)) }
            // The challenge counts once, whatever comes of it.
            let ask = client.ask
            client.ask = nil
            guard let ask, let password = faceUnlock.password(for: answer, challenge: ask.challenge, secret: secret) else {
                send(client, Wire.passkeyRefused)
                return send(client, lockState(for: client))
            }
            unlock(with: password, sealed: true,
                   rotation: faceUnlock.rotation(of: password, secret: secret, to: ask.next, next: next), for: client)
        case .enrol(let id, let publicKey, let authenticator, let clientData, let secret):
            // Only on a Mac that is open, where its user started the offer from the menu.
            guard !lock.isLocked, faceUnlock.offer != nil,
                  faceUnlock.enrol(id: id, publicKey: publicKey, authenticator: authenticator, client: clientData, secret: secret) else {
                return send(client, Wire.enrolled(false))
            }
            endEnrolment(enrolled: true)
        case .ping: send(client, Wire.pong)
        case .keyFrame:
            let now = ProcessInfo.processInfo.systemUptime
            guard viewer === client, now - lastKeyFrame >= timing.keyFrames else { return }
            lastKeyFrame = now
            screen.keyFrame()
        case .auth, .ignored: break
        }
    }

    /// Switches the live view on (or resizes it) for one client; the most recent requester wins.
    private func view(_ request: ScreenView.Request?, for client: Client) {
        guard let request else {
            if viewer === client { stopView() }
            return
        }
        guard permissions().screen else { return send(client, Wire.viewRefused) }
        if viewer !== client {
            // The phone that had the view hears that its picture stops, instead of seeing it stand still.
            if let displaced = viewer { send(displaced, Wire.viewTaken) }
            stopView()
        }
        viewer = client
        screen.locked = lock.isLocked
        screen.update(request)
        sessionsDidChange()
    }

    private func stopView() {
        viewer = nil
        screen.update(nil)
        sessionsDidChange()
    }
}

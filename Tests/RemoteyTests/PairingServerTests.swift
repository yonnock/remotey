import Network
import XCTest
@testable import Remotey

/// An answer of the agent's HTTP port.
struct Answer {
    let status: Int
    let head: [String]
    let body: [String: Any]

    func field(_ name: String) -> String? {
        head.first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }

    /// The device's key from `Set-Cookie`, and the cookie's attributes.
    var cookie: (key: String, attributes: Set<String>)? {
        guard let field = field("Set-Cookie") else { return nil }
        let parts = field.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let pair = parts.first?.split(separator: "=", maxSplits: 1), pair.count == 2 else { return nil }
        return (String(pair[1]), Set(parts.dropFirst()))
    }
}

/// One request on its own connection; the answer is everything until the agent closes it.
final class RawHTTP: @unchecked Sendable {
    private let connection: NWConnection
    private var received = Data()

    init(port: UInt16) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func send(_ request: Data) async -> Data {
        await withCheckedContinuation { done in
            connection.stateUpdateHandler = { [self] state in
                guard case .ready = state else { return }
                connection.send(content: request, completion: .idempotent)
                read { done.resume(returning: $0) }
            }
            connection.start(queue: .main)
        }
    }

    private func read(_ done: @escaping (Data) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            if let data { received.append(data) }
            guard complete || error != nil else { return read(done) }
            connection.cancel()
            done(received)
        }
    }
}

/// Pairing per device, tickets, the old token's switch, the pause, the Tailscale login and who is connected,
/// against a second agent on its own ports. Input is collected, nothing is posted; the live view is a stand-in.
@MainActor
final class PairingServerTests: XCTestCase {
    nonisolated(unsafe) private static var nextPort: UInt16 = 47980
    private let token = "test-token-test-token-test-token-test"
    private let view = #"{"t":"view","on":true,"w":390,"h":844,"zoom":1,"dpr":3,"codec":"h264","fps":60,"v":1}"#
    private var port: UInt16 = 0
    private var events: [CGEvent] = []
    private var screen = FakeScreen()
    private var server: Server!
    private var phones: [SocketPhone] = []
    private var clock = Date()
    private var allowed = (accessibility: true, screen: true)
    private var states: [Server.PairingState] = []

    private func start(timing: Server.Timing = Server.Timing()) async throws {
        port = Self.nextPort
        Self.nextPort += 2
        let input = Input { [unowned self] in events.append($0) }
        server = Server(token: token, input: input, port: port, devices: .temporary(now: { [unowned self] in clock }),
                        timing: timing, now: { [unowned self] in clock }, permissions: { [unowned self] in allowed },
                        activity: {}, screen: { [unowned self] _, _ in screen })
        server.pairingChanged = { [unowned self] in states.append($0) }
        try server.start()
        let listening = await eventually { server.health == .listening }
        XCTAssertTrue(listening, "\(server.health)")
    }

    override func tearDown() async throws {
        phones.forEach { $0.close() }
        server?.stop()
    }

    override class func tearDown() {
        Devices.removeTemporaries()
        super.tearDown()
    }

    // MARK: Helpers

    /// A request as the page's `fetch` sends it: its own origin, JSON.
    private func request(_ method: String, _ path: String, body: String? = nil, fields: [String: String] = [:],
                         page: Bool = true) async -> Answer {
        var all = page ? ["Host": "127.0.0.1:\(port)", "Origin": "http://127.0.0.1:\(port)", "Content-Type": "application/json"] : [:]
        all.merge(fields) { $1 }
        let body = body ?? ""
        var text = "\(method) \(path) HTTP/1.1\r\n"
        for (name, value) in all where !value.isEmpty { text += "\(name): \(value)\r\n" }
        text += "Content-Length: \(body.utf8.count)\r\n\r\n\(body)"
        let data = await RawHTTP(port: port).send(Data(text.utf8))
        let answer = String(decoding: data, as: UTF8.self)
        let parts = answer.components(separatedBy: "\r\n\r\n")
        let head = parts[0].components(separatedBy: "\r\n")
        let status = Int(head[0].split(separator: " ").dropFirst().first ?? "") ?? 0
        let json = (try? JSONSerialization.jsonObject(with: Data(parts.dropFirst().joined(separator: "\r\n\r\n").utf8))) as? [String: Any]
        return Answer(status: status, head: Array(head.dropFirst()), body: json ?? [:])
    }

    private func pair(_ code: String, fields: [String: String] = [:]) async -> Answer {
        await request("POST", "/pair", body: #"{"code":"\#(code)"}"#, fields: fields)
    }

    private func ticket(key: String, fields: [String: String] = [:]) async -> Answer {
        await request("POST", "/session", fields: ["Cookie": "other=1; \(server.cookieName)=\(key)"].merging(fields) { $1 })
    }

    /// A paired device's key.
    private func paired() async throws -> String {
        let answer = await pair(server.openPairing().digits)
        XCTAssertEqual(answer.status, 200)
        return try XCTUnwrap(answer.cookie?.key)
    }

    private func phone(_ first: String?, fields: [String: String] = [:]) async -> SocketPhone {
        let phone = SocketPhone(port: port + 1, fields: fields)
        phones.append(phone)
        if let first { phone.send(first) }
        _ = await eventually { !phone.messages.isEmpty || phone.closed }
        return phone
    }

    /// A phone connected with a fresh ticket of the device with this key.
    private func device(key: String, standalone: Bool = false) async throws -> SocketPhone {
        let answer = await self.ticket(key: key)
        let ticket = try XCTUnwrap(answer.body["ticket"] as? String)
        let phone = await phone(#"{"t":"auth","ticket":"\#(ticket)","standalone":\#(standalone)}"#)
        XCTAssertEqual(phone.messages.first?["t"] as? String, "ok", "\(phone.messages)")
        return phone
    }

    private func moves() -> Int { events.filter { $0.type == .mouseMoved }.count }

    private func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }

    // MARK: Pairing

    func testACodePairsOnceAndOnlyWhileTheOfferIsOpen() async throws {
        try await start()
        let closed = await pair("123456")
        XCTAssertEqual(closed.status, 403)
        XCTAssertEqual(closed.body["why"] as? String, "closed")

        let offer = server.openPairing()
        let byLink = await pair(offer.code, fields: ["User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X)"])
        XCTAssertEqual(byLink.status, 200)
        XCTAssertEqual(byLink.body["ok"] as? Bool, true)
        let device = try XCTUnwrap(byLink.body["device"] as? [String: String])
        XCTAssertEqual(device["name"], "iPhone")
        XCTAssertEqual(server.devices.map(\.id), [device["id"]])
        XCTAssertTrue(server.isPaired)
        XCTAssertEqual(states.last, .paired(server.devices[0]))
        XCTAssertEqual(byLink.field("Cache-Control"), "no-store")

        let again = await pair(offer.digits)
        XCTAssertEqual(again.status, 403, "the first use spent both codes")
        XCTAssertEqual(again.body["why"] as? String, "closed")
        XCTAssertNil(server.pairingOffer)
    }

    func testAFewWrongTriesEndTheOfferWith429() async throws {
        try await start()
        let offer = server.openPairing()
        let wrong = offer.digits == "000000" ? "000001" : "000000"
        for _ in 1..<Pairing.tries {
            let answer = await pair(wrong)
            XCTAssertEqual(answer.status, 403)
            XCTAssertEqual(answer.body["why"] as? String, "code")
        }
        let last = await pair(wrong)
        XCTAssertEqual(last.status, 429)
        let right = await pair(offer.digits)
        XCTAssertEqual(right.status, 429, "the right code comes too late")
        XCTAssertEqual(states.filter { $0 == .tries }.count, 1, "the Mac hears it once")
        XCTAssertFalse(server.isPaired)
    }

    func testAnOfferEndsByItself() async throws {
        try await start()
        let offer = server.openPairing(for: 0.2)
        let ended = await eventually { states.last == .expired }
        XCTAssertTrue(ended, "\(states)")
        // The clock of the offer is the server's: past its end, the code is gone.
        clock += 1
        let late = await pair(offer.digits)
        XCTAssertEqual(late.body["why"] as? String, "closed")
    }

    func testClosingThePairingWindowTakesTheCodes() async throws {
        try await start()
        let offer = server.openPairing()
        server.closePairing()
        XCTAssertEqual(states.last, .closed)
        let answer = await pair(offer.code)
        XCTAssertEqual(answer.body["why"] as? String, "closed")
    }

    // MARK: The cookie

    func testTheCookieIsForThePageAloneAndSecureBehindServe() async throws {
        try await start()
        let first = await pair(server.openPairing().digits)
        let local = try XCTUnwrap(first.cookie)
        XCTAssertTrue(local.attributes.isSuperset(of: ["HttpOnly", "SameSite=Strict", "Path=/", "Max-Age=\(Server.cookieLife)"]),
                      "\(local.attributes)")
        XCTAssertFalse(local.attributes.contains("Secure"), "plain HTTP on loopback has no TLS to ask for")
        XCTAssertFalse(local.attributes.contains { $0.hasPrefix("Domain") })
        let host = "mac.example.ts.net:8443"
        let second = await pair(server.openPairing().digits, fields: ["Host": host, "Origin": "https://\(host)"])
        let served = try XCTUnwrap(second.cookie)
        XCTAssertTrue(served.attributes.contains("Secure"))
        XCTAssertGreaterThanOrEqual(local.key.count, 43, "256 bits")
    }

    // MARK: Where a request comes from

    /// A page in the Mac's browser can neither guess codes nor use a cookie, and costs the offer no try.
    func testAnotherPageCannotPairOrTakeATicket() async throws {
        try await start()
        let key = try await paired()
        let offer = server.openPairing()
        let foreign = await pair(offer.digits, fields: ["Origin": "https://evil.example.com"])
        XCTAssertEqual(foreign.status, 403)
        XCTAssertEqual(foreign.body["why"] as? String, "origin")
        let rebound = await pair(offer.digits, fields: ["Host": "rebound.example.com:\(port)"])
        XCTAssertEqual(rebound.status, 403, "DNS rebinding")
        let form = await pair(offer.digits, fields: ["Content-Type": "text/plain"])
        XCTAssertEqual(form.status, 403, "what a form or a no-cors fetch sends")
        let stolen = await ticket(key: key, fields: ["Origin": "https://evil.example.com"])
        XCTAssertEqual(stolen.status, 403)
        XCTAssertNotNil(server.pairingOffer, "none of them counted as a try")
        let own = await pair(offer.digits)
        XCTAssertEqual(own.status, 200)
    }

    func testAPersonOtherThanTheOwnerIsRefusedThroughServe() async throws {
        try await start()
        server.owner = "owner@example.com"
        let offer = server.openPairing()
        let guest = await pair(offer.digits, fields: ["Tailscale-User-Login": "guest@example.com"])
        XCTAssertEqual(guest.status, 403)
        let page = await request("GET", "/", fields: ["Tailscale-User-Login": "guest@example.com"])
        XCTAssertEqual(page.status, 403)
        let funnel = await request("GET", "/", fields: ["Tailscale-Funnel-Request": "?1"])
        XCTAssertEqual(funnel.status, 403, "the internet, by Funnel")
        let guestSocket = await phone(#"{"t":"auth","token":"\#(token)"}"#, fields: ["Tailscale-User-Login": "guest@example.com"])
        // Refused at the handshake: no answer to the token, no session. (URLSession does not tell this task.)
        await pause(0.3)
        XCTAssertTrue(guestSocket.messages.isEmpty, "\(guestSocket.messages)")
        XCTAssertTrue(server.sessions.isEmpty)

        let owner = await pair(offer.digits, fields: ["Tailscale-User-Login": "owner@example.com"])
        XCTAssertEqual(owner.status, 200)
        XCTAssertEqual(server.devices.first?.login, "owner@example.com", "the label of who paired")
        let ownerSocket = await phone(#"{"t":"auth","token":"\#(token)"}"#, fields: ["Tailscale-User-Login": "owner@example.com"])
        XCTAssertEqual(ownerSocket.messages.first?["t"] as? String, "ok")
        let local = await phone(#"{"t":"auth","token":"\#(token)"}"#)
        XCTAssertEqual(local.messages.first?["t"] as? String, "ok", "without the field: on this Mac")
    }

    // MARK: Tickets

    func testACookieGivesATicketThatOpensTheSocketOnce() async throws {
        try await start()
        let none = await request("POST", "/session")
        XCTAssertEqual(none.status, 401)
        XCTAssertEqual(none.body["why"] as? String, "unpaired")
        let key = try await paired()
        let answer = await ticket(key: key)
        XCTAssertEqual(answer.status, 200)
        XCTAssertEqual(answer.cookie?.key, key, "renewed")
        let ticket = try XCTUnwrap(answer.body["ticket"] as? String)

        let phone = await phone(#"{"t":"auth","ticket":"\#(ticket)","standalone":true}"#)
        let ok = try XCTUnwrap(phone.messages.first)
        XCTAssertEqual(ok["t"] as? String, "ok")
        XCTAssertEqual(ok["device"] as? String, server.devices[0].name)
        XCTAssertEqual(ok["name"] as? String, Host.current().localizedName ?? "Mac")
        let used = await self.phone(#"{"t":"auth","ticket":"\#(ticket)"}"#)
        XCTAssertEqual(used.messages.first as NSDictionary?, ["t": "denied", "why": "ticket"])
        let closed = await eventually { used.closed }
        XCTAssertTrue(closed)

        let another = await self.ticket(key: key)
        let late = try XCTUnwrap(another.body["ticket"] as? String)
        clock += Tickets.life
        let expired = await self.phone(#"{"t":"auth","ticket":"\#(late)"}"#)
        XCTAssertEqual(expired.messages.first?["why"] as? String, "ticket")
    }

    func testARevokedDeviceIsOutAtOnce() async throws {
        try await start()
        let key = try await paired(), other = try await paired()
        let phone = try await device(key: key), bystander = try await device(key: other)
        let issued = await ticket(key: key)
        let pending = try XCTUnwrap(issued.body["ticket"] as? String)
        try server.revoke(server.devices[0].id)
        let out = await eventually { phone.closed }
        XCTAssertTrue(out)
        XCTAssertEqual(phone.heard("denied").first?["why"] as? String, "revoked")
        XCTAssertFalse(bystander.closed, "another device stays")
        let refused = await ticket(key: key)
        XCTAssertEqual(refused.status, 401)
        let stale = await self.phone(#"{"t":"auth","ticket":"\#(pending)"}"#)
        XCTAssertEqual(stale.messages.first?["why"] as? String, "revoked")

        try server.revokeAllDevices()
        let all = await eventually { bystander.closed }
        XCTAssertTrue(all)
        XCTAssertFalse(server.isPaired)
    }

    // MARK: The old token

    func testTheOldTokenWorksUntilItIsSwitchedOff() async throws {
        try await start()
        XCTAssertTrue(server.acceptsToken)
        let old = await phone(#"{"t":"auth","token":"\#(token)"}"#)
        XCTAssertEqual(old.messages.first?["t"] as? String, "ok")
        XCTAssertTrue(old.messages.first?["device"] is NSNull)
        let wrong = await phone(#"{"t":"auth","token":"wrong"}"#)
        XCTAssertEqual(wrong.messages.first?["why"] as? String, "token")

        // A phone paired the old way becomes a device without scanning again.
        let moved = await request("POST", "/pair", body: #"{"token":"\#(token)"}"#)
        XCTAssertEqual(moved.status, 200)
        let key = try XCTUnwrap(moved.cookie?.key)
        let paired = try await device(key: key)

        try server.setAcceptsToken(false)
        let dropped = await eventually { old.closed }
        XCTAssertTrue(dropped)
        XCTAssertEqual(old.heard("denied").first?["why"] as? String, "token")
        XCTAssertFalse(paired.closed, "the device stays")
        let refused = await phone(#"{"t":"auth","token":"\#(token)"}"#)
        XCTAssertEqual(refused.messages.first?["why"] as? String, "token")
        let noMore = await request("POST", "/pair", body: #"{"token":"\#(token)"}"#)
        XCTAssertEqual(noMore.status, 403)
        XCTAssertEqual(noMore.body["why"] as? String, "token")
    }

    /// "Disconnect all" gives a new token: the phones that use the old one go, the devices are the Mac's to revoke.
    func testANewTokenDropsOnlyThePhonesOfTheOldOne() async throws {
        try await start()
        let key = try await paired()
        let device = try await device(key: key)
        let old = await phone(#"{"t":"auth","token":"\#(token)"}"#)
        server.token = "another-token-another-token-another-token"
        let dropped = await eventually { old.closed }
        XCTAssertTrue(dropped)
        await pause(0.1)
        XCTAssertFalse(device.closed)
    }

    // MARK: Pause

    func testPausedTheMacTakesNoInputAndShowsNothing() async throws {
        try await start()
        let phone = try await device(key: try await paired())
        XCTAssertEqual(phone.heard("mac").first as NSDictionary?, ["t": "mac", "ax": true, "screen": true, "paused": false])
        phone.send(view)
        phone.send(#"{"t":"b","b":"left","d":true}"#)
        let viewing = await eventually { screen.views == 1 && events.contains { $0.type == .leftMouseDown } }
        XCTAssertTrue(viewing)

        try server.setPaused(true)
        let told = await eventually { phone.heard("mac").last?["paused"] as? Bool == true }
        XCTAssertTrue(told)
        XCTAssertEqual(phone.heard("view").last?["why"] as? String, "paused")
        XCTAssertNil(screen.requests.last ?? nil, "the view stopped")
        XCTAssertTrue(events.contains { $0.type == .leftMouseUp }, "the held button let go")
        let before = events.count
        phone.send(#"{"t":"m","dx":5,"dy":0}"#)
        phone.send(#"{"t":"key","k":"a","mods":[],"n":1}"#)
        phone.send(view)
        phone.send(#"{"t":"ping"}"#)
        let answered = await eventually { phone.heard("pong").count == 1 }
        XCTAssertTrue(answered)
        XCTAssertEqual(events.count, before, "nothing posted")
        XCTAssertEqual(screen.views, 1, "no view")
        XCTAssertEqual(phone.heard("view").count, 2)
        XCTAssertFalse(phone.closed, "still paired and connected")

        try server.setPaused(false)
        phone.send(#"{"t":"m","dx":5,"dy":0}"#)
        let moving = await eventually { moves() == 1 }
        XCTAssertTrue(moving)
        XCTAssertEqual(phone.heard("mac").last?["paused"] as? Bool, false)
    }

    /// A permission granted while the phone is connected shows on it without a restart.
    func testAGrantShowsOnThePhone() async throws {
        try await start(timing: Server.Timing(permissions: 0.05))
        allowed = (true, false)
        let phone = try await device(key: try await paired())
        XCTAssertEqual(phone.heard("mac").first?["screen"] as? Bool, false)
        phone.send(view)
        let refused = await eventually { phone.heard("view").first?["why"] as? String == "permission" }
        XCTAssertTrue(refused)
        allowed = (true, true)
        let granted = await eventually { phone.heard("mac").last?["screen"] as? Bool == true }
        XCTAssertTrue(granted)
        XCTAssertEqual(phone.heard("mac").count, 2, "once per change")
        phone.send(view)
        let viewing = await eventually { screen.views == 1 }
        XCTAssertTrue(viewing)
    }

    // MARK: Sessions

    func testTheMacSeesWhoIsConnected() async throws {
        try await start()
        var heard: [[Server.Session]] = []
        server.sessionsChanged = { heard.append($0) }
        var firstMoves: [Device.ID?] = []
        server.firstMove = { firstMoves.append($0) }
        let key = try await paired()
        let name = server.devices[0].name
        XCTAssertFalse(server.hasMoved)
        let phone = try await device(key: key, standalone: true)
        let old = await self.phone(#"{"t":"auth","token":"\#(token)"}"#)
        XCTAssertEqual(server.sessions.map(\.name), [name, nil])
        XCTAssertEqual(server.sessions.map(\.standalone), [true, false])
        XCTAssertEqual(server.sessions.first?.since, clock)

        phone.send(view)
        let watching = await eventually { server.sessions.first?.watches == true }
        XCTAssertTrue(watching)
        XCTAssertEqual(heard.last?.first?.watches, true, "the Mac heard it")
        phone.send(#"{"t":"m","dx":3,"dy":0}"#)
        let moved = await eventually { server.hasMoved }
        XCTAssertTrue(moved)
        phone.send(#"{"t":"m","dx":3,"dy":0}"#)
        old.send(#"{"t":"m","dx":3,"dy":0}"#)
        let both = await eventually { firstMoves.count == 2 }
        XCTAssertTrue(both)
        XCTAssertEqual(firstMoves, [server.devices[0].id, nil], "once per session, with its device")

        try server.rename(server.devices[0].id, to: "Arbeit")
        XCTAssertEqual(heard.last?.first?.name, "Arbeit")

        let device = try XCTUnwrap(server.sessions.first)
        server.end(device.id)
        let ended = await eventually { phone.closed && server.sessions.count == 1 }
        XCTAssertTrue(ended)
        XCTAssertNil(server.sessions.first?.device)
        XCTAssertNotNil(server.devices.first?.seen)
        old.close()
        let gone = await eventually { heard.last?.isEmpty == true }
        XCTAssertTrue(gone)
    }
}

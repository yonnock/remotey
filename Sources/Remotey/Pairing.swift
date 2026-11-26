import Foundation
import Security

/// The offer to pair one phone, open while the Mac shows its pairing window. Opening it is the consent: the
/// codes exist only then, for five minutes at most, so nothing else is asked at the Mac. Two codes, either one
/// pairs: a long one in the QR code's link and six digits to type, for a page that has no link (a Home Screen app
/// that came up without its key). The first use spends both; a few wrong tries end the offer.
final class Pairing {
    struct Offer: Equatable {
        /// In the link's fragment, `#p=<code>`. 128 bits: nobody guesses it in the tries there are.
        let code: String
        /// For typing. One in a million per try, and there are `tries` of them.
        let digits: String
        let ends: Date
    }

    enum Refusal: Equatable {
        /// Neither code: one try fewer.
        case code
        /// No offer is open.
        case closed
        /// The tries are used up. Stays so until the Mac opens a new offer.
        case tries
    }

    static let time: TimeInterval = 300
    static let tries = 5

    private(set) var offer: Offer?
    private var wrong = 0
    private var exhausted = false
    private let now: () -> Date
    private let random: () -> UInt32

    init(now: @escaping () -> Date = Date.init, random: @escaping () -> UInt32 = Pairing.random) {
        self.now = now
        self.random = random
    }

    /// A new offer in place of any before it, with fresh codes and a fresh count of tries.
    func open(for time: TimeInterval = Pairing.time) -> Offer {
        let offer = Offer(code: Token.random(16), digits: digits(), ends: now().addingTimeInterval(min(time, Self.time)))
        self.offer = offer
        wrong = 0
        exhausted = false
        return offer
    }

    func close() {
        offer = nil
        exhausted = false
    }

    /// Whether the offer ran out of time; it is gone then.
    @discardableResult
    func expire() -> Bool {
        guard let offer, now() >= offer.ends else { return false }
        close()
        return true
    }

    /// Spends the offer if `code` is either of its codes. Nil when it paired: the offer is gone then.
    func take(_ code: String) -> Refusal? {
        expire()
        if exhausted { return .tries }
        guard let offer else { return .closed }
        let typed = code.filter { !$0.isWhitespace && $0 != "-" }
        // Both compared every time, in constant time, so the time of an answer says nothing about either.
        let byLink = Token.matches(code, offer.code), byDigits = Token.matches(typed, offer.digits)
        if byLink || byDigits {
            self.offer = nil
            return nil
        }
        wrong += 1
        if wrong >= Self.tries {
            self.offer = nil
            exhausted = true
            return .tries
        }
        return .code
    }

    /// Six digits, each value as likely as the next.
    private func digits() -> String {
        // The largest multiple of a million below 2^32: what is above it would favour the low numbers.
        let limit = UInt32.max - UInt32.max % 1_000_000
        var value = random()
        while value >= limit { value = random() }
        return String(format: "%06u", value % 1_000_000)
    }

    static func random() -> UInt32 {
        var value: UInt32 = 0
        precondition(SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &value) == errSecSuccess)
        return value
    }

    /// What the QR code holds. The fragment never reaches a server, not even `tailscale serve`.
    static func link(host: String, code: String) -> String {
        "https://\(host):\(Tailscale.port)/#p=\(code)"
    }
}

/// What opens the socket for a device: the socket's handshake cannot hand its headers to the connection, so the
/// page trades its cookie for a ticket over HTTP and sends that first. Good once, for half a minute.
struct Tickets {
    enum Outcome: Equatable {
        case device(Device.ID)
        /// Unknown, used or expired.
        case unknown
        /// It was issued to a device that has been revoked since.
        case revoked
    }

    static let life: TimeInterval = 30
    /// More are never outstanding: the oldest goes first. A page takes one per connection.
    static let most = 64

    private var issued: [(ticket: String, device: Device.ID, ends: Date, revoked: Bool)] = []
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    mutating func issue(for device: Device.ID) -> String {
        purge()
        let ticket = Token.random()
        issued.append((ticket, device, now().addingTimeInterval(Self.life), false))
        if issued.count > Self.most { issued.removeFirst(issued.count - Self.most) }
        return ticket
    }

    /// Spends the ticket, whatever comes of it.
    mutating func take(_ ticket: String) -> Outcome {
        purge()
        guard let index = issued.firstIndex(where: { Token.matches($0.ticket, ticket) }) else { return .unknown }
        let entry = issued.remove(at: index)
        return entry.revoked ? .revoked : .device(entry.device)
    }

    /// The device's tickets open nothing any more, and say why.
    mutating func revoke(_ device: Device.ID? = nil) {
        for index in issued.indices where device == nil || issued[index].device == device { issued[index].revoked = true }
    }

    private mutating func purge() {
        let now = now()
        issued.removeAll { $0.ends <= now }
    }
}

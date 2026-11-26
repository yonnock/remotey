import XCTest
@testable import Remotey

final class PairingTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 1_000_000)

    private func pairing(random: @escaping () -> UInt32 = Pairing.random) -> Pairing {
        Pairing(now: { [unowned self] in clock }, random: random)
    }

    func testCodesExistOnlyWhileTheOfferIsOpen() {
        let pairing = pairing()
        XCTAssertEqual(pairing.take("123456"), .closed)
        let offer = pairing.open()
        XCTAssertEqual(offer.digits.count, 6)
        XCTAssertTrue(offer.digits.allSatisfy(\.isNumber))
        XCTAssertGreaterThanOrEqual(offer.code.count, 22, "128 bits")
        pairing.close()
        XCTAssertEqual(pairing.take(offer.digits), .closed)
        XCTAssertEqual(pairing.take(offer.code), .closed)
    }

    func testTheFirstUseSpendsBothCodes() {
        let pairing = pairing()
        let offer = pairing.open()
        XCTAssertNil(pairing.take(offer.code))
        XCTAssertEqual(pairing.take(offer.digits), .closed)
        let next = pairing.open()
        XCTAssertNil(pairing.take(" \(next.digits.prefix(3))-\(next.digits.dropFirst(3)) "), "typed with a space or a dash")
        XCTAssertEqual(pairing.take(next.code), .closed)
    }

    func testAnOfferEndsAfterFiveMinutesAtMost() {
        let pairing = pairing()
        let offer = pairing.open(for: 3600)
        XCTAssertEqual(offer.ends, clock.addingTimeInterval(300))
        clock += 299
        XCTAssertFalse(pairing.expire())
        clock += 1
        XCTAssertEqual(pairing.take(offer.digits), .closed)
        XCTAssertNil(pairing.offer)
    }

    func testAFewWrongTriesEndTheOffer() {
        let pairing = pairing()
        let offer = pairing.open()
        let wrong = offer.digits == "000000" ? "000001" : "000000"
        for _ in 1..<Pairing.tries { XCTAssertEqual(pairing.take(wrong), .code) }
        XCTAssertEqual(pairing.take("not-the-link-code"), .tries)
        XCTAssertEqual(pairing.take(offer.digits), .tries, "the right code no longer pairs")
        XCTAssertEqual(pairing.take(offer.code), .tries)
        pairing.close()
        XCTAssertEqual(pairing.take(offer.digits), .closed)
        let next = pairing.open()
        XCTAssertNil(pairing.take(next.digits), "a new offer counts from the start")
    }

    /// A value above the last whole million would make the low numbers likelier: it is drawn again.
    func testTheDigitsAreDrawnWithoutBias() {
        var values: [UInt32] = [UInt32.max, 4_294_000_000, 42]
        let offer = pairing(random: { values.removeFirst() }).open()
        XCTAssertEqual(offer.digits, "000042")
        XCTAssertTrue(values.isEmpty)
    }

    func testTheLinkCarriesTheCodeInItsFragment() {
        XCTAssertEqual(Pairing.link(host: "mac.example.ts.net", code: "abc"), "https://mac.example.ts.net:8443/#p=abc")
    }

    // MARK: Tickets

    func testATicketOpensOnceForHalfAMinute() {
        var tickets = Tickets(now: { [unowned self] in clock })
        let first = tickets.issue(for: "a")
        XCTAssertEqual(tickets.take(first), .device("a"))
        XCTAssertEqual(tickets.take(first), .unknown, "once")
        let late = tickets.issue(for: "a")
        clock += 30
        XCTAssertEqual(tickets.take(late), .unknown, "expired")
        XCTAssertEqual(tickets.take("made-up"), .unknown)
    }

    func testARevokedDevicesTicketsSaySo() {
        var tickets = Tickets(now: { [unowned self] in clock })
        let a = tickets.issue(for: "a"), b = tickets.issue(for: "b")
        tickets.revoke("a")
        XCTAssertEqual(tickets.take(a), .revoked)
        XCTAssertEqual(tickets.take(b), .device("b"))
        let c = tickets.issue(for: "c")
        tickets.revoke()
        XCTAssertEqual(tickets.take(c), .revoked)
    }

    func testOutstandingTicketsAreBounded() {
        var tickets = Tickets(now: { [unowned self] in clock })
        let oldest = tickets.issue(for: "a")
        for _ in 0..<Tickets.most { _ = tickets.issue(for: "a") }
        XCTAssertEqual(tickets.take(oldest), .unknown)
    }
}

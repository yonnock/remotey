import XCTest
@testable import Remotey

/// The assistant's steps and the pairing in them, against a made-up server: which code shows, when it goes on by
/// itself, and that no offer outlives its step.
final class AssistantFlowTests: XCTestCase {
    private var state = MacState(health: .listening, port: 47800, facts: SetupTests.ready())
    private var opened: [Pairing.Offer] = []
    private var closes = 0
    private var performed: [Setup.Action] = []
    private let phone = Device(id: "a", name: "iPhone 17 Pro", paired: Date(), seen: nil, login: nil, keyHash: "")

    private lazy var flow = AssistantFlow(
        pairer: .init(open: { [unowned self] in
            let offer = Pairing.Offer(code: "code\(opened.count)", digits: "12345\(opened.count)", ends: Date().addingTimeInterval(300))
            opened.append(offer)
            return offer
        }, close: { [unowned self] in closes += 1 }),
        state: { [unowned self] in state }, perform: { [unowned self] in performed.append($0) })

    func testAddingAPhoneShowsTheCodeAndItsLinkToThisMac() {
        flow.start(at: .pair)
        XCTAssertEqual(flow.phase, .pair)
        XCTAssertEqual(flow.code, .open(opened[0], link: "https://\(SetupTests.host):8443/#p=code0"))
        XCTAssertFalse(flow.canGoOn, "on only once a phone paired")
    }

    func testWhileSomethingKeepsAPhoneOutItStartsAtTheChecklistAndOffersNoCode() {
        state.facts.tailscale = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .none, funnel: false))
        flow.start(at: .pair)
        XCTAssertEqual(flow.phase, .prepare)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(flow.canGoOn)
        XCTAssertEqual(flow.next(), .prepare, "Weiter does nothing yet")

        state.facts = SetupTests.ready()
        XCTAssertTrue(flow.canGoOn)
        flow.next()
        XCTAssertEqual(flow.phase, .pair)
        XCTAssertEqual(opened.count, 1)
    }

    func testACodeThatWaitedForTailscaleComesByItself() {
        flow.start(at: .pair)
        state.health = .failed("Port 47800 ist belegt")
        flow.renewCode()
        XCTAssertEqual(flow.code, .unavailable)
        XCTAssertEqual(closes, 1, "the offer that was open is closed")
        state.health = .listening
        flow.stateChanged()
        XCTAssertEqual(opened.count, 2)
        if case .open = flow.code {} else { XCTFail("\(String(describing: flow.code))") }
    }

    /// The server tells the Mac of every offer it opens, and the Mac tells the assistant: that must not open
    /// another one, or the code on show would be one the server already replaced.
    func testOpeningACodeWhileTheMacReportsItOpensOne() {
        var inside = false
        let flow = AssistantFlow(pairer: .init(open: { [unowned self] in
            if !inside {
                inside = true
                self.flow.stateChanged()
                inside = false
            }
            let offer = Pairing.Offer(code: "code\(opened.count)", digits: "000000", ends: Date())
            opened.append(offer)
            return offer
        }, close: {}), state: { [unowned self] in state }, perform: { _ in })
        self.flow = flow
        flow.start(at: .pair)
        state.health = .failed("Port 47800 ist belegt")
        flow.renewCode()
        XCTAssertEqual(flow.code, .unavailable)
        state.health = .listening
        flow.stateChanged()
        XCTAssertEqual(opened.count, 2)
        XCTAssertEqual(flow.code, .open(opened[1], link: "https://\(SetupTests.host):8443/#p=code1"))
    }

    func testAPairedPhoneLeadsOnToTheFirstMoveAndItsMoveTicksIt() {
        flow.start(at: .pair)
        flow.pairing(.paired(phone))
        XCTAssertEqual(flow.phase, .move)
        XCTAssertEqual(flow.device, phone)
        XCTAssertNil(flow.code, "the offer is spent")
        XCTAssertEqual(closes, 0, "nothing left to close")

        flow.firstMove(by: nil)
        flow.firstMove(by: "another")
        XCTAssertFalse(flow.moved, "only the phone just paired counts")
        flow.firstMove(by: phone.id)
        XCTAssertTrue(flow.moved)
    }

    func testAnExpiredCodeIsReplacedOnRequest() {
        flow.start(at: .pair)
        flow.pairing(.expired)
        XCTAssertEqual(flow.code, .expired)
        flow.renewCode()
        XCTAssertEqual(opened.count, 2)
        flow.pairing(.tries)
        XCTAssertEqual(flow.code, .tries)
    }

    func testTheHomeScreenStepOffersTheDigitsAndTicksWhenTheAppConnects() {
        flow.start(at: .pair)
        flow.pairing(.paired(phone))
        flow.next()
        XCTAssertEqual(flow.phase, .homeScreen)
        XCTAssertEqual(opened.count, 2, "a Home Screen app without Safari's cookie types the digits")
        flow.sessions([Server.Session(id: 1, device: phone.id, name: phone.name, since: Date(), watches: false, standalone: false)])
        XCTAssertFalse(flow.onHomeScreen, "still in Safari")
        flow.sessions([Server.Session(id: 2, device: "b", name: "iPhone 2", since: Date(), watches: false, standalone: true)])
        XCTAssertTrue(flow.onHomeScreen)
        XCTAssertEqual(closes, 1, "the digits are not needed any more")
        XCTAssertNil(flow.next(), "done: the window closes")
    }

    func testNoOfferOutlivesItsStepOrTheWindow() {
        flow.start(at: .pair)
        flow.back()
        XCTAssertEqual(flow.phase, .prepare)
        XCTAssertEqual(closes, 1)
        flow.next()
        flow.stop()
        XCTAssertEqual(closes, 2)
        flow.stop()
        XCTAssertEqual(closes, 2, "closed once")
    }

    func testTheFirstStartSwitchesTheLoginItemOnOnce() {
        state.facts.loginItem = .off
        flow.start(at: .prepare, firstStart: true)
        XCTAssertEqual(performed, [.setLoginItem(true)])
        flow.start(at: .prepare, firstStart: true)
        XCTAssertEqual(performed.count, 1, "a box unticked by hand stays so")
        flow.start(at: .prepare)
        XCTAssertEqual(performed.count, 1)
    }

    func testTheFirstStartLeavesALoginItemThatWaitsForApprovalAlone() {
        state.facts.loginItem = .needsApproval
        flow.start(at: .prepare, firstStart: true)
        XCTAssertTrue(performed.isEmpty)
    }
}

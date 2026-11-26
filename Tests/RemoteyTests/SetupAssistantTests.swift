import XCTest
@testable import Remotey

/// A Tailscale that answers what the test says, and counts what it was asked.
private final class FakeTailscale: TailscaleClient {
    var snapshotAnswer: Tailscale.Snapshot = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .none, funnel: false))
    var snapshots = 0
    var selfTests: [String] = []
    var selfTestAnswer: Tailscale.SelfTest = .answered
    var applies = 0
    /// Printed while applying, before the outcome.
    var consent: URL?
    var applyOutcome: Tailscale.Outcome = .done
    /// Runs inside apply, after the consent: a test looks at the rows while the tool still waits.
    var whileApplying: (() -> Void)?

    func snapshot() -> Tailscale.Snapshot {
        snapshots += 1
        return snapshotAnswer
    }

    func applyServe(link: @escaping (URL) -> Void) -> Tailscale.Outcome {
        applies += 1
        if let consent { link(consent) }
        whileApplying?()
        if applyOutcome == .done { snapshotAnswer = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .ours, funnel: false)) }
        return applyOutcome
    }

    func removeServe() -> Tailscale.Outcome { .done }
    func logIn(link: @escaping (URL) -> Void) -> Tailscale.Outcome { .done }
    func turnOn() -> Tailscale.Outcome { .done }

    func selfTest(host: String) -> Tailscale.SelfTest {
        selfTests.append(host)
        return selfTestAnswer
    }
}

/// The assistant with every probe, effect and queue replaced: work that would go to the background runs
/// at once, and the timer ticks when the test says.
final class SetupAssistantTests: XCTestCase {
    private let tailscale = FakeTailscale()
    private var accessibility = false
    private var paired = false
    private var opened: [URL] = []
    private var asked = 0
    private var loginItem = LoginItem.State.off
    private var tick: (() -> Void)?
    private var timers = 0
    private var stopped = 0
    private var changes = 0

    private lazy var assistant: SetupAssistant = {
        let assistant = SetupAssistant(
            probes: .init(accessibility: { [unowned self] in accessibility },
                          screenRecording: { .init(granted: true, preflight: true) },
                          loginItem: { [unowned self] in loginItem },
                          paired: { [unowned self] in paired }, moved: { false }),
            effects: .init(open: { [unowned self] in opened.append($0) }, copy: { _ in }, showPairing: {}, restart: {},
                           askForAccessibility: { [unowned self] in asked += 1 }, askForScreenRecording: {},
                           setLoginItem: { [unowned self] in loginItem = $0 ? .on : .off }, openLoginItems: {}),
            tailscale: tailscale, background: { $0() }, main: { $0() },
            every: { [unowned self] _, tick in
                timers += 1
                self.tick = tick
                return { [unowned self] in stopped += 1 }
            })
        assistant.changed = { [unowned self] in changes += 1 }
        return assistant
    }()

    func testItLooksOnlyWhileWatched() {
        XCTAssertEqual(tailscale.snapshots, 0, "nothing before someone watches")
        assistant.watch()
        assistant.watch()
        XCTAssertEqual(timers, 1, "one timer for every watcher")
        XCTAssertEqual(tailscale.snapshots, 1, "a look at once")
        tick?()
        XCTAssertEqual(tailscale.snapshots, 2)
        assistant.unwatch()
        XCTAssertEqual(stopped, 0, "another one still watches")
        assistant.unwatch()
        assistant.unwatch()
        XCTAssertEqual(stopped, 1)
    }

    func testAChangeIsToldOnceNotEverySecond() {
        assistant.watch()
        let first = changes
        tick?()
        tick?()
        XCTAssertEqual(changes, first, "nothing new")
        accessibility = true
        tick?()
        XCTAssertEqual(changes, first + 1)
        XCTAssertEqual(assistant.row(.accessibility).state, .ok)
    }

    func testTheLaunchCheckOpensForAMissingStepAndNotWhenAllIsSet() {
        var open: Bool?
        assistant.launchCheck(firstStart: false) { open = $0 }
        XCTAssertEqual(open, true, "Accessibility and Serve are missing")

        accessibility = true
        tailscale.snapshotAnswer = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .ours, funnel: false))
        assistant.launchCheck(firstStart: false) { open = $0 }
        XCTAssertEqual(open, false)
        assistant.launchCheck(firstStart: true) { open = $0 }
        XCTAssertEqual(open, true)
    }

    func testApplyingShowsTheConsentLinkThenTestsTheAddressOnce() {
        accessibility = true
        assistant.refresh()
        XCTAssertEqual(assistant.row(.serve).action, .applyServe)

        let link = URL(string: "https://login.tailscale.com/f/serve?node=n1")!
        tailscale.consent = link
        var whileWaiting: Setup.Row?
        tailscale.whileApplying = { [unowned self] in whileWaiting = assistant.row(.serve) }
        assistant.perform(.applyServe)
        XCTAssertEqual(whileWaiting?.action, .open(link))
        assistant.perform(whileWaiting!.action!)
        XCTAssertEqual(opened, [link])

        XCTAssertEqual(tailscale.applies, 1)
        XCTAssertEqual(tailscale.selfTests, [SetupTests.host], "the new mapping is tested")
        XCTAssertEqual(assistant.row(.serve).state, .ok)
        XCTAssertEqual(assistant.summary, .init(state: .ok, text: "Bereit"))

        assistant.refresh()
        assistant.refresh()
        XCTAssertEqual(tailscale.selfTests.count, 1, "not every second")
        assistant.perform(.selfTest)
        XCTAssertEqual(tailscale.selfTests.count, 2, "but when asked")
    }

    func testAFailedApplyStaysOnTheRowUntilItIsTriedAgain() {
        tailscale.applyOutcome = .failed("Tailscale meldet: nein")
        assistant.refresh()
        assistant.perform(.applyServe)
        XCTAssertEqual(assistant.row(.serve), .init(item: .serve, state: .failed, detail: "Tailscale meldet: nein", action: .applyServe))
        assistant.refresh()
        XCTAssertEqual(assistant.row(.serve).state, .failed)
        tailscale.applyOutcome = .done
        assistant.perform(.applyServe)
        XCTAssertEqual(assistant.row(.serve).state, .ok)
    }

    func testAFailureEndsWhenTheMappingIsThereAnyway() {
        tailscale.applyOutcome = .failed("Tailscale meldet: nein")
        assistant.refresh()
        assistant.perform(.applyServe)
        XCTAssertEqual(assistant.row(.serve).state, .failed)
        // Mapped in Terminal meanwhile.
        tailscale.snapshotAnswer = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .ours, funnel: false))
        assistant.refresh()
        XCTAssertEqual(assistant.row(.serve).state, .ok)
    }

    func testAFailedSelfTestIsNotRepeatedByItself() {
        tailscale.snapshotAnswer = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .ours, funnel: false))
        tailscale.selfTestAnswer = .failed("Keine Antwort.")
        assistant.refresh()
        assistant.refresh()
        XCTAssertEqual(tailscale.selfTests.count, 1)
        XCTAssertEqual(assistant.row(.serve).action, .selfTest)
    }

    func testAFunnelIsNotTested() {
        tailscale.snapshotAnswer = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .ours, funnel: true))
        assistant.refresh()
        XCTAssertEqual(tailscale.selfTests, [])
        XCTAssertEqual(assistant.row(.serve).action, .removeServe)
    }

    func testThePermissionIsAskedForOnceThenSettingsOpen() {
        assistant.refresh()
        assistant.perform(assistant.row(.accessibility).action!)
        XCTAssertEqual(asked, 1)
        assistant.perform(assistant.row(.accessibility).action!)
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(opened, [Permissions.accessibilitySettings])
    }

    func testTheLoginItemTogglesAndIsReadBack() {
        assistant.refresh()
        assistant.perform(assistant.row(.loginItem).action!)
        XCTAssertEqual(assistant.row(.loginItem).state, .ok)
        XCTAssertEqual(assistant.row(.loginItem).action, .setLoginItem(false))
    }

    func testPairingComesFromOutside() {
        assistant.watch()
        XCTAssertEqual(assistant.row(.pairing).state, .actionNeeded)
        paired = true
        tick?()
        XCTAssertEqual(assistant.row(.pairing).state, .ok)
        XCTAssertEqual(assistant.hostname, SetupTests.host)
    }
}

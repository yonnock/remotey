import AppKit
import XCTest
@testable import Remotey

/// What the menu, the symbol and the settings make of the server's state and the checklist.
final class MacStateTests: XCTestCase {
    private func ready() -> MacState {
        var state = MacState(health: .listening, port: 47800)
        state.facts = SetupTests.ready()
        state.facts.screenRecording = .init(granted: true, preflight: true)
        state.facts.selfTest = .done(.answered)
        return state
    }

    private let session = Server.Session(id: 1, device: "a", name: "iPhone", since: Date(timeIntervalSince1970: 0),
                                         watches: false, standalone: false)

    // MARK: Symbol

    func testTheSymbolShowsAConnectedPhoneAndThePause() {
        var state = ready()
        XCTAssertEqual(state.look, .init())
        state.sessions = [session]
        XCTAssertEqual(state.look, .init(connected: true))
        XCTAssertEqual(state.look.symbol, "cursorarrow.rays")
        state.paused = true
        XCTAssertEqual(state.look.symbol, "cursorarrow.slash", "paused wins over connected")
        XCTAssertEqual(state.look.label, Texts.Menu.symbolPaused)
    }

    func testTheSymbolWarnsOfClosedPortsAndOfWhatKeepsAPhoneOut() {
        var state = ready()
        state.health = .failed("Port 47800 ist belegt")
        XCTAssertTrue(state.look.problem)
        state = ready()
        state.facts.accessibility = false
        XCTAssertTrue(state.look.problem, "a required permission")
        state = ready()
        state.facts.screenRecording = .init(granted: false, preflight: false)
        XCTAssertFalse(state.look.problem, "only the live view needs it")
        state = ready()
        state.facts.tailscale = nil
        XCTAssertFalse(state.look.problem, "Tailscale not yet asked: still checking")
        state.health = .starting
        XCTAssertFalse(state.look.problem)
    }

    func testEverySymbolIsATemplateThatTheMenuBarColours() {
        for look in [MacState.Look(), .init(connected: true), .init(paused: true), .init(problem: true)] {
            let image = StatusSymbol.image(look)
            XCTAssertTrue(image.isTemplate)
            XCTAssertGreaterThan(image.size.width, 0, "\(look.symbol) exists")
            XCTAssertEqual(image.accessibilityDescription, look.label)
        }
    }

    // MARK: Menu

    func testAllFineTheMenuShowsTicksAndTheTailnetName() {
        let lines = ready().statusLines
        XCTAssertEqual(lines.map(\.kind), [.accessibility, .screenRecording, .tailscale])
        XCTAssertEqual(lines.map(\.state), [.ok, .ok, .ok])
        XCTAssertEqual(lines.last?.subtitle, SetupTests.status.dnsName)
        XCTAssertTrue(lines.allSatisfy { $0.fix == nil }, "nothing to click on a fine line")
    }

    func testAMissingPermissionLeadsToItsFix() {
        var state = ready()
        state.facts.accessibility = false
        state.facts.screenRecording = .init(granted: false, preflight: false)
        state.facts.askedForScreenRecording = true
        let lines = state.statusLines
        XCTAssertEqual(lines[0].fix, .perform(.askForAccessibility))
        XCTAssertEqual(lines[1].fix, .perform(.openSettings(Permissions.screenRecordingSettings)))
        XCTAssertEqual(lines[1].subtitle, Texts.Menu.onlyLiveView)
    }

    func testTheTailscaleLineSpeaksForTheFirstOfItsRowsThatIsNotFine() {
        var state = ready()
        state.facts.tailscale = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .none, funnel: false))
        XCTAssertEqual(state.statusLines.last?.subtitle, Texts.Menu.notShared)
        XCTAssertEqual(state.statusLines.last?.fix, .assistant)
        state.facts.tailscale = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .ours, funnel: true))
        XCTAssertEqual(state.statusLines.last?.subtitle, Texts.Menu.funnel)
        XCTAssertEqual(state.statusLines.last?.state, .failed)
        state.facts.tailscale = .notInstalled
        XCTAssertEqual(state.statusLines.last?.subtitle, Texts.Menu.tailscaleOff)
        state.facts.tailscale = nil
        XCTAssertEqual(state.statusLines.last?.subtitle, Texts.Menu.checking)
        XCTAssertNil(state.statusLines.last?.fix, "nothing to do while it checks")
    }

    func testClosedPortsAndALostTokenHeadTheStatus() {
        var state = ready()
        state.health = .failed("Port 47800 ist belegt")
        state.tokenProblem = "Gilt nur bis zum Beenden"
        XCTAssertEqual(state.statusLines.prefix(2).map(\.kind), [.health, .token])
        XCTAssertEqual(state.statusLines.first?.subtitle, "Port 47800 ist belegt")
    }

    func testASessionSaysWhatItDoes() {
        var state = ready()
        XCTAssertEqual(state.subtitle(of: session), Texts.Menu.connected)
        let watching = Server.Session(id: 2, device: nil, name: nil, since: Date(), watches: true, standalone: false)
        XCTAssertEqual(state.subtitle(of: watching), Texts.Menu.connectedLive)
        XCTAssertEqual(MacState.name(of: watching), Texts.Menu.sharedKey, "the old token has no device")
        state.paused = true
        XCTAssertEqual(state.subtitle(of: watching), Texts.Menu.connectedPaused)
    }

    func testADeviceGetsTheSymbolOfItsKind() {
        XCTAssertEqual(MacState.symbol(forDevice: "iPhone 2"), "iphone")
        XCTAssertEqual(MacState.symbol(forDevice: "iPad"), "ipad")
        XCTAssertEqual(MacState.symbol(forDevice: "iPad oder Mac"), "ipad")
        XCTAssertEqual(MacState.symbol(forDevice: "Browser"), "desktopcomputer")
        XCTAssertEqual(MacState.symbol(forDevice: "Arbeit"), "iphone", "a name the user chose")
        XCTAssertEqual(MacState.symbol(forDevice: nil), "globe")
    }

    // MARK: Pairing

    func testPairingNeedsTheAddressInTheTailnetAndOpenPorts() {
        var state = ready()
        XCTAssertTrue(state.readyToPair)
        XCTAssertEqual(state.address, "https://\(SetupTests.status.dnsName!):\(Tailscale.port)")
        state.health = .starting
        XCTAssertFalse(state.readyToPair, "a link to ports that are not open leads nowhere")
        state = ready()
        state.facts.tailscale = .connected(SetupTests.brew, SetupTests.status, .init(mapping: .none, funnel: false))
        XCTAssertFalse(state.readyToPair)
        XCTAssertNil(state.address)
    }

    // MARK: Settings

    private var berlin: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int, year: Int = 2026) -> Date {
        berlin.date(from: DateComponents(year: year, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testADeviceSaysWhenItWasConnectedOrLastSeen() {
        let now = date(19, 14, 42)
        var device = Device(id: "a", name: "iPhone", paired: date(1, 9, 0), seen: date(18, 21, 7), login: nil, keyHash: "")
        var state = ready()
        XCTAssertEqual(state.subtitle(of: device, now: now, calendar: berlin), "Zuletzt gestern, 21:07")
        device.seen = date(19, 9, 5)
        XCTAssertEqual(state.subtitle(of: device, now: now, calendar: berlin), "Zuletzt heute, 09:05")
        device.seen = date(3, 8, 0)
        XCTAssertEqual(state.subtitle(of: device, now: now, calendar: berlin), "Zuletzt 3. Nov., 08:00")
        device.seen = date(3, 8, 0, year: 2025)
        XCTAssertEqual(state.subtitle(of: device, now: now, calendar: berlin), "Zuletzt 3. Nov. 2025, 08:00")
        device.seen = nil
        XCTAssertEqual(state.subtitle(of: device, now: now, calendar: berlin), "Gekoppelt 1. Nov., 09:00")

        state.sessions = [Server.Session(id: 1, device: "a", name: "iPhone", since: date(19, 14, 31), watches: true, standalone: false)]
        XCTAssertEqual(state.subtitle(of: device, now: now, calendar: berlin), "Verbunden seit 14:31 · Live-Bild an")
    }

    // MARK: Panel

    func testThePanelOpensUnderItsSymbolAndStaysOnItsDisplay() {
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 982)
        let size = NSSize(width: 320, height: 400)
        let button = NSRect(x: 1100, y: 958, width: 32, height: 24)
        XCTAssertEqual(MenuPanel.origin(size: size, below: button, on: screen), NSPoint(x: 1100, y: 958 - 5 - 400))
        let right = NSRect(x: 1400, y: 958, width: 32, height: 24)
        XCTAssertEqual(MenuPanel.origin(size: size, below: right, on: screen).x, 1512 - 320 - 6, "pulled in from the right edge")
        // A second display to the left, lower down: the panel stays on it.
        let other = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
        let there = NSRect(x: -100, y: 856, width: 32, height: 24)
        let origin = MenuPanel.origin(size: size, below: there, on: other)
        XCTAssertEqual(origin.x, -320 - 6)
        XCTAssertEqual(origin.y, 856 - 5 - 400)
        XCTAssertTrue(other.contains(NSRect(origin: origin, size: size)))
    }

    // MARK: Problems

    func testAKeyThatFailsToWriteSaysSo() {
        let model = MacModel()
        model.attempt { throw Token.WriteFailure(description: "Platte voll") }
        XCTAssertEqual(model.problem, MacModel.Problem(title: Texts.Problem.notSaved, text: "Platte voll"))
    }
}

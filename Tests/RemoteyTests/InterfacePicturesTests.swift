import AppKit
import SwiftUI
import XCTest
@testable import Remotey

/// The menu, the assistant, the settings and the Face ID window drawn off screen with made-up data, in light and
/// dark. With `REMOTEY_PICTURES=<folder>` each one is saved as a PNG (scripts/mac-pictures.sh); without it they
/// are only drawn, which checks that every state of every surface lays out.
@MainActor
final class InterfacePicturesTests: XCTestCase {
    // MARK: Made-up data: nothing here comes from this Mac or its tailnet.

    static let host = "macbook.example-tailnet.ts.net"
    static let owner = "jane@example.com"
    /// Thursday, 19 November 2026, 14:42, in the time zone the pictures are drawn in.
    static let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 14, minute: 42))!

    static let iPhone = Device(id: "iphone", name: "iPhone 17 Pro", paired: now.addingTimeInterval(-9 * 86400),
                               seen: now.addingTimeInterval(-11 * 60), login: owner, keyHash: "")
    static let iPad = Device(id: "ipad", name: "iPad Air", paired: now.addingTimeInterval(-30 * 86400),
                             seen: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 18, hour: 21, minute: 7)),
                             login: owner, keyHash: "")

    static func facts(ready: Bool = true) -> Setup.Facts {
        var facts = Setup.Facts()
        facts.accessibility = ready
        facts.screenRecording = .init(granted: ready, preflight: ready)
        facts.askedForAccessibility = true
        let status = Tailscale.Status(backend: .running, version: "1.90.1", dnsName: host, loginName: owner,
                                      certDomains: [host], authURL: nil)
        facts.tailscale = .connected(Tailscale.Binary(path: "/opt/homebrew/bin/tailscale", app: nil), status,
                                     .init(mapping: ready ? .ours : .none, funnel: false))
        facts.selfTest = ready ? .done(.answered) : .notRun
        facts.paired = ready
        facts.moved = ready
        facts.loginItem = .on
        return facts
    }

    static func state(ready: Bool = true, connected: Bool = true, paused: Bool = false) -> MacState {
        let session = Server.Session(id: 1, device: iPhone.id, name: iPhone.name, since: now.addingTimeInterval(-11 * 60),
                                     watches: true, standalone: true)
        return MacState(health: .listening, port: 47800, paused: paused, sessions: connected ? [session] : [],
                        devices: ready ? [iPhone, iPad] : [], acceptsToken: false, faceUnlock: ready, facts: facts(ready: ready))
    }

    /// A pairing offer for the pictures: codes that open nothing anywhere.
    static let offer = Pairing.Offer(code: "bWFkZS11cC1jb2RlLWZvci1waWN0dXJlcw", digits: "482913",
                                     ends: Date().addingTimeInterval(4 * 60 + 38.5))

    private func both(_ draw: (Pictures.Look) throws -> Void) rethrows {
        for look in Pictures.Look.allCases { try draw(look) }
    }

    // MARK: Menu

    private func menu(_ state: MacState, highlight: MenuView.Item? = nil, _ look: Pictures.Look) -> NSImage {
        let model = MacModel(state: state, now: Self.now)
        let content = Pictures.view(NSHostingView(rootView: MenuView(model: model, highlight: highlight)), look, width: MenuView.width)
        return Pictures.menu(content, symbol: StatusSymbol.image(state.look), look, radius: MenuPanel.cornerRadius)
    }

    func testTheMenu() throws {
        try both { look in
            try Pictures.save(menu(Self.state(), highlight: .addPhone, look), "menu-\(look)")
            var problem = Self.state(ready: false, connected: false)
            problem.facts.tailscale = .connected(Tailscale.Binary(path: "/opt/homebrew/bin/tailscale", app: nil),
                                                 .init(backend: .running, version: "1.90.1", dnsName: Self.host, loginName: Self.owner,
                                                       certDomains: [Self.host], authURL: nil), .init(mapping: .none, funnel: false))
            try Pictures.save(menu(problem, highlight: .status(.accessibility), look), "menu-problem-\(look)")
            try Pictures.save(menu(Self.state(paused: true), look), "menu-paused-\(look)")
        }
    }

    func testTheStatusSymbols() throws {
        let looks = [MacState.Look(), .init(connected: true), .init(paused: true), .init(problem: true), .init(connected: true, problem: true)]
        try both { look in
            let images = looks.map(StatusSymbol.image)
            let strip = NSImage(size: NSSize(width: 44 * CGFloat(images.count), height: 28), flipped: false) { rect in
                (look == .light ? NSColor(white: 0.93, alpha: 1) : NSColor(white: 0.16, alpha: 1)).setFill()
                rect.fill()
                for (index, image) in images.enumerated() {
                    let place = NSRect(x: CGFloat(index) * 44 + (44 - image.size.width) / 2, y: (28 - image.size.height) / 2,
                                       width: image.size.width, height: image.size.height)
                    Pictures.tinted(image, look).draw(in: place)
                }
                return true
            }
            for image in images { XCTAssertTrue(image.isTemplate, "the menu bar colours it") }
            try Pictures.save(strip, "symbols-\(look)")
        }
    }

    // MARK: Assistant

    private func assistant(_ state: MacState, _ look: Pictures.Look, _ setUp: (AssistantFlow) -> Void) -> NSImage {
        let model = MacModel(state: state, now: Self.now)
        let flow = AssistantFlow(pairer: .init(open: { Self.offer }, close: {}), state: { model.state }, perform: { _ in })
        setUp(flow)
        let window = AssistantWindow(model: model, flow: flow).makeWindow()
        defer { window.close() }
        return Pictures.shadowed(Pictures.window(window, look))
    }

    func testTheAssistant() throws {
        try both { look in
            var missing = Self.state(ready: false, connected: false)
            missing.facts.accessibility = true
            missing.facts.loginItem = .on
            try Pictures.save(assistant(missing, look) { $0.start(at: .prepare) }, "assistant-prepare-\(look)")
            var unpaired = Self.state(connected: false)
            unpaired.devices = []
            try Pictures.save(assistant(unpaired, look) { $0.start(at: .pair) }, "pairing-\(look)")
            try Pictures.save(assistant(unpaired, look) { flow in
                flow.start(at: .pair)
                flow.pairing(.paired(Self.iPhone))
                flow.firstMove(by: Self.iPhone.id)
            }, "assistant-moved-\(look)")
            try Pictures.save(assistant(unpaired, look) { flow in
                flow.start(at: .pair)
                flow.pairing(.paired(Self.iPhone))
                flow.next()
            }, "assistant-home-\(look)")
        }
    }

    // MARK: Settings

    func testTheSettings() throws {
        try both { look in
            for pane in MacModel.Pane.allCases {
                let model = MacModel(state: Self.state(), now: Self.now)
                let window = SettingsWindow(model: model).makeWindow(selecting: pane)
                defer { window.close() }
                try Pictures.save(Pictures.shadowed(Pictures.window(window, look)), "settings-\(Self.name(pane))-\(look)")
            }
        }
    }

    private static func name(_ pane: MacModel.Pane) -> String {
        switch pane {
        case .general: return "general"
        case .phones: return "phones"
        case .security: return "security"
        case .permissions: return "permissions"
        }
    }

    // MARK: Face ID

    func testTheFaceUnlockWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server(token: "picture-token-picture-token-picture", input: Input { _ in }, port: 47996,
                            faceUnlock: FaceUnlock(file: folder.appendingPathComponent("face-unlock")),
                            devices: Devices(file: folder.appendingPathComponent("devices")),
                            permissions: { (true, true) }, activity: {})
        try both { look in
            let window = FaceUnlockWindow(server: server, check: { _ in .right })
            let made = window.makeWindow()
            defer { made.close() }
            try Pictures.save(Pictures.shadowed(Pictures.window(made, look)), "faceid-\(look)")
        }
    }
}


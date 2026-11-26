import AppKit
import CoreImage
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Port `tailscale serve` exposes inside the tailnet (see scripts/tailscale-serve.sh).
    static let tailnetPort = 8443

    private let input = Input()
    private lazy var server: Server = {
        let loaded = Token.load()
        tokenProblem = loaded.failure.map { "Token nicht gespeichert, gilt nur bis zum Beenden: \($0)" }
        return Server(token: loaded.token, input: input)
    }()
    /// The token in use is not the one in the file, or there is none: the menu says so.
    private var tokenProblem: String?
    /// `pkill` and Control-C end the agent with a signal, on which AppKit does not call `applicationWillTerminate`.
    private var signals: [DispatchSourceSignal] = []
    private var statusItem: NSStatusItem!
    private var pairingWindow: NSWindow?
    private lazy var faceUnlockWindow = FaceUnlockWindow(server: server)

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Remotey")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        endOnSignals()
        // A window the last run left in the phone's shape, when it crashed or was killed.
        ShapedFrame.restore()
        server.healthChanged = { [weak self] health in self?.show(health) }
        show(server.health)
        do {
            try server.start()
        } catch {
            alert("Remotey konnte nicht starten", "Port \(Server.port)/\(Server.port + 1): \(error.localizedDescription)")
            NSApp.terminate(nil)
        }
        // Shows the system prompt once if the permission is missing.
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Leaves the Mac as it was: a window that took the phone's shape for the live view gets its frame back.
    func applicationWillTerminate(_ notification: Notification) {
        server.stop()
    }

    /// Ends the agent in order on SIGTERM and SIGINT, so the window in the phone's shape gets its frame back.
    private func endOnSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN) // else the default action ends the process before the source hears it
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signals.append(source)
        }
    }

    /// A dimmed icon while the ports are not open; the menu says why.
    private func show(_ health: Server.Health) {
        statusItem?.button?.appearsDisabled = health != .listening
        if health != .listening { pairingWindow?.close() }
    }

    private var healthText: String {
        let ports = "Port \(Server.port)/\(Server.port + 1)"
        return switch server.health {
        case .starting: "Öffnet \(ports)…"
        case .listening: "Bereit auf \(ports)"
        case .failed(let reason): "Nicht erreichbar: \(reason). Neuer Versuch folgt."
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(withTitle: healthText, action: nil, keyEquivalent: "")
        if let tokenProblem { menu.addItem(withTitle: tokenProblem, action: nil, keyEquivalent: "") }
        if AXIsProcessTrusted() {
            menu.addItem(withTitle: "Bedienungshilfen: erlaubt", action: nil, keyEquivalent: "")
        } else {
            add(menu, "Bedienungshilfen fehlen, Einstellungen öffnen…", #selector(openAccessibilitySettings))
        }
        menu.addItem(.separator())
        // No pairing while nothing listens: the phone would get a link that leads nowhere.
        let listening = server.health == .listening
        add(menu, "iPhone koppeln (QR-Code)…", listening ? #selector(showPairing) : nil)
        add(menu, "Link kopieren", listening ? #selector(copyLink) : nil)
        add(menu, "Token erneuern (trennt alle Geräte)", #selector(rotateToken))
        menu.addItem(.separator())
        if server.unlocksWithFaceID {
            add(menu, "Entsperren mit Face ID entfernen", #selector(removeFaceUnlock))
        } else {
            add(menu, "Entsperren mit Face ID einrichten…", #selector(enrolFaceUnlock))
        }
        menu.addItem(.separator())
        let login = add(menu, "Beim Anmelden starten", #selector(toggleLoginItem))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: Actions

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func copyLink() {
        guard let link = pairingLink() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
        // The link carries the token: by this convention clipboard managers keep it out of their history.
        NSPasteboard.general.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    }

    @objc private func rotateToken() {
        do {
            server.token = try Token.rotate()
            tokenProblem = nil
        } catch {
            // The old token is still in the file, so it stays: a new one would be lost with the next start.
            return alert("Token nicht erneuert", "\(error). Der bisherige Token gilt weiter.")
        }
        pairingWindow?.close()
        guard server.health == .listening else { return }
        showPairing()
    }

    @objc private func enrolFaceUnlock() {
        faceUnlockWindow.show()
    }

    @objc private func removeFaceUnlock() {
        server.removeFaceUnlock()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            alert("Anmeldeobjekt konnte nicht geändert werden", error.localizedDescription)
        }
    }

    @objc private func showPairing() {
        guard let link = pairingLink() else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "iPhone koppeln"
        window.isReleasedWhenClosed = false

        let image = NSImageView(image: Self.qrCode(link))
        image.imageScaling = .scaleProportionallyUpOrDown
        let hint = NSTextField(wrappingLabelWithString:
            "Mit der iPhone-Kamera scannen (Tailscale muss auf dem iPhone verbunden sein), "
            + "dann in Safari über Teilen „Zum Home-Bildschirm“ wählen. "
            + "Der Link enthält den Zugangsschlüssel, nicht weitergeben.")
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [image, hint])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        image.heightAnchor.constraint(equalToConstant: 300).isActive = true
        image.widthAnchor.constraint(equalToConstant: 300).isActive = true
        window.contentView = stack
        window.center()
        pairingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Helpers

    private func pairingLink() -> String? {
        guard let host = Self.tailscaleHostname() else {
            alert("Tailscale nicht gefunden",
                  "Der Tailscale-Name dieses Macs ließ sich nicht ermitteln. Läuft Tailscale und ist es angemeldet?")
            return nil
        }
        return "https://\(host):\(Self.tailnetPort)/#\(server.token)"
    }

    /// MagicDNS name of this Mac, e.g. `mac.example.ts.net`.
    private static func tailscaleHostname() -> String? {
        let candidates = ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale",
                          "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let binary = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["status", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = json["Self"] as? [String: Any],
              let name = (me["DNSName"] as? String)?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !name.isEmpty else { return nil }
        return name
    }

    private static func qrCode(_ text: String) -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return NSImage() }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else {
            return NSImage()
        }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    private func alert(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

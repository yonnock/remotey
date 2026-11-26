import AppKit
import CoreImage
import XCTest
@testable import Remotey

/// The Mac's interface as it was before the menu panel, the assistant and the settings (commit 23b8eae), drawn
/// off screen with the same made-up data as InterfacePicturesTests. `scripts/mac-pictures.sh --before` copies
/// this file into a checkout of that commit and runs it there; it does not build against the current sources.
///
/// - The pairing window is built here line by line as `AppDelegate.showPairing` built it, since that method
///   ordered it on screen.
/// - The Face ID window is the real one: the script makes its `content` reachable, the rest is its own code.
/// - The menu was an NSMenu, which only draws while it is open on screen. Its items are the ones
///   `AppDelegate.menuNeedsUpdate` made for a Mac that listens, has Accessibility, no Face ID and no login item;
///   they are drawn here in the system's menu font and metrics: 22 points a line, disabled lines in the
///   tertiary label colour, separators, the key equivalent at the right edge.
@MainActor
final class BeforePicturesTests: XCTestCase {
    static let host = "macbook.example-tailnet.ts.net"
    static let digits = "482913"

    func testThePairingWindow() throws {
        for look in Pictures.Look.allCases {
            let link = Pairing.link(host: Self.host, code: "bWFkZS11cC1jb2RlLWZvci1waWN0dXJlcw")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 430),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "iPhone koppeln"
            window.isReleasedWhenClosed = false
            let image = NSImageView(image: Self.qrCode(link))
            image.imageScaling = .scaleProportionallyUpOrDown
            let digits = "\(Self.digits.prefix(3)) \(Self.digits.dropFirst(3))"
            let hint = NSTextField(wrappingLabelWithString:
                "Mit der iPhone-Kamera scannen (Tailscale muss auf dem iPhone verbunden sein), "
                + "dann in Safari über Teilen „Zum Home-Bildschirm“ wählen. "
                + "Ohne Link auf dem iPhone diesen Code eingeben: \(digits). Gilt fünf Minuten, für ein Gerät.")
            hint.font = .systemFont(ofSize: 12)
            hint.textColor = .secondaryLabelColor
            let stack = NSStackView(views: [image, hint])
            stack.orientation = .vertical
            stack.spacing = 12
            stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
            image.heightAnchor.constraint(equalToConstant: 300).isActive = true
            image.widthAnchor.constraint(equalToConstant: 300).isActive = true
            window.contentView = stack
            try Pictures.save(Pictures.shadowed(Pictures.window(window, look)), "pairing-\(look)")
            window.close()
        }
    }

    /// As `AppDelegate.qrCode` made it.
    private static func qrCode(_ text: String) -> NSImage {
        let filter = CIFilter(name: "CIQRCodeGenerator")!
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        let output = filter.outputImage!.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    func testTheFaceUnlockWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remotey-pictures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let server = Server(token: "picture-token-picture-token-picture", input: Input { _ in }, port: 47996,
                            faceUnlock: FaceUnlock(file: folder.appendingPathComponent("face-unlock")),
                            devices: Devices(file: folder.appendingPathComponent("devices")),
                            permissions: { (true, true) }, activity: {})
        for look in Pictures.Look.allCases {
            let faceUnlock = FaceUnlockWindow(server: server, check: { _ in .right })
            // `show()` without ordering the window in.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300 + 48, height: 260),
                                  styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Entsperren mit Face ID"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = faceUnlock.content
            window.appearance = look.appearance
            faceUnlock.set(.password())
            faceUnlock.content.layoutSubtreeIfNeeded()
            window.setContentSize(faceUnlock.content.fittingSize)
            try Pictures.save(Pictures.shadowed(Pictures.window(window, look)), "faceid-\(look)")
            window.close()
        }
    }

    func testTheMenu() throws {
        // (title, enabled, checked, key equivalent); nil is a separator.
        let items: [(String, Bool, Bool, String)?] = [
            ("Bereit auf Port 47800/47801", false, false, ""),
            ("Bedienungshilfen: erlaubt", false, false, ""),
            nil,
            ("iPhone koppeln (QR-Code)…", true, false, ""),
            ("Link kopieren", true, false, ""),
            ("Alle trennen (neuer Token, Geräte entfernen)", true, false, ""),
            nil,
            ("Entsperren mit Face ID einrichten…", true, false, ""),
            nil,
            ("Beim Anmelden starten", true, false, ""),
            nil,
            ("Beenden", true, false, "⌘Q"),
        ]
        for look in Pictures.Look.allCases {
            let content = NSImage(size: Self.menuSize(items), flipped: true) { rect in
                NSAppearance(named: look == .light ? .aqua : .darkAqua)!.performAsCurrentDrawingAppearance {
                    Self.drawMenu(items, in: rect)
                }
                return true
            }
            let symbol = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: nil)!
                .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))!
            try Pictures.save(Pictures.menu(content, symbol: symbol, look, radius: 10), "menu-\(look)")
        }
    }

    private static let font = NSFont.menuFont(ofSize: 0)
    private static let line: CGFloat = 22, separator: CGFloat = 11, inset: CGFloat = 5, leading: CGFloat = 24

    private static func menuSize(_ items: [(String, Bool, Bool, String)?]) -> NSSize {
        let widest = items.compactMap { $0 }.map { ($0.0 as NSString).size(withAttributes: [.font: font]).width + ($0.3.isEmpty ? 0 : 40) }.max() ?? 0
        let height = items.reduce(2 * inset) { $0 + ($1 == nil ? separator : line) }
        return NSSize(width: ceil(leading + widest + 20), height: height)
    }

    private static func drawMenu(_ items: [(String, Bool, Bool, String)?], in rect: NSRect) {
        var y = inset
        for item in items {
            guard let (title, enabled, checked, key) = item else {
                NSColor.separatorColor.setFill()
                NSRect(x: 10, y: y + separator / 2, width: rect.width - 20, height: 1).fill()
                y += separator
                continue
            }
            let color = enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            let height = (title as NSString).size(withAttributes: attributes).height
            (title as NSString).draw(at: NSPoint(x: leading, y: y + (line - height) / 2), withAttributes: attributes)
            if checked { ("✓" as NSString).draw(at: NSPoint(x: 9, y: y + (line - height) / 2), withAttributes: attributes) }
            if !key.isEmpty {
                let keyAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
                let width = (key as NSString).size(withAttributes: keyAttributes).width
                (key as NSString).draw(at: NSPoint(x: rect.width - 14 - width, y: y + (line - height) / 2), withAttributes: keyAttributes)
            }
            y += line
        }
    }
}

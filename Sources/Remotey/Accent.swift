import AppKit
import SwiftUI

/// Remotey's accent: the orange of its icon and of the phone's page, used where macOS would use an app's own
/// accent colour. As macOS does for an app that names one, it stands only while the user leaves the system's
/// accent at Multicolor; a colour the user picked wins.
enum Accent {
    /// Whether the user picked an accent colour in System Settings. Multicolor, the default, writes no value.
    /// The pictures set it, so they show the same colour on every Mac.
    nonisolated(unsafe) static var userChoseColor: () -> Bool = { UserDefaults.standard.object(forKey: "AppleAccentColor") != nil }

    /// The system's orange: #ff9500 light, #ff9f0a dark, the page's `--c-accent`.
    static var nsColor: NSColor { userChoseColor() ? .controlAccentColor : .systemOrange }
    static var color: Color { Color(nsColor: nsColor) }

    /// Behind a highlighted menu row, under white text: the orange a step darker, as macOS darkens an accent
    /// for a selection. White on it has a contrast of 3.4 to 1; on the plain orange it would be 2.2.
    static var selection: NSColor {
        userChoseColor() ? .selectedContentBackgroundColor : NSColor(srgbRed: 0.86, green: 0.43, blue: 0, alpha: 1)
    }
}

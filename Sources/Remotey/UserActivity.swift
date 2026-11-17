import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Tells the Mac that its user is active, as a key on its own keyboard does: a display that sleeps powers
/// on, and one that is on stays on for its usual time. Posted events do neither. A sleeping display takes
/// them without lighting up, and without a display there is nothing to capture (measured on macOS 27).
/// Main thread only.
enum UserActivity {
    private static var assertion = IOPMAssertionID(0)
    private static var declared = -TimeInterval.infinity
    /// A pointer move comes a hundred times a second; the display's sleep timer counts in minutes.
    private static let interval: TimeInterval = 1

    static func declare() {
        let now = ProcessInfo.processInfo.systemUptime
        // A display that went to sleep since the last call is woken at once.
        guard now - declared >= interval || CGDisplayIsAsleep(CGMainDisplayID()) != 0 else { return }
        declared = now
        IOPMAssertionDeclareUserActivity("Remotey: input from the phone" as CFString, kIOPMUserActiveLocal, &assertion)
    }
}

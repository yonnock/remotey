import CoreGraphics
import ServiceManagement
import XCTest
@testable import Remotey

final class PermissionsTests: XCTestCase {
    private func window(_ pid: pid_t, _ name: String?) -> [String: Any] {
        var window: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid), kCGWindowLayer as String: 0]
        if let name { window[kCGWindowName as String] = name }
        return window
    }

    /// 1 is Remotey, 2 and 3 are apps, 9 is a system process such as WindowManager.
    private func visible(_ windows: [[String: Any]]) -> Bool? {
        Permissions.titlesVisible(in: windows, ownPID: 1, isApp: { [2, 3].contains($0) })
    }

    func testAnotherAppsTitleMeansThePermissionIsThere() {
        XCTAssertEqual(visible([window(2, nil), window(3, "")]), true, "an empty title counts: it is only there with the permission")
    }

    func testAppsWithoutTitlesMeanItIsNot() {
        XCTAssertEqual(visible([window(2, nil), window(3, nil)]), false)
        XCTAssertEqual(visible([window(9, "Fenster"), window(2, nil)]), false, "a system process keeps its title without it")
        XCTAssertEqual(visible([window(1, "Remotey"), window(2, nil)]), false, "its own windows tell nothing")
    }

    func testWithoutAnotherAppsWindowNothingIsKnown() {
        XCTAssertNil(visible([]))
        XCTAssertNil(visible([window(1, "Remotey"), window(9, "Fenster")]))
    }

    func testARestartIsNeededOnlyWhenTheGrantCameAfterTheStart() {
        XCTAssertTrue(Permissions.ScreenRecording(granted: true, preflight: false).needsRestart)
        XCTAssertFalse(Permissions.ScreenRecording(granted: true, preflight: true).needsRestart)
        XCTAssertFalse(Permissions.ScreenRecording(granted: false, preflight: false).needsRestart)
    }

    func testTheLoginItemHasFourStates() {
        XCTAssertEqual(LoginItem.state(.enabled), .on)
        XCTAssertEqual(LoginItem.state(.notRegistered), .off)
        XCTAssertEqual(LoginItem.state(.requiresApproval), .needsApproval)
        XCTAssertEqual(LoginItem.state(.notFound), .unavailable)
    }
}

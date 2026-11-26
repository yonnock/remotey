import OpenDirectory
import XCTest
@testable import Remotey

/// What the window does with a password typed into it. The directory is not asked here: a wrong password
/// would count as a failed login on this Mac.
final class FaceUnlockWindowTests: XCTestCase {
    func testAPasswordTheDirectoryTakesIsSealedAndOneItRefusesIsNot() {
        XCTAssertEqual(FaceUnlockWindow.judge("geheim", verdict: .right, earlier: nil), .seal)
        XCTAssertEqual(FaceUnlockWindow.judge("geheim", verdict: .wrong, earlier: nil), .refuse("Das ist nicht das Passwort dieses Macs."))
    }

    /// A directory that cannot be asked no longer lets every typo through: the password is typed twice.
    func testAPasswordTheDirectoryCannotCheckIsSealedOnlyIfTypedTheSameTwice() {
        XCTAssertEqual(FaceUnlockWindow.judge("geheim", verdict: .unknown, earlier: nil), .confirm)
        XCTAssertEqual(FaceUnlockWindow.judge("geheim", verdict: .unknown, earlier: "geheim"), .seal)
        XCTAssertEqual(FaceUnlockWindow.judge("geheimm", verdict: .unknown, earlier: "geheim"), .refuse("Die beiden Eingaben waren verschieden."))
        XCTAssertEqual(FaceUnlockWindow.judge("geheimm", verdict: .right, earlier: "geheim"), .refuse("Die beiden Eingaben waren verschieden."),
                       "the second entry is compared, whatever the directory would say")
    }

    func testOnlyInvalidCredentialsSayThatThePasswordIsWrong() {
        let invalid = NSError(domain: ODFrameworkErrorDomain, code: Int(kODErrorCredentialsInvalid.rawValue))
        XCTAssertEqual(FaceUnlockWindow.verdict(invalid), .wrong)
        for error in [NSError(domain: ODFrameworkErrorDomain, code: Int(kODErrorCredentialsAccountLocked.rawValue)),
                      NSError(domain: ODFrameworkErrorDomain, code: Int(kODErrorCredentialsServerUnreachable.rawValue)),
                      NSError(domain: NSCocoaErrorDomain, code: Int(kODErrorCredentialsInvalid.rawValue))] {
            XCTAssertEqual(FaceUnlockWindow.verdict(error), .unknown, "\(error)")
        }
    }
}

import XCTest
@testable import Remotey

/// The runner against /bin/sh, the one tool every Mac has.
final class CommandTests: XCTestCase {
    func testStdoutStderrAndStatusComeBackApart() {
        let result = Command.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], limit: 5, output: nil)
        XCTAssertEqual(result, Command.Result(status: 3, stdout: "out\n", stderr: "err\n"))
        XCTAssertFalse(result.succeeded)
    }

    func testAToolThatHangsIsStoppedAtItsLimit() {
        let start = Date()
        let result = Command.run("/bin/sh", ["-c", "echo started; sleep 30"], limit: 0.5, output: nil)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(result.stdout, "started\n", "what it printed before stays")
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
    }

    func testOutputArrivesWhileTheToolStillRuns() {
        let seen = expectation(description: "link printed")
        var finished = false
        DispatchQueue.global().async {
            _ = Command.run("/bin/sh", ["-c", "echo https://example.com/consent; sleep 2"], limit: 5) { chunk in
                if chunk.contains("https://example.com/consent") { seen.fulfill() }
            }
            finished = true
        }
        wait(for: [seen], timeout: 1.5)
        XCTAssertFalse(finished, "the link came before the tool ended")
    }

    func testAToolThatIsNotThereFails() {
        let result = Command.run("/nonexistent/tool", [], limit: 1, output: nil)
        XCTAssertEqual(result.status, 127)
    }
}

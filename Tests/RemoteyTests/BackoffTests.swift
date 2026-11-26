import XCTest
@testable import Remotey

final class BackoffTests: XCTestCase {
    func testTheWaitDoublesUpToTheLongestAndStartsOverAfterASuccess() {
        var backoff = Backoff(first: 1, longest: 30)
        XCTAssertEqual((0..<7).map { _ in backoff.failed() }, [1, 2, 4, 8, 16, 30, 30])
        XCTAssertEqual(backoff.failures, 7)
        backoff.reset()
        XCTAssertEqual(backoff.failed(), 1)
        for _ in 0..<100 { _ = backoff.failed() }
        XCTAssertEqual(backoff.failed(), 30, "no overflow after many failures")
    }
}

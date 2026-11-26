import Foundation

/// Waits between tries of something that keeps failing: each failure in a row doubles the wait, up to `longest`.
/// A success starts over at `first`.
struct Backoff {
    let first: TimeInterval
    let longest: TimeInterval
    /// Failures since the last success.
    private(set) var failures = 0

    init(first: TimeInterval, longest: TimeInterval) {
        self.first = first
        self.longest = max(first, longest)
    }

    /// Counts a failure and returns how long to wait before the next try.
    mutating func failed() -> TimeInterval {
        defer { failures += 1 }
        return min(first * pow(2, Double(min(failures, 30))), longest)
    }

    mutating func reset() { failures = 0 }
}

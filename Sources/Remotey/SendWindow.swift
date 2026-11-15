import Foundation

/// Bounds the pictures that are sent but not yet shown on the phone. Sockets and proxies on the way
/// buffer megabytes, so only the phone can tell whether it keeps up: it answers every picture it has
/// drawn or discarded. A slow link or phone then lowers the frame rate instead of building up delay.
///
/// The bound is a time, not a number of pictures. Wi-Fi holds a phone's packets back and hands them over
/// in a burst (power save, aggregation): 30 `tailscale ping`s to an iPhone on the same network took 16 to
/// 777 ms, median 104 ms. A window of at most six pictures shut with every such hold, which held a 60 fps
/// view at 6 pictures per round trip: 30 fps for 200 ms. And six large pictures on a slow link stood for
/// a second of delay. A time bounds the delay whatever the size of the pictures.
struct SendWindow {
    /// How much longer than its fastest answer the phone may take before no further picture leaves.
    /// On a link too slow for the stream this is the delay that builds up, on top of the fastest answer.
    static let slack: TimeInterval = 0.2
    /// Never more pictures under way than this, whatever the times say.
    static let most = 64

    private var underWay: [UInt32: TimeInterval] = [:]
    /// The shortest time the phone took to answer: the way there, decoding, drawing and the way back.
    private var fastestAnswer = TimeInterval.infinity
    private var last: UInt32 = 0

    /// Whether another picture may leave now. Two let the next one travel while one decodes, and are all
    /// until the phone has answered once. Then pictures leave as long as the oldest one under way is
    /// younger than the fastest answer plus `slack`.
    func isOpen(now: TimeInterval) -> Bool {
        guard underWay.count >= 2 else { return true }
        guard fastestAnswer.isFinite, underWay.count < Self.most, let oldest = underWay.values.min() else { return false }
        return now - oldest < fastestAnswer + Self.slack
    }

    /// A picture leaves now. Returns its number, which the phone answers with.
    mutating func send(now: TimeInterval) -> UInt32 {
        last &+= 1
        underWay[last] = now
        return last
    }

    /// The phone answered a picture. False if none with this number is under way.
    mutating func answered(_ number: UInt32, now: TimeInterval) -> Bool {
        guard let left = underWay.removeValue(forKey: number) else { return false }
        fastestAnswer = min(fastestAnswer, max(0, now - left))
        return true
    }

    /// A numbered picture was not sent after all. False if none with this number is under way.
    mutating func withdraw(_ number: UInt32) -> Bool {
        underWay.removeValue(forKey: number) != nil
    }

    /// For `REMOTEY_STATS`.
    var description: String {
        "under way \(underWay.count), fastest answer " + (fastestAnswer.isFinite ? "\(Int(fastestAnswer * 1000)) ms" : "none")
    }

    /// For a new viewer: the old one may never answer. Numbers go on, so a late answer of the old one fits no new picture.
    mutating func reset() {
        underWay.removeAll()
        fastestAnswer = .infinity
    }
}

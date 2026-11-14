import Foundation

/// Bounds the pictures that are sent but not yet shown on the phone. Sockets and proxies on the way
/// buffer megabytes, so only the phone can tell whether it keeps up: it answers every picture it has
/// drawn or discarded. A slow link or phone then lowers the frame rate instead of building up delay.
struct SendWindow {
    /// Never more than this many pictures under way, however slow the answers.
    static let most = 6

    private var underWay: [UInt32: TimeInterval] = [:]
    /// The shortest time the phone took to answer: the way there, decoding, drawing and the way back.
    private var fastestAnswer = TimeInterval.infinity
    private var last: UInt32 = 0

    /// Whether another picture may leave. Two let the next one travel while one decodes. A phone whose
    /// answers take several frame intervals even at its best gets that many more, or the wait for
    /// answers would hold the frame rate down.
    func isOpen(framesPerSecond: Int32) -> Bool {
        let extra = fastestAnswer.isFinite ? Int(fastestAnswer * Double(framesPerSecond)) : 0
        return underWay.count < min(Self.most, 2 + extra)
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

    /// For a new viewer: the old one may never answer. Numbers go on, so a late answer of the old one fits no new picture.
    mutating func reset() {
        underWay.removeAll()
        fastestAnswer = .infinity
    }
}

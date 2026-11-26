import Foundation

/// Fits the stream's bit rate to the link, from the phone's answers alone.
///
/// A link that carries less than the stream holds pictures in a queue: `SendWindow` then lowers the frame
/// rate, but the encoder spends its bit rate on the pictures that are left, so each one is larger and the
/// queue stays. Over a relay (Tailscale's DERP, when no direct connection comes about) that is a quarter
/// second of delay at a third of the frame rate. With a bit rate below what the link carries the queue is
/// empty: more pictures, each one fresh.
///
/// The link is judged once it has been busy for `interval`. Pictures queue on it when three things hold:
///
/// - Even the promptest answer of that time came later than the fastest one so far by `queued`. One late
///   answer says nothing: Wi-Fi and mobile links hold packets back for hundreds of milliseconds, and the
///   answers before and after such a hold are prompt. A queue makes every answer late.
/// - The answers came evenly. A link at its limit hands pictures over at the rate it carries and never
///   faster. One that held packets back hands them over at once, faster than they were sent: it has the room,
///   and a lower bit rate would cost sharpness and gain nothing. So a link whose fastest `span` carried more
///   than `burst` times its average has no queue, however late its answers are.
/// - The stream used at least half its bit rate, or pictures had to wait for the send window. Else the
///   stream is not what fills the link, and its bit rate not what would empty it. Where pictures waited and
///   no more than `few` answers came, their coming evenly says little: one small picture that a link held
///   back for most of a second is no link at its limit. That counts the second time in a row.
///
/// The first answers have no faster one to be late against. They are late by what they took beyond
/// `longestWay`: the first picture is a key frame of 150 to 300 KB, which a slow link carries for seconds.
/// `SendWindow` then lets the link run empty once, so the answers after that show how fast the phone answers.
///
/// A queue shows what the link carries, the bits answered while it was busy, and the bit rate goes a little
/// below that, by half at most at once. Below what the link carried, a queue drains. If the answers are
/// still late after `patience` more intervals, it was none: they are late for another reason, a longer way
/// since the phone changed its cell or its relay. Then the answers as they come now are the measure, and
/// the bit rate goes no lower for them.
///
/// Without a queue the bit rate rises while the stream uses it, so a link that got better is found again: by
/// `creep` near what the link last carried, by `rise` away from it. So the rate swings around what the link
/// carries, slowly, and the queue it finds that with is a fraction of what `SendWindow` allows.
struct LinkRate {
    /// The bit rate on a link that carries it, and the lowest one.
    static let most = 4_000_000.0
    static let least = 250_000.0
    /// The link is judged over this much time with pictures under way.
    static let interval: TimeInterval = 0.5
    /// Pictures queue on the link when the promptest answer is this much later than the fastest.
    static let queued: TimeInterval = 0.06
    /// The shortest time over which a link shows how fast it can hand pictures over, and how much faster than
    /// its average that is on a link that held them back. The span is several frames of the phone, which
    /// answers a picture when it draws it.
    static let span: TimeInterval = 0.1
    static let burst = 1.5
    /// With more answers than this, their coming evenly says something.
    static let few = 4
    /// The share of what the link carried that the stream may use.
    static let share = 0.85
    static let rise = 1.05
    static let creep = 1.01
    /// How far around what the link last carried the rate creeps.
    static let near = 0.8...1.15
    /// A queue is gone this many intervals after the bit rate went below what the link carried.
    static let patience = 3
    /// The way to the phone and back takes no longer than this on a link that carries a live view.
    static let longestWay: TimeInterval = 0.3

    private(set) var bitsPerSecond = most
    private var underWay = 0
    /// Since when the link is busy, and the time it was busy before that since it was last judged.
    private var busySince: TimeInterval?
    private var busy: TimeInterval = 0
    /// The answers since the link was last judged, after the last one before that or the time the link got busy.
    private var answers: [(at: TimeInterval, bits: Double)] = []
    private var promptest = TimeInterval.infinity
    /// What the link carried when pictures last queued on it.
    private var carriedLast: Double?
    /// The bit rate went below what the link carried, which was this much, and the link was judged this
    /// often since.
    private var trial: (carried: Double, intervals: Int)?
    /// A picture had to wait for the send window since the link was last judged.
    private var waited = false
    /// The fastest answer so far, or since the way to the phone was found to have become longer.
    private var fastest = TimeInterval.infinity
    /// The link last looked at its limit with too few answers to tell.
    private var doubted = false
    /// The link was judged before: there are answers to compare with.
    private var judged = false

    /// A picture leaves.
    mutating func sent(now: TimeInterval) {
        if underWay == 0 { busySince = now }
        underWay += 1
    }

    /// A picture is due and has to wait: the send window is shut.
    mutating func waits() {
        waited = true
    }

    /// The stream starts over with a key frame, at another size. What comes late after that is late for the
    /// key frame, so a queue has its time to drain again.
    mutating func restarts() {
        trial?.intervals = 0
    }

    /// A picture that left was not sent after all.
    mutating func withdrawn(now: TimeInterval) {
        underWay = max(0, underWay - 1)
        if underWay == 0, let since = busySince {
            busy += now - since
            busySince = nil
        }
    }

    /// The phone answered a picture of `bytes` after `took`. True if the bit rate changed.
    mutating func answered(after took: TimeInterval, bytes: Int, now: TimeInterval) -> Bool {
        fastest = min(fastest, took)
        promptest = min(promptest, took)
        if answers.isEmpty { answers.append((busySince ?? now, 0)) }
        answers.append((now, Double(bytes) * 8))
        let since = busySince ?? now
        underWay = max(0, underWay - 1)
        busySince = underWay > 0 ? since : nil
        let time = busy + now - since
        if underWay == 0 { busy = time }
        guard time >= Self.interval else { return false }

        let carried = answers.dropFirst().reduce(0) { $0 + $1.bits } / time, was = bitsPerSecond
        let late = promptest - min(fastest, judged ? .infinity : Self.longestWay)
        let doubtedBefore = doubted
        doubted = false
        if late > Self.queued, peak <= carried * Self.burst {
            if let waiting = trial, bitsPerSecond <= waiting.carried * Self.share {
                trial?.intervals += 1
                if waiting.intervals + 1 >= Self.patience {
                    // What is left of a queue after all would show: the fastest answer follows it down.
                    fastest = promptest
                    carriedLast = nil // nor was that what the link carries
                    trial = nil
                }
            } else if carried < bitsPerSecond / 2, judged, waited, answers.count - 1 <= Self.few, !doubtedBefore {
                doubted = true
            } else if carried >= bitsPerSecond / 2 || waited {
                // No lower than half at once: what looks like a link that carries little may be one hold.
                bitsPerSecond = max(Self.least, min(bitsPerSecond, max(bitsPerSecond / 2, carried * Self.share)))
                carriedLast = carried
                trial = bitsPerSecond <= carried * Self.share ? (carried, 0) : nil
            }
        } else if late <= Self.queued {
            trial = nil
            // Only a stream that uses its bit rate shows that the link carries it.
            if carried >= bitsPerSecond / 2 {
                let creeps = carriedLast.map { Self.near.contains(bitsPerSecond / $0) } ?? false
                bitsPerSecond = min(Self.most, bitsPerSecond * (creeps ? Self.creep : Self.rise))
            }
        }
        judged = true
        waited = false
        busy = 0
        busySince = underWay > 0 ? now : nil
        answers = [(now, 0)]
        promptest = .infinity
        return bitsPerSecond != was
    }

    /// The most bits a second the link handed over among `answers`: the bits of the pictures answered in a
    /// stretch of time, over the time since the answer before them. A stretch shorter than `span` counts as
    /// that long, so the answers of one moment are no rate beyond measure, and a link at its limit never
    /// shows more than it carries.
    private var peak: Double {
        var peak = 0.0
        for first in answers.indices {
            var bits = 0.0
            for last in answers.indices.dropFirst(first + 1) {
                bits += answers[last].bits
                peak = max(peak, bits / max(answers[last].at - answers[first].at, Self.span))
            }
        }
        return peak
    }

    /// The least bits a second for every pixel of a picture. Below that the encoder has too little for a
    /// picture in motion, and fewer pixels show more.
    static let bitsPerPixel = 0.75
    /// The shares of its full width a picture is sent at.
    static let sizes = [1, 0.75, 0.5]
    /// A larger picture comes back once the bit rate is this much above what it needs, so a rate that
    /// swings around a threshold does not restart the stream with every swing.
    static let headroom = 1.5

    /// The share of its full width a picture of `pixels` (at full width) is sent at with `bitsPerSecond`,
    /// when it is sent at `size` now.
    static func size(now size: Double, pixels: Double, bitsPerSecond: Double) -> Double {
        func needs(_ size: Double) -> Double { pixels * size * size * bitsPerPixel }
        let fits = sizes.first { bitsPerSecond >= needs($0) } ?? sizes.last!
        guard fits > size else { return fits }
        // Larger than now: only as far as the bit rate has room to spare.
        return sizes.first { $0 <= size || bitsPerSecond >= needs($0) * headroom } ?? size
    }
}

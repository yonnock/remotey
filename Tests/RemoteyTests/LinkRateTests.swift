import XCTest
@testable import Remotey

final class LinkRateTests: XCTestCase {
    /// A stream as `ScreenView` runs it, over a modelled link: a picture every 60th of a second while the
    /// send window is open. The encoder gives a picture the bits of its bit rate for the time since the last
    /// one, up to two frames' worth, as measured: on a link of 1 to 3 Mbit/s, pictures at 15 to 27 a second
    /// had 8.5 to 14 KB with 4 Mbit/s, where a 60th of a second has 8.3 KB. The first picture is a key frame
    /// of 250 KB.
    /// The link carries `capacity` bits a second, one picture after the other, and the answer is back
    /// `way(now)` after that.
    private struct Stream {
        var rate = LinkRate()
        var window = SendWindow()
        var now = 100.0
        private var free = 0.0, lastSent = 0.0
        private var answers: [(at: Double, number: UInt32)] = []
        /// How long each answer took, and the bit rate after each second.
        private(set) var took: [Double] = []
        private(set) var rates: [Double] = []

        /// `light`: the pictures change little, 1 KB each, as when the view pans over a still screen.
        mutating func run(seconds: Double, capacity: Double, moving: Bool = true, light: Bool = false,
                          way: (Double) -> Double = { _ in 0.03 }) {
            let end = now + seconds
            var second = now + 1
            while now < end {
                // An answer never overtakes the one before, as on one connection.
                while let answer = answers.first, answer.at <= now {
                    answers.removeFirst()
                    guard let picture = window.answered(answer.number, now: answer.at) else { continue }
                    took.append(picture.after)
                    _ = rate.answered(after: picture.after, bytes: picture.bytes, now: answer.at)
                }
                // A still screen sends a small picture twice a second.
                let due = moving || now - lastSent >= 0.5
                if due, !window.isOpen(now: now) { rate.waits() }
                if due, window.isOpen(now: now) {
                    let bits = lastSent == 0 ? 2_000_000 : light ? 8000 : moving ? rate.bitsPerSecond * min(now - lastSent, 1.0 / 30) : 4000
                    let number = window.send(Int(bits / 8), now: now)
                    rate.sent(now: now)
                    free = max(free, now) + bits / capacity
                    answers.append((max(free + way(now), answers.last?.at ?? 0), number))
                    lastSent = now
                }
                now += 1.0 / 60
                if now >= second {
                    rates.append(rate.bitsPerSecond)
                    second += 1
                }
            }
        }

        mutating func forget() {
            took = []
            rates = []
        }
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    func testALinkThatCarriesTheStreamKeepsItsBitRate() {
        var stream = Stream()
        stream.run(seconds: 20, capacity: 50_000_000)
        XCTAssertEqual(stream.rates.min(), LinkRate.most)
    }

    func testOnALinkThatCarriesLessTheBitRateGoesBelowWhatItCarries() {
        for capacity in [3_000_000.0, 1_500_000, 600_000] {
            var stream = Stream()
            stream.run(seconds: 12, capacity: capacity)
            stream.forget()
            stream.run(seconds: 30, capacity: capacity)
            XCTAssertLessThan(median(stream.rates), capacity, "\(capacity)")
            XCTAssertGreaterThan(stream.rates.min()!, capacity * 0.6, "the link is used: \(capacity)")
            XCTAssertLessThan(stream.rates.max()!, capacity * 1.25, "\(capacity)")
            // 30 ms is the way there and back. The queue that the send window alone allows adds 200 ms to it.
            XCTAssertLessThan(median(stream.took), 0.03 + 0.03, "no queue most of the time: \(capacity)")
            XCTAssertLessThan(stream.took.max()!, 0.03 + 0.15, "and a short one when the bit rate finds what the link carries: \(capacity)")
        }
    }

    func testTheFirstPictureAlreadyShowsASlowLink() {
        // The key frame takes two seconds on a link of 1 Mbit/s.
        var stream = Stream()
        stream.run(seconds: 4, capacity: 1_000_000)
        XCTAssertLessThan(stream.rate.bitsPerSecond, 1_200_000, "two seconds after the key frame arrived")
        XCTAssertGreaterThan(stream.rate.bitsPerSecond, 600_000, "what the link carried, not the lowest bit rate")
        // Without a faster answer to compare with, the key frame's own time is what shows it.
        var other = Stream()
        other.run(seconds: 1.2, capacity: 3_000_000)
        XCTAssertLessThan(other.rate.bitsPerSecond, 3_600_000, "half a second after a key frame that took two thirds of one")
        // On a link that carries it, the same key frame says nothing.
        var fast = Stream()
        fast.run(seconds: 4, capacity: 50_000_000) { _ in 0.25 }
        XCTAssertEqual(fast.rate.bitsPerSecond, LinkRate.most, "a long way to the phone and back is no slow link")
    }

    func testALongWayToThePhoneAndBackIsNoQueue() {
        // Half a second for every answer, on a link with room for the stream: late by any measure at first.
        var stream = Stream()
        stream.run(seconds: 30, capacity: 50_000_000) { _ in 0.5 }
        XCTAssertGreaterThan(stream.rates.min()!, LinkRate.most / 2, "one step down for the first answers, no more")
        XCTAssertEqual(stream.rate.bitsPerSecond, LinkRate.most)
    }

    func testWithoutTheFitTheQueueStaysAsLongAsTheSendWindowAllows() {
        // What the test above guards against, shown with the same model: pictures of the full bit rate.
        var window = SendWindow(), free = 0.0, lastSent = 100.0, took: [Double] = []
        var answers: [(at: Double, number: UInt32)] = []
        for step in 0..<1800 {
            let now = 100 + Double(step) / 60
            while let answer = answers.first, answer.at <= now {
                answers.removeFirst()
                if let picture = window.answered(answer.number, now: answer.at) { took.append(picture.after) }
            }
            guard step > 0, window.isOpen(now: now) else { continue }
            let bits = LinkRate.most * min(now - lastSent, 1.0 / 30)
            free = max(free, now) + bits / 1_500_000
            answers.append((free + 0.03, window.send(Int(bits / 8), now: now)))
            lastSent = now
        }
        XCTAssertGreaterThan(median(took), 0.03 + 0.15)
    }

    func testALinkThatHoldsPacketsBackHasNoQueue() {
        // Wi-Fi power save, a mobile cell: nothing for 400 ms, then all of it at once. And for 800 ms, longer
        // than the link is judged over: no answer of that time is prompt, but they all come together.
        for (hold, every) in [(0.4, 1.5), (0.8, 3.0)] {
            var stream = Stream()
            stream.run(seconds: 30, capacity: 50_000_000) { now in
                let phase = now.truncatingRemainder(dividingBy: every)
                return phase < hold ? 0.03 + hold - phase : 0.03
            }
            XCTAssertEqual(stream.rates.min(), LinkRate.most, "held for \(hold) s")
        }
    }

    func testAStallAtTheStartCostsOneStep() {
        // The first answer after 1.7 s, as the relay's first ping took: no telling from a slow link yet.
        var stream = Stream()
        stream.run(seconds: 20, capacity: 50_000_000) { now in max(0.03, 101.7 - now) }
        XCTAssertGreaterThanOrEqual(stream.rates.min()!, LinkRate.most / 2, "half at most, not what one stalled picture seems to show")
        XCTAssertEqual(stream.rate.bitsPerSecond, LinkRate.most)
    }

    func testALinkThatDelaysEveryPictureByAnotherTimeHasNoQueue() {
        // What `tailscale ping` measured to an idle iPhone on Wi-Fi, drawn anew for every picture. Hardly an
        // answer is prompt, but the link hands over at once what it held back.
        let pings = [170, 213, 23, 224, 38, 141, 231, 106, 96, 102, 72, 159, 115, 17, 333, 67, 69, 16, 117, 64, 136, 104, 777, 46, 135,
                     18, 17, 16, 20, 19]
        var stream = Stream(), seed: UInt32 = 1
        func ping() -> Double {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Double(pings[Int(seed >> 16) % pings.count]) / 1000
        }
        stream.run(seconds: 60, capacity: 50_000_000) { _ in ping() }
        XCTAssertGreaterThan(stream.rates.min()!, LinkRate.most / 2)
        XCTAssertGreaterThan(median(stream.rates), LinkRate.most * 0.9)
        // Nor with pictures that change little. Then the stream never shows that the link has room for
        // more, and only the way the answers come says that it does: all at once after each hold.
        var light = Stream()
        light.run(seconds: 60, capacity: 50_000_000, light: true) { _ in ping() }
        XCTAssertEqual(light.rates.min(), LinkRate.most)
    }

    /// Answers as given, without a model of the link: from `start` for `seconds`, 60 pictures a second, each
    /// answered after `took`, with `carried` bits a second between them (nil: what the bit rate asks for).
    /// Answers later than the send window allows had pictures waiting.
    private func answers(_ rate: inout LinkRate, from start: Int, seconds: Int, took: Double, carried: Double? = nil) {
        var under: [(at: Double, bytes: Int)] = []
        for step in 0..<(seconds * 60 + 30) {
            let now = Double(start) + Double(step) / 60
            while let answer = under.first, answer.at <= now {
                under.removeFirst()
                _ = rate.answered(after: took, bytes: answer.bytes, now: answer.at)
            }
            guard step < seconds * 60 else { continue }
            if took > 0.03 + SendWindow.slack { rate.waits() }
            rate.sent(now: now)
            under.append((now + took, Int((carried ?? rate.bitsPerSecond) / 60 / 8)))
        }
    }

    /// A link that carried 1 Mbit/s with answers a quarter second late, after the bit rate went below that.
    private func afterAQueue() -> LinkRate {
        var rate = LinkRate()
        answers(&rate, from: 0, seconds: 1, took: 0.03, carried: 1_000_000)
        answers(&rate, from: 2, seconds: 2, took: 0.28, carried: 1_000_000)
        XCTAssertEqual(rate.bitsPerSecond, 850_000, accuracy: 2000, "below what the link carried")
        return rate
    }

    func testAQueueHasTimeToDrainBeforeLateAnswersAreTakenForALongerWay() {
        // As late for another second, though the link now carries what the stream sends: a queue takes that
        // long to drain. The bit rate goes no lower for that, and no higher yet.
        var rate = afterAQueue()
        answers(&rate, from: 5, seconds: 1, took: 0.28)
        XCTAssertEqual(rate.bitsPerSecond, 850_000, accuracy: 2000)
        // Still as late seconds later: no queue. The answers as they come are the measure, and the bit rate rises.
        answers(&rate, from: 7, seconds: 4, took: 0.28)
        XCTAssertGreaterThan(rate.bitsPerSecond, 1_000_000)
    }

    func testAQueueThatDrainsLeavesWhatTheLinkCarriedAsTheMeasure() {
        // Late for a second more, then prompt. That was a queue: the bit rate creeps towards what the link carried.
        var rate = afterAQueue()
        answers(&rate, from: 5, seconds: 1, took: 0.28)
        answers(&rate, from: 7, seconds: 2, took: 0.03)
        XCTAssertGreaterThan(rate.bitsPerSecond, 850_000)
        XCTAssertLessThan(rate.bitsPerSecond, 900_000, "taken for a longer way after one late interval, it would rise five times as fast")
    }

    func testAStreamThatStartsOverGivesItsQueueTheTimeAgain() {
        // Another size, another key frame: what is late after it is late for that.
        var rate = afterAQueue(), other = afterAQueue()
        answers(&rate, from: 5, seconds: 1, took: 0.28)
        answers(&other, from: 5, seconds: 1, took: 0.28)
        rate.restarts()
        answers(&rate, from: 7, seconds: 2, took: 0.28)
        answers(&other, from: 7, seconds: 2, took: 0.28)
        XCTAssertEqual(rate.bitsPerSecond, 850_000, accuracy: 2000, "no lower, and not yet taken for a longer way")
        XCTAssertGreaterThan(other.bitsPerSecond, 880_000, "as it is by now for a stream that did not start over")
    }

    func testALinkThatCarriesLessThanPicturesThatChangeLittleNeedIsFound() {
        // 1 KB a picture, 60 a second, over a link of 300 kbit/s: the stream never uses half its bit rate, but
        // its pictures wait, and the answers come evenly.
        var stream = Stream()
        stream.run(seconds: 20, capacity: 300_000, light: true)
        XCTAssertLessThan(stream.rate.bitsPerSecond, 500_000)
    }

    func testTheBitRateRisesAgainOnALinkThatCarriesMore() {
        var stream = Stream()
        stream.run(seconds: 10, capacity: 1_000_000)
        XCTAssertLessThan(stream.rate.bitsPerSecond, 1_100_000)
        stream.run(seconds: 40, capacity: 50_000_000)
        XCTAssertEqual(stream.rate.bitsPerSecond, LinkRate.most)
    }

    func testAStillScreenDoesNotRaiseTheBitRate() {
        var stream = Stream()
        stream.run(seconds: 10, capacity: 1_000_000)
        // Small pictures now and then show nothing of what the link carries.
        let rate = stream.rate.bitsPerSecond
        stream.run(seconds: 60, capacity: 1_000_000, moving: false)
        // One step at most, for what was under way when the screen came to rest.
        XCTAssertLessThanOrEqual(stream.rate.bitsPerSecond, rate * LinkRate.creep)
    }

    func testALinkThatBecameSlowerForGoodIsNoQueue() {
        // Another relay or cell: every answer takes 150 ms longer from now on, with room for the whole stream.
        // One step down, and the answers stay as late: no queue. The bit rate is back within seconds.
        var stream = Stream()
        stream.run(seconds: 5, capacity: 50_000_000)
        stream.forget()
        stream.run(seconds: 30, capacity: 50_000_000) { _ in 0.18 }
        XCTAssertGreaterThan(stream.rates.min()!, LinkRate.most * 0.8, "one step")
        XCTAssertLessThanOrEqual(stream.rates.filter { $0 < LinkRate.most }.count, 5)
        XCTAssertEqual(stream.rate.bitsPerSecond, LinkRate.most)
        // The same while the screen is nearly still: the stream does not fill the link, so nothing is tried.
        var still = Stream()
        still.run(seconds: 5, capacity: 50_000_000)
        still.run(seconds: 30, capacity: 50_000_000, moving: false) { _ in 0.18 }
        XCTAssertEqual(still.rate.bitsPerSecond, LinkRate.most)
    }

    func testTheBitRateStaysWithinItsBounds() {
        var stream = Stream()
        stream.run(seconds: 60, capacity: 100_000)
        XCTAssertEqual(stream.rate.bitsPerSecond, LinkRate.least)
    }

    func testAPictureGetsSmallerOnceTheBitRateIsTooLowForItsPixels() {
        let pixels = 780.0 * 1688 // needs 0.99 Mbit/s at full size, 0.56 at three quarters, 0.25 at half
        XCTAssertEqual(LinkRate.size(now: 1, pixels: pixels, bitsPerSecond: 4_000_000), 1)
        XCTAssertEqual(LinkRate.size(now: 1, pixels: pixels, bitsPerSecond: 1_000_000), 1)
        XCTAssertEqual(LinkRate.size(now: 1, pixels: pixels, bitsPerSecond: 900_000), 0.75)
        XCTAssertEqual(LinkRate.size(now: 1, pixels: pixels, bitsPerSecond: 500_000), 0.5)
        XCTAssertEqual(LinkRate.size(now: 0.75, pixels: pixels, bitsPerSecond: 500_000), 0.5)
        XCTAssertEqual(LinkRate.size(now: 0.5, pixels: pixels, bitsPerSecond: 100_000), 0.5, "no smaller than half")
        XCTAssertEqual(LinkRate.size(now: 1, pixels: 320 * 240, bitsPerSecond: LinkRate.least), 1, "a small picture needs little")
    }

    func testAPictureGetsLargerOnlyWithRoomToSpare() {
        let pixels = 780.0 * 1688
        XCTAssertEqual(LinkRate.size(now: 0.75, pixels: pixels, bitsPerSecond: 1_200_000), 0.75, "a swing of the bit rate")
        XCTAssertEqual(LinkRate.size(now: 0.75, pixels: pixels, bitsPerSecond: 1_500_000), 1)
        XCTAssertEqual(LinkRate.size(now: 0.5, pixels: pixels, bitsPerSecond: 700_000), 0.5)
        XCTAssertEqual(LinkRate.size(now: 0.5, pixels: pixels, bitsPerSecond: 900_000), 0.75)
        XCTAssertEqual(LinkRate.size(now: 0.5, pixels: pixels, bitsPerSecond: 4_000_000), 1)
    }
}

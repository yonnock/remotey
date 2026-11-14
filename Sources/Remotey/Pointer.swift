import AppKit
import os

/// The mouse pointer in global display coordinates (origin top left of the main display).
enum Pointer {
    /// What the window server reports. It trails a move posted here by up to a display refresh.
    private static var reported: CGPoint { CGEvent(source: nil)?.location ?? .zero }
    private static let track = OSAllocatedUnfairLock(initialState: PointerTrack())

    /// Where the pointer is once the window server has caught up with the moves posted here.
    /// Moves that arrive in a burst add up, and the live view shows a move without waiting for the refresh.
    /// The report is read under the lock: the live view asks from its own queue, and a report that is
    /// out of date by the time it is compared would look like a pointer no move sent there.
    static var location: CGPoint {
        track.withLock { $0.location(reported: reported, now: ProcessInfo.processInfo.systemUptime) }
    }

    /// Call after posting a move to `target`.
    static func posted(_ target: CGPoint) {
        track.withLock { $0.post(target, reported: reported, now: ProcessInfo.processInfo.systemUptime) }
    }

    static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count > 0 ? id : nil
    }

    /// The pointer's current picture for the phone, which draws the pointer itself. Main thread only.
    static func picture() -> Picture? {
        let cursor = NSCursor.currentSystem ?? .arrow
        let size = cursor.image.size
        // Three pixels per point stay sharp on the phone at every zoom.
        let width = Int((size.width * 3).rounded(.up)), height = Int((size.height * 3).rounded(.up))
        var rect = CGRect(x: 0, y: 0, width: width, height: height)
        guard (1...768).contains(width), (1...768).contains(height),
              let image = cursor.image.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = Picture.context(nil, width: width, height: height), let pixels = context.data else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: rect)
        return Picture(pixels: Data(bytes: pixels, count: width * height * 4), width: width, height: height,
                       size: size, hotSpot: cursor.hotSpot)
    }

    /// Comparing the pixels is cheap, so the PNG is only made for a picture the phone does not have yet.
    struct Picture: Equatable {
        let pixels: Data
        let width: Int
        let height: Int
        /// In points, like the hot spot: the place inside the picture that sits at the pointer's location.
        let size: CGSize
        let hotSpot: CGPoint

        var png: Data? {
            var pixels = pixels
            return pixels.withUnsafeMutableBytes { bytes in
                Self.context(bytes.baseAddress, width: width, height: height)?.makeImage()
                    .flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            }
        }

        fileprivate static func context(_ data: UnsafeMutableRawPointer?, width: Int, height: Int) -> CGContext? {
            CGContext(data: data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
    }
}

/// Follows posted moves until the window server reports them.
struct PointerTrack {
    /// How long a posted move explains what the window server reports. A move it has not reported by
    /// then counts as refused, for example without the Accessibility permission.
    static let patience: TimeInterval = 0.25

    /// What the window server may report: the place before the recent moves, then their targets.
    /// Its reports do not come in order. An older place can follow a newer one, even after the last
    /// target was reported, so a place stays here for its time instead of leaving once it was seen.
    private var trail: [(place: CGPoint, time: TimeInterval)] = []

    mutating func location(reported: CGPoint, now: TimeInterval) -> CGPoint {
        trail.removeAll { now - $0.time >= Self.patience }
        guard let target = trail.last?.place,
              trail.contains(where: { abs($0.place.x - reported.x) < 0.01 && abs($0.place.y - reported.y) < 0.01 }) else {
            // No move sent the pointer there: the Mac's own mouse moved it, or a display edge held it.
            trail.removeAll()
            return reported
        }
        return target
    }

    mutating func post(_ target: CGPoint, reported: CGPoint, now: TimeInterval) {
        if trail.isEmpty { trail.append((reported, now)) }
        trail.append((target, now))
    }
}

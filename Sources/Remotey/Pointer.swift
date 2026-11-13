import CoreGraphics

/// The mouse pointer in global display coordinates (origin top left of the main display).
enum Pointer {
    static var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        return CGGetDisplaysWithPoint(point, 1, &id, &count) == .success && count > 0 ? id : nil
    }
}

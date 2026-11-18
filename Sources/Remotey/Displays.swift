import AppKit

/// The Mac's displays for the phone's picker, and the pointer's jump from one to another.
struct Displays {
    struct Display: Encodable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        /// Global points, origin top left of the main display: how the displays are arranged.
        let x: Double
        let y: Double
        let w: Double
        let h: Double
        /// The pointer is on this one.
        let pointer: Bool

        var bounds: CGRect { CGRect(x: x, y: y, width: w, height: h) }
    }

    /// Where the pointer was on a display when it last jumped off it, as shares of the display's width and
    /// height: they still name a place after the display moved in the arrangement or changed its mode.
    private var left: [CGDirectDisplayID: CGPoint] = [:]

    /// Main thread only.
    static func list(pointer: CGPoint = Pointer.location) -> [Display] {
        NSScreen.screens.compactMap { screen in
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { return nil }
            let bounds = CGDisplayBounds(id)
            return Display(id: id, name: screen.localizedName, x: bounds.minX, y: bounds.minY, w: bounds.width, h: bounds.height,
                           pointer: bounds.contains(pointer))
        }
    }

    /// Where the pointer goes on the display `id`: back to where it left it, else to its middle. Nil if it
    /// is there already, or no such display is among `displays`. The place it comes from is kept for the way back.
    mutating func jump(to id: CGDirectDisplayID, from pointer: CGPoint, among displays: [Display]) -> CGPoint? {
        guard let target = displays.first(where: { $0.id == id })?.bounds, !target.contains(pointer) else { return nil }
        if let from = displays.first(where: { $0.bounds.contains(pointer) }) {
            left[from.id] = CGPoint(x: (pointer.x - from.x) / from.w, y: (pointer.y - from.y) / from.h)
        }
        let share = left[id] ?? CGPoint(x: 0.5, y: 0.5)
        // Whole points inside the display: its far edges belong to the neighbour.
        return CGPoint(x: min((target.minX + share.x * target.width).rounded(), target.maxX - 1),
                       y: min((target.minY + share.y * target.height).rounded(), target.maxY - 1))
    }
}

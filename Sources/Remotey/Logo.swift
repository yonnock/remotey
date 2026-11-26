import AppKit
import SwiftUI

/// The logo of docs/logo.svg, drawn here so the app has an icon without a resource file: the pointer with its
/// two rays on a dark tile. It is the app's icon in alerts and the assistant's emblem.
struct Logo: View {
    var body: some View {
        Canvas { context, size in
            let scale = size.width / 512
            context.scaleBy(x: scale, y: scale)
            context.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: 512, height: 512), cornerRadius: 112, style: .continuous),
                         with: .color(Color(red: 0x11 / 255, green: 0x12 / 255, blue: 0x14 / 255)))
            context.translateBy(x: 34, y: 38)
            var rays = Path()
            for radius in [56.0, 100.0] { rays.addPath(Self.arc(radius: radius)) }
            context.stroke(rays, with: .color(Color(red: 0xe8 / 255, green: 0xe9 / 255, blue: 0xeb / 255)),
                           style: StrokeStyle(lineWidth: 18, lineCap: .round, lineJoin: .round))
            let pointer = Path { path in
                path.move(to: CGPoint(x: 176, y: 126))
                let corners: [(Double, Double)] = [(176, 347), (234.5, 295), (273.5, 386), (306, 373), (267, 282), (345, 282)]
                for (x, y) in corners { path.addLine(to: CGPoint(x: x, y: y)) }
                path.closeSubpath()
            }
            let amber = Color(red: 0xf2 / 255, green: 0xb8 / 255, blue: 0x4b / 255)
            context.fill(pointer, with: .color(amber))
            context.stroke(pointer, with: .color(amber), style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The SVG's arcs run around the pointer's tip, from 190° to 260° with y pointing down: drawn as short
    /// lines, so each starts where it should and none joins the other.
    private static func arc(radius: Double) -> Path {
        Path { path in
            let points = stride(from: 190.0, through: 260.0, by: 2.5).map { degrees -> CGPoint in
                let angle = degrees * .pi / 180
                return CGPoint(x: 176 + radius * cos(angle), y: 126 + radius * sin(angle))
            }
            path.addLines(points)
        }
    }

    /// The logo as the application's icon, with the margin macOS icons have around their tile.
    @MainActor
    static func icon(size: CGFloat = 512) -> NSImage {
        let renderer = ImageRenderer(content: Logo().padding(size * 0.1).frame(width: size, height: size))
        renderer.scale = 2
        return renderer.nsImage ?? NSImage()
    }
}

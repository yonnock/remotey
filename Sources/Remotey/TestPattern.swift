import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// Stands in for a display's capture while `REMOTEY_TEST_PATTERN` is set: a pattern that moves without
/// pause, at the size and rate the capture would have. For measuring the stream with nothing shown on the
/// Mac's screen; the pointer and the displays' arrangement stay real.
final class TestPattern {
    static let on = ProcessInfo.processInfo.environment["REMOTEY_TEST_PATTERN"] != nil

    /// Size in pixels and frames per second. Frame queue only, like the frames it makes.
    var size: (width: Int, height: Int, framesPerSecond: Int32) {
        didSet { if size.framesPerSecond != oldValue.framesPerSecond { schedule() } }
    }
    private let queue: DispatchQueue
    private let frame: (CVPixelBuffer) -> Void
    private let timer: DispatchSourceTimer
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let started = ProcessInfo.processInfo.systemUptime

    init(width: Int, height: Int, framesPerSecond: Int32, queue: DispatchQueue, frame: @escaping (CVPixelBuffer) -> Void) {
        size = (width, height, framesPerSecond)
        self.queue = queue
        self.frame = frame
        timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        timer.setEventHandler { [weak self] in self?.tick() }
        schedule()
        timer.resume()
    }

    deinit { timer.cancel() }

    func stop() { timer.cancel() }

    private func schedule() {
        timer.schedule(deadline: .now(), repeating: 1 / Double(size.framesPerSecond), leeway: .milliseconds(1))
    }

    /// Squares and stripes, like the edges of text and windows, moving 150 pixels a second to the side and 100 down.
    private func tick() {
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, size.width, size.height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return }
        let time = ProcessInfo.processInfo.systemUptime - started
        let squares = CIFilter.checkerboardGenerator()
        squares.width = 14
        squares.color0 = .white
        squares.color1 = CIColor(red: 0.15, green: 0.2, blue: 0.35)
        let stripes = CIFilter.stripesGenerator()
        stripes.width = 40
        stripes.color0 = CIColor(red: 0.9, green: 0.5, blue: 0.2, alpha: 0.5)
        stripes.color1 = .clear
        let moved = CGAffineTransform(translationX: time * 150, y: time * -100)
        let image = stripes.outputImage!.transformed(by: moved.rotated(by: 0.5))
            .composited(over: squares.outputImage!.transformed(by: moved))
        context.render(image, to: buffer, bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height),
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        frame(buffer)
    }
}

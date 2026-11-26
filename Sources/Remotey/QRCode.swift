import AppKit
import CoreImage

enum QRCode {
    /// The code for `text`, one pixel per module: drawn without interpolation it stays sharp at any size.
    static func image(_ text: String) -> NSImage {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return NSImage() }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return NSImage() }
        return NSImage(cgImage: cgImage, size: output.extent.size)
    }
}

import UIKit

extension UIImage {
    /// Reads the single pixel color from a 1x1 image.
    /// Re-renders into a known RGBA context to avoid byte-order issues
    /// (UIGraphicsImageRenderer uses BGRA on iOS by default).
    func pixelColor() -> UIColor? {
        guard let cgImage = self.cgImage else { return nil }
        return Self.samplePixel(from: cgImage, x: 0, y: 0)
    }

    /// Reads the pixel color at a specific point in image-display coordinates.
    func pixelColor(at point: CGPoint, in displaySize: CGSize) -> UIColor? {
        guard let cgImage = self.cgImage,
              cgImage.width > 0, cgImage.height > 0,
              displaySize.width > 0, displaySize.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(cgImage.width) / displaySize.width
        let scaleY = CGFloat(cgImage.height) / displaySize.height
        let pixelX = max(0, min(cgImage.width - 1, Int(point.x * scaleX)))
        let pixelY = max(0, min(cgImage.height - 1, Int(point.y * scaleY)))

        return Self.samplePixel(from: cgImage, x: pixelX, y: pixelY)
    }

    /// Render a single pixel into a known-format RGBA context and read it.
    /// This avoids depending on the source image's byte order (RGBA vs BGRA).
    private static func samplePixel(from cgImage: CGImage, x: Int, y: Int) -> UIColor? {
        var pixel: [UInt8] = [0, 0, 0, 0] // R, G, B, A
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw just the target pixel into the 1x1 context
        context.draw(cgImage, in: CGRect(x: -x, y: -y, width: cgImage.width, height: cgImage.height))

        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        let a = CGFloat(pixel[3]) / 255

        // Un-premultiply alpha
        guard a > 0 else { return UIColor(red: r, green: g, blue: b, alpha: 0) }
        return UIColor(red: r / a, green: g / a, blue: b / a, alpha: a)
    }
}

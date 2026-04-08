import UIKit

extension UIImage {
    /// Reads the single pixel color from a 1×1 image.
    /// Used for cheap color sampling where the renderer produces a tiny image.
    func pixelColor() -> UIColor? {
        guard let cgImage = self.cgImage,
              cgImage.width > 0, cgImage.height > 0,
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        // Read the first (and only) pixel of a 1x1 image at offset 0.
        let r = CGFloat(bytes[0]) / 255
        let g = CGFloat(bytes[1]) / 255
        let b = CGFloat(bytes[2]) / 255
        let a: CGFloat = bytesPerPixel >= 4 ? CGFloat(bytes[3]) / 255 : 1.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }

    /// Reads the pixel color at a specific point in image-display coordinates.
    /// `displaySize` is the size of the rendered image on screen (not the UIImage's native pixel size).
    /// The point is mapped to the underlying pixel grid via scale = image.pixel / displaySize.
    func pixelColor(at point: CGPoint, in displaySize: CGSize) -> UIColor? {
        guard let cgImage = self.cgImage,
              cgImage.width > 0, cgImage.height > 0,
              displaySize.width > 0, displaySize.height > 0,
              let dataProvider = cgImage.dataProvider,
              let data = dataProvider.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let scaleX = CGFloat(cgImage.width) / displaySize.width
        let scaleY = CGFloat(cgImage.height) / displaySize.height
        let pixelX = max(0, min(cgImage.width - 1, Int(point.x * scaleX)))
        let pixelY = max(0, min(cgImage.height - 1, Int(point.y * scaleY)))

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        let index = pixelY * cgImage.bytesPerRow + pixelX * bytesPerPixel
        let r = CGFloat(bytes[index]) / 255
        let g = CGFloat(bytes[index + 1]) / 255
        let b = CGFloat(bytes[index + 2]) / 255
        let a: CGFloat = bytesPerPixel >= 4 ? CGFloat(bytes[index + 3]) / 255 : 1.0
        return UIColor(red: r, green: g, blue: b, alpha: a)
    }
}

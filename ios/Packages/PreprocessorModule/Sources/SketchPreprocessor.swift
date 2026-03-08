import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Processes raw canvas snapshots into generation-ready images.
public struct SketchPreprocessor: Sendable {

    private static let targetSize = CGSize(width: 512, height: 512)
    private static let contentPadding: CGFloat = 0.10

    public init() {}

    // MARK: - Public API

    /// Process a UIImage from the canvas into a generation-ready image.
    public func process(_ image: UIImage) async throws -> ProcessedSketch {
        let monochromed = monochromeFlattened(image)
        let cropped = cropToContent(monochromed)
        let resized = resize(cropped, to: Self.targetSize)

        guard let jpegData = resized.jpegData(compressionQuality: 0.85) else {
            throw PreprocessorError.encodingFailed
        }

        let base64 = jpegData.base64EncodedString()

        return ProcessedSketch(
            imageData: jpegData,
            base64Image: base64,
            caption: nil,
            width: Int(Self.targetSize.width),
            height: Int(Self.targetSize.height)
        )
    }

    // MARK: - Private

    private func monochromeFlattened(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

        let filter = CIFilter.colorMonochrome()
        filter.inputImage = ciImage
        filter.color = CIColor(red: 0, green: 0, blue: 0)
        filter.intensity = 1.0

        let context = CIContext()
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return image
        }

        return UIImage(cgImage: cgImage)
    }

    private func cropToContent(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        let width = cgImage.width
        let height = cgImage.height

        // For now, return the full image — content-aware cropping
        // requires pixel analysis which will be refined in Week 2
        let paddingX = Int(CGFloat(width) * Self.contentPadding)
        let paddingY = Int(CGFloat(height) * Self.contentPadding)

        let cropRect = CGRect(
            x: max(0, paddingX),
            y: max(0, paddingY),
            width: max(1, width - 2 * paddingX),
            height: max(1, height - 2 * paddingY)
        )

        guard let cropped = cgImage.cropping(to: cropRect) else { return image }
        return UIImage(cgImage: cropped)
    }

    private func resize(_ image: UIImage, to targetSize: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}

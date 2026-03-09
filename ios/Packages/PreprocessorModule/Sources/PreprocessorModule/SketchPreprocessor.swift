import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Processes raw canvas snapshots into optimized images for generation.
public final class SketchPreprocessor: Sendable {

    // MARK: - Properties

    private let ciContext: CIContext

    // MARK: - Lifecycle

    public init() {
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ])
    }

    // MARK: - Public API

    /// Processes a raw canvas snapshot into a generation-ready image.
    ///
    /// Pipeline: monochrome flatten -> crop to content bounds -> resize -> JPEG export.
    /// - Parameters:
    ///   - image: Raw canvas snapshot from PencilKit.
    ///   - targetSize: Output dimensions. 512x512 for preview, 1024x1024 for refine.
    /// - Returns: A `ProcessedSketch` with JPEG data, or `nil` if processing fails.
    public func process(
        _ image: UIImage,
        targetSize: CGSize = CGSize(width: 512, height: 512)
    ) async -> ProcessedSketch? {
        guard let cgImage = image.cgImage else { return nil }

        let inputCI = CIImage(cgImage: cgImage)

        // Step 1: Flatten to high-contrast monochrome
        guard let monochrome = applyMonochrome(to: inputCI) else { return nil }

        // Step 2: Crop to content bounds with 10% padding
        let contentBounds = detectContentBounds(in: monochrome, fullExtent: inputCI.extent)
        let paddedBounds = addPadding(to: contentBounds, padding: 0.10, within: inputCI.extent)
        let cropped = monochrome.cropped(to: paddedBounds)
            .transformed(by: CGAffineTransform(
                translationX: -paddedBounds.origin.x,
                y: -paddedBounds.origin.y
            ))

        // Step 3: Resize to target size
        guard let resized = resize(cropped, to: targetSize) else { return nil }

        // Step 4: Export as JPEG data at 85% quality
        guard let jpegData = ciContext.jpegRepresentation(
            of: resized,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
        ) else { return nil }

        let originalBounds = CGRect(
            x: paddedBounds.origin.x,
            y: paddedBounds.origin.y,
            width: paddedBounds.width,
            height: paddedBounds.height
        )

        return ProcessedSketch(
            imageData: jpegData,
            caption: nil,
            originalBounds: originalBounds
        )
    }

    // MARK: - Private

    private func applyMonochrome(to input: CIImage) -> CIImage? {
        let monoFilter = CIFilter.photoEffectMono()
        monoFilter.inputImage = input

        guard let monoOutput = monoFilter.outputImage else { return nil }

        // Boost contrast for cleaner line detection
        let contrastFilter = CIFilter.colorControls()
        contrastFilter.inputImage = monoOutput
        contrastFilter.contrast = 1.5
        contrastFilter.brightness = 0.0
        contrastFilter.saturation = 0.0

        return contrastFilter.outputImage
    }

    private func detectContentBounds(in image: CIImage, fullExtent: CGRect) -> CGRect {
        // Render to a small bitmap for fast pixel scanning
        let scanSize = 256
        let scaleX = fullExtent.width / CGFloat(scanSize)
        let scaleY = fullExtent.height / CGFloat(scanSize)

        let scaled = image.transformed(by: CGAffineTransform(
            scaleX: CGFloat(scanSize) / fullExtent.width,
            y: CGFloat(scanSize) / fullExtent.height
        ))

        var bitmap = [UInt8](repeating: 0, count: scanSize * scanSize * 4)
        ciContext.render(
            scaled,
            toBitmap: &bitmap,
            rowBytes: scanSize * 4,
            bounds: CGRect(x: 0, y: 0, width: scanSize, height: scanSize),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )

        // Scan for non-white pixels (content threshold: < 240 in any channel)
        let threshold: UInt8 = 240
        var minX = scanSize
        var minY = scanSize
        var maxX = 0
        var maxY = 0
        var foundContent = false

        for y in 0..<scanSize {
            for x in 0..<scanSize {
                let offset = (y * scanSize + x) * 4
                let r = bitmap[offset]
                let g = bitmap[offset + 1]
                let b = bitmap[offset + 2]
                let a = bitmap[offset + 3]

                // Skip fully transparent pixels
                guard a > 10 else { continue }

                if r < threshold || g < threshold || b < threshold {
                    foundContent = true
                    minX = min(minX, x)
                    minY = min(minY, y)
                    maxX = max(maxX, x)
                    maxY = max(maxY, y)
                }
            }
        }

        guard foundContent else { return fullExtent }

        return CGRect(
            x: CGFloat(minX) * scaleX,
            y: CGFloat(minY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
    }

    private func addPadding(to rect: CGRect, padding: CGFloat, within bounds: CGRect) -> CGRect {
        let padX = rect.width * padding
        let padY = rect.height * padding

        let expanded = rect.insetBy(dx: -padX, dy: -padY)
        return expanded.intersection(bounds)
    }

    private func resize(_ image: CIImage, to targetSize: CGSize) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let scaleX = targetSize.width / extent.width
        let scaleY = targetSize.height / extent.height

        // Use aspect-fit: scale uniformly by the smaller factor, then
        // center the result within the target canvas on a white background
        let scale = min(scaleX, scaleY)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale

        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Create white background at target size
        let white = CIImage(color: CIColor.white)
            .cropped(to: CGRect(origin: .zero, size: targetSize))

        // Center the scaled sketch on the white background
        let offsetX = (targetSize.width - scaledWidth) / 2.0
        let offsetY = (targetSize.height - scaledHeight) / 2.0
        let centered = scaledImage.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))

        return centered.composited(over: white)
    }
}

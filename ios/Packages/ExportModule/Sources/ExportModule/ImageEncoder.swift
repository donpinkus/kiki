import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Encodes a `CGImage` into image-file bytes via ImageIO. No UIKit, so this is
/// the single encode path exercised by unit tests on the host.
public enum ImageEncoder {
    public static func encode(_ image: CGImage, as format: ExportFormat) throws -> Data {
        guard format.mediaKind == .image else {
            throw ExportError.unsupportedFormat(format)
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ExportError.encodingFailed
        }

        var options: [CFString: Any] = [:]
        if case .jpeg(let quality) = format {
            options[kCGImageDestinationLossyCompressionQuality] = quality
        }

        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ExportError.encodingFailed
        }
        return data as Data
    }
}

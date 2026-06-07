import CoreGraphics
import Foundation

/// Errors raised while turning an ``Exportable`` into file bytes.
public enum ExportError: Error, Equatable {
    /// The requested format doesn't apply to this media (e.g. encoding a still
    /// image as MP4).
    case unsupportedFormat(ExportFormat)
    /// The underlying image couldn't be encoded into the requested format.
    case encodingFailed
}

/// Something that can be turned into shareable file bytes in a given format.
///
/// `UIImage` conforms (on iOS) and ``ImageExportable`` provides a UIKit-free
/// conformance used in tests and on non-UIKit hosts. Video media will conform
/// later without changing this protocol.
public protocol Exportable {
    var mediaKind: MediaKind { get }
    func encode(as format: ExportFormat) throws -> Data
}

/// A still image backed by a `CGImage`. UIKit-free, so the encode path is
/// unit-testable on any host; `UIImage` delegates to the same ``ImageEncoder``.
public struct ImageExportable: Exportable {
    public let cgImage: CGImage

    public init(cgImage: CGImage) {
        self.cgImage = cgImage
    }

    public var mediaKind: MediaKind { .image }

    public func encode(as format: ExportFormat) throws -> Data {
        try ImageEncoder.encode(cgImage, as: format)
    }
}

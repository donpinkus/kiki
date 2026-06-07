#if canImport(UIKit)
import UIKit

/// Production conformance. Uses `UIImage`'s own encoders so orientation/scale
/// are honored (the CGImage path would drop orientation metadata).
extension UIImage: Exportable {
    public var mediaKind: MediaKind { .image }

    public func encode(as format: ExportFormat) throws -> Data {
        let data: Data?
        switch format {
        case .png:
            data = pngData()
        case .jpeg(let quality):
            data = jpegData(compressionQuality: quality)
        case .mp4:
            throw ExportError.unsupportedFormat(format)
        }
        guard let data else { throw ExportError.encodingFailed }
        return data
    }
}
#endif

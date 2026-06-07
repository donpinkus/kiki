import CoreGraphics
import UniformTypeIdentifiers

/// A concrete output format the share/export pipeline can produce.
///
/// Adding a format (or a whole media type) is a matter of adding a case here
/// plus an arm in the encoder — the share menu is data-driven off
/// ``imageFormats`` / ``videoFormats``, so new cases surface automatically.
public enum ExportFormat: Sendable, Identifiable, Hashable {
    case jpeg(quality: CGFloat)
    case png
    /// Video container — not yet wired into the share UI. Present so the image
    /// encoders have a concrete "doesn't apply to a still" case to reject, and
    /// so adding "Share video" later is additive rather than a new type.
    case mp4

    public var id: String {
        switch self {
        case .jpeg: return "jpeg"
        case .png: return "png"
        case .mp4: return "mp4"
        }
    }

    /// Label shown in the share menu.
    public var displayName: String {
        switch self {
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .mp4: return "MP4"
        }
    }

    /// File extension (no dot). Drives the temp filename so "Save to Files"
    /// shows e.g. `Kiki.jpg`.
    public var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .png: return "png"
        case .mp4: return "mp4"
        }
    }

    /// Uniform type — drives the image-encoder destination and the file's type
    /// in Files / share targets.
    public var utType: UTType {
        switch self {
        case .jpeg: return .jpeg
        case .png: return .png
        case .mp4: return .mpeg4Movie
        }
    }

    public var mediaKind: MediaKind {
        switch self {
        case .jpeg, .png: return .image
        case .mp4: return .video
        }
    }

    /// Image formats offered in the share menu, in display order.
    public static var imageFormats: [ExportFormat] {
        [.jpeg(quality: 0.9), .png]
    }
}

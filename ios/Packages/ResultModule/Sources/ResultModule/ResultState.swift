import UIKit

/// Represents the current state of the result pane.
public enum ResultState {
    case empty
    /// The stream is connecting (fal relay wiring; usually ~1–2s, but a cold
    /// fal pool can take a couple of minutes). `previousImage`, when present,
    /// is shown dimmed underneath the overlay so the user keeps seeing their
    /// last result while we reconnect.
    case provisioning(message: String, previousImage: UIImage?)
    case preview(image: UIImage)
    case streaming(image: UIImage, frameCount: Int = 0)
    case error(message: String, previousImage: UIImage?)
    /// Pre-MP4: the video pod is streaming JPEG frames as they decode.
    /// `latestFrame` is the most recent decoded frame; `fallback` is the
    /// last successful still (kept around so we never blank the pane —
    /// Constraint #2 — if anything fails mid-stream).
    case videoStreaming(latestFrame: UIImage, fallback: UIImage)
    /// Final state: looping the encoded MP4 from disk.
    case videoLooping(mp4URL: URL, fallback: UIImage)

    public var isPreview: Bool {
        if case .preview = self { return true }
        return false
    }

    public var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }

    public var isVideo: Bool {
        switch self {
        case .videoStreaming, .videoLooping: return true
        default: return false
        }
    }

    /// The still image to display for this state, if any. Used by the
    /// fullscreen floating panel, which renders image-only (no progress
    /// chrome) and therefore shows nothing when this is `nil`.
    public var displayImage: UIImage? {
        switch self {
        case .empty:
            return nil
        case .provisioning(_, let previousImage):
            return previousImage
        case .preview(let image):
            return image
        case .streaming(let image, _):
            return image
        case .error(_, let previousImage):
            return previousImage
        case .videoStreaming(let latestFrame, _):
            return latestFrame
        case .videoLooping(_, let fallback):
            return fallback
        }
    }
}

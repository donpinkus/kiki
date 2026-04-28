import UIKit

/// A stage in the generation pipeline.
public enum GenerationPhase: String, Sendable, Equatable, CaseIterable, Identifiable {
    case preparing
    case uploading
    case downloading

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .preparing: return "Capturing sketch"
        case .uploading: return "Sending to server"
        case .downloading: return "Loading image"
        }
    }
}

/// Tracks progress across all generation phases, including completed durations.
public struct GenerationProgress: Equatable, Sendable {
    public let currentPhase: GenerationPhase
    public let phaseStartedAt: Date
    public let durations: [GenerationPhase: TimeInterval]

    public init(
        currentPhase: GenerationPhase,
        phaseStartedAt: Date = Date(),
        durations: [GenerationPhase: TimeInterval] = [:]
    ) {
        self.currentPhase = currentPhase
        self.phaseStartedAt = phaseStartedAt
        self.durations = durations
    }
}

/// Represents the current state of the result pane.
public enum ResultState {
    case empty
    /// Backend GPU pod is being provisioned. `startedAt` is the
    /// server-authoritative pod-warm-cycle origin used to compute elapsed
    /// time for a smooth progress bar across many `message` updates. `nil`
    /// during the pre-WS-open window before we've received it from the
    /// server — the UI hides the progress bar entirely in that case so it
    /// can't render at 0% and look like the cycle is restarting.
    /// `previousImage`, when present, is shown dimmed underneath the
    /// warm-up overlay so the user keeps seeing their last result while
    /// we reconnect.
    case provisioning(message: String, startedAt: Date?, previousImage: UIImage?)
    case generating(progress: GenerationProgress, previousImage: UIImage?)
    case preview(image: UIImage)
    case streaming(image: UIImage, frameCount: Int = 0)
    case error(message: String, previousImage: UIImage?)
    /// Backend reaper paused the session after 30 min of no frame activity.
    /// User taps the overlay or starts drawing to resume; both call resumeStream().
    /// `previousImage` is displayed under a semi-transparent overlay so the
    /// user can see their last-generated image is still waiting for them.
    case idleTimeout(previousImage: UIImage?)
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
}

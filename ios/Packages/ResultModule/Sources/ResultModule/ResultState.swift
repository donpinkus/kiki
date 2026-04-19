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
    /// Backend GPU pod is being provisioned. `startedAt` lets the UI compute
    /// elapsed time for a smooth progress bar across many `message` updates.
    case provisioning(message: String, startedAt: Date)
    case generating(progress: GenerationProgress, previousImage: UIImage?)
    case preview(image: UIImage)
    case streaming(image: UIImage, frameCount: Int = 0)
    case error(message: String, previousImage: UIImage?)
    /// LTXV video generation in progress — pod is streaming decoded frames.
    /// `latestFrame` is the most recent frame received; `baseImage` is the
    /// original still that the video is being animated from (preserved so
    /// the right pane stays visually continuous if generation aborts).
    case videoStreaming(baseImage: UIImage, latestFrame: UIImage, framesReceived: Int)
    /// Final MP4 has arrived and is looping. `fallbackImage` is kept for
    /// instant restore if the player fails or the user resumes drawing.
    case videoLooping(mp4URL: URL, fallbackImage: UIImage)

    public var isPreview: Bool {
        if case .preview = self { return true }
        return false
    }

    public var isStreaming: Bool {
        if case .streaming = self { return true }
        return false
    }
}

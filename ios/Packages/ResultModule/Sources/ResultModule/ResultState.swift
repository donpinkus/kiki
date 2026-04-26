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
    /// `previousImage`, when present, is shown dimmed underneath the warm-up
    /// overlay so the user keeps seeing their last result while we reconnect.
    case provisioning(message: String, startedAt: Date, previousImage: UIImage?)
    case generating(progress: GenerationProgress, previousImage: UIImage?)
    case preview(image: UIImage)
    case streaming(image: UIImage, frameCount: Int = 0)
    case error(message: String, previousImage: UIImage?)
    /// Backend reaper paused the session after 30 min of no frame activity.
    /// User taps the overlay or starts drawing to resume; both call resumeStream().
    /// `previousImage` is displayed under a semi-transparent overlay so the
    /// user can see their last-generated image is still waiting for them.
    case idleTimeout(previousImage: UIImage?)
}

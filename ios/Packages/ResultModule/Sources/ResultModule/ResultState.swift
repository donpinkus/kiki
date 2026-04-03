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
    case generating(progress: GenerationProgress, previousImage: UIImage?)
    case preview(image: UIImage)
    case error(message: String, previousImage: UIImage?)

    public var isPreview: Bool {
        if case .preview = self { return true }
        return false
    }
}

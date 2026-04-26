import CoreGraphics
import Foundation

// MARK: - Input

/// One input sample fed to the recognizer.
///
/// Position is in canvas space (pan/zoom-invariant). Timestamp is required
/// for hold-velocity detection; everything else (force, tilt, azimuth) lives
/// on the calling side's `StrokePoint` and is consumed during brush-stamp
/// regeneration, not by the recognizer.
public struct RecognizerInputPoint: Equatable, Sendable {
    public let position: CGPoint
    public let timestamp: TimeInterval

    public init(position: CGPoint, timestamp: TimeInterval) {
        self.position = position
        self.timestamp = timestamp
    }
}

// MARK: - Output

public enum Verdict: Equatable, Sendable {
    case line(LineGeometry)
    case abstain(AbstainReason)

    public var isSnap: Bool {
        if case .abstain = self { return false }
        return true
    }
}

public struct LineGeometry: Equatable, Sendable {
    /// Raw first stroke point projected onto the fitted line.
    public let start: CGPoint
    /// Raw last stroke point projected onto the fitted line.
    public let end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }
}

public enum AbstainReason: String, Equatable, Sendable, Codable {
    /// Stroke path length below the floor.
    case tooShort
    /// Resampled point count below the floor (tiny strokes).
    case tooFewPoints
    /// Stroke turns more than 2.5π — likely a scribble or overtraced shape.
    case overtraced
    /// Top score didn't exceed the acceptance threshold.
    case lowConfidence
    /// Recognizer was disabled at the call site (kill switch / wrong tool).
    case disabled
}

// MARK: - Configuration

/// All recognizer thresholds in one place. Hot-reloadable in debug builds via
/// `RecognizerSeeds(...)` overrides; A/B testable via injection from
/// remote-config in release builds.
///
/// Defaults reflect §7 of the parent plan. v0 only uses the line-relevant
/// subset; the full set is included so v1 can reuse this struct unchanged.
public struct RecognizerSeeds: Equatable, Sendable {
    // Acceptance.
    // Calibrated 2026-04 against real Apple Pencil input: the user's *hold gesture*
    // is itself strong opt-in signal — they've explicitly committed to correction.
    // v0 leans aggressive: snaps anything from a clean line through ~25-29° bows;
    // 30°+ arcs and any visible S-curve still abstain via the lineNormRMS gate.
    public var acceptScore: CGFloat = 0.45
    public var confidenceHysteresis: CGFloat = 0.05

    // Hold detection
    public var holdStabilityWindow: TimeInterval = 0.120
    public var holdCommitDelay: TimeInterval = 0.450
    /// Bounding-box diagonal (pt) of recent positions that still counts as
    /// "stationary." Tolerates hand tremor and Apple Pencil position noise.
    /// Per-sample velocity is too noisy at 240 Hz: a 1pt jitter / (1/240s) =
    /// 240 pt/s, which would blow past any reasonable velocity threshold.
    /// Position-spread is the right framing.
    public var holdJitterTolerance: CGFloat = 20     // pt — bbox diagonal in the window (bumped from 6 for diagnostic)
    public var previewMoveCancelDist: CGFloat = 12   // pt — once preview is up, motion past this cancels (raised proportionally)

    // Pipeline
    public var speculativeFitHz: Double = 30
    public var targetSpacingFraction: CGFloat = 1.0 / 50
    public var minTargetSpacing: CGFloat = 2          // pt
    public var smoothingWindow: Int = 5
    public var dedupeMinDistance: CGFloat = 0.5       // pt — drop consecutive samples closer than this

    // Floors
    public var minPathLength: CGFloat = 16            // pt
    public var minResampledPoints: Int = 12
    public var overtraceTurnMax: CGFloat = 2.5 * .pi

    // Endpoint hook trim
    public var endpointTrimAngleDeg: CGFloat = 30
    public var endpointTrimLengthRatio: CGFloat = 0.05

    public init() {}

    public static let `default` = RecognizerSeeds()
}

// MARK: - Telemetry payload

/// Snapshot of the feature vector the recognizer used for its verdict.
/// Logged with every verdict for offline replay and threshold tuning.
public struct FeatureSnapshot: Equatable, Sendable, Codable {
    public let pathLength: CGFloat
    public let bboxDiagonal: CGFloat
    public let sagittaRatio: CGFloat
    public let totalAbsTurnDeg: CGFloat
    public let totalSignedTurnDeg: CGFloat
    public let lineNormRMS: CGFloat
    public let resampledPointCount: Int
    public let lineScore: CGFloat
}

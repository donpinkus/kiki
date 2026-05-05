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
    case arc(ArcGeometry)
    case ellipse(EllipseGeometry)
    case circle(CircleGeometry)
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

public struct EllipseGeometry: Equatable, Sendable {
    public let center: CGPoint
    /// Semi-major axis length (always ≥ semiMinor).
    public let semiMajor: CGFloat
    /// Semi-minor axis length.
    public let semiMinor: CGFloat
    /// Rotation in radians: angle of the semi-major axis from +x.
    public let rotation: CGFloat

    public init(center: CGPoint, semiMajor: CGFloat, semiMinor: CGFloat, rotation: CGFloat) {
        self.center = center
        self.semiMajor = semiMajor
        self.semiMinor = semiMinor
        self.rotation = rotation
    }

    public var axisRatio: CGFloat {
        guard semiMajor > 0 else { return 0 }
        return semiMinor / semiMajor
    }
}

public struct CircleGeometry: Equatable, Sendable {
    public let center: CGPoint
    public let radius: CGFloat

    public init(center: CGPoint, radius: CGFloat) {
        self.center = center
        self.radius = radius
    }
}

/// A circular arc — the portion of a circle between `startAngle` and
/// `endAngle`, traversed in `sweepDirection`. Angles are in radians,
/// with 0 along +x and π/2 along +y (UIKit convention: +y is *down*).
public struct ArcGeometry: Equatable, Sendable {
    public let center: CGPoint
    public let radius: CGFloat
    /// Angle of the arc's start point from the circle center.
    public let startAngle: CGFloat
    /// Angle of the arc's end point from the circle center.
    public let endAngle: CGFloat
    public enum Sweep: Sendable { case clockwise, counterClockwise }
    /// Which direction the user's stroke traversed the arc.
    public let sweep: Sweep

    public init(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        sweep: Sweep
    ) {
        self.center = center
        self.radius = radius
        self.startAngle = startAngle
        self.endAngle = endAngle
        self.sweep = sweep
    }

    /// Position of the arc start in world coords.
    public var startPoint: CGPoint {
        CGPoint(x: center.x + radius * cos(startAngle), y: center.y + radius * sin(startAngle))
    }
    /// Position of the arc end in world coords.
    public var endPoint: CGPoint {
        CGPoint(x: center.x + radius * cos(endAngle), y: center.y + radius * sin(endAngle))
    }
    /// Position of the arc midpoint (halfway around the swept path).
    public var midPoint: CGPoint {
        let mid = midAngle
        return CGPoint(x: center.x + radius * cos(mid), y: center.y + radius * sin(mid))
    }
    /// Angle (radians) at the arc's midpoint along the swept direction.
    public var midAngle: CGFloat {
        var d = endAngle - startAngle
        // Normalize to the swept direction:
        switch sweep {
        case .counterClockwise:
            // Want d in (0, 2π]
            while d <= 0 { d += 2 * .pi }
        case .clockwise:
            // Want d in [-2π, 0)
            while d >= 0 { d -= 2 * .pi }
        }
        return startAngle + d / 2
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
    /// Halír–Flusser ellipse fit returned NaN, degenerate axes, or no
    /// eigenvector satisfying the ellipse constraint.
    case degenerateEllipseFit
    /// Taubin circle fit returned NaN, near-line input, or other degeneracy.
    case degenerateCircleFit
    /// Arc score won the line-vs-arc contest but coverage was below the
    /// `arcCoverageMin` threshold (would look like a barely-visible bow).
    case arcTooShallow
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
    public var holdStabilityWindow: TimeInterval = 0.400
    public var holdCommitDelay: TimeInterval = 0.450
    /// Bounding-box diagonal (pt) of recent positions that still counts as
    /// "stationary." Tolerates hand tremor and Apple Pencil position noise.
    /// Per-sample velocity is too noisy at 240 Hz: a 1pt jitter / (1/240s) =
    /// 240 pt/s, which would blow past any reasonable velocity threshold.
    /// Position-spread is the right framing.
    ///
    /// 8pt: real micro-tremor on a still pen is < 3pt bbox over 400ms;
    /// 8pt comfortably catches that while still rejecting careful drawing
    /// (a pen moving > ~20pt/s covers > 8pt in 400ms). Briefly inflated to
    /// 20 during an early diagnostic, which turned out to mask a separate
    /// scoring bug rather than a hold-detection problem.
    public var holdJitterTolerance: CGFloat = 8      // pt — bbox diagonal in the window
    public var previewMoveCancelDist: CGFloat = 6    // pt — once preview is up, motion past this cancels

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

    // Arc (open-stroke curved) — competes against line for open strokes.
    /// Arc-score wins must beat the line-score by at least this margin to
    /// trigger an arc snap; otherwise we fall back to whichever has the
    /// higher absolute score.
    public var lineArcMargin: CGFloat = 0.08
    /// Minimum angular sweep (degrees) for an arc to commit. Bows shallower
    /// than this look like noisy lines; abstain rather than snap to arc.
    public var arcCoverageMin: CGFloat = 25

    // Closed-stroke routing & validation
    /// Stroke routes to closed-stroke branch (ellipse/circle) when
    /// endpointGap / pathLength ≤ this. The 0.10 default tolerates a small
    /// gap at the close (typical when drawing an "almost closed" loop).
    public var closureGate: CGFloat = 0.10
    /// Promote a fitted ellipse to a circle when min/max axis ratio is at
    /// least this. 0.92 mirrors PaleoSketch and feels right in practice.
    public var circleAxisRatioMin: CGFloat = 0.92
    /// Reject ellipses thinner than this (slivers — usually noisy lines).
    public var ellipseAxisRatioFloor: CGFloat = 0.05
    /// Reject ellipse fits whose axis grew beyond this multiple of the
    /// stroke's bbox diagonal (numerical blowup).
    public var ellipseAxisMaxBboxRatio: CGFloat = 2.0
    /// Reject ellipse fits whose center lies more than this multiple of the
    /// bbox diagonal outside the stroke's bbox.
    public var ellipseCenterMaxOutsideBboxRatio: CGFloat = 1.0

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
    public let closureRatio: CGFloat
    public let sagittaRatio: CGFloat
    public let totalAbsTurnDeg: CGFloat
    public let totalSignedTurnDeg: CGFloat
    public let signRatio: CGFloat
    public let lineNormRMS: CGFloat
    /// Normalized residual of the open-branch arc fit, or nil if no fit
    /// (closed stroke, or degenerate input).
    public let circleNormRMS: CGFloat?
    /// Angular sweep of the arc (degrees), nil if no arc fit.
    public let arcCoverageDeg: CGFloat?
    /// Normalized residual of the closed-branch ellipse fit, or nil if no
    /// fit was attempted (open stroke, or degenerate input).
    public let ellipseNormResidual: CGFloat?
    /// Promotion-eligible axis ratio (semiMinor/semiMajor), nil if no fit.
    public let ellipseAxisRatio: CGFloat?
    public let resampledPointCount: Int
    public let lineScore: CGFloat
    public let arcScore: CGFloat?
    public let ellipseScore: CGFloat?
}

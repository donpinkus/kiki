import CoreGraphics
import Foundation

/// Public, stateful entry point to the v0 line-only recognizer.
///
/// Lifecycle: `reset()` → many `feed(point:)` calls during a stroke →
/// `currentVerdict()` polled during hold for preview → `finalize()` at
/// touch-end or commit time.
///
/// Thread-safety: not thread-safe. Caller must serialize access (the canvas
/// already does this — touches arrive on the main thread).
public final class StrokeRecognizer {

    // MARK: - Configuration

    public var seeds: RecognizerSeeds

    // MARK: - State

    /// All input points fed during the current stroke (canvas space).
    private(set) var inputPoints: [RecognizerInputPoint] = []

    /// Cached verdict from the most recent full classification pass. Returned
    /// by `currentVerdict()` between throttled re-fits.
    private var cachedVerdict: Verdict = .abstain(.tooShort)
    private var cachedScore: CGFloat = 0
    private var lastFullFitTimestamp: TimeInterval = -.infinity

    /// Telemetry payload from the most recent classification pass. Populated
    /// alongside `cachedVerdict`; nil before any classification has run.
    public private(set) var lastFeatureSnapshot: FeatureSnapshot?

    // MARK: - Init

    public init(seeds: RecognizerSeeds = .default) {
        self.seeds = seeds
    }

    // MARK: - Lifecycle

    /// Reset state for a new stroke. Call from touchesBegan.
    public func reset() {
        inputPoints.removeAll(keepingCapacity: true)
        cachedVerdict = .abstain(.tooShort)
        cachedScore = 0
        lastFullFitTimestamp = -.infinity
        lastFeatureSnapshot = nil
    }

    /// Feed one input point. Call on every coalesced touch.
    /// O(1) per call — actual classification is deferred to `currentVerdict()`
    /// or `finalize()`.
    public func feed(point: RecognizerInputPoint) {
        inputPoints.append(point)
    }

    /// Speculative verdict for use during the hold window. Throttled
    /// internally to `seeds.speculativeFitHz` — between firings, returns
    /// the cached result. Safe to call on every touch.
    public func currentVerdict() -> Verdict {
        guard let last = inputPoints.last else { return cachedVerdict }
        let now = last.timestamp
        let interval = 1.0 / seeds.speculativeFitHz
        if now - lastFullFitTimestamp >= interval {
            runFullClassification()
            lastFullFitTimestamp = now
        }
        return cachedVerdict
    }

    /// Final classification — runs the full pipeline once, ignoring the
    /// throttle. Call on touchesEnded or hold-commit.
    public func finalize() -> Verdict {
        runFullClassification()
        return cachedVerdict
    }

    /// Confidence of the current top candidate, in [0, 1]. For UI hysteresis.
    public var currentConfidence: CGFloat {
        cachedScore
    }

    /// Timestamp of the most recently fed input point, or nil if no points yet.
    /// Used by callers driving a hold-commit timer based on input timestamps
    /// (deterministic) rather than wall-clock time.
    public var lastInputTimestamp: TimeInterval? {
        inputPoints.last?.timestamp
    }

    /// Most recent input point with timestamp (for diagnostic logging).
    public var lastInputPositionTimestamp: RecognizerInputPoint? {
        inputPoints.last
    }

    /// Second-to-last input point (for instantaneous velocity diagnostics).
    public var previousInputPositionTimestamp: RecognizerInputPoint? {
        guard inputPoints.count >= 2 else { return nil }
        return inputPoints[inputPoints.count - 2]
    }

    /// Live state for debugging hold detection. Returns nil if no points fed yet.
    public struct HoldDiagnostic: Equatable {
        public let inputPointCount: Int
        public let windowSpanSeconds: TimeInterval   // how full the stability window is
        public let bboxDiagonal: CGFloat             // jitter spread within the window
        public let isHolding: Bool
    }

    public func holdDiagnostic() -> HoldDiagnostic? {
        guard let last = inputPoints.last else { return nil }
        let now = last.timestamp
        let windowStart = now - seeds.holdStabilityWindow
        var startIdx = inputPoints.count - 1
        while startIdx > 0 && inputPoints[startIdx - 1].timestamp >= windowStart {
            startIdx -= 1
        }
        let span = now - inputPoints[startIdx].timestamp

        var minX = inputPoints[startIdx].position.x
        var maxX = minX
        var minY = inputPoints[startIdx].position.y
        var maxY = minY
        for i in (startIdx + 1)..<inputPoints.count {
            let p = inputPoints[i].position
            if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
        }
        let dx = maxX - minX
        let dy = maxY - minY
        let bbox = sqrt(dx * dx + dy * dy)

        return HoldDiagnostic(
            inputPointCount: inputPoints.count,
            windowSpanSeconds: span,
            bboxDiagonal: bbox,
            isHolding: isHolding
        )
    }

    // MARK: - Hold detection

    /// True when the stylus has been held nearly stationary for at least
    /// `seeds.holdStabilityWindow`. "Stationary" = the bounding box of all
    /// position samples in the window has diagonal ≤ `seeds.holdJitterTolerance`.
    ///
    /// This formulation tolerates the natural hand tremor that's always present
    /// when a person stops moving but doesn't fully lift the pen. Per-sample
    /// velocity (the previous formulation) explodes on micro-jitter at 240 Hz
    /// and produces false negatives in real use.
    public var isHolding: Bool {
        guard inputPoints.count >= 2 else { return false }
        let now = inputPoints.last!.timestamp
        let windowStart = now - seeds.holdStabilityWindow

        // Find the oldest sample still inside the window.
        var startIdx = inputPoints.count - 1
        while startIdx > 0 && inputPoints[startIdx - 1].timestamp >= windowStart {
            startIdx -= 1
        }
        // Need at least the full window's worth of samples.
        let oldest = inputPoints[startIdx].timestamp
        if (now - oldest) < seeds.holdStabilityWindow * 0.95 {
            return false
        }

        // Compute bounding-box diagonal of positions in the window.
        var minX = inputPoints[startIdx].position.x
        var maxX = minX
        var minY = inputPoints[startIdx].position.y
        var maxY = minY
        for i in (startIdx + 1)..<inputPoints.count {
            let p = inputPoints[i].position
            if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
        }
        let dx = maxX - minX
        let dy = maxY - minY
        let bboxDiagonal = sqrt(dx * dx + dy * dy)
        return bboxDiagonal <= seeds.holdJitterTolerance
    }

    // MARK: - Classification core

    private func runFullClassification() {
        let positions = inputPoints.map(\.position)

        guard let (classification, bbox) = Preprocessing.process(positions, seeds: seeds) else {
            cachedVerdict = .abstain(.tooShort)
            cachedScore = 0
            lastFeatureSnapshot = nil
            return
        }

        guard let line = fitLineTLS(classification, strokeScale: bbox) else {
            cachedVerdict = .abstain(.tooShort)
            cachedScore = 0
            lastFeatureSnapshot = nil
            return
        }

        guard let features = FeatureExtraction.extractLineFeatures(
            classification,
            bboxDiagonal: bbox,
            line: line
        ) else {
            cachedVerdict = .abstain(.tooShort)
            cachedScore = 0
            lastFeatureSnapshot = nil
            return
        }

        // Route on closure: closureRatio ≤ closureGate → closed-stroke branch
        // (ellipse/circle); otherwise → open-stroke branch (line).
        if features.closureRatio <= seeds.closureGate {
            classifyClosed(features: features, classification: classification, bbox: bbox)
        } else {
            classifyOpen(features: features, line: line, positions: positions)
        }
    }

    // MARK: - Open-stroke (line vs arc) branch

    private func classifyOpen(features: LineFeatures, line: LineFit, positions: [CGPoint]) {
        let lineScoreVal = LineClassifier.lineScore(features)

        // Try the arc fit alongside the line. If the fit fails (degenerate
        // input), arc score is nil and line decides on its own.
        let circle = fitCircleTaubin(positions, strokeScale: features.bboxDiagonal, seeds: seeds)
        let arcCoverage: CGFloat?
        let circleNormRMS: CGFloat?
        let arcScoreVal: CGFloat?
        if let circle = circle {
            let coverage = arcCoverageDegrees(positions, center: circle.center)
            arcCoverage = coverage
            circleNormRMS = circle.normRMS
            arcScoreVal = ArcClassifier.arcScore(
                features: features,
                circleNormRMS: circle.normRMS,
                arcCoverageDeg: coverage
            )
        } else {
            arcCoverage = nil
            circleNormRMS = nil
            arcScoreVal = nil
        }

        // Pick the winner. Arc must beat line by at least lineArcMargin to
        // overcome the user's expectation that "lines are simpler" — a stroke
        // that's plausibly either should default to line.
        let arcWins: Bool
        if let arcScoreVal = arcScoreVal {
            arcWins = arcScoreVal >= lineScoreVal + seeds.lineArcMargin
        } else {
            arcWins = false
        }

        let topScore = arcWins ? (arcScoreVal ?? 0) : lineScoreVal
        cachedScore = topScore

        lastFeatureSnapshot = FeatureSnapshot(
            pathLength: features.pathLength,
            bboxDiagonal: features.bboxDiagonal,
            closureRatio: features.closureRatio,
            sagittaRatio: features.sagittaRatio,
            totalAbsTurnDeg: features.totalAbsTurnDeg,
            totalSignedTurnDeg: features.totalSignedTurnDeg,
            signRatio: features.signRatio,
            lineNormRMS: features.lineNormRMS,
            circleNormRMS: circleNormRMS,
            arcCoverageDeg: arcCoverage,
            ellipseNormResidual: nil,
            ellipseAxisRatio: nil,
            resampledPointCount: features.resampledCount,
            lineScore: lineScoreVal,
            arcScore: arcScoreVal,
            ellipseScore: nil
        )

        // Floors apply regardless of which won.
        if let reason = LineClassifier.abstainReason(features: features, score: topScore, seeds: seeds) {
            cachedVerdict = .abstain(reason)
            return
        }

        if arcWins, let circle = circle, let coverage = arcCoverage {
            // Arc-too-shallow guard.
            if coverage < seeds.arcCoverageMin {
                cachedVerdict = .abstain(.arcTooShallow)
                return
            }
            // Build ArcGeometry: project raw first/last onto the fitted circle
            // (radial projection) so the arc starts/ends near where the user
            // actually drew. Sweep direction follows totalSignedTurn sign.
            let startAngle = atan2(positions.first!.y - circle.center.y,
                                   positions.first!.x - circle.center.x)
            let endAngle = atan2(positions.last!.y - circle.center.y,
                                 positions.last!.x - circle.center.x)
            let sweep: ArcGeometry.Sweep =
                features.totalSignedTurnRad >= 0 ? .counterClockwise : .clockwise
            cachedVerdict = .arc(ArcGeometry(
                center: circle.center,
                radius: circle.radius,
                startAngle: startAngle,
                endAngle: endAngle,
                sweep: sweep
            ))
            return
        }

        // Line wins (or arc unavailable).
        let geom = projectEndpoints(
            rawFirst: positions.first!,
            rawLast: positions.last!,
            line: line
        )
        cachedVerdict = .line(geom)
    }

    // MARK: - Closed-stroke (ellipse/circle) branch

    private func classifyClosed(features: LineFeatures, classification: [CGPoint], bbox: CGFloat) {
        // Try to fit an ellipse. If the fit fails (degenerate input,
        // numerical issues, or validation gates), abstain with a clear reason.
        guard let ellipseFit = fitEllipseHalirFlusser(classification, strokeScale: bbox, seeds: seeds) else {
            cachedScore = 0
            lastFeatureSnapshot = FeatureSnapshot(
                pathLength: features.pathLength,
                bboxDiagonal: features.bboxDiagonal,
                closureRatio: features.closureRatio,
                sagittaRatio: features.sagittaRatio,
                totalAbsTurnDeg: features.totalAbsTurnDeg,
                totalSignedTurnDeg: features.totalSignedTurnDeg,
                signRatio: features.signRatio,
                lineNormRMS: features.lineNormRMS,
                circleNormRMS: nil,
                arcCoverageDeg: nil,
                ellipseNormResidual: nil,
                ellipseAxisRatio: nil,
                resampledPointCount: features.resampledCount,
                lineScore: 0,
                arcScore: nil,
                ellipseScore: nil
            )
            cachedVerdict = .abstain(.degenerateEllipseFit)
            return
        }

        let baseScore = EllipseClassifier.ellipseScore(
            residual: ellipseFit.normResidual,
            closureRatio: features.closureRatio,
            axisRatio: ellipseFit.geometry.axisRatio
        )
        // Circle promotion: when axes are close to equal, add a flat bonus and
        // emit a CircleGeometry instead of EllipseGeometry. The bonus tips
        // ties toward circle when the fit is genuinely round.
        let isCircle = ellipseFit.geometry.axisRatio >= seeds.circleAxisRatioMin
        let score = baseScore + (isCircle ? EllipseClassifier.circlePromotionBonus : 0)
        cachedScore = score

        lastFeatureSnapshot = FeatureSnapshot(
            pathLength: features.pathLength,
            bboxDiagonal: features.bboxDiagonal,
            closureRatio: features.closureRatio,
            sagittaRatio: features.sagittaRatio,
            totalAbsTurnDeg: features.totalAbsTurnDeg,
            totalSignedTurnDeg: features.totalSignedTurnDeg,
            signRatio: features.signRatio,
            lineNormRMS: features.lineNormRMS,
            circleNormRMS: nil,
            arcCoverageDeg: nil,
            ellipseNormResidual: ellipseFit.normResidual,
            ellipseAxisRatio: ellipseFit.geometry.axisRatio,
            resampledPointCount: features.resampledCount,
            lineScore: 0,
            arcScore: nil,
            ellipseScore: score
        )

        if let reason = EllipseClassifier.abstainReason(features: features, score: score, seeds: seeds) {
            cachedVerdict = .abstain(reason)
            return
        }

        if isCircle {
            // Use the average semi-axis as the circle radius — feels right when
            // the ellipse is nearly round; doesn't over-anchor to either axis.
            let r = (ellipseFit.geometry.semiMajor + ellipseFit.geometry.semiMinor) / 2
            cachedVerdict = .circle(CircleGeometry(center: ellipseFit.geometry.center, radius: r))
        } else {
            cachedVerdict = .ellipse(ellipseFit.geometry)
        }
    }
}

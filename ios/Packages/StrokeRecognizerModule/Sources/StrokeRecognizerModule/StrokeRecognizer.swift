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

        let score = LineClassifier.lineScore(features)
        cachedScore = score
        lastFeatureSnapshot = FeatureSnapshot(
            pathLength: features.pathLength,
            bboxDiagonal: features.bboxDiagonal,
            sagittaRatio: features.sagittaRatio,
            totalAbsTurnDeg: features.totalAbsTurnDeg,
            totalSignedTurnDeg: features.totalSignedTurnDeg,
            lineNormRMS: features.lineNormRMS,
            resampledPointCount: features.resampledCount,
            lineScore: score
        )

        if let reason = LineClassifier.abstainReason(features: features, score: score, seeds: seeds) {
            cachedVerdict = .abstain(reason)
            return
        }

        // Snap. Project the user's actual first/last raw points onto the fit.
        let geom = projectEndpoints(
            rawFirst: positions.first!,
            rawLast: positions.last!,
            line: line
        )
        cachedVerdict = .line(geom)
    }
}

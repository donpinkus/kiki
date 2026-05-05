import CoreGraphics
import Foundation

/// Score-utility helpers — map a raw feature value into [0, 1].
enum Score {

    /// 1.0 when x = 0, 0.0 when x ≥ target, linear in between.
    static func goodLow(_ x: CGFloat, target: CGFloat) -> CGFloat {
        guard target > 0 else { return x <= 0 ? 1 : 0 }
        return max(0, min(1, 1 - x / target))
    }

    /// 0.0 when x = 0, 1.0 when x ≥ target, linear in between.
    static func goodHigh(_ x: CGFloat, target: CGFloat) -> CGFloat {
        guard target > 0 else { return x >= 0 ? 1 : 0 }
        return max(0, min(1, x / target))
    }
}

/// Line-only classifier. v0 has no other candidates competing — if the line
/// score is high enough, snap; otherwise abstain. v1 will reuse this score
/// inside a multi-candidate margin contest (see parent plan §6).
enum LineClassifier {

    /// Compute the line score from the feature vector. Always in [0, 1].
    ///
    /// Calibrated against real Apple Pencil input (Phase 0b diagnostic, 2026-04):
    /// at 240 Hz coalesced touches, hand tremor accumulates ~5-10° of jitter per
    /// 100 samples in `totalAbsTurn`. Using **signed** turn instead lets jitter
    /// cancel naturally — a noisy line has signed ≈ 0 even when abs is large.
    ///
    /// Weights:
    ///   0.45 · goodLow(lineNormRMS,        0.055)   ← unchanged (S-defender)
    ///   0.25 · goodLow(sagittaRatio,       0.130)
    ///   0.20 · goodLow(|signedTurnDeg|,    45°)
    ///   0.10 · goodLow(stableCornerCount,  1)       ← always 1.0 in v0
    ///
    /// Hold = opt-in. Sagitta and signed-turn targets are deliberately wide so
    /// 25-29° bows snap. lineNormRMS stays tight (0.055) because it's the only
    /// metric that punishes S-curves: in an S the two lobes don't cancel in RMS
    /// (squared error adds), so lineRMS climbs while signed-turn stays near 0.
    /// Without this gate, S-curves would wrong-snap.
    static func lineScore(_ features: LineFeatures) -> CGFloat {
        let signedTurnAbs = abs(features.totalSignedTurnDeg)
        return 0.45 * Score.goodLow(features.lineNormRMS, target: 0.055)
             + 0.25 * Score.goodLow(features.sagittaRatio, target: 0.130)
             + 0.20 * Score.goodLow(signedTurnAbs, target: 45)
             + 0.10  // stableCornerCount = 0 in v0 → goodLow(0, 1) = 1.0
    }

    /// Run the abstain rules in order. Returns the abstain reason if any
    /// rule fires, else nil.
    static func abstainReason(
        features: LineFeatures,
        score: CGFloat,
        seeds: RecognizerSeeds
    ) -> AbstainReason? {
        if features.pathLength < seeds.minPathLength {
            return .tooShort
        }
        if features.resampledCount < seeds.minResampledPoints {
            return .tooFewPoints
        }
        if abs(features.totalSignedTurnRad) > seeds.overtraceTurnMax {
            return .overtraced
        }
        if score < seeds.acceptScore {
            return .lowConfidence
        }
        return nil
    }
}

/// Arc classifier — competes against the line classifier for open strokes.
/// A high arc score requires: low circle-fit residual, consistent curvature
/// direction (signRatio near 1), meaningful angular sweep, visible sagitta,
/// and a reasonable totalAbsTurn.
enum ArcClassifier {

    /// Compute the arc score from features + circle fit. Always in [0, 1].
    ///
    /// Weights:
    ///   0.40 · goodLow(circleNormRMS,    0.025)
    ///   0.20 · goodHigh(signRatio,       0.85)         ← consistent direction
    ///   0.15 · goodBand(arcCoverageDeg,  30°…300°)
    ///   0.15 · goodHigh(sagittaRatio,    0.040)        ← visible bow
    ///   0.10 · goodBand(totalAbsTurnDeg, 25°…270°)
    static func arcScore(
        features: LineFeatures,
        circleNormRMS: CGFloat,
        arcCoverageDeg: CGFloat
    ) -> CGFloat {
        return 0.40 * Score.goodLow(circleNormRMS, target: 0.025)
             + 0.20 * Score.goodHigh(features.signRatio, target: 0.85)
             + 0.15 * Score.goodBand(arcCoverageDeg, low: 30, high: 300)
             + 0.15 * Score.goodHigh(features.sagittaRatio, target: 0.040)
             + 0.10 * Score.goodBand(features.totalAbsTurnDeg, low: 25, high: 270)
    }
}

/// Closed-stroke classifier — scores an ellipse fit + circle-promotion bonus.
/// Per plan §6.4. Circle promotion is a flat +0.05 bonus when axis ratio
/// passes the gate (cleaner than a goodHigh ramp, which would punish strokes
/// just above the threshold).
enum EllipseClassifier {

    /// Compute the ellipse score from the fit + features. Always in [0, 1].
    ///
    /// Weights:
    ///   0.55 · goodLow(ellipseNormResidual, 0.045)
    ///   0.25 · closureFit (1.0 when perfectly closed, 0.0 at closureGate)
    ///   0.20 · goodBand(axisRatio, 0.10, 1.00)  ← penalize slivers
    ///
    /// Like the line classifier, calibrated loose for the v0 hold-is-opt-in
    /// philosophy: a hand-drawn ellipse is rarely geometrically perfect, so
    /// we accept residuals up to ~4.5% of stroke scale.
    static func ellipseScore(
        residual: CGFloat,
        closureRatio: CGFloat,
        axisRatio: CGFloat
    ) -> CGFloat {
        // closureRatio is endpointGap/pathLength — small means well-closed.
        // 0 (perfect close) → 1.0 contribution; 0.10 (gate) → 0.0.
        let closureFit = max(0, min(1, 1 - closureRatio / 0.10))
        return 0.55 * Score.goodLow(residual, target: 0.045)
             + 0.25 * closureFit
             + 0.20 * Score.goodBand(axisRatio, low: 0.10, high: 1.00)
    }

    /// Bonus added when the ellipse passes the circle-promotion gate.
    /// Flat (not a ramp) so strokes just above the gate aren't penalized.
    static let circlePromotionBonus: CGFloat = 0.05

    /// Closed-stroke abstain rules. Mirrors LineClassifier.abstainReason
    /// shape; callers supply the relevant features+score.
    static func abstainReason(
        features: LineFeatures,
        score: CGFloat,
        seeds: RecognizerSeeds
    ) -> AbstainReason? {
        if features.pathLength < seeds.minPathLength {
            return .tooShort
        }
        if features.resampledCount < seeds.minResampledPoints {
            return .tooFewPoints
        }
        if abs(features.totalSignedTurnRad) > seeds.overtraceTurnMax {
            return .overtraced
        }
        if score < seeds.acceptScore {
            return .lowConfidence
        }
        return nil
    }
}

/// Score-utility helpers extension — `goodBand` for closed-stroke scoring.
extension Score {
    /// Plateau between low and high; falls off linearly on either side.
    /// Past `high`, falls to 0 over a 20% rolloff window.
    static func goodBand(_ x: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
        if x >= low && x <= high { return 1 }
        if x < low {
            return goodHigh(x, target: low)
        }
        let rolloff = max(high * 0.2, 0.0001)
        return goodLow(x - high, target: rolloff)
    }
}

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

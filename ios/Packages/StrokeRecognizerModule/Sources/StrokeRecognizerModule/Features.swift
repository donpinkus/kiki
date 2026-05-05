import CoreGraphics
import Foundation

/// Geometric features extracted from a preprocessed stroke.
struct LineFeatures: Equatable {
    let pathLength: CGFloat
    let bboxDiagonal: CGFloat
    let resampledCount: Int
    let chordLength: CGFloat
    /// endpointGap / pathLength. ≤ closureGate routes to closed-stroke branch.
    let closureRatio: CGFloat
    let sagittaRatio: CGFloat
    let totalSignedTurnRad: CGFloat
    let totalAbsTurnRad: CGFloat
    /// |signedTurn| / absTurn. ≈1 when the stroke turns consistently one way
    /// (arc-like), ≈0 when turning cancels (S-curve / scribble).
    let signRatio: CGFloat
    let lineNormRMS: CGFloat

    var totalAbsTurnDeg: CGFloat { totalAbsTurnRad * 180 / .pi }
    var totalSignedTurnDeg: CGFloat { totalSignedTurnRad * 180 / .pi }
}

enum FeatureExtraction {

    /// Compute the line-relevant feature set for a preprocessed point array.
    /// `bboxDiagonal` is supplied because preprocessing already computed it.
    /// Returns nil if the point array is too short to compute features.
    static func extractLineFeatures(
        _ points: [CGPoint],
        bboxDiagonal: CGFloat,
        line: LineFit
    ) -> LineFeatures? {
        guard points.count >= 2 else { return nil }

        let pathLen = Preprocessing.pathLength(points)
        let chord = distance(points.first!, points.last!)
        let closure = pathLen > 1e-6 ? chord / pathLen : 1
        let sagittaRatio = computeSagittaRatio(points, chordLength: chord)
        let (signedTurn, absTurn) = computeTurningAngles(points)
        let signRatio = absTurn > 1e-6 ? abs(signedTurn) / absTurn : 0

        return LineFeatures(
            pathLength: pathLen,
            bboxDiagonal: bboxDiagonal,
            resampledCount: points.count,
            chordLength: chord,
            closureRatio: closure,
            sagittaRatio: sagittaRatio,
            totalSignedTurnRad: signedTurn,
            totalAbsTurnRad: absTurn,
            signRatio: signRatio,
            lineNormRMS: line.normRMS
        )
    }

    // MARK: - Individual feature computations

    /// Maximum perpendicular distance of any point to the chord (segment from
    /// first to last point), divided by chord length. ~0 for straight lines;
    /// ~0.5 for a half-circle.
    static func computeSagittaRatio(_ points: [CGPoint], chordLength: CGFloat) -> CGFloat {
        guard chordLength > 1e-6, points.count >= 2 else { return 0 }
        let a = points.first!
        let b = points.last!
        // Chord direction
        let cdx = (b.x - a.x) / chordLength
        let cdy = (b.y - a.y) / chordLength
        // Normal to chord
        let nx = -cdy
        let ny = cdx

        var maxAbs: CGFloat = 0
        for p in points {
            let dx = p.x - a.x
            let dy = p.y - a.y
            let perp = abs(dx * nx + dy * ny)
            if perp > maxAbs { maxAbs = perp }
        }
        return maxAbs / chordLength
    }

    /// Returns (signedTurn, absTurn) in radians.
    /// signedTurn = Σ atan2(v_i × v_{i+1}, v_i · v_{i+1})
    /// absTurn    = Σ |signedTurn_i|
    static func computeTurningAngles(_ points: [CGPoint]) -> (signed: CGFloat, abs: CGFloat) {
        guard points.count >= 3 else { return (0, 0) }
        var signed: CGFloat = 0
        var abs_: CGFloat = 0

        var prev = unitTangent(from: points[0], to: points[1])
        for i in 2..<points.count {
            guard let tangent = unitTangent(from: points[i - 1], to: points[i]),
                  let p = prev else {
                prev = unitTangent(from: points[i - 1], to: points[i])
                continue
            }
            let cross = p.dx * tangent.dy - p.dy * tangent.dx
            let dot = p.dx * tangent.dx + p.dy * tangent.dy
            let angle = atan2(cross, dot)
            signed += angle
            abs_ += Swift.abs(angle)
            prev = tangent
        }
        return (signed, abs_)
    }

    // MARK: - Helpers

    private static func unitTangent(from a: CGPoint, to b: CGPoint) -> CGVector? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-9 else { return nil }
        return CGVector(dx: dx / len, dy: dy / len)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return sqrt(dx * dx + dy * dy)
    }
}

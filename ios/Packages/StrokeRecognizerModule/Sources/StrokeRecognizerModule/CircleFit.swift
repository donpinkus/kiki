import CoreGraphics
import Foundation

/// Result of an algebraic circle fit (Taubin variant).
struct CircleFitResult: Equatable {
    let center: CGPoint
    let radius: CGFloat
    /// RMS of `||p_i − center|| − radius`, normalized by `strokeScale`.
    let normRMS: CGFloat
}

/// Taubin's algebraic circle fit. Less biased than Kåsa for partial arcs;
/// the right pick when the input may be just a portion of the circle (which
/// is exactly the v1 arc-recognition case).
///
/// Algorithm:
///   1. Center the points at their centroid.
///   2. Compute z_i = x_i² + y_i² and Z̄ = mean(z).
///   3. Build the 3-column data matrix M with rows [(z_i − Z̄)/(2√Z̄), x_i, y_i].
///   4. Find the right singular vector for the smallest singular value of M
///      (= eigenvector for the smallest eigenvalue of MᵀM, a 3×3 matrix).
///   5. Recover algebraic coefficients (A, B, C, D) of the circle equation
///      A(x²+y²) + Bx + Cy + D = 0; D follows from D = −A·Z̄.
///   6. Center = (−B/(2A), −C/(2A)) + centroid; radius = √((B²+C²−4AD))/(2|A|).
///
/// Validation: rejects NaN/Inf, zero-A (degenerate), and radii > 5×strokeScale
/// (numerical blowup on near-line strokes — those should snap to line, not arc).
func fitCircleTaubin(
    _ points: [CGPoint],
    strokeScale: CGFloat,
    seeds: RecognizerSeeds = .default
) -> CircleFitResult? {
    guard points.count >= 3 else { return nil }
    let n = Double(points.count)

    // ---- Step 1: centroid ----
    var sumX: Double = 0, sumY: Double = 0
    for p in points { sumX += Double(p.x); sumY += Double(p.y) }
    let cx = sumX / n
    let cy = sumY / n

    // ---- Step 2: centered coords + z ----
    var xs = [Double](repeating: 0, count: points.count)
    var ys = [Double](repeating: 0, count: points.count)
    var zs = [Double](repeating: 0, count: points.count)
    var zSum: Double = 0
    for (i, p) in points.enumerated() {
        let x = Double(p.x) - cx
        let y = Double(p.y) - cy
        xs[i] = x
        ys[i] = y
        let z = x * x + y * y
        zs[i] = z
        zSum += z
    }
    let zMean = zSum / n
    guard zMean > 1e-12 else { return nil }
    let zNorm = 2 * sqrt(zMean)

    // ---- Step 3-4: build MᵀM (3×3, symmetric) and find smallest-eigenvalue eigenvector ----
    var m11: Double = 0, m12: Double = 0, m13: Double = 0
    var m22: Double = 0, m23: Double = 0
    var m33: Double = 0
    for i in 0..<points.count {
        let z0 = (zs[i] - zMean) / zNorm
        let x = xs[i]
        let y = ys[i]
        m11 += z0 * z0
        m12 += z0 * x
        m13 += z0 * y
        m22 += x * x
        m23 += x * y
        m33 += y * y
    }
    let mtm: [Double] = [
        m11, m12, m13,
        m12, m22, m23,
        m13, m23, m33,
    ]

    guard let eigs = eig3x3(mtm) else { return nil }
    // Smallest non-negative eigenvalue → its eigenvector is the algebraic fit.
    let smallest = eigs.min(by: { abs($0.value) < abs($1.value) })
    guard let (_, vec) = smallest else { return nil }

    // ---- Step 5: recover A, B, C, D ----
    var aPrime = vec[0]
    let bPrime = vec[1]
    let cPrime = vec[2]
    // Undo the (z − Z̄)/(2√Z̄) normalization on the z column to get the
    // physical A coefficient.
    aPrime = aPrime / zNorm
    let A = aPrime
    let B = bPrime
    let C = cPrime
    let D = -A * zMean - B * 0 - C * 0  // simplifies to -A·Z̄ since centered (mean x = mean y = 0)
    guard abs(A) > 1e-12 else { return nil }

    // ---- Step 6: center + radius ----
    let centerXNorm = -B / (2 * A)
    let centerYNorm = -C / (2 * A)
    let radiusSqDoubleAreaNumerator = B * B + C * C - 4 * A * D
    guard radiusSqDoubleAreaNumerator > 0 else { return nil }
    let radius = sqrt(radiusSqDoubleAreaNumerator) / (2 * abs(A))

    // Translate center back to world coords (we centered around the centroid).
    let center = CGPoint(x: CGFloat(centerXNorm + cx), y: CGFloat(centerYNorm + cy))
    let r = CGFloat(radius)

    // Validation
    guard r.isFinite, center.x.isFinite, center.y.isFinite else { return nil }
    guard r > 0 else { return nil }
    guard r <= 5 * strokeScale else { return nil }
    _ = seeds  // (reserved for future seed-driven validation)

    // RMS residual
    var sumSq: Double = 0
    for p in points {
        let dx = Double(p.x) - Double(center.x)
        let dy = Double(p.y) - Double(center.y)
        let d = sqrt(dx * dx + dy * dy) - radius
        sumSq += d * d
    }
    let rms = sqrt(sumSq / n)
    let normRMS = CGFloat(rms / max(Double(strokeScale), 1))

    return CircleFitResult(center: center, radius: r, normRMS: normRMS)
}

// MARK: - Arc geometry helpers

/// Compute total absolute angular sweep traversed by `points` around `center`,
/// using stroke order. Unwraps ±π discontinuities. Returns degrees.
func arcCoverageDegrees(_ points: [CGPoint], center: CGPoint) -> CGFloat {
    guard points.count >= 2 else { return 0 }
    var prev = atan2(points[0].y - center.y, points[0].x - center.x)
    var cumulative: CGFloat = 0
    for i in 1..<points.count {
        let cur = atan2(points[i].y - center.y, points[i].x - center.x)
        var d = cur - prev
        if d > .pi { d -= 2 * .pi }
        else if d < -.pi { d += 2 * .pi }
        cumulative += d
        prev = cur
    }
    return abs(cumulative) * 180 / .pi
}

/// Angle (radians) of `point` from `center`, in (-π, π].
func angleDegFromCenter(_ point: CGPoint, center: CGPoint) -> CGFloat {
    return atan2(point.y - center.y, point.x - center.x)
}

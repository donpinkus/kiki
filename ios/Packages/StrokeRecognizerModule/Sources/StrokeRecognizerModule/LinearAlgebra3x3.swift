import Foundation

// 3×3 matrix helpers shared between fitters (row-major, double precision).
// Visibility: file-level functions (internal to the module) so EllipseFit
// and CircleFit can both call them.

func matmul3x3(_ a: [Double], _ b: [Double]) -> [Double] {
    var r = [Double](repeating: 0, count: 9)
    for i in 0..<3 {
        for j in 0..<3 {
            var sum: Double = 0
            for k in 0..<3 { sum += a[i * 3 + k] * b[k * 3 + j] }
            r[i * 3 + j] = sum
        }
    }
    return r
}

func matvec3x3(_ m: [Double], _ v: [Double]) -> [Double] {
    return [
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    ]
}

func transpose3x3(_ m: [Double]) -> [Double] {
    return [
        m[0], m[3], m[6],
        m[1], m[4], m[7],
        m[2], m[5], m[8],
    ]
}

/// 3×3 inverse via cofactors. Returns nil if det is too small.
func inv3x3(_ m: [Double]) -> [Double]? {
    let a = m[0], b = m[1], c = m[2]
    let d = m[3], e = m[4], f = m[5]
    let g = m[6], h = m[7], i = m[8]
    let det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    guard abs(det) > 1e-12 else { return nil }
    let invDet = 1.0 / det
    return [
        invDet * (e * i - f * h),
        invDet * (c * h - b * i),
        invDet * (b * f - c * e),
        invDet * (f * g - d * i),
        invDet * (a * i - c * g),
        invDet * (c * d - a * f),
        invDet * (d * h - e * g),
        invDet * (b * g - a * h),
        invDet * (a * e - b * d),
    ]
}

/// Eigenvalues + right eigenvectors of a 3×3 non-symmetric real matrix.
/// Returns up to 3 (eigenvalue, eigenvector) pairs for real eigenvalues.
/// Complex roots are skipped. Eigenvectors are normalized to unit length.
func eig3x3(_ m: [Double]) -> [(value: Double, vector: [Double])]? {
    // Characteristic polynomial: λ³ + c2·λ² + c1·λ + c0 = 0
    let trace = m[0] + m[4] + m[8]
    let m2sum =
        m[0] * m[4] - m[1] * m[3] +
        m[0] * m[8] - m[2] * m[6] +
        m[4] * m[8] - m[5] * m[7]
    let det =
        m[0] * (m[4] * m[8] - m[5] * m[7]) -
        m[1] * (m[3] * m[8] - m[5] * m[6]) +
        m[2] * (m[3] * m[7] - m[4] * m[6])
    let c2 = -trace
    let c1 = m2sum
    let c0 = -det

    let roots = realCubicRoots(c2: c2, c1: c1, c0: c0)
    var result: [(Double, [Double])] = []
    for lambda in roots {
        if let v = nullspace3x3SubLambda(m: m, lambda: lambda) {
            result.append((lambda, v))
        }
    }
    return result.isEmpty ? nil : result
}

/// Real roots of λ³ + c2·λ² + c1·λ + c0 = 0 via the trigonometric method.
func realCubicRoots(c2: Double, c1: Double, c0: Double) -> [Double] {
    let p = c1 - c2 * c2 / 3
    let q = (2 * c2 * c2 * c2) / 27 - (c2 * c1) / 3 + c0
    let disc = -4 * p * p * p - 27 * q * q
    let shift = -c2 / 3

    if disc >= 0 {
        let r = sqrt(-p / 3)
        let arg = (3 * q) / (2 * p) * sqrt(-3 / p)
        let acosArg = max(-1.0, min(1.0, arg))
        let phi = acos(acosArg)
        var roots: [Double] = []
        for k in 0..<3 {
            let t = 2 * r * cos(phi / 3 - 2 * .pi * Double(k) / 3)
            roots.append(t + shift)
        }
        return roots
    } else {
        let sqrtTerm = sqrt(q * q / 4 + p * p * p / 27)
        let u = cbrt(-q / 2 + sqrtTerm)
        let v = cbrt(-q / 2 - sqrtTerm)
        return [u + v + shift]
    }
}

/// Unit vector in the nullspace of (M − λI) for a 3×3 matrix.
/// Picks the cross product of the two most-independent rows.
func nullspace3x3SubLambda(m: [Double], lambda: Double) -> [Double]? {
    var n = m
    n[0] -= lambda
    n[4] -= lambda
    n[8] -= lambda
    let r0 = (n[0], n[1], n[2])
    let r1 = (n[3], n[4], n[5])
    let r2 = (n[6], n[7], n[8])
    let candidates = [
        cross3(r0, r1),
        cross3(r0, r2),
        cross3(r1, r2),
    ]
    var best: (Double, Double, Double)?
    var bestMag: Double = 0
    for c in candidates {
        let mag = c.0 * c.0 + c.1 * c.1 + c.2 * c.2
        if mag > bestMag {
            bestMag = mag
            best = c
        }
    }
    guard let v = best, bestMag > 1e-18 else { return nil }
    let len = sqrt(bestMag)
    return [v.0 / len, v.1 / len, v.2 / len]
}

func cross3(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) {
    return (
        a.1 * b.2 - a.2 * b.1,
        a.2 * b.0 - a.0 * b.2,
        a.0 * b.1 - a.1 * b.0
    )
}

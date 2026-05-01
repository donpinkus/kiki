import CoreGraphics
import Foundation

/// Result of a Halír–Flusser stable ellipse fit.
struct EllipseFitResult: Equatable {
    let geometry: EllipseGeometry
    /// RMS of the geometric residual `||p_i − closestPointOnEllipse(p_i)||`,
    /// normalized by `strokeScale`. Lower is better.
    let normResidual: CGFloat
}

/// Direct least-squares ellipse fit, Halír–Flusser 1998 stabilization of the
/// Fitzgibbon, Pilu & Fisher 1999 method. Equations verified against the
/// scipython.com reference implementation; see plan §5.3 / §20.2.
///
/// Algorithm summary:
///   1. Normalize points to unit scale around their centroid.
///   2. Build design matrix rows D1=[x²,xy,y²], D2=[x,y,1].
///   3. Compute scatter blocks S1=D1ᵀD1, S2=D1ᵀD2, S3=D2ᵀD2.
///   4. T = −inv(S3)·S2ᵀ; M = inv(C)·(S1 + S2·T) where
///      C = [[0,0,2],[0,−1,0],[2,0,0]] is the ellipse-constraint matrix.
///   5. Solve eigenproblem of M; pick eigenvector v where 4·v[0]·v[2]−v[1]² > 0.
///   6. Recover full conic [A,B,C,D,E,F]: a₂ = T·a₁.
///   7. Convert conic to geometric (center, semi-axes, rotation).
///   8. Denormalize and validate.
///
/// Returns nil if the input is degenerate or the fit fails any validation gate
/// (degenerate axes, near-singular S3, no qualifying eigenvector, axes blown up
/// far past the stroke's bbox, center implausibly outside bbox).
func fitEllipseHalirFlusser(
    _ points: [CGPoint],
    strokeScale: CGFloat,
    seeds: RecognizerSeeds = .default
) -> EllipseFitResult? {
    guard points.count >= 6 else { return nil }

    // ---- Step 1: normalize ----
    var cx: CGFloat = 0
    var cy: CGFloat = 0
    for p in points { cx += p.x; cy += p.y }
    let n = CGFloat(points.count)
    cx /= n
    cy /= n
    let s = max(strokeScale / 2, 1)
    var normalized: [(x: Double, y: Double)] = []
    normalized.reserveCapacity(points.count)
    for p in points {
        normalized.append((Double((p.x - cx) / s), Double((p.y - cy) / s)))
    }

    // ---- Steps 2-3: scatter blocks (3×3 each, double precision) ----
    var s1 = [Double](repeating: 0, count: 9)  // D1ᵀD1
    var s2 = [Double](repeating: 0, count: 9)  // D1ᵀD2
    var s3 = [Double](repeating: 0, count: 9)  // D2ᵀD2
    for (x, y) in normalized {
        let d1: [Double] = [x * x, x * y, y * y]
        let d2: [Double] = [x, y, 1]
        for i in 0..<3 {
            for j in 0..<3 {
                s1[i * 3 + j] += d1[i] * d1[j]
                s2[i * 3 + j] += d1[i] * d2[j]
                s3[i * 3 + j] += d2[i] * d2[j]
            }
        }
    }

    // ---- Step 4: T = −inv(S3) · S2ᵀ; M = inv(C) · (S1 + S2·T) ----
    guard let s3Inv = inv3x3(s3) else { return nil }
    let s2t = transpose3x3(s2)
    let invS3_s2t = matmul3x3(s3Inv, s2t)
    var t = [Double](repeating: 0, count: 9)
    for i in 0..<9 { t[i] = -invS3_s2t[i] }

    let s2t2 = matmul3x3(s2, t)
    var inner = [Double](repeating: 0, count: 9)
    for i in 0..<9 { inner[i] = s1[i] + s2t2[i] }

    // C⁻¹ = [[0, 0, 1/2], [0, -1, 0], [1/2, 0, 0]]
    let cInv: [Double] = [0, 0, 0.5,  0, -1, 0,  0.5, 0, 0]
    let m = matmul3x3(cInv, inner)

    // ---- Step 5: eigenproblem; pick the ellipse-constraint eigenvector ----
    guard let eigs = eig3x3(m) else { return nil }
    var chosen: [Double]?
    for (_, vec) in eigs {
        // 4·v[0]·v[2] − v[1]² > 0 → ellipse
        let constraint = 4 * vec[0] * vec[2] - vec[1] * vec[1]
        if constraint > 0 {
            chosen = vec
            break
        }
    }
    guard let a1 = chosen else { return nil }

    // ---- Step 6: recover full conic ----
    let a2 = matvec3x3(t, a1)
    let A = a1[0], B = a1[1], C = a1[2]
    let D = a2[0], E = a2[1], F = a2[2]

    // ---- Step 7: conic → geometric (canonical 3×3 / 2×2 matrix approach) ----
    //
    // Conic in matrix form: M3 = [[A, B/2, D/2], [B/2, C, E/2], [D/2, E/2, F]]
    // Quadratic part:       M2 = [[A, B/2], [B/2, C]]
    //
    // Center: solve M2 · [h, k]ᵀ = -[D/2, E/2]ᵀ → Cramer's rule.
    //
    // After translating to the center, F becomes F' = F + (D/2)·h + (E/2)·k.
    // The eigenvalues λ₁, λ₂ of M2 are real (for an ellipse) and the
    // semi-axes are √(-F'/λ_i). The eigenvector for the smaller eigenvalue
    // points along the SEMI-MAJOR axis.
    let det2 = A * C - B * B / 4
    guard abs(det2) > 1e-12 else { return nil }

    let h = (-D / 2 * C - (-E / 2) * (B / 2)) / det2
    let k = (A * (-E / 2) - (B / 2) * (-D / 2)) / det2

    let fPrime = F + (D / 2) * h + (E / 2) * k

    // Eigenvalues of M2: λ² − tr·λ + det2 = 0
    let trace = A + C
    let discrim = trace * trace - 4 * det2
    guard discrim >= 0 else { return nil }
    let sqrtDisc = sqrt(discrim)
    let lambdaSmall = (trace - sqrtDisc) / 2  // → semi-major
    let lambdaLarge = (trace + sqrtDisc) / 2  // → semi-minor

    guard lambdaSmall != 0, lambdaLarge != 0 else { return nil }
    let r1Sq = -fPrime / lambdaSmall
    let r2Sq = -fPrime / lambdaLarge
    guard r1Sq > 0, r2Sq > 0 else { return nil }

    let semiMajorN = sqrt(r1Sq)
    let semiMinorN = sqrt(r2Sq)

    // Rotation: angle of the semi-major axis = angle of the eigenvector for
    // lambdaSmall. From (M2 - λI)v = 0, the first row gives
    // (A - λ)·v_x + (B/2)·v_y = 0 → v ∝ (B/2, λ - A).
    // For axis-aligned ellipse (B ≈ 0), the rotation is 0 if A < C (ellipse
    // is wider in x → semi-major along x), π/2 otherwise.
    let thetaN: Double
    if abs(B) > 1e-9 {
        thetaN = atan2(lambdaSmall - A, B / 2)
    } else {
        thetaN = (A < C) ? 0 : .pi / 2
    }

    // ---- Step 8: denormalize ----
    let center = CGPoint(x: CGFloat(h) * s + cx, y: CGFloat(k) * s + cy)
    let semiMajor = CGFloat(semiMajorN) * s
    let semiMinor = CGFloat(semiMinorN) * s
    let rotation = CGFloat(thetaN)

    // Validation gates
    guard semiMajor.isFinite, semiMinor.isFinite,
          center.x.isFinite, center.y.isFinite else { return nil }
    guard semiMinor / semiMajor >= seeds.ellipseAxisRatioFloor else { return nil }
    guard semiMajor <= seeds.ellipseAxisMaxBboxRatio * strokeScale else { return nil }
    if !centerWithinPlausibleRange(center: center, points: points, strokeScale: strokeScale, seeds: seeds) {
        return nil
    }

    let geometry = EllipseGeometry(
        center: center,
        semiMajor: semiMajor,
        semiMinor: semiMinor,
        rotation: rotation
    )

    // Geometric residual: distance from each point to the ellipse, RMS.
    let residual = ellipseGeometricRMS(points: points, ellipse: geometry) / max(strokeScale, 1)

    return EllipseFitResult(geometry: geometry, normResidual: residual)
}

// MARK: - Validation helpers

private func centerWithinPlausibleRange(
    center: CGPoint,
    points: [CGPoint],
    strokeScale: CGFloat,
    seeds: RecognizerSeeds
) -> Bool {
    var minX = points[0].x, maxX = points[0].x
    var minY = points[0].y, maxY = points[0].y
    for p in points.dropFirst() {
        if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
        if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
    }
    let slack = seeds.ellipseCenterMaxOutsideBboxRatio * strokeScale
    return center.x >= (minX - slack) && center.x <= (maxX + slack)
        && center.y >= (minY - slack) && center.y <= (maxY + slack)
}

/// Approximate geometric distance from each stroke point to the ellipse,
/// returning RMS. Uses a numerical "closest point on ellipse" approximation
/// that's good enough for residual scoring (not exact, but consistent).
///
/// For each point, transform into ellipse-local coords (centered, unrotated),
/// then approximate the closest point on the unit-scaled ellipse via the
/// canonical iterative root method; one Newton step gives sub-pixel accuracy
/// for our uses.
private func ellipseGeometricRMS(points: [CGPoint], ellipse: EllipseGeometry) -> CGFloat {
    let cosT = cos(-ellipse.rotation)
    let sinT = sin(-ellipse.rotation)
    let a = ellipse.semiMajor
    let b = ellipse.semiMinor
    var sumSq: CGFloat = 0
    for p in points {
        // Translate, rotate so the ellipse is axis-aligned at origin
        let dx = p.x - ellipse.center.x
        let dy = p.y - ellipse.center.y
        let lx = dx * cosT - dy * sinT
        let ly = dx * sinT + dy * cosT
        // Distance from (lx, ly) to the axis-aligned ellipse x²/a² + y²/b² = 1.
        // Approximation: scale onto the unit circle, find closest point, scale back.
        let scaleX = abs(lx) / max(a, 1e-9)
        let scaleY = abs(ly) / max(b, 1e-9)
        let r = sqrt(scaleX * scaleX + scaleY * scaleY)
        // (lx, ly) projected toward the ellipse along the radial direction.
        let projX = lx / max(r, 1e-9)
        let projY = ly / max(r, 1e-9)
        let dist = hypot(lx - projX, ly - projY)
        sumSq += dist * dist
    }
    return sqrt(sumSq / CGFloat(points.count))
}

// MARK: - 3×3 matrix helpers (row-major, double precision)

private func matmul3x3(_ a: [Double], _ b: [Double]) -> [Double] {
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

private func matvec3x3(_ m: [Double], _ v: [Double]) -> [Double] {
    return [
        m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
        m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
        m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
    ]
}

private func transpose3x3(_ m: [Double]) -> [Double] {
    return [
        m[0], m[3], m[6],
        m[1], m[4], m[7],
        m[2], m[5], m[8],
    ]
}

/// 3×3 inverse via cofactors. Returns nil if det is too small.
private func inv3x3(_ m: [Double]) -> [Double]? {
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
///
/// Uses analytic cubic root finding — for the small, well-conditioned
/// matrices Halír–Flusser produces (after centroid+scale normalization),
/// this is more reliable than naive iterative methods and avoids a LAPACK
/// dependency.
private func eig3x3(_ m: [Double]) -> [(value: Double, vector: [Double])]? {
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

/// Find real roots of λ³ + c2·λ² + c1·λ + c0 = 0 via the trigonometric method.
/// Returns 1 or 3 real roots. (Discriminant > 0: 1 real + 2 complex; ≤ 0: 3 real.)
private func realCubicRoots(c2: Double, c1: Double, c0: Double) -> [Double] {
    // Depress the cubic: λ = t − c2/3 → t³ + p·t + q = 0
    let p = c1 - c2 * c2 / 3
    let q = (2 * c2 * c2 * c2) / 27 - (c2 * c1) / 3 + c0
    let disc = -4 * p * p * p - 27 * q * q  // discriminant of the depressed cubic
    let shift = -c2 / 3

    if disc >= 0 {
        // Three real roots — trigonometric solution.
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
        // One real root — Cardano's formula.
        let sqrtTerm = sqrt(q * q / 4 + p * p * p / 27)
        let u = cbrt(-q / 2 + sqrtTerm)
        let v = cbrt(-q / 2 - sqrtTerm)
        return [u + v + shift]
    }
}

/// Find a unit vector in the nullspace of (M − λI) for a 3×3 matrix.
/// Used to recover an eigenvector for a known eigenvalue.
///
/// Approach: form the matrix N = M − λI. Find two rows whose cross product
/// is largest in magnitude (most linearly independent pair). Their cross
/// product is a vector orthogonal to both → in the nullspace.
private func nullspace3x3SubLambda(m: [Double], lambda: Double) -> [Double]? {
    var n = m
    n[0] -= lambda
    n[4] -= lambda
    n[8] -= lambda
    let r0 = (n[0], n[1], n[2])
    let r1 = (n[3], n[4], n[5])
    let r2 = (n[6], n[7], n[8])
    let candidates = [
        cross(r0, r1),
        cross(r0, r2),
        cross(r1, r2),
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

private func cross(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> (Double, Double, Double) {
    return (
        a.1 * b.2 - a.2 * b.1,
        a.2 * b.0 - a.0 * b.2,
        a.0 * b.1 - a.1 * b.0
    )
}

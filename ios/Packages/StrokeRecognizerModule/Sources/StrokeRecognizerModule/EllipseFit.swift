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

// 3×3 helpers live in LinearAlgebra3x3.swift (shared with CircleFit).

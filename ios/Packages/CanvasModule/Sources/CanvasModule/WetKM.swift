import Foundation
import simd

/// Pure-math core of the wet brush's spectral Kubelka-Munk pigment mixing (pro-brush
/// Phase 4 Step 2) plus the premultiplied-`_srgb`-texel recovery used by the CPU pickup.
///
/// Deliberately **UIKit/Metal-free** so `OfflineTests/main.swift` can compile this file
/// on macOS and assert the exact shipped math against reference values (same pattern as
/// `BrushDynamics.swift`; per `feedback_verify_shader_color_offline`). `CanvasRenderer`
/// owns the Metal side: it builds Float copies of these tables for the fragment shader
/// (`wetStampFragment`, which mirrors `mix(_:_:_:)` in MSL) and calls into here for the
/// CPU carried-load evolution.
enum WetKM {

    /// Number of reflectance bands (400–700 nm).
    static let bandCount = 36

    /// sRGB transfer decode (encoded → linear), the scalar used at every byte boundary.
    static func s2l(_ c: Float) -> Float { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    /// Recover a STRAIGHT LINEAR color + alpha from one premultiplied `.bgra8Unorm_srgb`
    /// texel. The texture stores `sRGB_encode(linear × alpha)` — premultiplication happens
    /// in LINEAR space (shaders emit linear premult; the `_srgb` store encodes it). Because
    /// the transfer function is nonlinear, the order is load-bearing: DECODE each byte
    /// first, THEN un-premultiply. The reverse order (dividing the encoded byte by alpha,
    /// then decoding) returns colors up to ~3× too light on semi-transparent paint and
    /// silently saturates via its pre-decode clamp — shipped bug in the wet smear pickup,
    /// fixed 2026-07-14. The GPU wet shader always had the correct order for free:
    /// framebuffer fetch of an `_srgb` attachment yields already-linear premult values.
    static func straightLinear(b: UInt8, g: UInt8, r: UInt8, a: UInt8) -> (color: SIMD3<Float>, alpha: Float) {
        let af = Float(a) / 255.0
        guard af > 1e-4 else { return (SIMD3<Float>(0, 0, 0), 0) }
        func recover(_ v: UInt8) -> Float { min(s2l(Float(v) / 255.0) / af, 1.0) }
        return (SIMD3<Float>(recover(r), recover(g), recover(b)), af)
    }

    /// Build the spectral-mixing tables once: the 7 Mallett-Yuksel basis reflectance
    /// spectra (locked tuning) and the per-band spectrum→linear-RGB matrix (Wyman CMF
    /// approx + D65). Ported from the km_tune_final spike — see
    /// `documents/references/wet-paint-color-spike/`.
    static func buildTables() -> (basis: [[Double]], mat: [SIMD3<Double>]) {
        let NB = bandCount
        let wl: [Double] = (0..<NB).map { 400.0 + Double($0) * (300.0 / Double(NB - 1)) }
        func g(_ x: Double, _ mu: Double, _ s1: Double, _ s2: Double) -> Double {
            let t = (x - mu) * (x < mu ? 1/s1 : 1/s2); return exp(-0.5 * t * t)
        }
        func xbar(_ l: Double) -> Double { 1.056*g(l,599.8,37.9,31.0) + 0.362*g(l,442.0,16.0,26.7) - 0.065*g(l,501.1,20.4,26.2) }
        func ybar(_ l: Double) -> Double { 0.821*g(l,568.8,46.9,40.5) + 0.286*g(l,530.9,16.3,31.1) }
        func zbar(_ l: Double) -> Double { 1.217*g(l,437.0,11.8,36.0) + 0.681*g(l,459.0,26.0,13.8) }
        func d65(_ l: Double) -> Double { 100.0*exp(-0.5*pow((l-470)/260,2)) + 12.0*exp(-0.5*pow((l-600)/90,2)) }
        let ill = wl.map(d65), xb = wl.map(xbar), yb = wl.map(ybar), zb = wl.map(zbar)
        var knorm = 0.0; for i in 0..<NB { knorm += ill[i]*yb[i] }

        var mat = [SIMD3<Double>](repeating: .zero, count: NB)
        for i in 0..<NB {
            let e = ill[i] / knorm
            let X = e*xb[i], Y = e*yb[i], Z = e*zb[i]
            mat[i] = SIMD3<Double>(
                 3.2406*X - 1.5372*Y - 0.4986*Z,
                -0.9689*X + 1.8758*Y + 0.0415*Z,
                 0.0557*X - 0.2040*Y + 1.0570*Z)
        }

        func clampS(_ v: Double) -> Double { max(0.004, min(1.0, v)) }
        func sig(_ x: Double) -> Double { 1/(1+exp(-x)) }
        func bump(_ l: Double, _ mu: Double, _ w: Double) -> Double { exp(-0.5*pow((l-mu)/w,2)) }
        let aS = 0.32, wS = 26.0, aR = 0.32   // locked blue-basis tuning
        func basis(_ k: Int, _ l: Double) -> Double {
            switch k {
            case 0: return clampS(0.985)                                              // white
            case 1: return clampS(0.02 + 0.96*sig((555 - l)/20))                      // cyan
            case 2: return clampS(0.02 + 0.96*(sig((465 - l)/18) + sig((l-595)/18)))  // magenta
            case 3: return clampS(0.02 + 0.96*sig((l - 520)/16))                      // yellow
            case 4: return clampS(0.02 + 0.96*sig((l - 595)/10))                      // red
            case 5: return clampS(0.02 + 0.96*bump(l,540,42))                         // green
            default: return clampS(0.02 + 0.96*(bump(l,458,32) + aS*bump(l,520,wS) + aR*bump(l,660,30)) * sig((l-415)/12)) // blue
            }
        }
        var basisD = [[Double]]()
        for k in 0..<7 { basisD.append(wl.map { basis(k, $0) }) }
        return (basisD, mat)
    }

    /// Mallett-Yuksel sorted-channel upsample: linear RGB → 36-band reflectance spectrum.
    static func upsample(_ lin: SIMD3<Double>, basis: [[Double]]) -> [Double] {
        let NB = bandCount
        let r = max(0, lin.x), gc = max(0, lin.y), b = max(0, lin.z)
        var w = [Double](repeating: 0, count: 7)   // white,cyan,magenta,yellow,red,green,blue
        let mn = min(r, min(gc, b)); w[0] = mn
        let rr = r - mn, gg = gc - mn, bb = b - mn
        if rr <= gg && rr <= bb { w[1] = min(gg, bb); if gg > bb { w[5] = gg - bb } else { w[6] = bb - gg } }
        else if gg <= rr && gg <= bb { w[2] = min(rr, bb); if rr > bb { w[4] = rr - bb } else { w[6] = bb - rr } }
        else { w[3] = min(rr, gg); if rr > gg { w[4] = rr - gg } else { w[5] = gg - rr } }
        var spec = [Double](repeating: 0, count: NB)
        for k in 0..<7 where w[k] > 0 { let bs = basis[k]; for i in 0..<NB { spec[i] += w[k]*bs[i] } }
        for i in 0..<NB { spec[i] = max(0.004, min(1.0, spec[i])) }
        return spec
    }

    static func ks(_ R: Double) -> Double { let r = max(1e-4, min(1.0-1e-6, R)); return (1-r)*(1-r)/(2*r) }
    static func rFromKS(_ ks: Double) -> Double { max(0, min(1, 1 + ks - sqrt(ks*ks + 2*ks))) }

    /// Spectral Kubelka-Munk mix of two linear-RGB colors (same model as the wet shader).
    /// Endpoint-exact: t=0 → a, t=1 → b. The integrated linear RGB is clamped to [0,1]
    /// BEFORE the endpoint-residual correction (the KM gotcha — see pro-brush-roadmap).
    static func mix(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float,
                    basis: [[Double]], mat: [SIMD3<Double>]) -> SIMD3<Float> {
        let td = Double(t)
        let aD = SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z))
        let bD = SIMD3<Double>(Double(b.x), Double(b.y), Double(b.z))
        let sa = upsample(aD, basis: basis), sb = upsample(bD, basis: basis)
        var mixLin = SIMD3<Double>.zero, aRT = SIMD3<Double>.zero, bRT = SIMD3<Double>.zero
        for i in 0..<bandCount {
            let A = mat[i]
            aRT += sa[i] * A; bRT += sb[i] * A
            let ksm = ks(sa[i]) * (1 - td) + ks(sb[i]) * td
            mixLin += rFromKS(ksm) * A
        }
        func cl(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(max(0,min(1,v.x)), max(0,min(1,v.y)), max(0,min(1,v.z))) }
        let m = cl(mixLin), ar = cl(aRT), br = cl(bRT)
        let out = m + (1 - td) * (aD - ar) + td * (bD - br)
        return SIMD3<Float>(Float(max(0, min(1, out.x))), Float(max(0, min(1, out.y))), Float(max(0, min(1, out.z))))
    }
}

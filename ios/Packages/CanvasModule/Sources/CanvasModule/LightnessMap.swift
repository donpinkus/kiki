import Foundation

/// P4a lightness-map tips (2026-07-15) — pure math core, UIKit/Metal-free so OfflineTests
/// asserts it (the MSL in `CanvasRenderer.lightnessShapedStampFragment` mirrors these
/// formulas; the offline suite is the shared oracle per `feedback_verify_shader_color_offline`).
///
/// The idea (Krita `KoColorSpacePreserveLightnessUtils.h:14-67`, Peter Schatz's algorithm):
/// reinterpret the grayscale tip art as a VALUE map instead of discarding everything but
/// coverage. A quadratic `f(x) = (2−4z)x² + (4z−1)x` is fitted so that `f(0)=0, f(1)=1,
/// f(0.5)=z` where `z` is the brush color's HSL lightness — so black tip pixels darken to
/// black, white lighten to white, and **mid-gray tip pixels reproduce the brush color
/// exactly** (the invariant the offline oracle pins). Hue/saturation are preserved by
/// remapping only the L of HSL.
///
/// **Color space: all of this happens in sRGB-ENCODED values** (Krita's u8 pipeline works
/// on encoded values; doing the quadratic in linear shifts the perceived midpoint — the
/// exact gamma landmine the plan flags). The fragment converts linear→work in sRGB→linear.
enum LightnessMap {

    /// HSL lightness of an sRGB color: (max+min)/2.
    static func lightness(r: Double, g: Double, b: Double) -> Double {
        (max(r, max(g, b)) + min(r, min(g, b))) / 2
    }

    /// Full HSL of an sRGB color — used to precompute the per-stroke fragment uniform
    /// (h, s, z) so the shader only runs the quadratic + HSL→RGB + s2l per pixel.
    static func hsl(r: Double, g: Double, b: Double) -> (h: Double, s: Double, l: Double) {
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else { return (0, 0, l) }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        return (h / 6, s, l)
    }

    /// Recenter COVERAGE-AUTHORED tip luma for value mapping. Our shape PNGs encode
    /// luminance = coverage (white = full paint), so in-shape luma clusters near the
    /// texture's mean, not around 0.5 like purpose-authored lightness art — feeding it
    /// to the quadratic directly washes every stroke toward white. Remap so the SHAPE'S
    /// MEAN luma lands on 0.5 (= exact brush color) and variation swings both ways.
    ///
    /// The deviation is additionally DAMPED by coverage (`m / (0.7·mean)`, clamped to 1):
    /// in coverage-authored art the anti-aliased tip EDGE also has low luma, and without
    /// damping the map reads it as "dark paint" — every stroke grows a black/gray halo
    /// (seen in the first dry-10 render). Damping makes faint texels fade toward the
    /// plain brush color while interior speckle (moderate luma at full-ish coverage)
    /// keeps most of its value swing.
    /// `neighborhood` is the tip's LOCAL coverage around the texel (shader: a coarse-mip
    /// sample). Damping on the texel's own luma cannot work — chalk's edge-falloff
    /// midtones and its interior speckle share the same m, so any per-texel knee either
    /// leaves a dark halo or erases interior structure (both observed in dry-10). The
    /// neighborhood separates them: interior speckle sits amid bright field (≈1 → full
    /// effect), boundary texels mix with outside zeros (→ damped, fade with brush color).
    static func recenter(_ m: Double, mean: Double, neighborhood: Double, gain: Double = 1.6) -> Double {
        let t = min(1, max(0, (neighborhood - 0.5) / 0.4))
        let damp = t * t * (3 - 2 * t)
        return min(1, max(0, 0.5 + (m - mean) * gain * damp))
    }

    /// The Schatz quadratic: f(0)=0, f(1)=1, f(0.5)=z.
    static func quadratic(_ x: Double, z: Double) -> Double {
        let bCoef = 4 * z - 1
        let aCoef = 2 - 4 * z
        return min(1, max(0, aCoef * x * x + bCoef * x))
    }

    /// Set the HSL lightness of an sRGB color, preserving hue + saturation.
    /// Standard HSL round-trip (RGB → H,S kept implicitly → RGB at new L).
    static func setLightness(r: Double, g: Double, b: Double, newL: Double) -> (r: Double, g: Double, b: Double) {
        let mx = max(r, max(g, b)), mn = min(r, min(g, b))
        let l = (mx + mn) / 2
        let d = mx - mn
        guard d > 1e-9 else {
            // Achromatic: lightness IS the color.
            return (newL, newL, newL)
        }
        let s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn)
        // Hue from RGB.
        var h: Double
        if mx == r { h = (g - b) / d + (g < b ? 6 : 0) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        // HSL → RGB at (h, s, newL).
        func hue2rgb(_ p: Double, _ q: Double, _ t0: Double) -> Double {
            var t = t0
            if t < 0 { t += 1 }; if t > 1 { t -= 1 }
            if t < 1.0 / 6 { return p + (q - p) * 6 * t }
            if t < 1.0 / 2 { return q }
            if t < 2.0 / 3 { return p + (q - p) * (2.0 / 3 - t) * 6 }
            return p
        }
        let q = newL < 0.5 ? newL * (1 + s) : newL + s - newL * s
        let p = 2 * newL - q
        return (hue2rgb(p, q, h + 1.0 / 3), hue2rgb(p, q, h), hue2rgb(p, q, h - 1.0 / 3))
    }

    /// Full pipeline for one tip pixel: brush sRGB color + tip luma + strength →
    /// value-mapped sRGB color. strength 0 = brush color unchanged (mode off blends in).
    static func apply(brushSRGB: (r: Double, g: Double, b: Double), tipLuma: Double,
                      strength: Double) -> (r: Double, g: Double, b: Double) {
        let z = lightness(r: brushSRGB.r, g: brushSRGB.g, b: brushSRGB.b)
        let mapped = quadratic(tipLuma, z: z)
        let l = z + (mapped - z) * min(max(strength, 0), 1)
        return setLightness(r: brushSRGB.r, g: brushSRGB.g, b: brushSRGB.b, newL: l)
    }
}

import Foundation
import CoreGraphics
import simd

/// The wet brush's incremental stroke walk (pro-brush Phase 4), extracted verbatim from
/// `MetalCanvasView.applyNewWetStamps` (2026-07-14) so the BrushHarness can drive the
/// exact shipped wet pipeline headless on macOS. **UIKit/Metal-free**: canvas access is
/// injected as closures (`sample`/`sampleAveraged` read the layer texture, `mix` is the
/// spectral KM load evolution — all three are `CanvasRenderer` methods on device).
///
/// One walker instance lives per wet stroke (created at touch-begin, discarded at
/// stroke end/cancel). `advance` processes only the points added since the last call —
/// the same incremental, cross-batch bookkeeping the eraser uses — and returns the new
/// stamps to feed `CanvasRenderer.applyWetStamps`. Each stamp packs the CURRENT carried
/// load (straight linear RGB) in rgb and the per-stamp deposit weight in alpha.
struct WetStrokeWalker {

    /// Carried paint "load" (linear straight RGB) for the smear: starts as the brush ink
    /// (or the canvas color under the first dab in smudge mode) and contaminates toward
    /// the canvas colors the stroke crosses.
    private(set) var load: SIMD3<Float> = .zero
    /// The load's carried ALPHA (smudge mode only; wet ink is the opaque-paint model).
    /// Seeded from the paint under the first dab and pulled toward each sampled alpha at
    /// the pickup rate — crossing blank canvas depletes it, so a smudge drag-off tail
    /// thins and dies instead of laying opaque paint forever. Packed per stamp as
    /// `StampInstance.wetTargetAlpha`; the wet fragment moves dst.a toward it (2026-07-15
    /// fix: smudging 40%-opacity paint used to harden it fully opaque).
    private(set) var loadAlpha: Float = 0

    private var lastPointIndex = 0
    private var lastSpacing: CGFloat
    /// Total arc length walked (document px) — drives the Charge reservoir decay.
    private var arcTotal: CGFloat = 0
    /// TRUE arc length walked since the last emitted stamp, carried across segments AND
    /// across `advance` batches (same fix as the dry walk, 2026-07-15: measuring this as
    /// the chord from the last stamp point starves deposit on tight scribbles and opens
    /// visible gaps on direction changes at speed).
    private var arcSinceLastStamp: CGFloat = 0

    init(startPosition: CGPoint, brush: BrushConfig) {
        lastSpacing = max(brush.baseWidth * brush.spacing, 0.5)
    }

    /// Walk the stroke's new points (since the previous `advance`) and return the wet
    /// stamps to render. `sample`/`sampleAveraged` return (straight linear color, alpha)
    /// at a canvas-pixel position or nil out of bounds; `mix(a, b, t)` KM-mixes a→b.
    mutating func advance(
        stroke: Stroke,
        scale: CGFloat,
        clipPath: CGPath?,
        sample: (Int, Int) -> (color: SIMD3<Float>, alpha: Float)?,
        sampleAveraged: (Int, Int) -> (color: SIMD3<Float>, alpha: Float)?,
        mix: (SIMD3<Float>, SIMD3<Float>, Float) -> SIMD3<Float>
    ) -> [CanvasRenderer.StampInstance] {
        guard stroke.points.count > lastPointIndex else { return [] }

        let brush = stroke.brush
        func s2l(_ c: CGFloat) -> Float { let x = Float(c); return x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055, 2.4) }
        // Per-stamp deposit weight = Mix alone. Opacity is expressed as the ALPHA CEILING
        // in the wet fragment (2026-07-16) — folding it in here too double-penalized:
        // translucent wet strokes both capped their alpha AND barely mixed color
        // (the fixture-3 "poor mixing" report). Opacity 1 is unchanged either way.
        let dep = Float(max(0, min(1, brush.wetStrength)))
        let baseColor = SIMD3<Float>(s2l(brush.color.red), s2l(brush.color.green), s2l(brush.color.blue))
        let hardness = Float(brush.hardness)
        let aspect = Float(min(max(brush.aspectRatio, 0.05), 1))
        let spacingFrac = max(brush.spacing, 0.02)
        let pickup = Float(max(0, min(1, brush.wetPickup)))   // how fast the load picks up canvas color
        // Charge (P7): finite paint reservoir. deposit weight × 0.5^(arc/halfLife);
        // charge 1 = bottomless (identity — pre-Charge strokes byte-identical).
        let refill = Float(max(0, min(1, brush.wetRefill)))
        let charge = max(0, min(1, brush.wetCharge))
        let chargeHalfLife: CGFloat = charge >= 0.999 ? .infinity : 180 + 3420 * charge * charge

        // Fresh paint load at the start of a stroke. SMUDGE seeds the load (color AND
        // alpha) from the CANVAS under the first dab — push existing paint, introduce no
        // new ink; starting on blank canvas seeds alpha ≈ 0, so the stroke deposits
        // nearly nothing (Procreate smudges nothing on blank canvas). A normal wet brush
        // seeds from the brush ink with the legacy opaque-paint alpha model.
        if lastPointIndex == 0 {
            if brush.wetSmudge,
               let p0 = stroke.points.first,
               let s = sampleAveraged(Int(p0.position.x * scale), Int(p0.position.y * scale)) {
                // 3×3-averaged seed: one texel is jittery on noisy paint (the GPU deposit
                // sees a soft-coverage footprint, the seed shouldn't hinge on one pixel).
                load = s.alpha > 0.02 ? s.color : baseColor
                loadAlpha = s.alpha
            } else {
                load = baseColor
                loadAlpha = brush.wetSmudge ? 0 : 1
            }
        }

        var newStamps: [CanvasRenderer.StampInstance] = []
        var spacing = lastSpacing

        // Place a stamp carrying the CURRENT load, then contaminate the load toward the
        // canvas under it (the smear: deposited color evolves & travels). In smudge mode
        // the load's ALPHA also tracks the sampled alpha — including alpha ≈ 0 over blank
        // canvas, which is what makes a drag-off tail deplete and die.
        func emit(_ pos: CGPoint, _ width: CGFloat) {
            guard clipPath.map({ $0.contains(pos) }) ?? true else { return }
            let cx = Int(pos.x * scale), cy = Int(pos.y * scale)
            // Charge: the reservoir level rides in wetTargetAlpha for INK stamps — the
            // scratch fragment scales its deposited alpha by it (the KM weight in
            // color.a stays pure Mix; over bare paper only alpha can express dryness).
            // Ink stamps never reach the RMW pipeline, so the smudge ≥0 convention is
            // safe to reuse. Smudge keeps packing its carried alpha, unchanged.
            let remaining = chargeHalfLife.isFinite ? Float(pow(0.5, Double(arcTotal / chargeHalfLife))) : 1
            newStamps.append(CanvasRenderer.StampInstance(
                center: SIMD2<Float>(Float(pos.x * scale), Float(pos.y * scale)),
                radius: Float(width * 0.5 * scale), rotation: 0,
                color: SIMD4<Float>(load.x, load.y, load.z, dep), hardness: hardness, aspect: aspect,
                wetTargetAlpha: brush.wetSmudge ? loadAlpha : remaining))
            if let s = sample(cx, cy) {
                if s.alpha > 0.05 {
                    load = mix(load, s.color, pickup * s.alpha)
                }
                if brush.wetSmudge {
                    loadAlpha += (s.alpha - loadAlpha) * pickup
                }
            }
            // Refill (ink only): pull the load back toward the brush's own ink — the
            // well is bottomless, so contamination picked up above dissipates over the
            // following dabs and the stroke returns to pure ink. Applied AFTER pickup:
            // at refill 1 the brush re-loads fully every dab (pickup never sticks).
            if !brush.wetSmudge, refill > 0 {
                load = mix(load, baseColor, refill)
            }
        }

        // First dab of the stroke (so a tap/dot deposits paint), placed once.
        if lastPointIndex == 0 {
            let p0 = stroke.points[0]
            let w0 = brush.effectiveWidth(force: p0.force, altitude: p0.altitude)
            emit(p0.position, w0)
            arcSinceLastStamp = 0
            spacing = max(w0 * spacingFrac, 0.5)
        }

        let startIdx = max(lastPointIndex, 1)
        for i in startIdx..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            let dx = curr.position.x - prev.position.x
            let dy = curr.position.y - prev.position.y
            let segDist = hypot(dx, dy)
            guard segDist > 0 else { continue }

            var traveled = max(0, spacing - arcSinceLastStamp)

            while traveled <= segDist {
                var t = traveled / segDist
                var force = prev.force + (curr.force - prev.force) * t
                var altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                var width = brush.effectiveWidth(force: force, altitude: altitude)
                // The step just taken was sized by the PREVIOUS dab's width. If THIS dab
                // came out narrower (pressure/tilt dropped — with tiltSensitivity the
                // width can swing several × within a stroke), the gap overshoots its
                // coverage and bare canvas shows through (fixture-3's white cracks).
                // Pull the dab back so its distance from the previous one fits its OWN
                // spacing. One refinement is enough — width varies smoothly.
                let ownGap = max(width * spacingFrac, 0.5)
                if ownGap < spacing {
                    traveled = max(traveled - (spacing - ownGap), 0)
                    t = traveled / segDist
                    force = prev.force + (curr.force - prev.force) * t
                    altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                    width = brush.effectiveWidth(force: force, altitude: altitude)
                }
                let x = prev.position.x + dx * t
                let y = prev.position.y + dy * t

                emit(CGPoint(x: x, y: y), width)

                spacing = max(width * spacingFrac, 0.5)
                traveled += spacing
            }
            // Post-loop `traveled` sits one gap past the last stamp (emitted or carried);
            // this recovers the arc walked since it either way (see dry-walk fix).
            arcSinceLastStamp = segDist - (traveled - spacing)
            arcTotal += segDist
        }

        lastPointIndex = stroke.points.count
        lastSpacing = spacing

        return newStamps
    }
}

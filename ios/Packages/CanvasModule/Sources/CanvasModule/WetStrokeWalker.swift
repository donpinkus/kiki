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
    private var lastStampPos: CGPoint
    private var lastSpacing: CGFloat

    init(startPosition: CGPoint, brush: BrushConfig) {
        lastStampPos = startPosition
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
        // Per-stamp deposit weight. In wet mode the Opacity slider scales deposit
        // (build-up rate) — the direct-to-layer path has no scratch ceiling to apply it to.
        let dep = Float(max(0, min(1, brush.wetStrength)) * max(0, min(1, brush.opacity)))
        let baseColor = SIMD3<Float>(s2l(brush.color.red), s2l(brush.color.green), s2l(brush.color.blue))
        let hardness = Float(brush.hardness)
        let aspect = Float(min(max(brush.aspectRatio, 0.05), 1))
        let spacingFrac = max(brush.spacing, 0.02)
        let pickup = Float(max(0, min(1, brush.wetPickup)))   // how fast the load picks up canvas color

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
        var stampPos = lastStampPos
        var spacing = lastSpacing

        // Place a stamp carrying the CURRENT load, then contaminate the load toward the
        // canvas under it (the smear: deposited color evolves & travels). In smudge mode
        // the load's ALPHA also tracks the sampled alpha — including alpha ≈ 0 over blank
        // canvas, which is what makes a drag-off tail deplete and die.
        func emit(_ pos: CGPoint, _ width: CGFloat) {
            guard clipPath.map({ $0.contains(pos) }) ?? true else { return }
            let cx = Int(pos.x * scale), cy = Int(pos.y * scale)
            newStamps.append(CanvasRenderer.StampInstance(
                center: SIMD2<Float>(Float(pos.x * scale), Float(pos.y * scale)),
                radius: Float(width * 0.5 * scale), rotation: 0,
                color: SIMD4<Float>(load.x, load.y, load.z, dep), hardness: hardness, aspect: aspect,
                wetTargetAlpha: brush.wetSmudge ? loadAlpha : -1))
            if let s = sample(cx, cy) {
                if s.alpha > 0.05 {
                    load = mix(load, s.color, pickup * s.alpha)
                }
                if brush.wetSmudge {
                    loadAlpha += (s.alpha - loadAlpha) * pickup
                }
            }
        }

        // First dab of the stroke (so a tap/dot deposits paint), placed once.
        if lastPointIndex == 0 {
            let p0 = stroke.points[0]
            let w0 = brush.effectiveWidth(force: p0.force, altitude: p0.altitude)
            emit(p0.position, w0)
            stampPos = p0.position
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

            let distFromLastStamp = hypot(prev.position.x - stampPos.x, prev.position.y - stampPos.y)
            var traveled = max(0, spacing - distFromLastStamp)

            while traveled <= segDist {
                let t = traveled / segDist
                let x = prev.position.x + dx * t
                let y = prev.position.y + dy * t
                let force = prev.force + (curr.force - prev.force) * t
                let altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                let width = brush.effectiveWidth(force: force, altitude: altitude)

                emit(CGPoint(x: x, y: y), width)

                stampPos = CGPoint(x: x, y: y)
                spacing = max(width * spacingFrac, 0.5)
                traveled += spacing
            }
        }

        lastPointIndex = stroke.points.count
        lastStampPos = stampPos
        lastSpacing = spacing

        return newStamps
    }
}

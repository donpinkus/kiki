import Foundation
import CoreGraphics
import simd

/// The eraser's incremental stroke walk, extracted from `MetalCanvasView.applyNewEraserStamps`
/// (2026-09-10) so it shares the arc-carry semantics of the dry and wet walks and can be
/// asserted offline.
///
/// The old inline walk measured "distance since the last stamp" as the straight-line
/// chord from the last stamp point — the exact starvation bug fixed in the dry walk on
/// 2026-07-15: scrubbing inside one stamp gap of the touch-down point erased nothing
/// until the pen left that circle, and a tap erased nothing (no first dab). This walker
/// carries TRUE arc length across segments AND across `advance` batches, places the
/// first dab at touch-down, and pulls a dab back when its own width shrinks so the gap
/// never overshoots coverage (same refinement as `WetStrokeWalker`).
///
/// Pure Foundation — UIKit/Metal-free. One instance per eraser stroke.
struct EraserStrokeWalker {
    /// Stamp gap as a fraction of the dab width.
    static let spacingFraction: CGFloat = 0.3

    private var lastPointIndex = 0
    private var lastSpacing: CGFloat
    /// True arc length walked since the last emitted stamp (walk units).
    private var arcSinceLastStamp: CGFloat = 0
    private let spacingFloor: CGFloat

    init(brush: BrushConfig, scale: CGFloat) {
        spacingFloor = StrokeWalkUnits.spacingFloor(scale: scale)
        lastSpacing = max(brush.baseWidth * Self.spacingFraction, spacingFloor)
    }

    /// Walk the points added since the previous call and return the new stamps
    /// (canvas pixels). `clip` discards dabs whose center is outside the selection.
    mutating func advance(stroke: Stroke, scale: CGFloat, clip: StampClip?) -> [CanvasRenderer.StampInstance] {
        guard stroke.points.count > lastPointIndex else { return [] }
        let brush = stroke.brush
        let color = SIMD4<Float>(1, 1, 1, 1)
        var out: [CanvasRenderer.StampInstance] = []
        var spacing = lastSpacing

        func emit(_ pos: CGPoint, _ width: CGFloat) {
            if let clip, !clip.contains(pos) { return }
            out.append(CanvasRenderer.StampInstance(
                center: SIMD2<Float>(Float(pos.x * scale), Float(pos.y * scale)),
                radius: Float(width * 0.5 * scale),
                rotation: 0,
                color: color))
        }

        // First dab at touch-down so a tap erases a dot.
        if lastPointIndex == 0 {
            let p0 = stroke.points[0]
            let w0 = brush.effectiveWidth(force: p0.force, altitude: p0.altitude)
            emit(p0.position, w0)
            arcSinceLastStamp = 0
            spacing = max(w0 * Self.spacingFraction, spacingFloor)
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
                // Width-pullback: the step was sized by the previous dab; if this one
                // came out narrower, pull it back so its gap fits its own coverage.
                let ownGap = max(width * Self.spacingFraction, spacingFloor)
                if ownGap < spacing {
                    traveled = max(traveled - (spacing - ownGap), 0)
                    t = traveled / segDist
                    force = prev.force + (curr.force - prev.force) * t
                    altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                    width = brush.effectiveWidth(force: force, altitude: altitude)
                }
                emit(CGPoint(x: prev.position.x + dx * t, y: prev.position.y + dy * t), width)
                spacing = max(width * Self.spacingFraction, spacingFloor)
                traveled += spacing
            }
            // Post-loop `traveled` sits one gap past the last stamp (emitted or carried).
            arcSinceLastStamp = segDist - (traveled - spacing)
        }

        lastPointIndex = stroke.points.count
        lastSpacing = spacing
        return out
    }
}

/// Walk-space length constants for every stamp walk, defined in DOCUMENT PIXELS
/// (the fixed 2048² canvas) and converted to the walk's own space via `scale`
/// (= document px per walk unit: `canvasScale` for live view-point strokes, 1 for
/// BrushHarness fixtures already in canvas px).
///
/// Before 2026-09-10 these were bare literals in "walk units" — view POINTS live but
/// canvas PIXELS on replay — so Fall Off, Charge, spacing floors and the Speed /
/// Distance sensors read ~2× differently between the iPad and the harness, and
/// between iPads of different sizes. The values below are the old literals × 2,
/// i.e. what they effectively were on the 12.9" reference iPad (canvasScale ≈ 2.16),
/// so on-device feel is preserved within ~8% and every other size/replay now matches it.
enum StrokeWalkUnits {
    /// Minimum stamp gap (document px).
    static let spacingFloorPx: CGFloat = 1
    /// Smooth-edge spacing cap floor (document px).
    static let spacingCapFloorPx: CGFloat = 1.5
    /// Width below which the smooth-edge spacing cap is skipped (document px).
    static let sagCapMinWidthPx: CGFloat = 2
    /// Fall Off die length range (document px): `dieMinPx + dieRangePx × (1−f)²`.
    static let fallOffDieMinPx: CGFloat = 500
    static let fallOffDieRangePx: CGFloat = 9500

    @inline(__always) static func spacingFloor(scale: CGFloat) -> CGFloat { spacingFloorPx / max(scale, 0.0001) }
    @inline(__always) static func spacingCapFloor(scale: CGFloat) -> CGFloat { spacingCapFloorPx / max(scale, 0.0001) }
    @inline(__always) static func sagCapMinWidth(scale: CGFloat) -> CGFloat { sagCapMinWidthPx / max(scale, 0.0001) }
    /// Sag tolerance κ (document px) → walk units. Linear in length, so scaling κ
    /// commutes with `sqrt(8κ·w/2)`.
    @inline(__always) static func sagKappa(px: CGFloat, scale: CGFloat) -> CGFloat { px / max(scale, 0.0001) }
    @inline(__always) static func fallOffDieLength(fallOff: CGFloat, scale: CGFloat) -> CGFloat {
        let f = min(max(fallOff, 0), 1)
        guard f > 0 else { return .infinity }
        return (fallOffDieMinPx + fallOffDieRangePx * (1 - f) * (1 - f)) / max(scale, 0.0001)
    }
}

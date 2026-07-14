import Foundation
import CoreGraphics
import simd

/// The pure stroke→stamps dab pipeline, extracted verbatim from `MetalCanvasView`
/// (2026-07-14) so the BrushHarness can run the exact shipped pipeline headless on
/// macOS (see `BrushHarness/README.md`). **UIKit-free by design** — everything here is
/// Foundation + CoreGraphics + simd. `MetalCanvasView.generateStampsForStroke` is now a
/// thin wrapper over `stamps(for:scale:clipPath:tuning:)`; behavior must stay
/// byte-identical to the pre-extraction code (live preview, replay, and undo all
/// re-walk strokes through this and depend on determinism for the same points + seed).
enum StrokeStampGenerator {

    /// The Brush Studio dev-panel knobs that parameterize `StrokeDynamicsState`
    /// (sensor normalization periods). Defaults match `MetalCanvasView`'s.
    struct DevTuning: Sendable {
        var maxSpeed: Double
        var distancePeriod: Double
        var fadePeriod: Double
        init(maxSpeed: Double = 1500, distancePeriod: Double = 600, fadePeriod: Double = 64) {
            self.maxSpeed = maxSpeed
            self.distancePeriod = distancePeriod
            self.fadePeriod = fadePeriod
        }
    }

    /// Stable per-stroke RNG seed derived from the stroke's UUID (FNV-1a over the 16 bytes).
    /// Stable across app launches — unlike `UUID.hashValue`, which is process-seeded — so a
    /// saved stroke's scatter/jitter replays identically after relaunch. Feeds the Fuzzy
    /// sensors + scatter (`StrokeDynamicsState`, `BrushDynamics.swift`).
    static func strokeSeed(_ id: UUID) -> UInt64 {
        let b = id.uuid
        let bytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in bytes { h = (h ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return h
    }

    /// Premultiplied stamp color. Alpha is the brush's **flow** (per-stamp deposit) —
    /// NOT opacity. The per-stroke opacity ceiling is applied separately when the
    /// scratch (active stroke) is composited onto the canvas (see
    /// `MetalCanvasView.currentStrokeOpacity` + `CanvasRenderer.activeStrokeOpacity`).
    /// This split is what lets a 30%-opacity stroke that crosses itself stay 30%
    /// instead of stacking to opaque.
    static func premultipliedColor(_ brush: BrushConfig) -> SIMD4<Float> {
        // brush.color is sRGB (display) values. Stamps render into a
        // .bgra8Unorm_srgb scratch texture, whose store applies a linear→sRGB
        // ENCODE — so the shader must be fed LINEAR values for the stored pixel to
        // equal the chosen color. Packing sRGB directly encodes a second time →
        // every stroke lands a shade too light, and (now that the eyedropper reads
        // the true canvas value) sampling a painted color and repainting it
        // compounds lighter each cycle. Convert sRGB→linear here, matching the wet
        // brush. Premultiply by flow in linear space, since the `_srgb` blend
        // pipeline composites in linear.
        func s2l(_ c: CGFloat) -> Float { let x = Float(c); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let r = s2l(brush.color.red)
        let g = s2l(brush.color.green)
        let b = s2l(brush.color.blue)
        let a = Float(brush.flow)
        return SIMD4<Float>(r * a, g * a, b * a, a)
    }

    /// Generate stamp instances for a complete stroke (used by replay + active drawing).
    /// When `clipPath` is set (lasso), stamps whose center falls outside the clip path
    /// are discarded (CPU-side clip masking).
    static func stamps(for stroke: Stroke, scale: CGFloat, clipPath: CGPath? = nil,
                              tuning: DevTuning = DevTuning()) -> [CanvasRenderer.StampInstance] {
        guard !stroke.points.isEmpty else { return [] }

        let brush = stroke.brush
        let color = premultipliedColor(brush)
        let hardness = Float(brush.hardness)
        // Spacing as a fraction of stamp width; clamped so a tiny value can't generate
        // a runaway number of stamps (the renderer also caps per-frame stamp count).
        let spacingFraction = max(brush.spacing, 0.02)
        var stamps: [CanvasRenderer.StampInstance] = []

        // Textured (non-round) shapes orient their stamps to the stroke direction so
        // anisotropic tips (dry-brush streaks, chisel) run along the line, not across it.
        // Convention: the stamp's local +y axis (the PNG's vertical) is aligned with the
        // travel direction → rotation = atan2(-dx, dy). Round (procedural) brushes are
        // radially symmetric, so they stay at 0.
        let orientsToStroke = BrushShapeCatalog.orientsToStroke(brush.shapeID)
        func strokeRotation(dx: CGFloat, dy: CGFloat) -> Float {
            guard orientsToStroke, dx != 0 || dy != 0 else { return 0 }
            return Float(atan2(-dx, dy))
        }
        // Direction at the very start/end caps, taken from the first/last real segment.
        let firstDir: (CGFloat, CGFloat) = stroke.points.count > 1
            ? (stroke.points[1].position.x - stroke.points[0].position.x,
               stroke.points[1].position.y - stroke.points[0].position.y)
            : (0, 0)

        // --- Krita-grade brush dynamics (BrushDynamics.swift) -----------------------------
        // When the brush carries non-inert `dynamics`, size/flow/rotation are resolved per
        // dab through the sensor→curve→combine→remap machine. When it does NOT (the default
        // pen and every legacy brush), `dabAttrs` returns EXACTLY today's values — width via
        // `effectiveWidth`, the constant premultiplied `color`, shape-oriented `rotation` —
        // so existing strokes are byte-identical. The per-stroke `StrokeDynamicsState` is
        // rebuilt on every call (this function re-runs per frame on the full point list), so
        // live preview, replay, and undo are deterministic for the same points + seed.
        let dyn = brush.dynamics
        let hasDyn = !(dyn?.isInert ?? true)
        func s2lLocal(_ c: CGFloat) -> Float { let x = Float(c); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        // Only the dynamics path consumes these; keep the default-pen path free of the extra
        // work (it returns before touching them). Per-stroke color jitter (if any) is applied
        // ONCE here in sRGB-HSV, then converted to linear — so the whole stroke is one coherent
        // jittered color (not per-dab speckle, which img2img averages out).
        let baseLinRGB: SIMD3<Float> = {
            guard hasDyn else { return .zero }
            var srgb = (r: Double(brush.color.red), g: Double(brush.color.green), b: Double(brush.color.blue))
            if let cj = dyn?.colorJitter, !cj.isInert {
                let s = strokeSeed(stroke.id)
                srgb = cj.applied(toSRGB: srgb,
                                  rH: brushHash01(s, 0, 0x4011),
                                  rS: brushHash01(s, 0, 0x4012),
                                  rB: brushHash01(s, 0, 0x4013))
            }
            return SIMD3<Float>(s2lLocal(CGFloat(srgb.r)), s2lLocal(CGFloat(srgb.g)), s2lLocal(CGFloat(srgb.b)))
        }()
        let baseFlow = Float(brush.flow)
        var dynState: StrokeDynamicsState? = hasDyn
            ? StrokeDynamicsState(seed: strokeSeed(stroke.id), distancePeriod: tuning.distancePeriod,
                                  fadePeriod: tuning.fadePeriod, maxSpeed: tuning.maxSpeed)
            : nil

        /// Per-dab (width, premultiplied color, rotation). The `!hasDyn` branch is today's
        /// exact behavior; the dynamics branch advances stroke state and evaluates the curve
        /// options. `dt` is the seconds across the segment this dab sits on (for the Speed sensor).
        func dabAttrs(x: CGFloat, y: CGFloat, force: CGFloat, altitude: CGFloat, azimuth: CGFloat,
                      dx: CGFloat, dy: CGFloat, dt: Double)
            -> (width: CGFloat, color: SIMD4<Float>, rotation: Float, offset: CGPoint) {
            guard hasDyn, var st = dynState else {
                return (brush.effectiveWidth(force: force, altitude: altitude), color, strokeRotation(dx: dx, dy: dy), .zero)
            }
            let input = st.advance(
                x: Double(x), y: Double(y), force: Double(force), altitude: Double(altitude),
                azimuth: Double(azimuth), dx: Double(dx), dy: Double(dy), dt: dt)
            dynState = st
            let w: CGFloat = dyn?.size != nil
                ? brush.baseWidth * CGFloat(dyn!.size!.value(input))
                : brush.effectiveWidth(force: force, altitude: altitude)
            let flowMul = dyn?.flow?.value(input) ?? 1.0
            // Clamp to [0,1]: a brush authored with flow.maxValue > 1 could otherwise produce
            // premultiplied alpha > 1 (malformed for the _srgb blend). P1-review fix.
            let a = min(1, max(0, baseFlow * Float(flowMul)))
            let col = SIMD4<Float>(baseLinRGB.x * a, baseLinRGB.y * a, baseLinRGB.z * a, a)
            var rot = strokeRotation(dx: dx, dy: dy)
            if let rotOpt = dyn?.rotation { rot += Float(rotOpt.value(input) * Double.pi) } // [-1,1] turns → ±π
            // Scatter: per-dab random center displacement, magnitude = value × dab diameter.
            // Displaces only the rendered stamp; the spacing/path walk uses the un-scattered point.
            var offset = CGPoint.zero
            if let sc = dyn?.scatter {
                let mag = sc.value(input)
                offset = CGPoint(x: w * CGFloat((2 * input.randScatterX - 1) * mag),
                                 y: w * CGFloat((2 * input.randScatterY - 1) * mag))
            }
            return (w, col, rot, offset)
        }
        // ---------------------------------------------------------------------------------

        let first = stroke.points[0]
        let firstDt = stroke.points.count > 1 ? max(0, Double(stroke.points[1].timestamp - first.timestamp)) : 0
        let firstAttr = dabAttrs(x: first.position.x, y: first.position.y, force: first.force, altitude: first.altitude,
                                 azimuth: first.azimuth, dx: firstDir.0, dy: firstDir.1, dt: firstDt)
        let firstWidth = firstAttr.width
        if clipPath.map({ $0.contains(CGPoint(x: first.position.x + firstAttr.offset.x,
                                              y: first.position.y + firstAttr.offset.y)) }) ?? true {
            stamps.append(CanvasRenderer.StampInstance(
                center: SIMD2<Float>(Float((first.position.x + firstAttr.offset.x) * scale),
                                     Float((first.position.y + firstAttr.offset.y) * scale)),
                radius: Float(firstWidth * 0.5 * scale),
                rotation: firstAttr.rotation,
                color: firstAttr.color,
                hardness: hardness
            ))
        }

        var lastStampPos = first.position
        var currentSpacing = max(firstWidth * spacingFraction, 0.5)

        for i in 1..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            let dx = curr.position.x - prev.position.x
            let dy = curr.position.y - prev.position.y
            let segmentDist = hypot(dx, dy)
            guard segmentDist > 0 else { continue }

            let leftover = hypot(prev.position.x - lastStampPos.x, prev.position.y - lastStampPos.y)
            var traveled = max(0, currentSpacing - leftover)
            let segDt = max(0, Double(curr.timestamp - prev.timestamp))
            // Shortest-arc azimuth delta so interpolation across the 0/2π seam takes the short
            // way (a chisel tip rotating past 0 must not spin ~360° backward). P1-review fix.
            var dAz = curr.azimuth - prev.azimuth
            if dAz > .pi { dAz -= 2 * .pi } else if dAz < -.pi { dAz += 2 * .pi }

            while traveled <= segmentDist {
                let t = traveled / segmentDist
                let x = prev.position.x + dx * t
                let y = prev.position.y + dy * t
                let force = prev.force + (curr.force - prev.force) * t
                let altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                let azimuth = prev.azimuth + dAz * t
                // Per-dab step (fraction of the segment) so the Speed sensor sees this dab's own
                // dt/displacement instead of the whole segment's reused N times. P1-review fix.
                let stepFrac = min(1, currentSpacing / segmentDist)
                let attr = dabAttrs(x: x, y: y, force: force, altitude: altitude, azimuth: azimuth,
                                    dx: dx * stepFrac, dy: dy * stepFrac, dt: segDt * Double(stepFrac))
                let width = attr.width

                let pos = CGPoint(x: x, y: y)
                let scattered = CGPoint(x: x + attr.offset.x, y: y + attr.offset.y)
                if clipPath.map({ $0.contains(scattered) }) ?? true {
                    stamps.append(CanvasRenderer.StampInstance(
                        center: SIMD2<Float>(Float(scattered.x * scale), Float(scattered.y * scale)),
                        radius: Float(width * 0.5 * scale),
                        rotation: attr.rotation,
                        color: attr.color,
                        hardness: hardness
                    ))
                }

                lastStampPos = pos
                currentSpacing = max(width * spacingFraction, 0.5)
                traveled += currentSpacing
            }
        }

        // End cap.
        if let last = stroke.points.last {
            let n = stroke.points.count
            let lastDir: (CGFloat, CGFloat) = n > 1
                ? (last.position.x - stroke.points[n - 2].position.x,
                   last.position.y - stroke.points[n - 2].position.y)
                : firstDir
            let lastDt = n > 1 ? max(0, Double(last.timestamp - stroke.points[n - 2].timestamp)) : 0
            let attr = dabAttrs(x: last.position.x, y: last.position.y, force: last.force, altitude: last.altitude,
                                azimuth: last.azimuth, dx: lastDir.0, dy: lastDir.1, dt: lastDt)
            let width = attr.width
            if clipPath.map({ $0.contains(CGPoint(x: last.position.x + attr.offset.x,
                                                  y: last.position.y + attr.offset.y)) }) ?? true {
                stamps.append(CanvasRenderer.StampInstance(
                    center: SIMD2<Float>(Float((last.position.x + attr.offset.x) * scale),
                                         Float((last.position.y + attr.offset.y) * scale)),
                    radius: Float(width * 0.5 * scale),
                    rotation: attr.rotation,
                    color: attr.color,
                    hardness: hardness
                ))
            }
        }

        applyTaper(to: &stamps, taper: brush.taper)
        return stamps
    }

    /// Taper the stamp radii toward both ends of the stroke. `taper` [0,1] sets the
    /// taper length as a fraction of the stroke's half-length; each stamp's radius is
    /// scaled by how far it sits inside that taper zone (linear, → 0 at the very tips).
    /// Operates on the final stamp centers (canvas px) so it's independent of how the
    /// stamps were generated. No-op for taper == 0 or strokes too short to taper.
    static func applyTaper(to stamps: inout [CanvasRenderer.StampInstance], taper: CGFloat) {
        guard taper > 0, stamps.count > 2 else { return }
        var arc = [CGFloat](repeating: 0, count: stamps.count)
        for i in 1..<stamps.count {
            let a = stamps[i - 1].center, b = stamps[i].center
            arc[i] = arc[i - 1] + CGFloat(hypot(b.x - a.x, b.y - a.y))
        }
        let length = arc[stamps.count - 1]
        let taperLen = taper * length * 0.5
        guard taperLen > 0 else { return }
        for i in 0..<stamps.count {
            let s = arc[i]
            let tIn = min(s / taperLen, 1)
            let tOut = min((length - s) / taperLen, 1)
            stamps[i].radius *= Float(min(tIn, tOut))
        }
    }
}

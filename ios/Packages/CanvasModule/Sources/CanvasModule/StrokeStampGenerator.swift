import Foundation
import CoreGraphics
import simd

/// The pure stroke→stamps dab pipeline, extracted verbatim from `MetalCanvasView`
/// (2026-07-14) so the BrushHarness can run the exact shipped pipeline headless on
/// macOS (see `BrushHarness/README.md`). **UIKit-free by design** — everything here is
/// Foundation + CoreGraphics + simd.
///
/// 2026-09-10: the walk became a stateful `DryStrokeWalker` so the LIVE preview only
/// walks the points added since the last touch event (it used to re-walk the whole
/// stroke per `touchesMoved` — O(n²) over a stroke's life, and every dab re-ran the
/// clip test). `stamps(for:)` is the finalization path (undo, replay, flatten): it
/// builds a walker, advances it over the whole stroke and finishes with the end cap +
/// taper — the same dab math as the incremental preview, so the committed stroke is
/// identical to what the preview accumulated (plus cap + taper).
enum StrokeStampGenerator {

    /// The Brush Studio dev-panel knobs that parameterize `StrokeDynamicsState`
    /// (sensor normalization periods). Lengths are in DOCUMENT PIXELS (see
    /// `StrokeWalkUnits`): `maxSpeed` px/s, `distancePeriod` px; `fadePeriod` is a dab
    /// count. Defaults match `AppCoordinator`'s.
    struct DevTuning: Sendable {
        var maxSpeed: Double
        var distancePeriod: Double
        var fadePeriod: Double
        init(maxSpeed: Double = 3000, distancePeriod: Double = 1200, fadePeriod: Double = 64) {
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
        // Flow is a [0,1] deposit; clamp so a malformed fixture can't produce
        // premultiplied alpha > 1 (source-over goes negative).
        let a = Float(min(max(brush.flow, 0), 1))
        return SIMD4<Float>(r * a, g * a, b * a, a)
    }

    /// Generate stamp instances for a complete stroke (finalization: flatten, replay,
    /// undo, shape snap). When `clip` is set (selection), stamps whose center falls
    /// outside it are discarded.
    /// `includeEndCap`: emit the final dab at the stroke's last point. TRUE for every
    /// finalization path. The live preview (`DryStrokeWalker.previewStamps`) never
    /// carries a cap: the cap sits at the live pencil position and re-evaluates with
    /// live force and a shifting dab serial each frame, so in place it visibly
    /// grew/shrank with pressure and its scatter draws danced (device report,
    /// 2026-07-15). Ink the user sees during a stroke is monotonic — dabs only ever
    /// get added.
    static func stamps(for stroke: Stroke, scale: CGFloat, clip: StampClip? = nil,
                       tuning: DevTuning = DevTuning(),
                       includeEndCap: Bool = true) -> [CanvasRenderer.StampInstance] {
        guard !stroke.points.isEmpty else { return [] }
        var walker = DryStrokeWalker(stroke: stroke, scale: scale, clip: clip, tuning: tuning)
        walker.advance(stroke)
        return walker.finish(stroke, includeEndCap: includeEndCap)
    }

    /// Legacy symmetric entry point (kept for callers/tests): both ends at `taper`.
    static func applyTaper(to stamps: inout [CanvasRenderer.StampInstance], taper: CGFloat) {
        applyTaper(to: &stamps, startLen: taper, endLen: taper, opacityAmount: 0)
    }

    /// Taper the stamps toward the stroke's ends (richer taper, 2026-07-16).
    /// `startLen`/`endLen` [0,1] set each end's taper length as a fraction of the
    /// stroke's half-length (independent ends — Procreate's Taper pane); the size
    /// factor ramps linearly to 0 at the very tips. `opacityAmount` [0,1] additionally
    /// fades the stamp's premultiplied color by the same ramp (0 = size-only, the
    /// legacy look; 1 = tips fade fully transparent). Operates on final stamp centers
    /// (canvas px) so it's independent of how the stamps were generated.
    static func applyTaper(to stamps: inout [CanvasRenderer.StampInstance],
                           startLen: CGFloat, endLen: CGFloat, opacityAmount: CGFloat) {
        guard startLen > 0 || endLen > 0, stamps.count > 2 else { return }
        var arc = [CGFloat](repeating: 0, count: stamps.count)
        for i in 1..<stamps.count {
            let a = stamps[i - 1].center, b = stamps[i].center
            arc[i] = arc[i - 1] + CGFloat(hypot(b.x - a.x, b.y - a.y))
        }
        let length = arc[stamps.count - 1]
        let startTaperLen = startLen * length * 0.5
        let endTaperLen = endLen * length * 0.5
        guard startTaperLen > 0 || endTaperLen > 0 else { return }
        let opac = Float(min(max(opacityAmount, 0), 1))
        for i in 0..<stamps.count {
            let s = arc[i]
            let tIn = startTaperLen > 0 ? min(s / startTaperLen, 1) : 1
            let tOut = endTaperLen > 0 ? min((length - s) / endTaperLen, 1) : 1
            let factor = Float(min(tIn, tOut))
            stamps[i].radius *= factor
            if opac > 0 {
                // Premultiplied: scaling the whole vector scales alpha with it.
                stamps[i].color *= (1 - opac) + opac * factor
            }
        }
    }
}

/// The dry brush's stateful stroke walk. Create one per stroke, call `advance` with the
/// growing stroke after each input batch (only the new points are walked), read
/// `previewStamps()` for the live scratch, and `finish` once at lift.
///
/// Every per-stroke constant is resolved in `init` from the brush; every cross-batch
/// walk variable (spacing carry, arc, dynamics state, fall-off reservoir, dab serial)
/// is a stored property. `StrokeStampGenerator.stamps(for:)` is exactly
/// init → advance(all points) → finish, so finalization and preview share one code path.
///
/// Taper density: the walk tightens dab spacing inside taper zones by the same ramp
/// the radii get (`taperDensity`), which needs the stroke's TOTAL arc. Finalization
/// knows it (the walker is built from the whole stroke); the live walker is built from
/// the first point only, so `totalArc == 0` and density stays 1 until lift — the live
/// tip of a tapered stroke can bead slightly for the duration of the stroke, then the
/// lift regen lands the correct density.
struct DryStrokeWalker {
    typealias Stamp = CanvasRenderer.StampInstance

    private typealias DabAttrs = (width: CGFloat, color: SIMD4<Float>, rotation: Float, offset: CGPoint,
                                  aspect: Float, scatterMags: SIMD3<Float>, spacingMul: CGFloat, grainMul: Float)

    // MARK: Per-stroke constants

    private let brush: BrushConfig
    private let scale: CGFloat
    private let clip: StampClip?
    private let color: SIMD4<Float>
    private let hardness: Float
    private let aspect: Float
    private let spacingJitter: CGFloat
    private let spacingSeed: UInt64
    private let spacingFraction: CGFloat
    private let smoothIntent: Bool
    private let flatInterior: Bool
    private let movingGrainOn: Bool
    private let sagKappa: CGFloat
    private let rotationJitterAmount: Double
    private let rotationFollow: CGFloat
    private let tipAngle: Float
    private let hasDyn: Bool
    private let dyn: BrushDynamics?
    private let baseLinRGB: SIMD3<Float>
    private let baseFlow: Float
    private let dabCJ: ColorJitter?
    private let secondarySRGB: (r: Double, g: Double, b: Double)?
    private let baseSRGB: (r: Double, g: Double, b: Double)
    private let stampCount: Int
    private let countJitter: Double
    private let taperStartLen: CGFloat
    private let taperEndLen: CGFloat
    private let hasTaper: Bool
    private let totalArc: CGFloat
    private let fallOff: CGFloat
    private let dieLength: CGFloat
    private let spacingFloor: CGFloat
    private let spacingCapFloor: CGFloat
    private let sagCapMinWidth: CGFloat

    // MARK: Walk state (carried across `advance` batches)

    private var dynState: StrokeDynamicsState?
    /// Flow compensation for the CURRENT dab (set alongside currentSpacing).
    private var flowCompRatio: Float = 1
    private var stamps: [Stamp] = []
    /// Arc position of the current dab along the point list (drives taperDensity).
    private var walkArc: CGFloat = 0
    /// Fall Off: cumulative arc length at the current dab / previous dab position.
    private var fallArc: CGFloat = 0
    private var lastDabPos: CGPoint? = nil
    private var dabSerial: UInt64 = 0
    /// TRUE arc length accumulated since the last emitted stamp, carried across
    /// segments and batches (chord-from-last-stamp starved tight scribbles, 2026-07-15).
    private var arcSinceLastStamp: CGFloat = 0
    private var currentSpacing: CGFloat = 0
    private var lastPointIndex = 0
    private var finished = false
    /// Direction at the start cap (first real segment), fixed when the first dab lands.
    private var firstDir: (CGFloat, CGFloat) = (0, 0)

    /// `stroke` supplies the brush, the seed and (for finalization) the full point list
    /// used to size the taper zones. For a live walker pass the stroke as it exists at
    /// touch-begin (one point).
    init(stroke: Stroke, scale: CGFloat, clip: StampClip?,
         tuning: StrokeStampGenerator.DevTuning = .init()) {
        let brush = stroke.brush
        self.brush = brush
        self.scale = scale
        self.clip = clip
        color = StrokeStampGenerator.premultipliedColor(brush)
        hardness = Float(brush.hardness)
        // P4b base aspect; the `ratio` CurveOption (cheap-knobs batch) multiplies it
        // per dab in `dabAttrs` (Procreate Pressure/Tilt Roundness).
        aspect = Float(min(max(brush.aspectRatio, 0.05), 1))
        // Spacing jitter: deterministic per-gap multiplier (stroke seed + stamp index).
        spacingJitter = min(max(brush.spacingJitter, 0), 1)
        spacingSeed = StrokeStampGenerator.strokeSeed(stroke.id)
        // Spacing as a fraction of stamp width; clamped so a tiny value can't generate
        // a runaway number of stamps (the renderer also caps per-frame stamp count).
        spacingFraction = max(brush.spacing, 0.02)
        spacingFloor = StrokeWalkUnits.spacingFloor(scale: scale)
        spacingCapFloor = StrokeWalkUnits.spacingCapFloor(scale: scale)
        sagCapMinWidth = StrokeWalkUnits.sagCapMinWidth(scale: scale)
        // A procedural tip with NO rotation semantics of its own — safe to orient to the
        // stroke (for moving grain / the flat-sided superellipse) without changing look.
        let rotationAgnostic = brush.shapeID == nil && brush.spacing <= 0.35
            && brush.aspectRatio >= 0.999 && brush.tipAngle == 0
            && brush.dynamics?.rotation == nil && brush.dynamics?.ratio == nil
        // Smooth-edge spacing cap (2026-07-16): the scallop sag between adjacent dabs is
        // ≈ spacing²/(8·radius) px, so the tolerable spacing grows with √radius — small
        // brushes are naturally sub-pixel smooth while big ones need tighter packing.
        // Applied only when the user's spacing signals SMOOTH intent (≤ 0.35); brushes
        // with deliberately visible stamping (Spray at 0.5+) are untouched. The allowed
        // sag κ relaxes for soft rims (blur hides scallops) and tightens for max-blend
        // moving grain (its union edge is harder than accumulated source-over). Any
        // reduction is flow-COMPENSATED per dab so per-arc-length density is preserved:
        // a' = 1 − (1−a)^(s_render/s_nominal).
        smoothIntent = spacingFraction <= 0.35
        // Flat-sided interior dabs (the Procreate square-stamp mechanism): procedural
        // smooth-intent strokes slide a stroke-aligned superellipse — mathematically
        // flat edge, no scallop at ANY spacing. First + end-cap dabs stay round so the
        // stroke's ENDS keep the round tip profile.
        flatInterior = smoothIntent && rotationAgnostic
        movingGrainOn = brush.grainMoving && brush.grainID != nil
        // κ in document px (old view-point literals × 2, see StrokeWalkUnits).
        let kappaPx: CGFloat = movingGrainOn ? 0.6 : (0.7 + (1 - min(max(brush.hardness, 0), 1)) * 2.4)
        sagKappa = StrokeWalkUnits.sagKappa(px: kappaPx, scale: scale)

        // Textured (non-round) shapes orient their stamps to the stroke direction so
        // anisotropic tips (dry-brush streaks, chisel) run along the line, not across it.
        // Convention: the stamp's local +y axis (the PNG's vertical) is aligned with the
        // travel direction → rotation = atan2(-dx, dy). Round (procedural) brushes are
        // radially symmetric, so they stay at 0.
        let orientsToStroke = BrushShapeCatalog.orientsToStroke(brush.shapeID)
        // Random per-dab spin (Procreate Shape "Scatter"). Two sources, take the max:
        // the user knob `brush.rotationJitter` (explicit intent — applies even with
        // follow/dynamics rotation, adding spin on top), and the dry-media shapes'
        // catalog flag (full spin, but only when the brush doesn't drive rotation
        // explicitly — same-orientation art repetition reads as discernible stamps,
        // device report 2026-07-16).
        let catalogSpin: CGFloat = (BrushShapeCatalog.descriptor(for: brush.shapeID).rotationJitter
            && brush.dynamics?.rotation == nil && brush.rotationFollow == nil) ? 1 : 0
        rotationJitterAmount = Double(max(catalogSpin, max(0, min(1, brush.rotationJitter))))
        // Signed follow-stroke rotation (Procreate Shape "Rotation" −1…1). nil = legacy:
        // catalog-orienting shapes follow fully, others stay upright.
        rotationFollow = {
            if let f = brush.rotationFollow, brush.shapeID != nil { return max(-1, min(1, f)) }
            if orientsToStroke { return 1 }
            // Moving grain AND the flat-sided interior dab both need the dab's local
            // frame aligned to the travel direction (local-Y = along-stroke). Only for
            // tips with NO rotation semantics of their own: a truly round symmetric tip
            // orients for free, but an aspect nib / tipAngle / rotation-dynamics brush
            // must keep its authored orientation (forcing follow silently flattened the
            // 45° calligraphy nib into uniform width — dry-06 regression, caught in the
            // superellipse battery review).
            if brush.grainMoving && brush.grainID != nil { return 1 }
            return rotationAgnostic ? 1 : 0
        }()
        // Static tip angle (calligraphy nib): added to every dab's rotation, before any
        // follow-stroke or dynamic component. Randomized (Procreate Shape "Randomized")
        // adds ONE random spin per stroke on top — every stroke lands the tip at a new
        // angle, but the stroke itself is coherent (unlike per-dab Scatter).
        tipAngle = Float(brush.tipAngle)
            + (brush.randomizedRotation
               ? Float(brushHash01(StrokeStampGenerator.strokeSeed(stroke.id), 0, 0x9A0D) * 2 * Double.pi)
               : 0)
        // --- Krita-grade brush dynamics (BrushDynamics.swift) -----------------------------
        // When the brush carries non-inert `dynamics`, size/flow/rotation are resolved per
        // dab through the sensor→curve→combine→remap machine. When it does NOT (the default
        // pen and every legacy brush), `dabAttrs` returns EXACTLY the classic values — width
        // via `effectiveWidth`, the constant premultiplied `color`, shape-oriented
        // `rotation`. The per-stroke `StrokeDynamicsState` lives in the walker, so live
        // preview, replay, and undo are deterministic for the same points + seed.
        let dyn = brush.dynamics
        self.dyn = dyn
        hasDyn = !(dyn?.isInert ?? true)
        func s2lLocal(_ c: CGFloat) -> Float { let x = Float(c); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let hasDyn = self.hasDyn
        let seed = StrokeStampGenerator.strokeSeed(stroke.id)
        // Only the dynamics path consumes these; keep the default-pen path free of the extra
        // work (it returns before touching them). Per-stroke color jitter (if any) is applied
        // ONCE here in sRGB-HSV, then converted to linear — so the whole stroke is one coherent
        // jittered color (not per-dab speckle, which img2img averages out).
        baseLinRGB = {
            guard hasDyn else { return .zero }
            var srgb = (r: Double(brush.color.red), g: Double(brush.color.green), b: Double(brush.color.blue))
            if let cj = dyn?.colorJitter, !cj.isInert {
                srgb = cj.applied(toSRGB: srgb,
                                  rH: brushHash01(seed, 0, 0x4011),
                                  rS: brushHash01(seed, 0, 0x4012),
                                  rB: brushHash01(seed, 0, 0x4013),
                                  rD: brushHash01(seed, 0, 0x4014))
            }
            return SIMD3<Float>(s2lLocal(CGFloat(srgb.r)), s2lLocal(CGFloat(srgb.g)), s2lLocal(CGFloat(srgb.b)))
        }()
        baseFlow = Float(brush.flow)
        // Per-dab color jitter (P6 "Stamp Color Jitter"): the base sRGB (already carrying
        // any per-STROKE jitter) is re-jittered per dab in sRGB-HSV, then s2l. Only pay
        // the HSV round trip when configured.
        dabCJ = {
            guard let cj = dyn?.dabColorJitter, !cj.isInert else { return nil }
            return cj
        }()
        // Secondary ink (P6): active only when BOTH the color and the blend curve exist.
        secondarySRGB = {
            guard let sec = brush.secondaryColor, dyn?.secondary != nil else { return nil }
            return (Double(sec.red), Double(sec.green), Double(sec.blue))
        }()
        let dabCJ = self.dabCJ, secondarySRGB = self.secondarySRGB
        baseSRGB = {
            guard hasDyn, dabCJ != nil || secondarySRGB != nil else { return (0, 0, 0) }
            var srgb = (r: Double(brush.color.red), g: Double(brush.color.green), b: Double(brush.color.blue))
            if let cj = dyn?.colorJitter, !cj.isInert {
                srgb = cj.applied(toSRGB: srgb,
                                  rH: brushHash01(seed, 0, 0x4011),
                                  rS: brushHash01(seed, 0, 0x4012),
                                  rB: brushHash01(seed, 0, 0x4013),
                                  rD: brushHash01(seed, 0, 0x4014))
            }
            return srgb
        }()
        // Sensor periods are authored in document px / px·s⁻¹; the walk runs in the
        // stroke's own space, so convert by `scale` (document px per walk unit).
        let unit = Double(max(scale, 0.0001))
        dynState = hasDyn
            ? StrokeDynamicsState(seed: seed, distancePeriod: tuning.distancePeriod / unit,
                                  fadePeriod: tuning.fadePeriod, maxSpeed: tuning.maxSpeed / unit)
            : nil

        // Count (Procreate Shape "Count" / "Count Jitter"): stamps per spacing point.
        // Copy 0 is the normal dab (byte-identical when count == 1); copies 1…n−1 re-draw
        // the scatter channels deterministically (stroke seed + dab serial + copy index)
        // at the same magnitudes, so they cluster around the walk point.
        stampCount = min(max(brush.stampCount, 1), 16)
        countJitter = min(max(brush.stampCountJitter, 0), 1)
        // Taper-aware dab DENSITY (2026-07-16): applyTaper shrinks radii after the walk,
        // so without this the tip dabs — spaced by their pre-taper width — separate into
        // beads (caught by dry-17). Inside a taper zone the walk tightens spacing by the
        // same ramp the radii will get (floored so the dab count stays bounded).
        let taperStartLen = max(brush.taper, brush.taperStart)
        let taperEndLen = max(brush.taper, brush.taperEnd)
        self.taperStartLen = taperStartLen
        self.taperEndLen = taperEndLen
        hasTaper = taperStartLen > 0 || taperEndLen > 0
        totalArc = {
            guard taperStartLen > 0 || taperEndLen > 0, stroke.points.count > 1 else { return 0 }
            var t: CGFloat = 0
            for i in 1..<stroke.points.count {
                let a = stroke.points[i - 1].position, b = stroke.points[i].position
                t += hypot(b.x - a.x, b.y - a.y)
            }
            return t
        }()

        // Fall Off (Procreate Stroke Path): paint runs out over drawn distance. The die
        // length shrinks as the knob rises — 500 document px at 1.0, ~10000 near 0
        // (effectively "never" on the 2048² document). Quadratic knee gives the slider
        // a usable low end. Scales the premultiplied dab color (flow), preserving ratio.
        fallOff = min(max(brush.fallOff, 0), 1)
        dieLength = StrokeWalkUnits.fallOffDieLength(fallOff: fallOff, scale: scale)
    }

    // MARK: Per-dab helpers

    private func jitteredSpacing(_ base: CGFloat, _ index: Int) -> CGFloat {
        guard spacingJitter > 0 else { return base }
        let r = CGFloat(brushHash01(spacingSeed, UInt64(index), 0x5AC3)) // [0,1)
        return max(spacingFloor, base * (1 + spacingJitter * (2 * r - 1)))
    }

    private func renderSpacing(_ nominal: CGFloat, width: CGFloat) -> (spacing: CGFloat, flowComp: Float) {
        guard smoothIntent, width > sagCapMinWidth else { return (nominal, 1) }
        let cap = max((8 * sagKappa * width * 0.5).squareRoot(), spacingCapFloor)
        guard nominal > cap else { return (nominal, 1) }
        // Max-blend (moving grain) doesn't accumulate — no compensation needed.
        let comp = movingGrainOn ? 1 : Float(cap / nominal)
        return (cap, comp)
    }

    private func strokeRotation(dx: CGFloat, dy: CGFloat) -> Float {
        guard rotationFollow != 0, dx != 0 || dy != 0 else { return tipAngle }
        return tipAngle + Float(CGFloat(atan2(-dx, dy)) * rotationFollow)
    }

    private func taperDensity(_ arc: CGFloat) -> CGFloat {
        guard hasTaper, totalArc > 0 else { return 1 }
        let sLen = taperStartLen * totalArc * 0.5
        let eLen = taperEndLen * totalArc * 0.5
        let tIn = sLen > 0 ? min(arc / sLen, 1) : 1
        let tOut = eLen > 0 ? min((totalArc - arc) / eLen, 1) : 1
        return max(min(tIn, tOut), 0.12)
    }

    /// Per-dab (width, premultiplied color, rotation, …). The `!hasDyn` branch is the classic
    /// behavior; the dynamics branch advances stroke state and evaluates the curve
    /// options. `dt` is the seconds across the segment this dab sits on (for the Speed sensor).
    private mutating func dabAttrs(x: CGFloat, y: CGFloat, force: CGFloat, altitude: CGFloat, azimuth: CGFloat,
                                   dx: CGFloat, dy: CGFloat, dt: Double, roll: CGFloat = 0) -> DabAttrs {
        guard hasDyn, var st = dynState else {
            return (brush.effectiveWidth(force: force, altitude: altitude), color, strokeRotation(dx: dx, dy: dy), .zero, aspect, .zero, 1, 1)
        }
        func s2lLocal(_ c: CGFloat) -> Float { let x = Float(c); return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        let input = st.advance(
            x: Double(x), y: Double(y), force: Double(force), altitude: Double(altitude),
            azimuth: Double(azimuth), dx: Double(dx), dy: Double(dy), dt: dt, roll: Double(roll))
        dynState = st
        let w: CGFloat = dyn?.size != nil
            ? brush.baseWidth * CGFloat(dyn!.size!.value(input))
            : brush.effectiveWidth(force: force, altitude: altitude)
        let flowMul = dyn?.flow?.value(input) ?? 1.0
        // Clamp to [0,1]: a brush authored with flow.maxValue > 1 could otherwise produce
        // premultiplied alpha > 1 (malformed for the _srgb blend). P1-review fix.
        let a = min(1, max(0, baseFlow * Float(flowMul)))
        var linRGB = baseLinRGB
        if dabCJ != nil || secondarySRGB != nil {
            var srgb = baseSRGB
            // Secondary blend FIRST (the dab's base tone), jitter on top.
            if let sec = secondarySRGB, let curve = dyn?.secondary {
                let t = min(max(curve.value(input), 0), 1)
                srgb = (srgb.r + (sec.r - srgb.r) * t,
                        srgb.g + (sec.g - srgb.g) * t,
                        srgb.b + (sec.b - srgb.b) * t)
            }
            if let cj = dabCJ {
                let dab = st.dabIndex   // post-advance: unique, monotonically increasing per dab
                srgb = cj.applied(toSRGB: srgb,
                                  rH: brushHash01(spacingSeed, dab, 0x4021),
                                  rS: brushHash01(spacingSeed, dab, 0x4022),
                                  rB: brushHash01(spacingSeed, dab, 0x4023),
                                  rD: brushHash01(spacingSeed, dab, 0x4024))
            }
            linRGB = SIMD3<Float>(s2lLocal(CGFloat(srgb.r)), s2lLocal(CGFloat(srgb.g)), s2lLocal(CGFloat(srgb.b)))
        }
        if let dk = dyn?.darkness {
            // Device-space darken (multiply in sRGB, like Krita's darken option):
            // encode each channel back to sRGB, scale, re-linearize. Only paid when
            // darkness is configured. The curve output is the darkening AMOUNT
            // (0 none → 1 black), so a plain pressure sensor darkens under pressure.
            let mul = 1 - Float(min(max(dk.value(input), 0), 1))
            func l2s(_ x: Float) -> Float { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
            func s2f(_ x: Float) -> Float { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            linRGB = SIMD3<Float>(s2f(l2s(linRGB.x) * mul), s2f(l2s(linRGB.y) * mul), s2f(l2s(linRGB.z) * mul))
        }
        let col = SIMD4<Float>(linRGB.x * a, linRGB.y * a, linRGB.z * a, a)
        var rot = strokeRotation(dx: dx, dy: dy)
        if let rotOpt = dyn?.rotation { rot += Float(rotOpt.value(input) * Double.pi) } // [-1,1] turns → ±π
        // Scatter: per-dab random center displacement, magnitude = value × dab diameter.
        // Displaces only the rendered stamp; the spacing/path walk uses the un-scattered point.
        // Three channels (isotropic + Procreate's Stroke-Path split): lateral displaces
        // PERPENDICULAR to the travel direction, linear ALONG it. Magnitudes (× width)
        // are also returned so Count copies can take independent draws at the same size.
        var offset = CGPoint.zero
        var mags = SIMD3<Float>(0, 0, 0) // (iso, lateral, linear) × width
        let segLen = hypot(dx, dy)
        let ux = segLen > 0 ? dx / segLen : 0
        let uy = segLen > 0 ? dy / segLen : 0
        if let sc = dyn?.scatter {
            let mag = w * CGFloat(sc.value(input))
            mags.x = Float(mag)
            offset.x += mag * CGFloat(2 * input.randScatterX - 1)
            offset.y += mag * CGFloat(2 * input.randScatterY - 1)
        }
        if let sl = dyn?.scatterLateral {
            let mag = w * CGFloat(sl.value(input))
            mags.y = Float(mag)
            let d = mag * CGFloat(2 * input.randScatterLat - 1)
            offset.x += -uy * d
            offset.y += ux * d
        }
        if let sn = dyn?.scatterLinear {
            let mag = w * CGFloat(sn.value(input))
            mags.z = Float(mag)
            let d = mag * CGFloat(2 * input.randScatterLin - 1)
            offset.x += ux * d
            offset.y += uy * d
        }
        // Roundness/ratio (Procreate Pressure/Tilt Roundness): per-dab aspect multiplier.
        var dabAspect = aspect
        if let ratioOpt = dyn?.ratio {
            dabAspect = Float(min(max(CGFloat(aspect) * CGFloat(ratioOpt.value(input)), 0.05), 1))
        }
        // Speed→Spacing (Procreate Dynamics): per-dab multiplier on the NEXT walk gap.
        let spacingMul = dyn?.spacing != nil ? CGFloat(dyn!.spacing!.value(input)) : 1
        let grainMul = dyn?.grain != nil ? Float(dyn!.grain!.value(input)) : 1
        return (w, col, rot, offset, dabAspect, mags, max(0.05, spacingMul), grainMul)
    }

    private mutating func appendDab(_ attr: DabAttrs, x: CGFloat, y: CGFloat, dx: CGFloat, dy: CGFloat,
                                    arc: CGFloat = 0, interior: Bool = false) {
        dabSerial &+= 1
        var attr = attr
        if brush.grainDepthJitter > 0.001 {
            // Procreate Grain "Depth Jitter": random per-stamp texture strength,
            // one-sided down from the configured Depth.
            attr.grainMul *= Float(1 - brushHash01(spacingSeed, dabSerial, 0x6A1B)
                                     * Double(min(max(brush.grainDepthJitter, 0), 1)))
        }
        if rotationJitterAmount > 0 {
            // Centered: ±(amount·π) — at 1 that's the full circle (uniform, same
            // distribution as the legacy 0…2π spin); partial amounts wobble around
            // the tip's driven orientation instead of spinning one way.
            let spin = (brushHash01(spacingSeed, dabSerial, 0x5B1A) - 0.5) * 2 * Double.pi * rotationJitterAmount
            attr.rotation += Float(spin)
        }
        if flowCompRatio < 1 {
            // a' = 1−(1−a)^ratio; premultiplied color scales by a'/a exactly.
            let a = attr.color.w
            if a > 1e-5 {
                let aPrime = 1 - pow(1 - a, flowCompRatio)
                attr.color *= aPrime / a
            }
        }
        if fallOff > 0 {
            if let lp = lastDabPos { fallArc += hypot(x - lp.x, y - lp.y) }
            lastDabPos = CGPoint(x: x, y: y)
            let m = Float(max(0, 1 - fallArc / dieLength))
            if m <= 0 { return }  // paint ran out
            attr.color *= m
        }
        var copies = stampCount
        if stampCount > 1, countJitter > 0 {
            let r = brushHash01(spacingSeed, dabSerial, 0xC07)
            copies = max(1, stampCount - Int(floor(Double(stampCount) * countJitter * r)))
        }
        let segLen = hypot(dx, dy)
        let ux = segLen > 0 ? dx / segLen : 0
        let uy = segLen > 0 ? dy / segLen : 0
        for c in 0..<copies {
            var off = attr.offset
            if c > 0 {
                let idx = dabSerial &* 31 &+ UInt64(c)
                off = .zero
                if attr.scatterMags.x > 0 {
                    let m = CGFloat(attr.scatterMags.x)
                    off.x += m * CGFloat(2 * brushHash01(spacingSeed, idx, 0xC0A7) - 1)
                    off.y += m * CGFloat(2 * brushHash01(spacingSeed, idx, 0xC0A8) - 1)
                }
                if attr.scatterMags.y > 0 {
                    let d = CGFloat(attr.scatterMags.y) * CGFloat(2 * brushHash01(spacingSeed, idx, 0xC0A9) - 1)
                    off.x += -uy * d
                    off.y += ux * d
                }
                if attr.scatterMags.z > 0 {
                    let d = CGFloat(attr.scatterMags.z) * CGFloat(2 * brushHash01(spacingSeed, idx, 0xC0AA) - 1)
                    off.x += ux * d
                    off.y += uy * d
                }
            }
            let pos = CGPoint(x: x + off.x, y: y + off.y)
            // The clip is a baked even-odd bitmap so magic-wand masks work: holes
            // (negative-point refinement) and disjoint objects both resolve correctly.
            if let clip, !clip.contains(pos) { continue }
            stamps.append(Stamp(
                center: SIMD2<Float>(Float(pos.x * scale), Float(pos.y * scale)),
                radius: Float(attr.width * 0.5 * scale),
                rotation: attr.rotation,
                color: attr.color,
                hardness: hardness,
                aspect: attr.aspect,
                arcU: Float(arc * scale),
                grainMul: attr.grainMul,
                edgeFlat: (interior && flatInterior) ? 1 : 0
            ))
        }
    }

    // MARK: Walk

    /// The start cap. Its direction, `dt` and (for the Speed sensor) displacement come
    /// from the first real segment, so it is placed only once a second point exists —
    /// or at `finish` for a single-point tap. That keeps the incremental walk identical
    /// to the whole-stroke walk (the old per-frame regen saw the second point on its
    /// first run anyway; a one-point regen never survived to the canvas).
    private mutating func placeFirstDab(_ stroke: Stroke) {
        let first = stroke.points[0]
        firstDir = stroke.points.count > 1
            ? (stroke.points[1].position.x - first.position.x,
               stroke.points[1].position.y - first.position.y)
            : (0, 0)
        let firstDt = stroke.points.count > 1 ? max(0, Double(stroke.points[1].timestamp - first.timestamp)) : 0
        let firstAttr = dabAttrs(x: first.position.x, y: first.position.y, force: first.force, altitude: first.altitude,
                                 azimuth: first.azimuth, dx: firstDir.0, dy: firstDir.1, dt: firstDt,
                                 roll: first.rollAngle)
        let firstWidth = firstAttr.width
        // Resolve the first gap BEFORE placing the dab so the start dot gets the same
        // flow compensation as the body (it used to skip it: a darker start dot on
        // smooth big brushes with flow < 1).
        let firstRS = renderSpacing(
            max(firstWidth * spacingFraction * firstAttr.spacingMul * taperDensity(0), spacingFloor),
            width: firstWidth)
        flowCompRatio = firstRS.flowComp
        appendDab(firstAttr, x: first.position.x, y: first.position.y, dx: firstDir.0, dy: firstDir.1)
        currentSpacing = jitteredSpacing(firstRS.spacing, 0)
        arcSinceLastStamp = 0
        lastPointIndex = 1
    }

    /// Walk the points added since the last call (all of them on the first call).
    /// A one-point stroke places nothing yet (see `placeFirstDab`).
    mutating func advance(_ stroke: Stroke) {
        guard !finished, stroke.points.count > lastPointIndex, stroke.points.count > 1 else { return }
        if lastPointIndex == 0 { placeFirstDab(stroke) }

        for i in max(lastPointIndex, 1)..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            let dx = curr.position.x - prev.position.x
            let dy = curr.position.y - prev.position.y
            let segmentDist = hypot(dx, dy)
            guard segmentDist > 0 else { continue }

            var traveled = max(0, currentSpacing - arcSinceLastStamp)
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
                let roll = prev.rollAngle + (curr.rollAngle - prev.rollAngle) * t
                let attr = dabAttrs(x: x, y: y, force: force, altitude: altitude, azimuth: azimuth,
                                    dx: dx * stepFrac, dy: dy * stepFrac, dt: segDt * Double(stepFrac),
                                    roll: roll)
                let width = attr.width

                appendDab(attr, x: x, y: y, dx: dx, dy: dy, arc: walkArc + traveled, interior: true)

                let rs = renderSpacing(
                    max(width * spacingFraction * attr.spacingMul * taperDensity(walkArc + traveled), spacingFloor),
                    width: width)
                flowCompRatio = rs.flowComp
                currentSpacing = jitteredSpacing(rs.spacing, stamps.count)
                traveled += currentSpacing
            }
            // Post-loop, `traveled` sits one gap past the last emitted stamp (or one gap
            // past the pre-segment arc when nothing emitted) — this recovers the arc
            // walked since the last stamp in both cases.
            arcSinceLastStamp = segmentDist - (traveled - currentSpacing)
            walkArc += segmentDist
        }
        lastPointIndex = stroke.points.count
    }

    /// The live scratch contents: every interior dab so far (no end cap), tapered when
    /// the brush tapers so the tips read right while drawing.
    func previewStamps() -> [Stamp] {
        guard hasTaper else { return stamps }
        var out = stamps
        StrokeStampGenerator.applyTaper(to: &out, startLen: taperStartLen, endLen: taperEndLen,
                                        opacityAmount: brush.taperOpacity)
        return out
    }

    /// Finalize: walk any remaining points, place the end cap, apply the taper.
    /// The walker is spent afterwards.
    mutating func finish(_ stroke: Stroke, includeEndCap: Bool = true) -> [Stamp] {
        guard !finished, !stroke.points.isEmpty else { return stamps }
        advance(stroke)
        if lastPointIndex == 0 { placeFirstDab(stroke) } // single-point tap
        finished = true
        if includeEndCap, let last = stroke.points.last {
            let n = stroke.points.count
            let lastDir: (CGFloat, CGFloat) = n > 1
                ? (last.position.x - stroke.points[n - 2].position.x,
                   last.position.y - stroke.points[n - 2].position.y)
                : firstDir
            let lastDt = n > 1 ? max(0, Double(last.timestamp - stroke.points[n - 2].timestamp)) : 0
            let attr = dabAttrs(x: last.position.x, y: last.position.y, force: last.force, altitude: last.altitude,
                                azimuth: last.azimuth, dx: lastDir.0, dy: lastDir.1, dt: lastDt,
                                roll: last.rollAngle)
            appendDab(attr, x: last.position.x, y: last.position.y, dx: lastDir.0, dy: lastDir.1,
                      arc: walkArc)
        }
        var out = stamps
        StrokeStampGenerator.applyTaper(to: &out, startLen: taperStartLen, endLen: taperEndLen,
                                        opacityAmount: brush.taperOpacity)
        return out
    }
}

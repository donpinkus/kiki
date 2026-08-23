// UIKit is optional here (macOS BrushHarness compiles this file too); only the
// `CodableColor.uiColor` convenience needs it.
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Layer Blend Mode

/// Per-layer compositing mode (Procreate-style). Separable modes only — each
/// channel blends independently; formulas per the W3C compositing spec,
/// evaluated in LINEAR space (our `_srgb` textures hand the shader linear).
/// `shaderIndex` must match the `switch` in `blendCompositorFragment`.
public enum LayerBlendMode: String, Codable, Sendable, CaseIterable {
    case normal
    case darken, multiply, colorBurn, linearBurn
    case lighten, screen, colorDodge, add
    case overlay, softLight, hardLight
    case difference, exclusion

    public var displayName: String {
        switch self {
        case .normal: "Normal"
        case .darken: "Darken"
        case .multiply: "Multiply"
        case .colorBurn: "Color Burn"
        case .linearBurn: "Linear Burn"
        case .lighten: "Lighten"
        case .screen: "Screen"
        case .colorDodge: "Color Dodge"
        case .add: "Add"
        case .overlay: "Overlay"
        case .softLight: "Soft Light"
        case .hardLight: "Hard Light"
        case .difference: "Difference"
        case .exclusion: "Exclusion"
        }
    }

    /// Short badge shown on the layer row (Procreate's "N").
    public var shortCode: String {
        switch self {
        case .normal: "N"
        case .darken: "D"
        case .multiply: "M"
        case .colorBurn: "Cb"
        case .linearBurn: "Lb"
        case .lighten: "L"
        case .screen: "S"
        case .colorDodge: "Cd"
        case .add: "A"
        case .overlay: "O"
        case .softLight: "Sl"
        case .hardLight: "Hl"
        case .difference: "Df"
        case .exclusion: "E"
        }
    }

    /// Stable id passed to the blend shader. Do not renumber.
    public var shaderIndex: UInt32 {
        switch self {
        case .normal: 0
        case .darken: 1
        case .multiply: 2
        case .colorBurn: 3
        case .linearBurn: 4
        case .lighten: 5
        case .screen: 6
        case .colorDodge: 7
        case .add: 8
        case .overlay: 9
        case .softLight: 10
        case .hardLight: 11
        case .difference: 12
        case .exclusion: 13
        }
    }
}

// MARK: - Layer Info

/// Metadata for a single canvas layer (name, visibility). The actual texture
/// is stored by index on `CanvasRenderer`.
public struct LayerInfo: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var isVisible: Bool
    /// Fully locked: no painting, erasing, or clearing (Procreate swipe-Lock).
    public var isLocked: Bool
    /// Alpha lock: strokes only land where the layer already has content.
    public var isAlphaLocked: Bool
    /// Compositing mode (applied at composite time, never baked into pixels).
    public var blendMode: LayerBlendMode
    /// Whole-layer opacity 0…1 (composite-time, never baked into pixels).
    public var opacity: Double

    public init(id: UUID = UUID(), name: String, isVisible: Bool = true,
                isLocked: Bool = false, isAlphaLocked: Bool = false,
                blendMode: LayerBlendMode = .normal, opacity: Double = 1) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
        self.isLocked = isLocked
        self.isAlphaLocked = isAlphaLocked
        self.blendMode = blendMode
        self.opacity = opacity
    }

    // Backward-compatible decode: layer metadata saved before the lock/blend
    // fields existed loads with flags off, Normal blend, full opacity.
    enum CodingKeys: String, CodingKey { case id, name, isVisible, isLocked, isAlphaLocked, blendMode, opacity }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isVisible = try c.decode(Bool.self, forKey: .isVisible)
        isLocked = try c.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        isAlphaLocked = try c.decodeIfPresent(Bool.self, forKey: .isAlphaLocked) ?? false
        blendMode = (try c.decodeIfPresent(String.self, forKey: .blendMode))
            .flatMap(LayerBlendMode.init(rawValue:)) ?? .normal
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1
    }
}

// MARK: - Stroke Point

/// Per-point data captured from Apple Pencil during a stroke.
public struct StrokePoint: Codable, Sendable {
    public var position: CGPoint
    public var force: CGFloat       // 0–1 normalized
    public var altitude: CGFloat    // radians: 0 = flat, π/2 = perpendicular
    /// Apple Pencil azimuth (tilt *direction*) in radians, [0, 2π). Feeds the TiltDirection
    /// sensor (chisel/flat-pencil shape — high img2img leverage). Defaults to 0 for inputs
    /// and saved strokes that predate azimuth capture (backward-compatible decode below).
    public var azimuth: CGFloat
    /// Apple Pencil Pro barrel-roll angle in radians (UITouch.rollAngle, iOS 17.5+).
    /// 0 for non-Pro pencils, fingers, and recordings that predate capture. Feeds the
    /// BarrelRotation sensor. Added 2026-07-15 (backward-compatible decode below).
    public var rollAngle: CGFloat
    public var timestamp: TimeInterval

    public init(position: CGPoint, force: CGFloat, altitude: CGFloat, timestamp: TimeInterval,
                azimuth: CGFloat = 0, rollAngle: CGFloat = 0) {
        self.position = position
        self.force = force
        self.altitude = altitude
        self.azimuth = azimuth
        self.rollAngle = rollAngle
        self.timestamp = timestamp
    }

    // Explicit CodingKeys + decoder so saved strokes without `azimuth`/`rollAngle` still
    // load (→ 0). `encode(to:)` is synthesized from these keys.
    enum CodingKeys: String, CodingKey { case position, force, altitude, azimuth, rollAngle, timestamp }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        position = try c.decode(CGPoint.self, forKey: .position)
        force = try c.decode(CGFloat.self, forKey: .force)
        altitude = try c.decode(CGFloat.self, forKey: .altitude)
        azimuth = try c.decodeIfPresent(CGFloat.self, forKey: .azimuth) ?? 0
        rollAngle = try c.decodeIfPresent(CGFloat.self, forKey: .rollAngle) ?? 0
        timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
    }
}

// MARK: - Codable Color

/// RGBA color wrapper that's Codable and Sendable for brush serialization.
public struct CodableColor: Codable, Sendable, Equatable {
    public var red: CGFloat
    public var green: CGFloat
    public var blue: CGFloat
    public var alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = CodableColor(red: 0, green: 0, blue: 0)
    public static let white = CodableColor(red: 1, green: 1, blue: 1)

    #if canImport(UIKit)
    public var uiColor: UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
    #endif
}

// MARK: - Brush Configuration

/// Configures how a brush stroke is rendered.
public struct BrushConfig: Codable, Sendable {
    public var color: CodableColor
    public var baseWidth: CGFloat
    /// Per-stroke opacity ceiling [0,1]. Applied once when the finished stroke is
    /// composited onto the canvas — overlapping stamps within a single stroke never
    /// exceed this. This is the "Glaze" rendering behavior (cf. `flow`).
    public var opacity: CGFloat
    /// Per-stamp deposit rate [0,1] ("Flow"). Baked into each stamp's alpha, so
    /// overlapping stamps within one stroke build up toward solid coverage. Distinct
    /// from `opacity`: flow controls within-stroke build-up, opacity caps the stroke.
    public var flow: CGFloat
    /// Pressure-to-width gamma curve. <1 = heavy feel (wider early), >1 = light feel (narrow early).
    public var pressureGamma: CGFloat
    /// How much Apple Pencil tilt widens the stroke (0 = none, 1 = dramatic).
    public var tiltSensitivity: CGFloat
    /// StreamLine stabilization [0,1]. 0 = the drawn point follows the pencil exactly;
    /// higher values lag the drawn point behind the pencil (low-pass smoothing) for
    /// steadier, more confident lines. Applied at input time and baked into the stored
    /// stroke points (see `MetalCanvasView.smoothedStrokePoint`). See pro-brush-roadmap Phase 1.
    public var streamline: CGFloat
    /// Gaussian arc-length smoothing [0,1] (P3, Procreate "Stabilization"): a trailing
    /// Gaussian-weighted average over the DISTANCE drawn — frame-rate independent, gives
    /// clean curvature instead of a lagged polyline. 0 = off. See `StrokeStabilizer`.
    public var stabilization: CGFloat
    /// Pressure smoothing [0,1] (P3, Procreate "StreamLine → Pressure"): low-pass on force
    /// only; geometry untouched. 0 = off.
    public var pressureSmoothing: CGFloat
    /// Edge hardness [0,1]. 0 = soft, feathered edge; 1 = crisp edge (thin AA rim only).
    /// Applied procedurally in the brush fragment shader from per-stamp distance.
    public var hardness: CGFloat
    /// Stamp spacing as a fraction of the (pressure-modulated) stamp width. Lower =
    /// denser/smoother strokes; higher = spaced-out dabs. Default 0.3.
    public var spacing: CGFloat
    /// Spacing jitter [0,1] (Procreate "Spacing Jitter"): per-gap deterministic random
    /// multiplier on the spacing (seeded by stroke id + stamp index — replay-identical).
    /// 0 = even gaps. Dry path only.
    public var spacingJitter: CGFloat
    /// Stroke-end taper [0,1]. 0 = no taper; higher tapers the stamp radius toward the
    /// start and end of the stroke (the taper length is this fraction of the half-stroke).
    public var taper: CGFloat
    /// Per-end taper OVERRIDES (richer taper, 2026-07-16): when > 0 they set the taper
    /// length for that end alone, on top of the symmetric `taper` (effective length per
    /// end = max(taper, taperStart/End)). 0 = follow `taper` (default, back-compat).
    public var taperStart: CGFloat
    public var taperEnd: CGFloat
    /// How much the taper also fades OPACITY toward the stroke tips [0,1] (Procreate's
    /// Taper "Opacity" slider). 0 = size-only taper (the pre-2026-07-16 look).
    public var taperOpacity: CGFloat
    /// Wet-mix mode (pro-brush Phase 4, Step 1). When true the brush writes directly to
    /// the canvas layer (eraser-style RMW) and mixes its color into the pixels under it,
    /// instead of stamping opaquely via the scratch — i.e. wet-on-wet build-up.
    /// **ARCHITECTURE: this Bool (and `wetSmudge`) is a mode-toggle on the OLD wet path that the
    /// unified-brush-engine SAB rework (Step 3 / PLAN P7) DELETES wholesale. Do NOT build new
    /// behavior on it or extend it — wetness becomes a derived scalar in the unified pass there.**
    public var wetEnabled: Bool
    /// Wet deposit strength [0,1] ("Mix"): per-stamp weight toward the carried load color
    /// (scaled further by `opacity` in the wet path). Low values let the underlying color
    /// show through and build up gradually — high values cover in one pass.
    public var wetStrength: CGFloat
    /// Wet pickup [0,1] ("Smear"): how fast the carried load contaminates toward the canvas
    /// color it crosses. 0 = no smear (pure deposit); higher = the brush drags/carries color
    /// further along the stroke (smudgier).
    public var wetPickup: CGFloat
    /// Wet Charge [0,1] (Procreate Wet Mix "Charge", P7): how much paint the brush is
    /// loaded with. 1 = bottomless (deposits forever — the pre-Charge behavior, and the
    /// default). Lower = the deposit weight decays over drawn arc length: the stroke
    /// starts at full Mix and dries toward a faint tint as the reservoir runs out
    /// (half-life 180…3600px on the 2048² document, quadratic in Charge).
    public var wetCharge: CGFloat
    /// Wet Blur [0,1] (Procreate Wet Mix "Blur"/"Grade", smudge only): softens the
    /// smudge — the pickup samples a NEIGHBORHOOD average (radius grows with blur and
    /// brush size) instead of a point, and the smudge dab's rim softens, so dragged
    /// edges melt instead of staying crisp. 0 = crisp point smudge (default).
    public var wetBlur: CGFloat
    /// Wetness Jitter [0,1] (Procreate Wet Mix): per-dab random reduction of the deposit
    /// weight — some dabs land wet and full, others nearly dry, giving the stroke an
    /// organic patchiness. 0 = even deposit (default). Deterministic per dab (stroke id
    /// + dab index), so replay is identical. Ink mode only.
    public var wetJitter: CGFloat
    /// Wet Refill [0,1] (Painter's "resaturation"): how fast the carried load is pulled
    /// BACK toward the brush's own ink between dabs — the brush continuously re-loads
    /// from an infinite well of its color. 0 = never (contamination persists until the
    /// next crossing — the pre-Refill behavior and default). Higher = picked-up color
    /// dissipates over distance and the stroke returns to pure ink; during a crossing,
    /// Refill vs Smear sets the contamination equilibrium. Ink mode only (smudge has no
    /// ink to refill from).
    public var wetRefill: CGFloat
    /// Smudge mode (P4): when true (with `wetEnabled`), the carried paint load is seeded from
    /// the CANVAS color under the first dab instead of the brush ink — so the brush pushes
    /// existing color around (Procreate-style smudge) and introduces no new ink. `wetStrength`
    /// (Mix) = redeposit strength; `wetPickup` (Smear) = how fast it re-grabs canvas color.
    /// Device-only (inherits the wet render path). See `BrushConfig.smudge(...)`.
    public var wetSmudge: Bool
    /// Brush-tip shape id (see `BrushShapeCatalog`). nil / "round" = the procedural soft
    /// circle; other ids bind a grayscale stamp texture. Textured shapes orient to the
    /// stroke direction. See pro-brush-roadmap Phase 3.
    public var shapeID: String?
    /// Tip aspect ratio (P4b anisotropy): 1 = round (today's tip), <1 flattens the tip
    /// along its local Y axis (the travel axis for stroke-oriented shapes) — a chisel /
    /// calligraphy nib once combined with `rotation` (fixed via shape orientation or a
    /// Rotation dynamics option). Implemented as a vertex-stage Y-scale of the stamp
    /// quad, so it applies to procedural, textured, AND wet dabs with no fragment cost.
    /// Clamped to [0.05, 1] at stamp packing.
    public var aspectRatio: CGFloat
    /// Grain texture id (P8; see `GrainCatalog`). nil = no grain. Grain carves the dab
    /// coverage with a soft-HEIGHT composite in DOCUMENT space (tooth stays put under
    /// the stroke, dry-media style). Ignored by the wet path (v1).
    public var grainID: String?
    /// Grain depth [0,1]: 0 = grain off (identity), higher = tooth valleys carve the
    /// dab away more aggressively (soft-HEIGHT: clamp(cov/(1−0.99·d) − src·d, 0, 1)).
    public var grainDepth: CGFloat
    /// Grain scale multiplier on the 256px tile (× the grain's nativeScale). >1 = coarser.
    public var grainScale: CGFloat
    /// Grain mode (P8 "Moving", 2026-07-16): false = document-space tooth (Procreate
    /// "Texturized" — grain stays put under the stroke, dry-media invariant); true =
    /// the grain rides WITH the stroke in an arc-anchored frame (Procreate "Moving" —
    /// streaky crayon/lead). Moving grain carves per dab in the stamp fragments;
    /// document grain carves once at scratch-composite time.
    public var grainMoving: Bool
    /// Moving-grain "Movement" [0,1] (Procreate): 0 = smear/drag — the streak
    /// anisotropy (lateral ×3.5, along ×0.45; the crayon/lead look); 1 = Rolling —
    /// isotropic, the texture rolls under the brush undistorted (grids stay square).
    public var grainMovement: CGFloat
    /// Moving-grain "Zoom" [0,1] (Procreate): 0 = Follow size — the tile scales with
    /// brush size; 1 = Cropped — fixed tile from the texture's own resolution.
    /// Texturized mode always uses the fixed document-anchored tile.
    public var grainZoom: CGFloat
    /// Moving-grain "Rotation" [-1,1] (Procreate): grain angle vs the stroke
    /// direction, ±1 ≙ ±180°. 0 = aligned with the stroke frame.
    public var grainRotation: CGFloat
    /// Moving-grain "Depth Minimum" [0,1] (Procreate): floor for MODULATED depth —
    /// when the dynamics grain curve / Depth Jitter pull depth down, it bottoms out
    /// here instead of 0. Inert when nothing modulates.
    public var grainDepthMinimum: CGFloat
    /// Moving-grain "Offset Jitter" (Procreate): one random tile offset per stroke,
    /// so repeated strokes don't repeat the same grain phase.
    public var grainOffsetJitter: Bool
    /// Grain "Brightness" [-1,1] (both modes): pre-adjusts the grain texture.
    public var grainBrightness: CGFloat
    /// Grain "Contrast" [-1,1] (both modes): pre-adjusts the grain texture.
    public var grainContrast: CGFloat
    /// P4a lightness-map strength [0,1]: reinterpret the shaped tip's grayscale as a VALUE
    /// map (Krita PreserveLightness / Schatz quadratic) — dark tip pixels darken the ink,
    /// light ones lighten it, mid-gray = exact brush color. 0 = off (flat ink, today's
    /// look). Shaped tips only; the round procedural tip has no luma to map.
    public var tipLightness: CGFloat
    /// Static tip angle in RADIANS (Krita's brush-tip angle): the nib's base orientation
    /// before any follow-stroke or dynamic rotation is added. The calligraphy knob — a
    /// flat tip (aspectRatio < 1) held at 45° is `tipAngle = π/4`. NOTE: a no-sensor
    /// rotationLike CurveOption folds to 0 (verified offline), so this field is the ONLY
    /// way to hold a fixed nib angle.
    public var tipAngle: CGFloat
    /// Fall Off [0,1] (Procreate Stroke Path): the stroke's paint runs out over drawn
    /// distance — flow ramps to zero at a die length that shrinks as the knob rises
    /// (0 = never dies; 1 = dies within a few hundred document px). Applied as a
    /// per-dab flow multiplier over cumulative arc length; dry path only.
    public var fallOff: CGFloat
    /// Stamps per spacing point (Procreate Shape "Count", 1–16). Copies beyond the first
    /// get independent scatter draws (using the brush's scatter/lateral/linear magnitudes),
    /// so Count × Scatter = clustered texture. With no scatter configured the copies
    /// coincide (Procreate semantics — Count is designed to pair with Scatter).
    public var stampCount: Int
    /// Count jitter [0,1] (Procreate "Count Jitter"): randomly reduces the per-dab copy
    /// count (deterministic per dab; replay-identical). 0 = always `stampCount`.
    public var stampCountJitter: CGFloat
    /// Signed follow-stroke rotation (Procreate Shape "Rotation" −100…100 ≙ −1…1).
    /// nil = legacy behavior (shapes orient per `BrushShapeCatalog.orientsToStroke`,
    /// fully). Set: multiplies the stroke-following angle — 1 follow, 0 fixed upright,
    /// −1 inverse-follow (mirror). Shaped tips only.
    public var rotationFollow: CGFloat?
    /// Random per-dab tip spin [0,1] (Procreate Shape "Scatter" — rotation
    /// randomization, NOT positional offset). 0 = none; 1 = fully random orientation.
    /// Deterministic per dab (stroke-seeded). Adds on top of follow/tip rotation.
    /// The dry-media shapes' catalog `rotationJitter` flag forces 1 (legacy behavior).
    public var rotationJitter: CGFloat
    /// One random tip rotation PER STROKE (Procreate Shape "Randomized"): each stroke
    /// lands the tip at a new angle, but the stroke itself stays coherent.
    public var randomizedRotation: Bool
    /// Random per-stamp grain-strength reduction [0,1] (Procreate Grain "Depth Jitter"):
    /// grainMul ×= 1 − r·jitter, one-sided down from the configured Depth.
    public var grainDepthJitter: CGFloat
    /// Mirror the tip art horizontally / vertically (Procreate Shape "Flip X/Y").
    /// Vertex-stage UV flip; no effect on the symmetric procedural round tip.
    public var flipX: Bool
    public var flipY: Bool
    /// Secondary ink (P6 "Secondary Color"): when set AND `dynamics.secondary` provides
    /// a blend curve, each dab's color lerps (sRGB) from the primary toward this by the
    /// curve's per-dab value — pressure-driven two-tone nibs, distance gradients, fuzzy
    /// two-color speckle. nil = single-ink brush (default).
    public var secondaryColor: CodableColor?
    /// Krita-grade brush dynamics: per-parameter sensor→curve→combine→remap options
    /// (`BrushDynamics`). `nil` (the default) means "no dynamics" — the legacy
    /// `pressureGamma`/`tiltSensitivity` scalars drive size and everything else is a flat
    /// scalar, i.e. today's pen exactly. Each non-nil `CurveOption` overrides one parameter.
    /// This is the additive seed of the eventual `BrushDescriptor`
    /// (`documents/plans/unified-brush-engine.md` §2.1 / `documents/research/krita-brush/PLAN.md`).
    public var dynamics: BrushDynamics?

    public init(
        color: CodableColor,
        baseWidth: CGFloat,
        opacity: CGFloat = 1.0,
        flow: CGFloat = 1.0,
        pressureGamma: CGFloat = 0.7,
        tiltSensitivity: CGFloat = 0.0,
        streamline: CGFloat = 0.0,
        stabilization: CGFloat = 0.0,
        pressureSmoothing: CGFloat = 0.0,
        hardness: CGFloat = 0.5,
        spacing: CGFloat = 0.3,
        spacingJitter: CGFloat = 0.0,
        taper: CGFloat = 0.0,
        taperStart: CGFloat = 0.0,
        taperEnd: CGFloat = 0.0,
        taperOpacity: CGFloat = 0.0,
        wetEnabled: Bool = false,
        wetStrength: CGFloat = 0.4,
        wetPickup: CGFloat = 0.25,
        wetSmudge: Bool = false,
        wetCharge: CGFloat = 1.0,
        wetRefill: CGFloat = 0.0,
        wetJitter: CGFloat = 0.0,
        wetBlur: CGFloat = 0.0,
        shapeID: String? = nil,
        aspectRatio: CGFloat = 1.0,
        grainID: String? = nil,
        grainDepth: CGFloat = 0.5,
        grainScale: CGFloat = 1.0,
        grainMoving: Bool = false,
        grainMovement: CGFloat = 0.0,
        grainZoom: CGFloat = 1.0,
        grainRotation: CGFloat = 0.0,
        grainDepthMinimum: CGFloat = 0.0,
        grainOffsetJitter: Bool = false,
        grainBrightness: CGFloat = 0.0,
        grainContrast: CGFloat = 0.0,
        tipLightness: CGFloat = 0.0,
        tipAngle: CGFloat = 0.0,
        fallOff: CGFloat = 0.0,
        stampCount: Int = 1,
        stampCountJitter: CGFloat = 0.0,
        rotationFollow: CGFloat? = nil,
        rotationJitter: CGFloat = 0.0,
        randomizedRotation: Bool = false,
        grainDepthJitter: CGFloat = 0.0,
        flipX: Bool = false,
        flipY: Bool = false,
        secondaryColor: CodableColor? = nil,
        dynamics: BrushDynamics? = nil
    ) {
        self.color = color
        self.baseWidth = baseWidth
        self.opacity = opacity
        self.flow = flow
        self.pressureGamma = pressureGamma
        self.tiltSensitivity = tiltSensitivity
        self.streamline = streamline
        self.stabilization = stabilization
        self.pressureSmoothing = pressureSmoothing
        self.hardness = hardness
        self.spacing = spacing
        self.spacingJitter = spacingJitter
        self.taper = taper
        self.taperStart = taperStart
        self.taperEnd = taperEnd
        self.taperOpacity = taperOpacity
        self.wetEnabled = wetEnabled
        self.wetStrength = wetStrength
        self.wetPickup = wetPickup
        self.wetSmudge = wetSmudge
        self.wetCharge = wetCharge
        self.wetRefill = wetRefill
        self.wetJitter = wetJitter
        self.wetBlur = wetBlur
        self.shapeID = shapeID
        self.aspectRatio = aspectRatio
        self.grainID = grainID
        self.grainDepth = grainDepth
        self.grainScale = grainScale
        self.grainMoving = grainMoving
        self.grainMovement = grainMovement
        self.grainZoom = grainZoom
        self.grainRotation = grainRotation
        self.grainDepthMinimum = grainDepthMinimum
        self.grainOffsetJitter = grainOffsetJitter
        self.grainBrightness = grainBrightness
        self.grainContrast = grainContrast
        self.tipLightness = tipLightness
        self.tipAngle = tipAngle
        self.fallOff = fallOff
        self.stampCount = stampCount
        self.stampCountJitter = stampCountJitter
        self.rotationFollow = rotationFollow
        self.rotationJitter = rotationJitter
        self.randomizedRotation = randomizedRotation
        self.grainDepthJitter = grainDepthJitter
        self.flipX = flipX
        self.flipY = flipY
        self.secondaryColor = secondaryColor
        self.dynamics = dynamics
    }

    /// A ready-to-use Procreate-style smudge brush: wet path, load seeded from the canvas
    /// (no new ink), strong smear. Wire a smudge tool button to set this as the active brush.
    public static func smudge(baseWidth: CGFloat = 30, strength: CGFloat = 0.6) -> BrushConfig {
        BrushConfig(color: .black, baseWidth: baseWidth, opacity: 1.0, hardness: 0.5,
                    wetEnabled: true, wetStrength: strength, wetPickup: 0.85, wetSmudge: true)
    }

    public static let defaultPen = BrushConfig(color: .black, baseWidth: 5, pressureGamma: 0.7)

    /// Valid width range for the pen and eraser tools.
    // Floor is 2.5, not 1: on the log-scale size slider sub-2.5 px sizes ate 20% of the
    // travel and aren't useful strokes at 2048² document resolution.
    public static let widthRange: ClosedRange<CGFloat> = 2.5...100

    /// Charge → deposit-decay half-life in document px (pure; offline-asserted).
    /// `.infinity` at charge ≥ 0.999 (bottomless — the identity the default relies on).
    public var wetChargeHalfLife: CGFloat {
        let c = max(0, min(1, wetCharge))
        return c >= 0.999 ? .infinity : 180 + 3420 * c * c
    }

    /// Compute effective stroke width for a given pressure and tilt.
    public func effectiveWidth(force: CGFloat, altitude: CGFloat = .pi / 2) -> CGFloat {
        var width = baseWidth * pow(max(force, 0.01), pressureGamma)
        if tiltSensitivity > 0 {
            let tiltFactor = 1.0 + tiltSensitivity * (1.0 - altitude / (.pi / 2)) * 2.0
            width *= tiltFactor
        }
        return width
    }

    // MARK: - Backward-compatible Codable

    enum CodingKeys: String, CodingKey {
        case color, baseWidth, opacity, flow, pressureGamma, pressureOpacity
        case streamline, taperIn, taperOut, tiltSensitivity
        case hardness, spacing, taper, wetEnabled, wetStrength, wetPickup, shapeID
        case dynamics, wetSmudge, aspectRatio, stabilization, pressureSmoothing
        case grainID, grainDepth, grainScale, spacingJitter, tipLightness
        case stampCount, stampCountJitter, rotationFollow, flipX, flipY, fallOff, tipAngle
        case wetCharge, wetRefill, wetJitter, wetBlur, secondaryColor
        case taperStart, taperEnd, taperOpacity, grainMoving, rotationJitter
        case randomizedRotation, grainDepthJitter
        case grainMovement, grainZoom
        case grainRotation, grainDepthMinimum, grainOffsetJitter, grainBrightness, grainContrast
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        color = try container.decode(CodableColor.self, forKey: .color)
        baseWidth = try container.decode(CGFloat.self, forKey: .baseWidth)
        pressureGamma = try container.decode(CGFloat.self, forKey: .pressureGamma)
        opacity = try container.decodeIfPresent(CGFloat.self, forKey: .opacity) ?? 1.0
        // Default flow to 1.0 so configs saved before flow/opacity were split decode
        // unchanged (old "opacity" was baked per-stamp ≈ flow=1.0 with the value as ceiling).
        flow = try container.decodeIfPresent(CGFloat.self, forKey: .flow) ?? 1.0
        tiltSensitivity = try container.decodeIfPresent(CGFloat.self, forKey: .tiltSensitivity) ?? 0.0
        // Default streamline to 0.0 so configs saved without it decode to "no smoothing"
        // (matches pre-Phase-1 behavior). The key already existed as a legacy no-op.
        streamline = try container.decodeIfPresent(CGFloat.self, forKey: .streamline) ?? 0.0
        // P3 stabilization rebuild — default 0 (off) so earlier configs decode unchanged.
        stabilization = try container.decodeIfPresent(CGFloat.self, forKey: .stabilization) ?? 0.0
        pressureSmoothing = try container.decodeIfPresent(CGFloat.self, forKey: .pressureSmoothing) ?? 0.0
        // Phase 2 fields — default to the init defaults so configs saved before them
        // decode unchanged.
        hardness = try container.decodeIfPresent(CGFloat.self, forKey: .hardness) ?? 0.5
        spacing = try container.decodeIfPresent(CGFloat.self, forKey: .spacing) ?? 0.3
        spacingJitter = try container.decodeIfPresent(CGFloat.self, forKey: .spacingJitter) ?? 0.0
        taper = try container.decodeIfPresent(CGFloat.self, forKey: .taper) ?? 0.0
        taperStart = try container.decodeIfPresent(CGFloat.self, forKey: .taperStart) ?? 0.0
        taperEnd = try container.decodeIfPresent(CGFloat.self, forKey: .taperEnd) ?? 0.0
        taperOpacity = try container.decodeIfPresent(CGFloat.self, forKey: .taperOpacity) ?? 0.0
        wetEnabled = try container.decodeIfPresent(Bool.self, forKey: .wetEnabled) ?? false
        wetStrength = try container.decodeIfPresent(CGFloat.self, forKey: .wetStrength) ?? 0.4
        wetPickup = try container.decodeIfPresent(CGFloat.self, forKey: .wetPickup) ?? 0.25
        wetSmudge = try container.decodeIfPresent(Bool.self, forKey: .wetSmudge) ?? false
        wetCharge = try container.decodeIfPresent(CGFloat.self, forKey: .wetCharge) ?? 1.0
        wetRefill = try container.decodeIfPresent(CGFloat.self, forKey: .wetRefill) ?? 0.0
        wetJitter = try container.decodeIfPresent(CGFloat.self, forKey: .wetJitter) ?? 0.0
        wetBlur = try container.decodeIfPresent(CGFloat.self, forKey: .wetBlur) ?? 0.0
        // Phase 3 — default nil (procedural round) so pre-Phase-3 configs decode unchanged.
        shapeID = try container.decodeIfPresent(String.self, forKey: .shapeID)
        // P4b — default 1 (round) so configs saved before aspect decode unchanged.
        aspectRatio = try container.decodeIfPresent(CGFloat.self, forKey: .aspectRatio) ?? 1.0
        // P8 grain — defaults keep earlier configs grain-free.
        grainID = try container.decodeIfPresent(String.self, forKey: .grainID)
        grainDepth = try container.decodeIfPresent(CGFloat.self, forKey: .grainDepth) ?? 0.5
        grainScale = try container.decodeIfPresent(CGFloat.self, forKey: .grainScale) ?? 1.0
        grainMoving = try container.decodeIfPresent(Bool.self, forKey: .grainMoving) ?? false
        tipLightness = try container.decodeIfPresent(CGFloat.self, forKey: .tipLightness) ?? 0.0
        // Cheap-knobs batch 2 — defaults reproduce single-stamp, catalog-oriented, unflipped tips.
        fallOff = try container.decodeIfPresent(CGFloat.self, forKey: .fallOff) ?? 0.0
        tipAngle = try container.decodeIfPresent(CGFloat.self, forKey: .tipAngle) ?? 0.0
        stampCount = try container.decodeIfPresent(Int.self, forKey: .stampCount) ?? 1
        stampCountJitter = try container.decodeIfPresent(CGFloat.self, forKey: .stampCountJitter) ?? 0.0
        rotationFollow = try container.decodeIfPresent(CGFloat.self, forKey: .rotationFollow)
        rotationJitter = try container.decodeIfPresent(CGFloat.self, forKey: .rotationJitter) ?? 0.0
        randomizedRotation = try container.decodeIfPresent(Bool.self, forKey: .randomizedRotation) ?? false
        grainDepthJitter = try container.decodeIfPresent(CGFloat.self, forKey: .grainDepthJitter) ?? 0.0
        grainMovement = try container.decodeIfPresent(CGFloat.self, forKey: .grainMovement) ?? 0.0
        grainZoom = try container.decodeIfPresent(CGFloat.self, forKey: .grainZoom) ?? 1.0
        grainRotation = try container.decodeIfPresent(CGFloat.self, forKey: .grainRotation) ?? 0.0
        grainDepthMinimum = try container.decodeIfPresent(CGFloat.self, forKey: .grainDepthMinimum) ?? 0.0
        grainOffsetJitter = try container.decodeIfPresent(Bool.self, forKey: .grainOffsetJitter) ?? false
        grainBrightness = try container.decodeIfPresent(CGFloat.self, forKey: .grainBrightness) ?? 0.0
        grainContrast = try container.decodeIfPresent(CGFloat.self, forKey: .grainContrast) ?? 0.0
        flipX = try container.decodeIfPresent(Bool.self, forKey: .flipX) ?? false
        flipY = try container.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
        secondaryColor = try container.decodeIfPresent(CodableColor.self, forKey: .secondaryColor)
        // Krita-grade dynamics — default nil (legacy scalar behavior) so configs saved before
        // it decode to today's pen unchanged.
        dynamics = try container.decodeIfPresent(BrushDynamics.self, forKey: .dynamics)
        // Removed fields — decoded for backward compat with saved configs, not stored.
        _ = try container.decodeIfPresent(CGFloat.self, forKey: .pressureOpacity)
        _ = try container.decodeIfPresent(CGFloat.self, forKey: .taperIn)
        _ = try container.decodeIfPresent(CGFloat.self, forKey: .taperOut)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(color, forKey: .color)
        try container.encode(baseWidth, forKey: .baseWidth)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(flow, forKey: .flow)
        try container.encode(pressureGamma, forKey: .pressureGamma)
        try container.encode(tiltSensitivity, forKey: .tiltSensitivity)
        try container.encode(streamline, forKey: .streamline)
        try container.encode(stabilization, forKey: .stabilization)
        try container.encode(pressureSmoothing, forKey: .pressureSmoothing)
        try container.encode(hardness, forKey: .hardness)
        try container.encode(spacing, forKey: .spacing)
        try container.encode(spacingJitter, forKey: .spacingJitter)
        try container.encode(taper, forKey: .taper)
        try container.encode(taperStart, forKey: .taperStart)
        try container.encode(taperEnd, forKey: .taperEnd)
        try container.encode(taperOpacity, forKey: .taperOpacity)
        try container.encode(wetEnabled, forKey: .wetEnabled)
        try container.encode(wetStrength, forKey: .wetStrength)
        try container.encode(wetPickup, forKey: .wetPickup)
        try container.encode(wetSmudge, forKey: .wetSmudge)
        try container.encode(wetCharge, forKey: .wetCharge)
        try container.encode(wetRefill, forKey: .wetRefill)
        try container.encode(wetJitter, forKey: .wetJitter)
        try container.encode(wetBlur, forKey: .wetBlur)
        try container.encodeIfPresent(secondaryColor, forKey: .secondaryColor)
        try container.encodeIfPresent(shapeID, forKey: .shapeID)
        // aspectRatio was decoded-but-never-encoded from P4b (2026-07-15 fix): saved
        // brushes / recorded fixtures silently lost their aspect on round-trip.
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(grainID, forKey: .grainID)
        try container.encode(grainDepth, forKey: .grainDepth)
        try container.encode(grainScale, forKey: .grainScale)
        try container.encode(grainMoving, forKey: .grainMoving)
        try container.encode(tipLightness, forKey: .tipLightness)
        try container.encode(fallOff, forKey: .fallOff)
        try container.encode(tipAngle, forKey: .tipAngle)
        try container.encode(stampCount, forKey: .stampCount)
        try container.encode(stampCountJitter, forKey: .stampCountJitter)
        try container.encodeIfPresent(rotationFollow, forKey: .rotationFollow)
        try container.encode(rotationJitter, forKey: .rotationJitter)
        try container.encode(randomizedRotation, forKey: .randomizedRotation)
        try container.encode(grainDepthJitter, forKey: .grainDepthJitter)
        try container.encode(grainMovement, forKey: .grainMovement)
        try container.encode(grainZoom, forKey: .grainZoom)
        try container.encode(grainRotation, forKey: .grainRotation)
        try container.encode(grainDepthMinimum, forKey: .grainDepthMinimum)
        try container.encode(grainOffsetJitter, forKey: .grainOffsetJitter)
        try container.encode(grainBrightness, forKey: .grainBrightness)
        try container.encode(grainContrast, forKey: .grainContrast)
        try container.encode(flipX, forKey: .flipX)
        try container.encode(flipY, forKey: .flipY)
        try container.encodeIfPresent(dynamics, forKey: .dynamics)
    }
}

// MARK: - Stroke

/// A complete stroke: a sequence of points with a brush configuration.
public struct Stroke: Codable, Sendable, Identifiable {
    public let id: UUID
    public var points: [StrokePoint]
    public var brush: BrushConfig

    public init(id: UUID = UUID(), points: [StrokePoint] = [], brush: BrushConfig = .defaultPen) {
        self.id = id
        self.points = points
        self.brush = brush
    }
}

// MARK: - Tool State

/// The currently active drawing tool.
public enum ToolState: Sendable {
    case brush(BrushConfig)
    case eraser(width: CGFloat)
    case lasso
    /// Magic wand: taps are SAM segmentation prompts, not strokes.
    case magicWand
}

// MARK: - Layered Drawing Persistence

/// Persistence envelope for multi-layer canvas data. Each layer is stored
/// as a separate PNG blob alongside its metadata.
struct LayeredDrawing: Codable {
    let version: Int
    let layers: [LayerEntry]
    let activeLayerIndex: Int

    struct LayerEntry: Codable {
        let id: String
        let name: String
        let isVisible: Bool
        let pngData: Data
        // Optionals so older saves decode (nil → false / normal / 1.0).
        let isLocked: Bool?
        let isAlphaLocked: Bool?
        let blendMode: String?
        let opacity: Double?
    }
}


// MARK: - BrushConfig equality

/// Memberwise equality (synthesized). Lets SwiftUI diff configs — the Brush Studio's
/// live preview re-renders via `.task(id: config)` only when a knob actually changed.
extension BrushConfig: Equatable {}

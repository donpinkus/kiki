// UIKit is optional here (macOS BrushHarness compiles this file too); only the
// `CodableColor.uiColor` convenience needs it.
import Foundation
import CoreGraphics
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Layer Info

/// Metadata for a single canvas layer (name, visibility). The actual texture
/// is stored by index on `CanvasRenderer`.
public struct LayerInfo: Codable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var isVisible: Bool

    public init(id: UUID = UUID(), name: String, isVisible: Bool = true) {
        self.id = id
        self.name = name
        self.isVisible = isVisible
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
        wetEnabled: Bool = false,
        wetStrength: CGFloat = 0.4,
        wetPickup: CGFloat = 0.25,
        wetSmudge: Bool = false,
        shapeID: String? = nil,
        aspectRatio: CGFloat = 1.0,
        grainID: String? = nil,
        grainDepth: CGFloat = 0.5,
        grainScale: CGFloat = 1.0,
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
        self.wetEnabled = wetEnabled
        self.wetStrength = wetStrength
        self.wetPickup = wetPickup
        self.wetSmudge = wetSmudge
        self.shapeID = shapeID
        self.aspectRatio = aspectRatio
        self.grainID = grainID
        self.grainDepth = grainDepth
        self.grainScale = grainScale
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
        case grainID, grainDepth, grainScale, spacingJitter
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
        wetEnabled = try container.decodeIfPresent(Bool.self, forKey: .wetEnabled) ?? false
        wetStrength = try container.decodeIfPresent(CGFloat.self, forKey: .wetStrength) ?? 0.4
        wetPickup = try container.decodeIfPresent(CGFloat.self, forKey: .wetPickup) ?? 0.25
        wetSmudge = try container.decodeIfPresent(Bool.self, forKey: .wetSmudge) ?? false
        // Phase 3 — default nil (procedural round) so pre-Phase-3 configs decode unchanged.
        shapeID = try container.decodeIfPresent(String.self, forKey: .shapeID)
        // P4b — default 1 (round) so configs saved before aspect decode unchanged.
        aspectRatio = try container.decodeIfPresent(CGFloat.self, forKey: .aspectRatio) ?? 1.0
        // P8 grain — defaults keep earlier configs grain-free.
        grainID = try container.decodeIfPresent(String.self, forKey: .grainID)
        grainDepth = try container.decodeIfPresent(CGFloat.self, forKey: .grainDepth) ?? 0.5
        grainScale = try container.decodeIfPresent(CGFloat.self, forKey: .grainScale) ?? 1.0
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
        try container.encode(wetEnabled, forKey: .wetEnabled)
        try container.encode(wetStrength, forKey: .wetStrength)
        try container.encode(wetPickup, forKey: .wetPickup)
        try container.encode(wetSmudge, forKey: .wetSmudge)
        try container.encodeIfPresent(shapeID, forKey: .shapeID)
        // aspectRatio was decoded-but-never-encoded from P4b (2026-07-15 fix): saved
        // brushes / recorded fixtures silently lost their aspect on round-trip.
        try container.encode(aspectRatio, forKey: .aspectRatio)
        try container.encodeIfPresent(grainID, forKey: .grainID)
        try container.encode(grainDepth, forKey: .grainDepth)
        try container.encode(grainScale, forKey: .grainScale)
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
    }
}


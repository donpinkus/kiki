import CoreGraphics

// MARK: - Brush presets / control-isolation test brushes
//
// TEMPORARY (dev): while tuning the sensor+curve engine (`BrushDynamics.swift`), the catalog is a
// set of CONTROL-ISOLATION TEST brushes — each varies exactly ONE control (pressure→size,
// speed→size, tilt→size, scatter, …) with everything else pinned to neutral, so each part of the
// engine can be unit-tested + tuned against the live input HUD. Real curated presets return once
// the engine is verified. See documents/research/krita-brush/IMPLEMENTATION-LOG.md.

/// A brush preset / test: a dynamics bundle + tip params, plus optional hard pins for
/// baseWidth/opacity/flow so an isolation test fully specifies the brush (no stray pressure/tilt
/// response leaking in from the legacy scalars).
public struct BrushPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let dynamics: BrushDynamics
    public let hardness: CGFloat
    public let spacing: CGFloat
    public let shapeID: String?
    /// Pins (nil = keep the user's current value). Test brushes set these so the test is reproducible.
    public let baseWidth: CGFloat?
    public let opacity: CGFloat?
    public let flow: CGFloat?
    /// One-line instruction shown in the Brush Studio when this is active (gesture + what to expect).
    public let note: String?

    public init(id: String, name: String, dynamics: BrushDynamics,
                hardness: CGFloat = 0.5, spacing: CGFloat = 0.3, shapeID: String? = nil,
                baseWidth: CGFloat? = nil, opacity: CGFloat? = nil, flow: CGFloat? = nil,
                note: String? = nil) {
        self.id = id; self.name = name; self.dynamics = dynamics
        self.hardness = hardness; self.spacing = spacing; self.shapeID = shapeID
        self.baseWidth = baseWidth; self.opacity = opacity; self.flow = flow; self.note = note
    }

    /// Apply onto a base brush. Overrides applied where non-nil; otherwise base is preserved.
    public func applied(to base: BrushConfig) -> BrushConfig {
        var c = base
        c.dynamics = dynamics
        c.hardness = hardness
        c.spacing = spacing
        c.shapeID = shapeID
        if let baseWidth { c.baseWidth = baseWidth }
        if let opacity { c.opacity = opacity }
        if let flow { c.flow = flow }
        return c
    }
}

public enum BrushPresetCatalog {

    private static func curve(_ pts: [(Double, Double)]) -> ResponseCurve {
        ResponseCurve(points: pts.map { ResponseCurve.Point($0.0, $0.1) })
    }
    private static func opt(_ sensors: [SensorChannel], min: Double = 0, max: Double = 1,
                            fold: BrushFold = .sizeLike, strength: Double = 1,
                            combine: CombineMode = .multiply, useSameCurve: Bool = true,
                            common: ResponseCurve = .identity) -> CurveOption {
        CurveOption(sensors: sensors, combineMode: combine, fold: fold, strength: strength,
                    minValue: min, maxValue: max, useSameCurve: useSameCurve, commonCurve: common)
    }
    /// Constant size = baseWidth (no legacy pressure/tilt leak), for isolating non-size controls.
    private static var constSize: CurveOption { opt([], strength: 1) }

    // --- The 10 control-isolation test brushes -------------------------------------------------

    public static let pressureSize = BrushPreset(
        id: "t_pressure_size", name: "TEST: Pressure→Size",
        dynamics: BrushDynamics(size: opt([SensorChannel(sensor: .pressure)], min: 0.05)),
        hardness: 0.5, spacing: 0.1, baseWidth: 36, opacity: 1, flow: 1,
        note: "Vary pressure → width tracks it. HUD: sizeMul should ≈ pressure.")

    public static let pressureFlow = BrushPreset(
        id: "t_pressure_flow", name: "TEST: Pressure→Flow",
        dynamics: BrushDynamics(size: constSize,
                                flow: opt([SensorChannel(sensor: .pressure)], min: 0.05)),
        hardness: 0.5, spacing: 0.08, baseWidth: 36, opacity: 0.5, flow: 1,
        note: "Width fixed; darkness tracks pressure. Press light vs hard, and repeat passes to build up.")

    public static let speedSize = BrushPreset(
        id: "t_speed_size", name: "TEST: Speed→Size",
        dynamics: BrushDynamics(size: opt([SensorChannel(sensor: .speed, curve: curve([(0, 1.0), (1, 0.2)]))],
                                          min: 0.05, useSameCurve: false)),
        hardness: 0.5, spacing: 0.1, baseWidth: 36, opacity: 1, flow: 1,
        note: "Fast = thin, slow = full. Watch HUD speedRaw and tune maxSpeed (Engine sliders) so your range fills 0→1.")

    public static let tiltSize = BrushPreset(
        id: "t_tilt_size", name: "TEST: Tilt→Size",
        dynamics: BrushDynamics(size: opt([SensorChannel(sensor: .tiltElevation)], min: 0.1)),
        hardness: 0.5, spacing: 0.1, baseWidth: 40, opacity: 1, flow: 1,
        note: "Upright pencil = wide, flat = thin (HUD tilt: 1=upright, 0=flat).")

    public static let azimuthRotation = BrushPreset(
        id: "t_azimuth_rot", name: "TEST: Azimuth→Rotation",
        dynamics: BrushDynamics(size: constSize,
                                rotation: opt([SensorChannel(sensor: .tiltDirection)], fold: .rotationLike)),
        hardness: 0.7, spacing: 0.08, shapeID: "drybrush", baseWidth: 50, opacity: 1, flow: 1,
        note: "Draw horizontal strokes, twisting the pencil between them → tip angle changes. HUD: azimuth.")

    public static let angleRotation = BrushPreset(
        id: "t_angle_rot", name: "TEST: Angle→Rotation",
        dynamics: BrushDynamics(size: constSize,
                                rotation: opt([SensorChannel(sensor: .drawingAngle)], fold: .rotationLike)),
        hardness: 0.7, spacing: 0.08, shapeID: "drybrush", baseWidth: 50, opacity: 1, flow: 1,
        note: "Draw in varying directions → tip rotates with heading (adds to the tip's built-in orient). HUD: angle.")

    public static let distanceSize = BrushPreset(
        id: "t_distance_size", name: "TEST: Distance→Size",
        dynamics: BrushDynamics(size: opt([SensorChannel(sensor: .distance)], min: 0.05,
                                          common: curve([(0, 0.15), (1, 1.0)]))),
        hardness: 0.5, spacing: 0.1, baseWidth: 36, opacity: 1, flow: 1,
        note: "Long stroke → width ramps thin→thick over ~one distance period (tune period in Engine sliders).")

    public static let fadeSize = BrushPreset(
        id: "t_fade_size", name: "TEST: Fade→Size",
        dynamics: BrushDynamics(size: opt([SensorChannel(sensor: .fade)], min: 0.05,
                                          common: curve([(0, 0.15), (1, 1.0)]))),
        hardness: 0.5, spacing: 0.1, baseWidth: 36, opacity: 1, flow: 1,
        note: "Continuous stroke → width grows over the first ~[fade period] dabs.")

    public static let scatter = BrushPreset(
        id: "t_scatter", name: "TEST: Scatter",
        dynamics: BrushDynamics(size: opt([SensorChannel(sensor: .pressure)], min: 0.3),
                                scatter: opt([], strength: 0.6)),
        hardness: 0.6, spacing: 0.9, baseWidth: 28, opacity: 1, flow: 1,
        note: "Scribble → dabs scatter around the path (wide spacing makes each dab visible).")

    public static let colorJitter = BrushPreset(
        id: "t_color_jitter", name: "TEST: Color jitter",
        dynamics: BrushDynamics(size: constSize,
                                colorJitter: ColorJitter(hue: 0.1, saturation: 0.2, brightness: 0.15)),
        hardness: 0.5, spacing: 0.1, baseWidth: 36, opacity: 1, flow: 1,
        note: "Draw SEPARATE strokes → each a slightly different shade (per-stroke, not within a stroke).")

    /// The ordered set of control-isolation test brushes.
    public static let all: [BrushPreset] = [
        pressureSize, pressureFlow, speedSize, tiltSize, azimuthRotation, angleRotation,
        distanceSize, fadeSize, scatter, colorJitter,
    ]
}

// MARK: - Curated presets (preset-library v1, 2026-07-15)

/// A user-facing brush preset: a full recipe over the shipped machinery (shape, grain,
/// lightness map, dynamics, stabilization, Count/scatter, Fall Off). A preset REPLACES
/// every secondary knob but keeps the user's **color and size** — those are primary tool
/// state. Distinct from the control-isolation `BrushPreset` test brushes above (dev-only,
/// each varies exactly one control); these are the "feels like Procreate" deliverable of
/// `documents/research/krita-brush/13-procreate-parity.md` §6.
///
/// NOTE: no preset uses the Speed sensor yet — Speed dynamics stay pinned until
/// `maxSpeed` is tuned on device (handoff item 2).
public struct CuratedPreset: Identifiable, Sendable {
    public let id: String
    public let displayName: String
    /// Apply the recipe onto a plain base carrying the user's color/size/opacity.
    public let configure: @Sendable (_ base: BrushConfig) -> BrushConfig

    public init(id: String, displayName: String,
                configure: @escaping @Sendable (_ base: BrushConfig) -> BrushConfig) {
        self.id = id
        self.displayName = displayName
        self.configure = configure
    }
}

public enum CuratedPresetCatalog {

    /// Pressure→size curve shared by the sketching presets: light touch thins the line
    /// without ever vanishing.
    private static func pressureSize(min: Double = 0.35) -> CurveOption {
        CurveOption(sensors: [SensorChannel(sensor: .pressure)], minValue: min)
    }
    /// Like `pressureSize` but CONCAVE (≈ p^0.35), matching the legacy pressureGamma feel
    /// of brushes without size dynamics. A linear curve reaches only ~50% width at
    /// typical drawing pressure, which made Charcoal/6B feel much smaller than Chalk or
    /// Pastel at the same size setting (device report, 2026-07-15). Dry media stay fat.
    private static func softPressureSize(min: Double) -> CurveOption {
        CurveOption(sensors: [SensorChannel(sensor: .pressure)], minValue: min,
                    commonCurve: ResponseCurve(points: [
                        ResponseCurve.Point(0, 0), ResponseCurve.Point(0.25, 0.62),
                        ResponseCurve.Point(0.5, 0.78), ResponseCurve.Point(0.75, 0.90),
                        ResponseCurve.Point(1, 1)]))
    }
    private static func pressureFlow(min: Double) -> CurveOption {
        CurveOption(sensors: [SensorChannel(sensor: .pressure)], minValue: min)
    }

    public static let all: [CuratedPreset] = [

        CuratedPreset(id: "pencil6b", displayName: "6B Pencil") { base in
            var b = base
            b.shapeID = "charcoal"
            b.grainID = "paper"
            b.grainDepth = 0.35
            b.grainScale = 0.8
            b.tipLightness = 0.3
            b.flow = 0.75
            b.hardness = 0.6
            b.spacing = 0.12
            b.pressureSmoothing = 0.3
            b.dynamics = BrushDynamics(size: softPressureSize(min: 0.35), flow: pressureFlow(min: 0.4),
                                       // The signature 6B move: pressing harder darkens
                                       // the graphite, not just widens it (cap: never
                                       // darker than 60% of the ink).
                                       darkness: CurveOption(sensors: [SensorChannel(sensor: .pressure)], maxValue: 0.4))
            return b
        },

        CuratedPreset(id: "inkpen", displayName: "Ink Pen") { base in
            var b = base
            b.hardness = 0.9
            b.flow = 1.0
            b.spacing = 0.08
            b.streamline = 0.4
            b.stabilization = 0.35
            b.taper = 0.25
            b.dynamics = BrushDynamics(size: pressureSize(min: 0.3))
            return b
        },

        CuratedPreset(id: "calligraphy", displayName: "Calligraphy") { base in
            var b = base
            b.aspectRatio = 0.22
            b.hardness = 0.8
            b.flow = 1.0
            b.spacing = 0.05
            b.streamline = 0.3
            // Fixed 45° nib via the STATIC tip angle. (The first cut used a no-sensor
            // rotationLike CurveOption assuming it folds to its strength — it folds to 0,
            // so the nib sat horizontal. Caught on device 2026-07-15.)
            b.tipAngle = .pi / 4
            return b
        },

        CuratedPreset(id: "chalk", displayName: "Chalk") { base in
            var b = base
            b.shapeID = "chalk"
            b.grainID = "paper"
            b.grainDepth = 0.6
            b.tipLightness = 0.5
            b.flow = 0.85
            b.spacing = 0.15
            b.spacingJitter = 0.3
            b.dynamics = BrushDynamics(flow: pressureFlow(min: 0.35))
            return b
        },

        CuratedPreset(id: "charcoal", displayName: "Charcoal") { base in
            var b = base
            b.shapeID = "charcoal"
            b.grainID = "paper"
            b.grainDepth = 0.5
            b.tipLightness = 0.6
            b.flow = 0.8
            b.spacing = 0.15
            b.dynamics = BrushDynamics(size: softPressureSize(min: 0.5), flow: pressureFlow(min: 0.4))
            return b
        },

        CuratedPreset(id: "pastel", displayName: "Pastel") { base in
            var b = base
            b.shapeID = "pastel"
            b.grainID = "speckle"
            b.grainDepth = 0.5
            b.tipLightness = 0.5
            b.flow = 0.9
            b.spacing = 0.14
            b.dynamics = BrushDynamics(
                flow: pressureFlow(min: 0.45),
                colorJitter: ColorJitter(hue: 0.015, saturation: 0.08, brightness: 0.06),
                // Per-dab sparkle (P6): brightness-led, hue barely moves — value texture
                // survives img2img; hue speckle would average out.
                dabColorJitter: ColorJitter(hue: 0.008, saturation: 0.06, brightness: 0.1))
            return b
        },

        CuratedPreset(id: "drybrush", displayName: "Dry Brush") { base in
            var b = base
            b.shapeID = "drybrush"
            b.grainID = "canvasWeave"
            b.grainDepth = 0.4
            b.flow = 0.8
            b.spacing = 0.1
            b.dynamics = BrushDynamics(
                ratio: CurveOption(sensors: [SensorChannel(sensor: .pressure)], minValue: 0.55))
            return b
        },

        CuratedPreset(id: "airbrush", displayName: "Airbrush") { base in
            var b = base
            b.hardness = 0.0
            b.flow = 0.25
            b.spacing = 0.08
            b.dynamics = BrushDynamics(size: pressureSize(min: 0.6), flow: pressureFlow(min: 0.2))
            return b
        },

        CuratedPreset(id: "spraypaint", displayName: "Spray Paint") { base in
            var b = base
            b.shapeID = "ink"
            b.flow = 0.6
            b.spacing = 0.5
            b.spacingJitter = 0.5
            b.stampCount = 3
            b.stampCountJitter = 0.4
            b.dynamics = BrushDynamics(scatter: CurveOption(sensors: [], strength: 0.6))
            return b
        },

        CuratedPreset(id: "marker", displayName: "Marker") { base in
            var b = base
            b.hardness = 0.75
            b.flow = 1.0
            b.opacity = 0.7   // Glaze ceiling: self-crossings stay flat, marker-style
            b.spacing = 0.08
            b.fallOff = 0.12  // gentle dry-out on very long strokes
            return b
        },
    ]

    public static func preset(for id: String) -> CuratedPreset? {
        all.first { $0.id == id }
    }
}

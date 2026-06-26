import CoreGraphics

// MARK: - Brush presets (Krita-grade dynamics, curated)
//
// A small curated set of brushes that exercise the sensor+curve engine
// (`BrushDynamics.swift`) — the "curated preset library, not an on-device Brush Studio"
// posture from `feedback_ipad_dev_toggles`. Each preset is the keystone made tangible:
// pressure/speed/tilt/angle driving size/flow/rotation through response curves.
//
// A preset preserves the user's active color + baseWidth + opacity; it only sets the
// dynamics + tip-shape parameters. The dynamics math for each was verified offline
// (OfflineTests + a preset prototype harness) before authoring here.
//
// Tuning note (for Donald): the exact curve points / min-max below are sensible starting
// values — the *feel* is best dialed in on device. Per `feedback_direct_params`, these are
// concrete values, not abstracted sliders.

/// One curated brush preset: a dynamics bundle + tip parameters, applied onto the user's
/// current brush.
public struct BrushPreset: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let dynamics: BrushDynamics
    public let hardness: CGFloat
    public let spacing: CGFloat
    public let shapeID: String?

    public init(id: String, name: String, dynamics: BrushDynamics,
                hardness: CGFloat = 0.5, spacing: CGFloat = 0.3, shapeID: String? = nil) {
        self.id = id
        self.name = name
        self.dynamics = dynamics
        self.hardness = hardness
        self.spacing = spacing
        self.shapeID = shapeID
    }

    /// Apply this preset onto a base brush, preserving color / baseWidth / opacity / flow.
    public func applied(to base: BrushConfig) -> BrushConfig {
        var c = base
        c.dynamics = dynamics
        c.hardness = hardness
        c.spacing = spacing
        c.shapeID = shapeID
        return c
    }
}

public enum BrushPresetCatalog {

    private static func curve(_ pts: [(Double, Double)]) -> ResponseCurve {
        ResponseCurve(points: pts.map { ResponseCurve.Point($0.0, $0.1) })
    }
    private static func sizeOpt(_ sensors: [SensorChannel], strength: Double = 1,
                                min: Double = 0, max: Double = 1, combine: CombineMode = .multiply,
                                useSameCurve: Bool = true, common: ResponseCurve = .identity) -> CurveOption {
        CurveOption(sensors: sensors, combineMode: combine, fold: .sizeLike, strength: strength,
                    minValue: min, maxValue: max, useSameCurve: useSameCurve, commonCurve: common)
    }

    /// Pressure inker — width and deposit both rise firmly with pressure (crisp edge, tight
    /// spacing). The classic "press harder = bolder" pen.
    public static let inker = BrushPreset(
        id: "inker", name: "Inker",
        dynamics: BrushDynamics(
            size: sizeOpt([SensorChannel(sensor: .pressure)], min: 0.15),
            flow: sizeOpt([SensorChannel(sensor: .pressure)], min: 0.4)),
        hardness: 0.85, spacing: 0.08)

    /// Soft sketching pencil — size follows pressure through a soft gamma(1.6) ramp (stays
    /// thin until you lean in), light deposit so build-up reads like graphite.
    public static let softPencil = BrushPreset(
        id: "soft_pencil", name: "Soft Pencil",
        dynamics: BrushDynamics(
            size: sizeOpt([SensorChannel(sensor: .pressure)], min: 0.1, common: .gamma(1.6)),
            flow: sizeOpt([SensorChannel(sensor: .pressure)], min: 0.25)),
        hardness: 0.4, spacing: 0.12)

    /// Speed-taper pencil — size = pressure × a descending speed curve, so fast strokes
    /// thin out (calligraphic taper-by-speed) while pressure still governs the body.
    /// `useSameCurve = false` so the speed channel uses its own descending curve while
    /// pressure stays linear (the Krita per-sensor-curve subtlety).
    public static let speedPencil = BrushPreset(
        id: "speed_pencil", name: "Speed Pencil",
        dynamics: BrushDynamics(
            size: sizeOpt(
                [SensorChannel(sensor: .pressure),
                 SensorChannel(sensor: .speed, curve: curve([(0, 1.0), (1, 0.4)]))],
                min: 0.1, combine: .multiply, useSameCurve: false),
            flow: sizeOpt([SensorChannel(sensor: .pressure)], min: 0.3)),
        hardness: 0.5, spacing: 0.1)

    /// Calligraphy nib — the dab rotates to follow the stroke heading (drawing-angle →
    /// rotation, the rotation-like fold), so an anisotropic/oriented tip cuts thick-and-thin
    /// edges. Pressure drives size. Visible only on oriented/anisotropic tips (uses the
    /// "ink" textured shape, which orients to the stroke).
    public static let calligraphy = BrushPreset(
        id: "calligraphy", name: "Calligraphy",
        dynamics: BrushDynamics(
            size: sizeOpt([SensorChannel(sensor: .pressure)], min: 0.25),
            rotation: CurveOption(sensors: [SensorChannel(sensor: .drawingAngle)],
                                  fold: .rotationLike, strength: 1)),
        hardness: 0.8, spacing: 0.06, shapeID: "ink")

    /// The ordered curated set, for a future preset picker UI.
    public static let all: [BrushPreset] = [inker, softPencil, speedPencil, calligraphy]
}

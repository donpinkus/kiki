import Foundation

// MARK: - Brush Dynamics — the sensor → curve → combine → remap machine
//
// This is the "keystone" from the Krita brush research
// (`documents/research/krita-brush/PLAN.md` §2.1, doc 02). It replaces our two
// hardcoded scalars (`pressureGamma`, `tiltSensitivity`) with Krita's one orthogonal
// abstraction: *any* input axis (a `BrushSensor`) runs through *its own* response curve,
// the per-sensor results combine by a selectable operator, and the combined value is
// folded into a final brush scalar by one of two folds (size-like or rotation-like).
//
// The math here mirrors Krita verbatim so the behavior is predictable and a future
// `.kpp`/`.brush` importer round-trips. Source of truth re-verified against
// `~/krita_src`:
//   - folds + combine:   plugins/paintops/libpaintop/KisCurveOption.cpp:61-163
//   - sensor parameter:  plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:35-51
//   - HSV fold split:    plugins/paintops/libpaintop/KisHSVOption.cpp:44-53
//
// Pure Swift (Foundation only, no UIKit/simd) so it compiles into the iOS target AND can
// be verified offline with a standalone `swift` harness (per `feedback_verify_shader_color_offline`).
//
// Everything defaults to identity: a `BrushConfig` with no `dynamics` (or an all-identity
// `BrushDynamics`) reproduces today's pen exactly. Adding a dynamic is provably
// non-regressive for existing brushes.

// MARK: Scalar helpers (mirror KisDynamicSensor / KisAlgebra2D)

@inline(__always) func b_lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// [0,1] → [-1,1]. Krita `KisDynamicSensor::scalingToAdditive`.
@inline(__always) func scalingToAdditive(_ x: Double) -> Double { -1.0 + 2.0 * x }
/// [-1,1] → [0,1]. Krita `KisDynamicSensor::additiveToScaling`.
@inline(__always) func additiveToScaling(_ x: Double) -> Double { 0.5 * (1.0 + x) }

/// Wrap `value` into the half-open range [min,max). Krita `KisAlgebra2D::wrapValue`.
/// Used by the rotation-like fold so hue/angle wrap instead of clamping.
@inline(__always) func wrapValue(_ value: Double, _ minV: Double, _ maxV: Double) -> Double {
    let range = maxV - minV
    guard range > 0 else { return minV }
    var v = value - minV
    v = v.truncatingRemainder(dividingBy: range)
    if v < 0 { v += range }
    return v + minV
}

// MARK: - ResponseCurve

/// A response curve: control points in the unit square fitted with a monotone cubic
/// (Fritsch–Carlson) Hermite spline and baked into a 256-entry LUT. Krita uses a natural
/// cubic spline (`libs/image/kis_cubic_curve.cpp`); monotone-cubic is chosen deliberately
/// to avoid the overshoot a natural spline can produce between widely-spaced points
/// (research doc 02 §6.5) — the spline *brand* is not load-bearing for behavior, only the
/// "author with a spline, evaluate with a flat LUT" shape is.
///
/// `pow(force, gamma)` — our entire legacy pressure response — is just one curve shape, so
/// the legacy scalars become identity-equivalent presets of this type.
public struct ResponseCurve: Codable, Equatable, Sendable {
    public struct Point: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    }

    /// Sorted-by-x control points, each in [0,1]². Default is the identity `(0,0)…(1,1)`.
    public var points: [Point]

    public init(points: [Point]) {
        self.points = points.sorted { $0.x < $1.x }
    }

    /// The identity curve — a pass-through. Detected so it can skip the LUT entirely
    /// (Krita drops identity curves to `nullopt`, `KisDynamicSensor.cpp:21-23`).
    public static let identity = ResponseCurve(points: [Point(0, 0), Point(1, 1)])

    /// A `pow(x, gamma)` curve sampled at `samples` control points — the bridge that turns
    /// our legacy `pressureGamma` into a curve preset.
    public static func gamma(_ gamma: Double, samples: Int = 9) -> ResponseCurve {
        guard gamma != 1.0 else { return .identity }
        let n = max(2, samples)
        var pts: [Point] = []
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            pts.append(Point(x, pow(x, gamma)))
        }
        return ResponseCurve(points: pts)
    }

    /// True when this curve is the literal identity line, so callers can skip evaluation.
    public var isIdentity: Bool {
        points.count == 2 &&
        points[0].x == 0 && points[0].y == 0 &&
        points[1].x == 1 && points[1].y == 1
    }

    // The baked LUT is computed lazily and cached. Not part of Codable (derived).
    private var _lut: [Double]? = nil

    private enum CodingKeys: String, CodingKey { case points }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.points = try c.decode([Point].self, forKey: .points).sorted { $0.x < $1.x }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
    }

    public static func == (lhs: ResponseCurve, rhs: ResponseCurve) -> Bool { lhs.points == rhs.points }

    /// Evaluate the curve at `x ∈ [0,1]`. Identity short-circuits to `x`. Otherwise a
    /// clamp + floor + lerp on the baked LUT (Krita `interpolateLinear`).
    public mutating func value(_ x: Double) -> Double {
        if isIdentity { return min(1, max(0, x)) }
        if _lut == nil { _lut = Self.bakeLUT(points) }
        return Self.readLUT(_lut!, x)
    }

    /// Non-mutating evaluation (bakes a throwaway LUT). Prefer the mutating form on a hot path.
    public func valued(_ x: Double) -> Double {
        if isIdentity { return min(1, max(0, x)) }
        return Self.readLUT(Self.bakeLUT(points), x)
    }

    static let lutSize = 256

    static func readLUT(_ lut: [Double], _ x: Double) -> Double {
        let n = lut.count
        let pos = min(Double(n - 1), max(0, x * Double(n - 1)))
        let i = Int(pos.rounded(.down))
        if i >= n - 1 { return lut[n - 1] }
        let t = pos - Double(i)
        return b_lerp(lut[i], lut[i + 1], t)
    }

    /// Bake control points → 256-entry LUT via a monotone cubic Hermite spline.
    static func bakeLUT(_ pts: [Point]) -> [Double] {
        let n = lutSize
        var lut = [Double](repeating: 0, count: n)
        let cps = pts.count >= 2 ? pts : [Point(0, 0), Point(1, 1)]
        // Fritsch–Carlson monotone tangents.
        let k = cps.count
        var slope = [Double](repeating: 0, count: max(1, k - 1))
        for i in 0..<(k - 1) {
            let dx = cps[i + 1].x - cps[i].x
            slope[i] = dx != 0 ? (cps[i + 1].y - cps[i].y) / dx : 0
        }
        var m = [Double](repeating: 0, count: k)
        m[0] = slope[0]
        m[k - 1] = slope[k - 2]
        for i in 1..<(k - 1) {
            if slope[i - 1] * slope[i] <= 0 {
                m[i] = 0
            } else {
                m[i] = (slope[i - 1] + slope[i]) / 2
            }
        }
        // Enforce monotonicity (Fritsch–Carlson).
        for i in 0..<(k - 1) where slope[i] != 0 {
            let a = m[i] / slope[i]
            let b = m[i + 1] / slope[i]
            let h = a * a + b * b
            if h > 9 {
                let tau = 3.0 / h.squareRoot()
                m[i] = tau * a * slope[i]
                m[i + 1] = tau * b * slope[i]
            }
        }
        for j in 0..<n {
            let x = Double(j) / Double(n - 1)
            lut[j] = min(1, max(0, evalHermite(cps, m, x)))
        }
        return lut
    }

    private static func evalHermite(_ cps: [Point], _ m: [Double], _ x: Double) -> Double {
        if x <= cps.first!.x { return cps.first!.y }
        if x >= cps.last!.x { return cps.last!.y }
        var i = 0
        while i < cps.count - 1 && x > cps[i + 1].x { i += 1 }
        let x0 = cps[i].x, x1 = cps[i + 1].x
        let y0 = cps[i].y, y1 = cps[i + 1].y
        let h = x1 - x0
        guard h > 0 else { return y0 }
        let t = (x - x0) / h
        let t2 = t * t, t3 = t2 * t
        let h00 = 2 * t3 - 3 * t2 + 1
        let h10 = t3 - 2 * t2 + t
        let h01 = -2 * t3 + 3 * t2
        let h11 = t3 - t2
        return h00 * y0 + h10 * h * m[i] + h01 * y1 + h11 * h * m[i + 1]
    }
}

// MARK: - Sensors

/// One input axis. Mirrors Krita's `KisDynamicSensor` set (research doc 02 §1.2). Each
/// sensor reads exactly one axis of the per-dab `SensorInput` and normalizes it.
public enum BrushSensor: String, Codable, CaseIterable, Sendable {
    case pressure          // info.pressure() — already [0,1]
    case speed             // normalized drawing speed
    case tiltElevation     // tilt amount (0 = perpendicular … 1 = flat)
    case tiltDirection     // azimuth — ADDITIVE
    case drawingAngle      // stroke heading — ABSOLUTE rotation
    case distance          // length along the stroke, normalized by a period
    case fade              // dab count, normalized by a period
    case fuzzyPerDab       // per-dab random — ADDITIVE
    case fuzzyPerStroke    // one random draw per stroke — ADDITIVE

    /// Additive sensors sum into the additive bucket (Krita `isAdditive()`).
    public var isAdditive: Bool {
        switch self {
        case .tiltDirection, .fuzzyPerDab, .fuzzyPerStroke: return true
        default: return false
        }
    }

    /// Absolute-rotation sensors overwrite the absolute offset (Krita `isAbsoluteRotation()`).
    public var isAbsoluteRotation: Bool { self == .drawingAngle }

    /// The raw, pre-curve normalized value for this sensor. Scaling sensors → [0,1];
    /// additive sensors → [-1,1] (Krita's `value(info)` convention).
    func rawValue(_ input: SensorInput) -> Double {
        switch self {
        case .pressure:       return clamp01(input.pressure)
        case .speed:          return clamp01(input.speedNorm)
        case .tiltElevation:  return clamp01(input.tiltElevationNorm)
        case .tiltDirection:  return scalingToAdditive(clamp01(input.azimuthNorm)) // [0,1]→[-1,1] additive
        case .drawingAngle:   return clamp01(input.drawingAngleNorm)               // absolute
        case .distance:       return clamp01(input.distanceNorm)
        case .fade:           return clamp01(input.fadeNorm)
        case .fuzzyPerDab:    return 2.0 * input.randPerDab - 1.0                  // [-1,1] additive
        case .fuzzyPerStroke: return 2.0 * input.randPerStroke - 1.0              // [-1,1] additive
        }
    }
}

@inline(__always) func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

/// One sensor paired with its response curve (Krita's per-sensor curve, used when
/// `useSameCurve == false`; otherwise the option's common curve is shared).
public struct SensorChannel: Codable, Equatable, Sendable {
    public var sensor: BrushSensor
    public var curve: ResponseCurve
    public init(sensor: BrushSensor, curve: ResponseCurve = .identity) {
        self.sensor = sensor
        self.curve = curve
    }

    /// Krita `KisDynamicSensor::parameter` — fold additive/absolute into [0,1], run the
    /// curve, unfold. Returns the post-curve sensor value in the sensor's native domain.
    func parameter(_ input: SensorInput, common: ResponseCurve?, useSameCurve: Bool) -> Double {
        let raw = sensor.rawValue(input)
        var c = (useSameCurve ? (common ?? curve) : curve)
        if c.isIdentity { return raw }
        if sensor.isAdditive {
            let scaled = c.value(additiveToScaling(raw)) // [-1,1]→[0,1]→curve
            return scalingToAdditive(scaled)             // →[-1,1]
        } else if sensor.isAbsoluteRotation {
            let scaled = c.value(wrapValue(raw + 0.5, 0, 1))
            return wrapValue(scaled + 0.5, 0, 1)
        } else {
            return c.value(raw)
        }
    }
}

// MARK: - CurveOption

public enum CombineMode: Int, Codable, Sendable {
    case multiply = 0, add = 1, max = 2, min = 3, difference = 4
}

/// Which final fold turns the combined sensor components into a brush scalar.
/// `sizeLike` (size/opacity/flow/spacing/ratio) clamps; `rotationLike` (rotation/hue) wraps.
public enum BrushFold: Int, Codable, Sendable { case sizeLike = 0, rotationLike = 1 }

/// A single tunable brush parameter driven by sensors. Mirrors `KisCurveOption`.
public struct CurveOption: Codable, Equatable, Sendable {
    public var sensors: [SensorChannel]
    public var combineMode: CombineMode
    public var fold: BrushFold
    /// The option's headline strength (Krita's `constant`).
    public var strength: Double
    /// Output remap floor/ceiling (Krita's `strengthMinValue`/`strengthMaxValue`).
    public var minValue: Double
    public var maxValue: Double
    public var useCurve: Bool
    public var useSameCurve: Bool
    /// The shared curve used when `useSameCurve` (Krita's `commonCurve`).
    public var commonCurve: ResponseCurve

    public init(
        sensors: [SensorChannel],
        combineMode: CombineMode = .multiply,
        fold: BrushFold = .sizeLike,
        strength: Double = 1.0,
        minValue: Double = 0.0,
        maxValue: Double = 1.0,
        useCurve: Bool = true,
        useSameCurve: Bool = true,
        commonCurve: ResponseCurve = .identity
    ) {
        self.sensors = sensors
        self.combineMode = combineMode
        self.fold = fold
        self.strength = strength
        self.minValue = minValue
        self.maxValue = maxValue
        self.useCurve = useCurve
        self.useSameCurve = useSameCurve
        self.commonCurve = commonCurve
    }

    struct Components {
        var scaling: Double = 1
        var additive: Double = 0
        var absoluteOffset: Double = 0
        var constant: Double = 1
        var hasScaling = false
        var hasAdditive = false
        var hasAbsoluteOffset = false
        var minSizeLike: Double = 0
        var maxSizeLike: Double = 1
    }

    /// Krita `KisCurveOption::computeValueComponents` — bucket sensors and combine the
    /// scaling bucket by `combineMode`.
    func computeComponents(_ input: SensorInput, useStrength: Bool = true) -> Components {
        var comp = Components()
        if useCurve {
            var scalingValues: [Double] = []
            for ch in sensors {
                let v = ch.parameter(input, common: commonCurve, useSameCurve: useSameCurve)
                if ch.sensor.isAdditive {
                    comp.additive += v; comp.hasAdditive = true
                } else if ch.sensor.isAbsoluteRotation {
                    comp.absoluteOffset = v; comp.hasAbsoluteOffset = true
                } else {
                    scalingValues.append(v); comp.hasScaling = true
                }
            }
            if scalingValues.count == 1 {
                comp.scaling = scalingValues[0]
            } else if scalingValues.count > 1 {
                switch combineMode {
                case .add:        comp.scaling = scalingValues.reduce(0, +)
                case .max:        comp.scaling = scalingValues.max() ?? 1
                case .min:        comp.scaling = scalingValues.min() ?? 1
                case .difference: comp.scaling = (scalingValues.max() ?? 0) - (scalingValues.min() ?? 0)
                case .multiply:   comp.scaling = scalingValues.reduce(1, *)
                }
            }
        }
        if useStrength { comp.constant = strength }
        comp.minSizeLike = minValue
        comp.maxSizeLike = maxValue
        return comp
    }

    /// Krita `ValueComponents::sizeLikeValue` — clamp(min, constant·offset·scaling·additive, max).
    public func sizeLikeValue(_ input: SensorInput) -> Double {
        let c = computeComponents(input)
        let offset = c.hasAbsoluteOffset ? c.absoluteOffset : 1.0
        let scalingPart = c.hasScaling ? c.scaling : 1.0
        let additivePart = c.hasAdditive ? additiveToScaling(c.additive) : 1.0
        let raw = c.constant * offset * scalingPart * additivePart
        return Swift.min(c.maxSizeLike, Swift.max(c.minSizeLike, raw))
    }

    /// Krita `ValueComponents::rotationLikeValue` — wrap(2·offset + constant·(coeff·toAdditive(scaling) + additive)).
    public func rotationLikeValue(
        _ input: SensorInput,
        normalizedBaseAngle: Double = 0,
        absoluteAxesFlipped: Bool = false,
        scalingPartCoeff: Double = 1.0,
        disableScalingPart: Bool = false
    ) -> Double {
        let c = computeComponents(input)
        let offset = !c.hasAbsoluteOffset
            ? normalizedBaseAngle
            : (absoluteAxesFlipped ? 0.5 - c.absoluteOffset : c.absoluteOffset)
        let realScalingPart = (c.hasScaling && !disableScalingPart) ? scalingToAdditive(c.scaling) : 0.0
        let realAdditivePart = c.hasAdditive ? c.additive : 0.0
        return wrapValue(2 * offset + c.constant * (scalingPartCoeff * realScalingPart + realAdditivePart), -1, 1)
    }

    /// Evaluate to the value the brush consumes, routed by `fold`.
    public func value(_ input: SensorInput) -> Double {
        switch fold {
        case .sizeLike:     return sizeLikeValue(input)
        case .rotationLike: return rotationLikeValue(input)
        }
    }
}

// MARK: - SensorInput + StrokeDynamicsState

/// The per-dab bundle of normalized axes a `CurveOption` reads. Built by
/// `StrokeDynamicsState` as the stroke is resampled.
public struct SensorInput: Sendable {
    public var pressure: Double          // [0,1]
    public var tiltElevationNorm: Double // [0,1] — 0 perpendicular … 1 fully tilted
    public var azimuthNorm: Double       // [0,1] — tilt direction / (2π)
    public var drawingAngleNorm: Double  // [0,1] — stroke heading 0.5 + angle/2π
    public var speedNorm: Double         // [0,1]
    public var distanceNorm: Double      // [0,1]
    public var fadeNorm: Double          // [0,1]
    public var randPerDab: Double        // [0,1)
    public var randPerStroke: Double     // [0,1)

    public init(
        pressure: Double = 1,
        tiltElevationNorm: Double = 0,
        azimuthNorm: Double = 0,
        drawingAngleNorm: Double = 0,
        speedNorm: Double = 0,
        distanceNorm: Double = 0,
        fadeNorm: Double = 0,
        randPerDab: Double = 0,
        randPerStroke: Double = 0
    ) {
        self.pressure = pressure
        self.tiltElevationNorm = tiltElevationNorm
        self.azimuthNorm = azimuthNorm
        self.drawingAngleNorm = drawingAngleNorm
        self.speedNorm = speedNorm
        self.distanceNorm = distanceNorm
        self.fadeNorm = fadeNorm
        self.randPerDab = randPerDab
        self.randPerStroke = randPerStroke
    }
}

/// Stateless splitmix64-style hash for deterministic, lock-free per-dab/per-stroke
/// randomness — the research's chosen replacement for Krita's stateful taus88 +
/// mutex'd per-stroke `QHash` (doc 06 §3). `hash(seed, index, channel)` → [0,1).
@inline(__always) public func brushHash01(_ seed: UInt64, _ index: UInt64, _ channel: UInt64) -> Double {
    var z = seed &+ index &* 0x9E37_79B9_7F4A_7C15 &+ channel &* 0xD1B5_4A32_D192_ED03
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    z = z ^ (z >> 31)
    return Double(z >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
}

/// Accumulates the running stroke quantities the state-dependent sensors need
/// (arc length, dab index, smoothed speed, heading), and builds a `SensorInput` per dab.
/// Threaded through the resample loop. Krita threads the equivalent via
/// `KisDistanceInformation`.
public struct StrokeDynamicsState {
    public var seed: UInt64
    /// Period (in points) over which Distance/Fade sensors ramp 0→1, then optionally repeat.
    public var distancePeriod: Double
    public var fadePeriod: Double
    /// Max speed (points/second) that maps to speedNorm = 1. Tunable; Krita normalizes in
    /// its tool layer (research §2.2 — unverified constant, tune on device).
    public var maxSpeed: Double

    public private(set) var arcLength: Double = 0
    public private(set) var dabIndex: UInt64 = 0
    private var lastX: Double?
    private var lastY: Double?
    private var smoothedSpeed: Double = 0
    private let perStrokeRand: Double

    public init(seed: UInt64, distancePeriod: Double = 256, fadePeriod: Double = 64, maxSpeed: Double = 3000) {
        self.seed = seed
        self.distancePeriod = distancePeriod
        self.fadePeriod = fadePeriod
        self.maxSpeed = maxSpeed
        self.perStrokeRand = brushHash01(seed, 0, 0xF17E)
    }

    /// Advance state for a dab at `(x,y)` with `force`, `altitude` (radians; 0 flat … π/2
    /// perpendicular), `azimuth` (radians), instantaneous heading `dx,dy`, and `dt`
    /// seconds since the previous point; returns the `SensorInput` for this dab.
    public mutating func advance(
        x: Double, y: Double, force: Double, altitude: Double, azimuth: Double,
        dx: Double, dy: Double, dt: Double
    ) -> SensorInput {
        if let lx = lastX, let ly = lastY {
            arcLength += hypotD(x - lx, y - ly)
        }
        lastX = x; lastY = y

        // Speed: instantaneous distance/time, EMA-smoothed, normalized by maxSpeed.
        if dt > 0 {
            let inst = hypotD(dx, dy) / dt
            smoothedSpeed = 0.4 * inst + 0.6 * smoothedSpeed
        }
        let speedNorm = clamp01(smoothedSpeed / maxSpeed)

        // Tilt elevation: altitude π/2 (perpendicular) → 0, 0 (flat) → 1.
        let elevation = clamp01(1.0 - altitude / (Double.pi / 2))
        // Azimuth → [0,1).
        let azNorm = wrapValue(azimuth / (2 * Double.pi), 0, 1)
        // Heading → [0,1): 0.5 + angle/2π (Krita DrawingAngle).
        let heading = (dx == 0 && dy == 0) ? 0.5 : wrapValue(0.5 + atan2(dy, dx) / (2 * Double.pi), 0, 1)

        let distNorm = distancePeriod > 0 ? wrapValue(arcLength / distancePeriod, 0, 1) : 0
        let fadeNorm = fadePeriod > 0 ? clamp01(Double(dabIndex) / fadePeriod) : 0
        let randPerDab = brushHash01(seed, dabIndex &+ 1, 0xDAB)

        let input = SensorInput(
            pressure: clamp01(force),
            tiltElevationNorm: elevation,
            azimuthNorm: azNorm,
            drawingAngleNorm: heading,
            speedNorm: speedNorm,
            distanceNorm: distNorm,
            fadeNorm: fadeNorm,
            randPerDab: randPerDab,
            randPerStroke: perStrokeRand
        )
        dabIndex += 1
        return input
    }
}

@inline(__always) func hypotD(_ a: Double, _ b: Double) -> Double { (a * a + b * b).squareRoot() }

// MARK: - BrushDynamics (the per-brush collection of curve options)

/// The dynamics for one brush: a `CurveOption` per parameter. All optional; a nil option
/// means "no dynamics for this parameter" → the legacy scalar / constant is used, so an
/// empty `BrushDynamics` reproduces today's pen exactly.
///
/// Codable and fully backward-compatible (every field `decodeIfPresent`). This is the
/// additive seed of the eventual `BrushDescriptor` (`unified-brush-engine.md` §2.1); it is
/// introduced alongside the flat `BrushConfig` rather than replacing it, so the migration
/// stays incremental.
public struct BrushDynamics: Codable, Equatable, Sendable {
    /// Size multiplier (applied to `baseWidth`). Size-like fold.
    public var size: CurveOption?
    /// Per-stroke opacity ceiling multiplier. Size-like fold.
    public var opacity: CurveOption?
    /// Per-dab flow multiplier. Size-like fold.
    public var flow: CurveOption?
    /// Dab rotation (turns, [-1,1] → ±π). Rotation-like fold.
    public var rotation: CurveOption?

    public init(size: CurveOption? = nil, opacity: CurveOption? = nil, flow: CurveOption? = nil, rotation: CurveOption? = nil) {
        self.size = size
        self.opacity = opacity
        self.flow = flow
        self.rotation = rotation
    }

    /// True if no parameter has a non-identity dynamic — the legacy path can run unchanged.
    public var isInert: Bool {
        size == nil && opacity == nil && flow == nil && rotation == nil
    }

    enum CodingKeys: String, CodingKey { case size, opacity, flow, rotation }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(CurveOption.self, forKey: .size)
        opacity = try c.decodeIfPresent(CurveOption.self, forKey: .opacity)
        flow = try c.decodeIfPresent(CurveOption.self, forKey: .flow)
        rotation = try c.decodeIfPresent(CurveOption.self, forKey: .rotation)
    }
}

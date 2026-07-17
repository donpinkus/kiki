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
// The fold/combine/sensor-folding MATH mirrors Krita exactly (verified line-by-line, P1
// review) so behavior is predictable and a future `.kpp`/`.brush` importer round-trips.
// Source of truth re-verified against `~/krita_src`:
//   - folds + combine:   plugins/paintops/libpaintop/KisCurveOption.cpp:61-163
//   - sensor parameter:  plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:35-51
//   - HSV fold split:    plugins/paintops/libpaintop/KisHSVOption.cpp:44-53
//
// DELIBERATE divergences (sound, not bugs): (1) monotone-cubic (Fritsch–Carlson) LUT instead
// of Krita's natural cubic — no overshoot; (2) stateless-hash RNG instead of taus88 —
// lock-free + replay-deterministic. INPUT-DOMAIN substitutions (iOS gives different raw
// axes than Krita's tablet layer): tiltElevation is derived from `UITouch.altitudeAngle`
// (not Krita's xTilt/yTilt `acos`); the speed `maxSpeed` scale is a tunable, not Krita's
// tool-layer constant. SIMPLIFICATIONS: Distance is periodic-only and Fade is clamp-only
// (Krita's per-sensor `isPeriodic` flag is collapsed to one mode each).
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

    /// Sorted-by-x control points, each in [0,1]². **Immutable** (`let`) so the baked LUT can
    /// never go stale relative to the points. Default is the identity `(0,0)…(1,1)`.
    public let points: [Point]

    /// Baked 256-entry LUT, computed **once** at init/decode (nil for the identity curve,
    /// which passes through). Because the bake is eager and `points` is immutable, `value()`
    /// is a pure read and copies of this struct share the LUT via copy-on-write — so
    /// evaluating a curve on the per-dab hot path does **ZERO** spline bakes. (The previous
    /// lazy/mutating cache was structurally unreachable: callers copy the struct by value, so
    /// the cache was written to a throwaway and re-baked every dab. Fixed per P1 review.)
    private let lut: [Double]?

    /// True when this is the literal identity line, so callers skip evaluation entirely
    /// (Krita drops identity curves to `nullopt`, `KisDynamicSensor.cpp:21-23`).
    public let isIdentity: Bool

    public init(points: [Point]) {
        let sorted = points.sorted { $0.x < $1.x }
        self.points = sorted
        let ident = sorted.count == 2
            && sorted[0].x == 0 && sorted[0].y == 0
            && sorted[1].x == 1 && sorted[1].y == 1
        self.isIdentity = ident
        self.lut = ident ? nil : Self.bakeLUT(sorted)
    }

    /// The identity curve — a pass-through.
    public static let identity = ResponseCurve(points: [Point(0, 0), Point(1, 1)])

    /// A `pow(x, gamma)` curve sampled at `samples` control points — the bridge that turns
    /// our legacy `pressureGamma` into a curve preset. Precondition `gamma > 0`
    /// (`pow(0, gamma<0)` = +Inf); a non-positive gamma falls back to identity.
    public static func gamma(_ gamma: Double, samples: Int = 9) -> ResponseCurve {
        guard gamma > 0, gamma != 1.0 else { return .identity }
        let n = max(2, samples)
        var pts: [Point] = []
        for i in 0..<n {
            let x = Double(i) / Double(n - 1)
            pts.append(Point(x, pow(x, gamma)))
        }
        return ResponseCurve(points: pts)
    }

    /// Evaluate at `x ∈ [0,1]` — a pure LUT read (identity passes through). Non-mutating: the
    /// LUT was baked at construction, so there is no per-call/per-dab spline solve.
    public func value(_ x: Double) -> Double {
        guard let lut else { return min(1, max(0, x)) }
        return Self.readLUT(lut, x)
    }

    // Codable: only `points` is stored; the LUT + isIdentity are recomputed on decode via
    // the designated initializer.
    private enum CodingKeys: String, CodingKey { case points }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(points: try c.decode([Point].self, forKey: .points))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(points, forKey: .points)
    }

    public static func == (lhs: ResponseCurve, rhs: ResponseCurve) -> Bool { lhs.points == rhs.points }

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
    // Append-only (rawValues live in saved brush JSON). Added 2026-07-15:
    case barrelRotation    // Apple Pencil Pro roll angle — ADDITIVE (like tiltDirection)

    /// Additive sensors sum into the additive bucket (Krita `isAdditive()`).
    public var isAdditive: Bool {
        switch self {
        case .tiltDirection, .fuzzyPerDab, .fuzzyPerStroke, .barrelRotation: return true
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
        case .barrelRotation: return scalingToAdditive(clamp01(input.rollNorm))    // Pencil Pro roll, additive
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
        let c = (useSameCurve ? (common ?? curve) : curve) // value-type; no copy cost, LUT shared (COW)
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
    /// scaling bucket by `combineMode`. Alloc-free: running aggregates (product/sum/max/min)
    /// are tracked inline so the per-dab hot path makes no heap allocation (P2-review micro-opt);
    /// behavior is identical to the prior array-based version (verified by the offline suite,
    /// which exercises all five combine modes).
    func computeComponents(_ input: SensorInput, useStrength: Bool = true) -> Components {
        var comp = Components()
        if useCurve {
            var prod = 1.0, sum = 0.0, mx = -Double.greatestFiniteMagnitude, mn = Double.greatestFiniteMagnitude
            var n = 0
            for ch in sensors {
                let v = ch.parameter(input, common: commonCurve, useSameCurve: useSameCurve)
                if ch.sensor.isAdditive {
                    comp.additive += v; comp.hasAdditive = true
                } else if ch.sensor.isAbsoluteRotation {
                    comp.absoluteOffset = v; comp.hasAbsoluteOffset = true
                } else {
                    n += 1; comp.hasScaling = true
                    prod *= v; sum += v
                    if v > mx { mx = v }
                    if v < mn { mn = v }
                }
            }
            if n == 1 {
                comp.scaling = sum // a single value: sum == prod == that value
            } else if n > 1 {
                switch combineMode {
                case .add:        comp.scaling = sum
                case .max:        comp.scaling = mx
                case .min:        comp.scaling = mn
                case .difference: comp.scaling = mx - mn
                case .multiply:   comp.scaling = prod
                }
            }
            // n == 0 → no scaling sensors → comp.scaling stays its default 1.0 (as before).
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
    public var rollNorm: Double          // [0,1] — Pencil Pro barrel roll / (2π); 0 when absent
    public var drawingAngleNorm: Double  // [0,1] — stroke heading 0.5 + angle/2π
    public var speedNorm: Double         // [0,1]
    public var distanceNorm: Double      // [0,1]
    public var fadeNorm: Double          // [0,1]
    public var randPerDab: Double        // [0,1)
    public var randPerStroke: Double     // [0,1)
    public var randScatterX: Double      // [0,1) — independent per-dab draw for scatter X
    public var randScatterY: Double      // [0,1) — independent per-dab draw for scatter Y
    public var randScatterLat: Double    // [0,1) — independent per-dab draw, lateral (⊥ stroke) jitter
    public var randScatterLin: Double    // [0,1) — independent per-dab draw, linear (∥ stroke) jitter

    public init(
        pressure: Double = 1,
        tiltElevationNorm: Double = 0,
        azimuthNorm: Double = 0,
        rollNorm: Double = 0,
        drawingAngleNorm: Double = 0,
        speedNorm: Double = 0,
        distanceNorm: Double = 0,
        fadeNorm: Double = 0,
        randPerDab: Double = 0,
        randPerStroke: Double = 0,
        randScatterX: Double = 0.5,
        randScatterY: Double = 0.5,
        randScatterLat: Double = 0.5,
        randScatterLin: Double = 0.5
    ) {
        self.pressure = pressure
        self.tiltElevationNorm = tiltElevationNorm
        self.azimuthNorm = azimuthNorm
        self.rollNorm = rollNorm
        self.drawingAngleNorm = drawingAngleNorm
        self.speedNorm = speedNorm
        self.distanceNorm = distanceNorm
        self.fadeNorm = fadeNorm
        self.randPerDab = randPerDab
        self.randPerStroke = randPerStroke
        self.randScatterX = randScatterX
        self.randScatterY = randScatterY
        self.randScatterLat = randScatterLat
        self.randScatterLin = randScatterLin
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
    /// Max speed (points/second) that maps to speedNorm = 1. Tuned on device (2026-06-27):
    /// 3000 was too high — normal-fast strokes only reached ~0.3–0.5, so the Speed sensor barely
    /// registered. 1500 makes a moderately-fast stroke hit full effect. Krita normalizes in its
    /// tool layer (research §2.2). Raise if every stroke reads thin; lower if speed barely bites.
    public var maxSpeed: Double

    public private(set) var arcLength: Double = 0
    public private(set) var dabIndex: UInt64 = 0
    private var lastX: Double?
    private var lastY: Double?
    private var smoothedSpeed: Double = 0
    private let perStrokeRand: Double

    public init(seed: UInt64, distancePeriod: Double = 256, fadePeriod: Double = 64, maxSpeed: Double = 1500) {
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
        dx: Double, dy: Double, dt: Double, roll: Double = 0
    ) -> SensorInput {
        if let lx = lastX, let ly = lastY {
            arcLength += hypotD(x - lx, y - ly)
        }
        lastX = x; lastY = y

        // Speed: instantaneous distance/time, smoothed, normalized by maxSpeed. The EMA is
        // TIME-CONSTANT (alpha derived from dt), not fixed-weight, so the smoothed speed is
        // independent of dab DENSITY — a dense stroke and a sparse one over the same path and
        // time converge identically. (A fixed `0.4·inst + 0.6·prev` per dab would converge
        // faster the more dabs/sec, making speed response depend on spacing. P1-review fix.)
        if dt > 0 {
            let inst = hypotD(dx, dy) / dt
            let tau = 0.05 // seconds — speed smoothing time constant
            let alpha = 1 - exp(-dt / tau)
            smoothedSpeed += (inst - smoothedSpeed) * alpha
        }
        let speedNorm = clamp01(smoothedSpeed / maxSpeed)

        // Tilt elevation, matching Krita's TiltElevation convention: perpendicular stylus
        // (altitude π/2) → 1, flat (altitude 0) → 0. (Krita derives this from xTilt/yTilt via
        // acos; iOS gives `altitude` directly. The legacy `tiltSensitivity` widening in
        // BrushConfig.effectiveWidth uses the opposite "tilt amount" sense and is unchanged.)
        let elevation = clamp01(altitude / (Double.pi / 2))
        // Azimuth → [0,1).
        let azNorm = wrapValue(azimuth / (2 * Double.pi), 0, 1)
        // Pencil Pro barrel roll → [0,1) (0 for non-Pro input / older recordings).
        let rollN = wrapValue(roll / (2 * Double.pi), 0, 1)
        // Heading → [0,1): 0.5 + angle/2π (Krita DrawingAngle).
        let heading = (dx == 0 && dy == 0) ? 0.5 : wrapValue(0.5 + atan2(dy, dx) / (2 * Double.pi), 0, 1)

        let distNorm = distancePeriod > 0 ? wrapValue(arcLength / distancePeriod, 0, 1) : 0
        let fadeNorm = fadePeriod > 0 ? clamp01(Double(dabIndex) / fadePeriod) : 0
        let randPerDab = brushHash01(seed, dabIndex &+ 1, 0xDAB)
        // Independent per-dab streams for scatter X/Y (distinct channels so X and Y don't correlate).
        let scatterX = brushHash01(seed, dabIndex &+ 1, 0x5CA7)
        let scatterY = brushHash01(seed, dabIndex &+ 1, 0x5CA8)
        let scatterLat = brushHash01(seed, dabIndex &+ 1, 0x5CA9)
        let scatterLin = brushHash01(seed, dabIndex &+ 1, 0x5CAA)

        let input = SensorInput(
            pressure: clamp01(force),
            tiltElevationNorm: elevation,
            azimuthNorm: azNorm,
            rollNorm: rollN,
            drawingAngleNorm: heading,
            speedNorm: speedNorm,
            distanceNorm: distNorm,
            fadeNorm: fadeNorm,
            randPerDab: randPerDab,
            randPerStroke: perStrokeRand,
            randScatterX: scatterX,
            randScatterY: scatterY,
            randScatterLat: scatterLat,
            randScatterLin: scatterLin
        )
        dabIndex += 1
        return input
    }
}

@inline(__always) func hypotD(_ a: Double, _ b: Double) -> Double { (a * a + b * b).squareRoot() }

// MARK: - BrushInputSample (live dev HUD readout)

/// A snapshot of the live brush inputs + resulting multipliers, for the on-device input HUD used
/// to tune the dynamics engine (dev-only). Emitted per move-sample while drawing a dynamic brush.
public struct BrushInputSample: Sendable, Equatable {
    public var pressure: Double
    public var speedRaw: Double        // points/second (pre-normalization)
    public var speedNorm: Double       // [0,1] after maxSpeed normalization + smoothing
    public var tiltElevation: Double   // [0,1] (1 = perpendicular)
    public var azimuth: Double         // [0,1] (tilt direction / 2π)
    public var drawingAngle: Double    // [0,1] (stroke heading)
    public var distanceNorm: Double    // [0,1] (arc length / distance period)
    public var fadeNorm: Double        // [0,1] (dab count / fade period)
    public var sizeMul: Double         // active size CurveOption value (1 if none)
    public var flowMul: Double         // active flow CurveOption value (1 if none)
    public var dabIndex: Int

    public init(pressure: Double = 0, speedRaw: Double = 0, speedNorm: Double = 0,
                tiltElevation: Double = 0, azimuth: Double = 0, drawingAngle: Double = 0,
                distanceNorm: Double = 0, fadeNorm: Double = 0,
                sizeMul: Double = 1, flowMul: Double = 1, dabIndex: Int = 0) {
        self.pressure = pressure; self.speedRaw = speedRaw; self.speedNorm = speedNorm
        self.tiltElevation = tiltElevation; self.azimuth = azimuth; self.drawingAngle = drawingAngle
        self.distanceNorm = distanceNorm; self.fadeNorm = fadeNorm
        self.sizeMul = sizeMul; self.flowMul = flowMul; self.dabIndex = dabIndex
    }

    /// The live normalized value for a given sensor (for plotting a marker on its curve). nil for
    /// sensors with no meaningful instantaneous position (the random Fuzzy sensors).
    public func value(for sensor: BrushSensor) -> Double? {
        switch sensor {
        case .pressure: return pressure
        case .speed: return speedNorm
        case .tiltElevation: return tiltElevation
        case .tiltDirection: return azimuth
        case .barrelRotation: return nil // roll marker not shown in the HUD curve strip (dev HUD predates it)
        case .drawingAngle: return drawingAngle
        case .distance: return distanceNorm
        case .fade: return fadeNorm
        case .fuzzyPerDab, .fuzzyPerStroke: return nil
        }
    }
}

// MARK: - BrushDynamics (the per-brush collection of curve options)

/// The dynamics for one brush: a `CurveOption` per parameter. All optional; a nil option
/// means "no dynamics for this parameter" → the legacy scalar / constant is used, so an
/// empty `BrushDynamics` reproduces today's pen exactly.
///
/// Codable and fully backward-compatible (every field `decodeIfPresent`). This is the
/// additive seed of the eventual `BrushDescriptor` (`unified-brush-engine.md` §2.1); it is
/// introduced alongside the flat `BrushConfig` rather than replacing it, so the migration
/// stays incremental.
// NOTE (persistence stability): `BrushSensor` (String) cases and the `CombineMode`/`BrushFold`
// (Int) raw values now appear in saved brush JSON. Treat them as append-only — never rename a
// `BrushSensor` case or renumber the Int enums, or old saved brushes/presets decode wrong.
public struct BrushDynamics: Codable, Equatable, Sendable {
    /// Size multiplier (applied to `baseWidth`). Size-like fold.
    public var size: CurveOption?
    /// Per-dab flow multiplier. Size-like fold.
    public var flow: CurveOption?
    /// Dab rotation (turns, [-1,1] → ±π). Rotation-like fold.
    public var rotation: CurveOption?
    /// Scatter: per-dab random center displacement, magnitude = value × dab diameter. Size-like
    /// fold (so scatter can itself be pressure/speed-driven). Krita `KisScatterOption`.
    public var scatter: CurveOption?
    /// Spacing multiplier (Procreate Dynamics "Speed → Spacing"): per-dab multiplier on
    /// the walk gap. Size-like fold. Drive with Speed so fast strokes space out (spray)
    /// or tighten (default curve inverted). Applied to the NEXT gap after each dab.
    public var spacing: CurveOption?
    /// Lateral scatter (Procreate "Jitter"⊥): per-dab random displacement PERPENDICULAR
    /// to the stroke direction only, magnitude = value × dab diameter. Size-like fold.
    /// Splits the isotropic `scatter` into the Procreate Stroke-Path components.
    public var scatterLateral: CurveOption?
    /// Linear scatter (Procreate "Jitter"∥): per-dab random displacement ALONG the stroke
    /// direction only, magnitude = value × dab diameter. Size-like fold.
    public var scatterLinear: CurveOption?
    /// Tip roundness/aspect multiplier (Procreate "Pressure/Tilt Roundness"): per-dab
    /// multiplier on `BrushConfig.aspectRatio`, size-like fold, result clamped to
    /// [0.05, 1]. Drive with pressure for a nib that squashes as you press. Added
    /// 2026-07-15 (cheap-knobs batch on the P4b aspect plumbing).
    public var ratio: CurveOption?
    /// Per-stroke HSV jitter of the ink color (one random shift per stroke). High img2img
    /// leverage (the model reads color). nil = no jitter.
    public var colorJitter: ColorJitter?
    /// Secondary-color blend (P6): per-dab weight [0,1] from the primary ink toward
    /// `BrushConfig.secondaryColor` — pressure for two-tone nibs, Distance for along-
    /// stroke gradients, Fuzzy for two-color speckle. Size-like fold. Inert unless the
    /// config carries a secondary color.
    public var secondary: CurveOption?
    /// Grain strength (P8 leftover): per-dab multiplier on the MOVING grain's depth —
    /// drive with pressure (default curve inverted-feel: harder press → tooth fills)
    /// or a fuzzy sensor for grain flicker. Size-like fold. Document-space grain is not
    /// per-dab (composite-time carve); its pressure response comes through flow.
    public var grain: CurveOption?
    /// Darkness (Procreate Color Dynamics "Darkness" / Color Pressure darkness): per-dab
    /// darkening AMOUNT — value(input) 0 leaves the ink alone, 1 is black (the ink is
    /// multiplied by 1−value in sRGB space, a device-space darken like Krita's darken
    /// option). The plain pressure sensor therefore gives "press harder, ink darkens"
    /// out of the box; cap the effect with maxValue (e.g. 0.45 → never darker than 55%).
    /// Fuzzy sensors give darkness jitter. Size-like fold.
    public var darkness: CurveOption?
    /// PER-DAB HSV jitter (Procreate "Stamp Color Jitter"): every dab draws its own shift
    /// — the pastel/oil "sparkle". Deferred in P2 for img2img reasons (fine speckle can
    /// average out in klein); revisited per 13-procreate-parity.md — keep amounts small
    /// and prefer brightness over hue for generation-friendly texture. nil = off.
    public var dabColorJitter: ColorJitter?
    // NOTE: there is intentionally NO per-stroke `opacity` CurveOption. Our Glaze model's opacity
    // is a per-stroke ceiling, which doesn't map onto per-dab sensors; the per-dab "opacity" feel
    // is `flow`. A dead `opacity` field was removed (review H2) — re-add only with a real
    // per-stroke resolution (e.g. driven by a stroke-level sensor) wired into currentStrokeOpacity().

    public init(size: CurveOption? = nil, flow: CurveOption? = nil,
                rotation: CurveOption? = nil, scatter: CurveOption? = nil,
                scatterLateral: CurveOption? = nil, scatterLinear: CurveOption? = nil,
                ratio: CurveOption? = nil, spacing: CurveOption? = nil,
                darkness: CurveOption? = nil, grain: CurveOption? = nil,
                secondary: CurveOption? = nil,
                colorJitter: ColorJitter? = nil, dabColorJitter: ColorJitter? = nil) {
        self.size = size
        self.flow = flow
        self.rotation = rotation
        self.scatter = scatter
        self.scatterLateral = scatterLateral
        self.scatterLinear = scatterLinear
        self.ratio = ratio
        self.spacing = spacing
        self.darkness = darkness
        self.grain = grain
        self.secondary = secondary
        self.colorJitter = colorJitter
        self.dabColorJitter = dabColorJitter
    }

    /// True if no parameter has a non-identity dynamic — the legacy path can run unchanged.
    public var isInert: Bool {
        size == nil && flow == nil && rotation == nil
            && scatter == nil && scatterLateral == nil && scatterLinear == nil
            && ratio == nil && spacing == nil && darkness == nil && grain == nil
            && secondary == nil
            && (colorJitter?.isInert ?? true) && (dabColorJitter?.isInert ?? true)
    }

    enum CodingKeys: String, CodingKey { case size, flow, rotation, scatter, scatterLateral, scatterLinear, ratio, spacing, darkness, grain, secondary, colorJitter, dabColorJitter }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        size = try c.decodeIfPresent(CurveOption.self, forKey: .size)
        flow = try c.decodeIfPresent(CurveOption.self, forKey: .flow)
        rotation = try c.decodeIfPresent(CurveOption.self, forKey: .rotation)
        scatter = try c.decodeIfPresent(CurveOption.self, forKey: .scatter)
        scatterLateral = try c.decodeIfPresent(CurveOption.self, forKey: .scatterLateral)
        scatterLinear = try c.decodeIfPresent(CurveOption.self, forKey: .scatterLinear)
        ratio = try c.decodeIfPresent(CurveOption.self, forKey: .ratio)
        spacing = try c.decodeIfPresent(CurveOption.self, forKey: .spacing)
        darkness = try c.decodeIfPresent(CurveOption.self, forKey: .darkness)
        grain = try c.decodeIfPresent(CurveOption.self, forKey: .grain)
        secondary = try c.decodeIfPresent(CurveOption.self, forKey: .secondary)
        colorJitter = try c.decodeIfPresent(ColorJitter.self, forKey: .colorJitter)
        dabColorJitter = try c.decodeIfPresent(ColorJitter.self, forKey: .dabColorJitter)
    }
}

// MARK: - ColorJitter (per-stroke HSV shift) + sRGB↔HSV helpers

/// Per-stroke random HSV jitter of the ink. Amounts in [0,1]: `hue` is a fraction of the full
/// hue circle (±), `saturation`/`brightness` are ± multiplicative fractions. Applied ONCE per
/// stroke from the per-stroke RNG, so a stroke is one coherent color (not per-dab speckle, which
/// the img2img model averages out — `_CONTEXT.md`). Mirrors Krita `KisColorOption` per-stroke mode.
public struct ColorJitter: Codable, Equatable, Sendable {
    public var hue: Double
    public var saturation: Double
    public var brightness: Double
    public init(hue: Double = 0, saturation: Double = 0, brightness: Double = 0) {
        self.hue = hue; self.saturation = saturation; self.brightness = brightness
    }
    public var isInert: Bool { hue == 0 && saturation == 0 && brightness == 0 }

    /// Apply the jitter to an sRGB color given three independent [0,1) random draws (one per
    /// channel). Returns sRGB. Each draw maps to a symmetric ±shift via `2r−1`.
    public func applied(toSRGB rgb: (r: Double, g: Double, b: Double),
                        rH: Double, rS: Double, rB: Double) -> (r: Double, g: Double, b: Double) {
        var hsv = rgbToHSV(rgb)
        hsv.h = (hsv.h + (2 * rH - 1) * hue).truncatingRemainder(dividingBy: 1.0)
        if hsv.h < 0 { hsv.h += 1.0 }
        hsv.s = clamp01(hsv.s * (1 + (2 * rS - 1) * saturation))
        hsv.v = clamp01(hsv.v * (1 + (2 * rB - 1) * brightness))
        return hsvToRGB(hsv)
    }
}

/// sRGB (each [0,1]) → HSV (h,s,v each [0,1]). Pure; operates in gamma sRGB space (matches
/// Krita's HSV transforms, which are not linearized).
public func rgbToHSV(_ c: (r: Double, g: Double, b: Double)) -> (h: Double, s: Double, v: Double) {
    let maxV = max(c.r, c.g, c.b), minV = min(c.r, c.g, c.b)
    let delta = maxV - minV
    var h = 0.0
    if delta > 0 {
        if maxV == c.r { h = ((c.g - c.b) / delta).truncatingRemainder(dividingBy: 6) }
        else if maxV == c.g { h = (c.b - c.r) / delta + 2 }
        else { h = (c.r - c.g) / delta + 4 }
        h /= 6
        if h < 0 { h += 1 }
    }
    let s = maxV > 0 ? delta / maxV : 0
    return (h, s, maxV)
}

/// HSV → sRGB (inverse of `rgbToHSV`).
public func hsvToRGB(_ c: (h: Double, s: Double, v: Double)) -> (r: Double, g: Double, b: Double) {
    if c.s <= 0 { return (c.v, c.v, c.v) }
    let h6 = (c.h - floor(c.h)) * 6
    let i = Int(h6)
    let f = h6 - Double(i)
    let p = c.v * (1 - c.s)
    let q = c.v * (1 - c.s * f)
    let t = c.v * (1 - c.s * (1 - f))
    switch i % 6 {
    case 0: return (c.v, t, p)
    case 1: return (q, c.v, p)
    case 2: return (p, c.v, t)
    case 3: return (p, q, c.v)
    case 4: return (t, p, c.v)
    default: return (c.v, p, q)
    }
}

import Foundation

// Offline verification for BrushDynamics.swift (the sensor+curve keystone engine).
// Pure-Swift, no UIKit — so it runs on macOS even though CanvasModule itself is iOS-only.
// Asserts the engine's output against Krita's exact formulas (hand-computed reference
// values). See ./README.md for how to run. Per `feedback_verify_shader_color_offline`.

var failures = 0
func check(_ name: String, _ got: Double, _ want: Double, tol: Double = 1e-9) {
    if abs(got - want) <= tol {
        print("PASS  \(name)  (\(got))")
    } else {
        print("FAIL  \(name)  got \(got) want \(want)")
        failures += 1
    }
}
func checkBool(_ name: String, _ cond: Bool) {
    if cond { print("PASS  \(name)") } else { print("FAIL  \(name)"); failures += 1 }
}

// --- helpers mirror Krita (KisDynamicSensor / KisAlgebra2D) ---
check("scalingToAdditive(0)", scalingToAdditive(0), -1)
check("scalingToAdditive(1)", scalingToAdditive(1), 1)
check("additiveToScaling(-1)", additiveToScaling(-1), 0)
check("additiveToScaling(1)", additiveToScaling(1), 1)
check("wrapValue(1.0,-1,1)", wrapValue(1.0, -1, 1), -1) // wraps to -1 in [-1,1)
check("wrapValue(0.5,-1,1)", wrapValue(0.5, -1, 1), 0.5)
check("wrapValue(1.25,0,1)", wrapValue(1.25, 0, 1), 0.25)
check("wrapValue(-0.25,0,1)", wrapValue(-0.25, 0, 1), 0.75)

// --- ResponseCurve (256-LUT; tol 1e-3 reflects LUT quantization, same as Krita's LUT) ---
let ident = ResponseCurve.identity
checkBool("identity.isIdentity", ident.isIdentity)
check("identity.value(0.37)", ident.value(0.37), 0.37)
let g2 = ResponseCurve.gamma(2.0, samples: 9)
checkBool("gamma(2) not identity", !g2.isIdentity)
check("gamma(2).value(0.5)", g2.value(0.5), 0.25, tol: 1e-3)
check("gamma(2).value(0.0)", g2.value(0.0), 0.0)
check("gamma(2).value(1.0)", g2.value(1.0), 1.0)
check("gamma(2).value(0.25)", g2.value(0.25), 0.0625, tol: 1e-3)
checkBool("gamma(1)==identity", ResponseCurve.gamma(1.0).isIdentity)

// --- size-like fold ---
func sizeOpt(min: Double = 0, max: Double = 1, strength: Double = 1, sensors: [SensorChannel], combine: CombineMode = .multiply) -> CurveOption {
    CurveOption(sensors: sensors, combineMode: combine, fold: .sizeLike, strength: strength, minValue: min, maxValue: max)
}
let press = SensorChannel(sensor: .pressure)
let opt1 = sizeOpt(sensors: [press])
check("size pressure=0.5", opt1.value(SensorInput(pressure: 0.5)), 0.5)
check("size pressure=0.0", opt1.value(SensorInput(pressure: 0.0)), 0.0)
check("size pressure=1.0", opt1.value(SensorInput(pressure: 1.0)), 1.0)

// min remap: "even zero pressure paints 20%"
let opt2 = sizeOpt(min: 0.2, max: 1.0, sensors: [press])
check("size min-remap pressure=0", opt2.value(SensorInput(pressure: 0)), 0.2)
check("size min-remap pressure=0.5", opt2.value(SensorInput(pressure: 0.5)), 0.5)
check("size min-remap pressure=1", opt2.value(SensorInput(pressure: 1)), 1.0)

// combine modes: pressure(0.8) & speed(0.5)
let speed = SensorChannel(sensor: .speed)
let inP = SensorInput(pressure: 0.8, speedNorm: 0.5)
check("combine multiply", sizeOpt(sensors: [press, speed], combine: .multiply).value(inP), 0.4)
check("combine max", sizeOpt(sensors: [press, speed], combine: .max).value(inP), 0.8)
check("combine min", sizeOpt(sensors: [press, speed], combine: .min).value(inP), 0.5)
// combine ADD (0.8+0.5=1.3) — clamps to maxValue; test both clamped and headroom
check("combine add (clamped to max 1)", sizeOpt(sensors: [press, speed], combine: .add).value(inP), 1.0)
check("combine add (max 2.0 → 1.3)", sizeOpt(max: 2.0, sensors: [press, speed], combine: .add).value(inP), 1.3, tol: 1e-9)
// combine DIFFERENCE (max-min = 0.8-0.5 = 0.3)
check("combine difference", sizeOpt(sensors: [press, speed], combine: .difference).value(inP), 0.3, tol: 1e-9)
// useCurve=false → option collapses to its constant strength (sensors ignored)
var noCurve = sizeOpt(strength: 0.7, sensors: [press]); noCurve.useCurve = false
check("useCurve=false → constant strength", noCurve.value(SensorInput(pressure: 0.1)), 0.7)

// additive sensor folds via additiveToScaling
let fuzz = SensorChannel(sensor: .fuzzyPerStroke)
let optF = sizeOpt(sensors: [press, fuzz])
check("size + fuzz rand=0.5", optF.value(SensorInput(pressure: 1, randPerStroke: 0.5)), 0.5)
check("size + fuzz rand=1.0", optF.value(SensorInput(pressure: 1, randPerStroke: 1.0)), 1.0)

// rotation-like fold: drawingAngle (absolute)
let rotOpt = CurveOption(sensors: [SensorChannel(sensor: .drawingAngle)], fold: .rotationLike, strength: 1.0)
check("rotation drawingAngle=0.25", rotOpt.value(SensorInput(drawingAngleNorm: 0.25)), 0.5)
check("rotation drawingAngle=0.5", rotOpt.value(SensorInput(drawingAngleNorm: 0.5)), -1.0)
// rotation-like with a SCALING sensor only (no absolute offset → normalizedBaseAngle path):
// wrap(2·0 + 1·(1·scalingToAdditive(pressure))). pressure=0.75 → scalingToAdditive(0.75)=0.5 → wrap(0.5)=0.5
let rotScale = CurveOption(sensors: [SensorChannel(sensor: .pressure)], fold: .rotationLike, strength: 1.0)
check("rotation scaling pressure=0.75", rotScale.value(SensorInput(pressure: 0.75)), 0.5)
// rotation-like with absolute(drawingAngle=0.25) + ADDITIVE(fuzzy, rand=1→additive 1):
// wrap(2·0.25 + 1·(0 + 1)) = wrap(1.5,-1,1) = -0.5
let rotAddAbs = CurveOption(sensors: [SensorChannel(sensor: .drawingAngle), SensorChannel(sensor: .fuzzyPerStroke)],
                            fold: .rotationLike, strength: 1.0)
check("rotation absolute+additive", rotAddAbs.value(SensorInput(drawingAngleNorm: 0.25, randPerStroke: 1.0)), -0.5)
// rotation-like absoluteAxesFlipped: offset = 0.5 - absoluteOffset. drawingAngle=0.1 → 0.4 → wrap(0.8)=0.8
check("rotation flipped drawingAngle=0.1",
      rotOpt.rotationLikeValue(SensorInput(drawingAngleNorm: 0.1), absoluteAxesFlipped: true), 0.8)
// NON-IDENTITY curve on an ADDITIVE sensor (exercises additiveToScaling→curve→scalingToAdditive):
// fuzzy rand=0.75→raw 0.5→additiveToScaling 0.75→gamma(2) 0.5625→scalingToAdditive 0.125→additiveToScaling 0.5625
let fuzzGamma = sizeOpt(sensors: [SensorChannel(sensor: .fuzzyPerStroke, curve: .gamma(2.0))])
var fuzzGammaPer = fuzzGamma; fuzzGammaPer.useSameCurve = false
check("additive sensor + gamma curve", fuzzGammaPer.value(SensorInput(randPerStroke: 0.75)), 0.5625, tol: 2e-3)
// NON-IDENTITY curve on an ABSOLUTE sensor: drawingAngle=0.25→wrap(0.75)→gamma(2) 0.5625→wrap(1.0625)=0.0625
//   → rotationLike offset 0.0625 → wrap(0.125)=0.125
let angleGamma = CurveOption(sensors: [SensorChannel(sensor: .drawingAngle, curve: .gamma(2.0))],
                             fold: .rotationLike, strength: 1.0, useSameCurve: false)
check("absolute sensor + gamma curve", angleGamma.value(SensorInput(drawingAngleNorm: 0.25)), 0.125, tol: 2e-3)
// Sensor normalization: a 45° heading (dx=dy=1) → drawingAngleNorm = 0.5 + (π/4)/(2π) = 0.625
var headState = StrokeDynamicsState(seed: 1)
_ = headState.advance(x: 0, y: 0, force: 1, altitude: .pi/2, azimuth: 0, dx: 0, dy: 0, dt: 0)
let h45 = headState.advance(x: 1, y: 1, force: 1, altitude: .pi/2, azimuth: 0, dx: 1, dy: 1, dt: 0.01)
check("heading 45° → 0.625", h45.drawingAngleNorm, 0.625, tol: 1e-6)

// deterministic hash
let h1 = brushHash01(42, 1, 0xDAB), h2 = brushHash01(42, 1, 0xDAB), h3 = brushHash01(42, 2, 0xDAB)
checkBool("hash stable", h1 == h2)
checkBool("hash in [0,1)", h1 >= 0 && h1 < 1)
checkBool("hash varies by index", h1 != h3)

// StrokeDynamicsState
var st = StrokeDynamicsState(seed: 7)
let i0 = st.advance(x: 0, y: 0, force: 0.5, altitude: .pi/2, azimuth: 0, dx: 0, dy: 0, dt: 0)
check("state pressure passthrough", i0.pressure, 0.5)
// Krita convention: perpendicular stylus → 1, flat → 0 (review H1 flip).
check("state tiltElevation perpendicular=1", i0.tiltElevationNorm, 1.0)
let i1 = st.advance(x: 100, y: 0, force: 1.0, altitude: 0, azimuth: 0, dx: 100, dy: 0, dt: 0.1)
check("state tiltElevation flat=0", i1.tiltElevationNorm, 0.0)
checkBool("state speed>0 after move", i1.speedNorm > 0)
checkBool("state arclength accumulates", st.arcLength == 100.0)

// BrushDynamics inert default + Codable backward-compat
checkBool("empty BrushDynamics isInert", BrushDynamics().isInert)
checkBool("BrushDynamics with size not inert", !BrushDynamics(size: opt1).isInert)
let dyn = BrushDynamics(size: opt2, rotation: rotOpt)
let back = try! JSONDecoder().decode(BrushDynamics.self, from: JSONEncoder().encode(dyn))
checkBool("Codable round-trip equal", back == dyn)
checkBool("empty JSON → inert", try! JSONDecoder().decode(BrushDynamics.self, from: "{}".data(using: .utf8)!).isInert)

// --- scatter + color jitter (P2) ---
check("scatter constant (no sensors → strength)", CurveOption(sensors: [], fold: .sizeLike, strength: 0.7).value(SensorInput()), 0.7)
let hsvRT = hsvToRGB(rgbToHSV((0.2, 0.5, 0.8)))
check("hsv roundtrip r", hsvRT.r, 0.2); check("hsv roundtrip g", hsvRT.g, 0.5); check("hsv roundtrip b", hsvRT.b, 0.8)
let jitNoop = ColorJitter(hue: 0.1, saturation: 0.2, brightness: 0.2).applied(toSRGB: (0.2, 0.5, 0.8), rH: 0.5, rS: 0.5, rB: 0.5)
check("color jitter r=0.5 is no-op", jitNoop.r, 0.2)
checkBool("color jitter changes color when r≠0.5", {
    let j = ColorJitter(hue: 0.1, saturation: 0.2, brightness: 0.2).applied(toSRGB: (0.2, 0.5, 0.8), rH: 1, rS: 1, rB: 1)
    return j.r != 0.2 || j.g != 0.5 || j.b != 0.8
}())
checkBool("default SensorInput scatter symmetric (no offset)", 2 * SensorInput().randScatterX - 1 == 0)
check("ColorJitter inert default", BrushDynamics(colorJitter: ColorJitter()).isInert ? 1 : 0, 1)
check("scatter makes dynamics non-inert", BrushDynamics(scatter: CurveOption(sensors: [], strength: 0.5)).isInert ? 0 : 1, 1)
// scatter DETERMINISM: two identical states produce identical scatter draws (replay/undo invariance)
var scA = StrokeDynamicsState(seed: 5), scB = StrokeDynamicsState(seed: 5)
let sa = scA.advance(x: 10, y: 20, force: 0.7, altitude: 1, azimuth: 0.3, dx: 2, dy: 1, dt: 0.01)
let sb = scB.advance(x: 10, y: 20, force: 0.7, altitude: 1, azimuth: 0.3, dx: 2, dy: 1, dt: 0.01)
checkBool("scatter deterministic (same seed+index)", sa.randScatterX == sb.randScatterX && sa.randScatterY == sb.randScatterY)
checkBool("scatter X/Y decorrelated", sa.randScatterX != sa.randScatterY)
// HSV edge cases: gray (s=0) and black (v=0) round-trips
let grayRT = hsvToRGB(rgbToHSV((0.5, 0.5, 0.5)))
check("hsv gray roundtrip", grayRT.r, 0.5); check("hsv gray s=0", rgbToHSV((0.5, 0.5, 0.5)).s, 0)
let blackRT = hsvToRGB(rgbToHSV((0, 0, 0)))
check("hsv black roundtrip r", blackRT.r, 0); check("hsv black v=0", rgbToHSV((0, 0, 0)).v, 0)

// --- WetKM: premultiplied-_srgb texel recovery (CanvasRenderer.sampleLayerColor) ---
// The texture stores sRGB_encode(linear × alpha); recovery must DECODE first, THEN
// un-premultiply. The reverse order shipped as a bug (wet pickup read semi-transparent
// paint up to ~3× too light; fixed 2026-07-14) — the last check pins that regression.
func l2s(_ c: Double) -> Double { c <= 0.0031308 ? c*12.92 : 1.055*pow(c, 1/2.4)-0.055 }
func encodeTexel(lin: Double, a: Double) -> (v: UInt8, a: UInt8) {
    (UInt8((l2s(lin * a) * 255).rounded()), UInt8((a * 255).rounded()))
}
for (lin, a) in [(0.20, 0.5), (0.50, 0.5), (0.05, 0.3), (0.80, 0.25), (0.50, 1.0)] {
    let t = encodeTexel(lin: lin, a: a)
    let rec = WetKM.straightLinear(b: t.v, g: t.v, r: t.v, a: t.a)
    // Tolerance: one 8-bit step in encoded space, amplified by 1/alpha after decode.
    check("texel recovery lin=\(lin) a=\(a)", Double(rec.color.x), lin, tol: 0.02 / a)
    check("texel recovery alpha a=\(a)", Double(rec.alpha), a, tol: 1/255.0 + 1e-6)
}
checkBool("texel recovery: a=0 → (0, alpha 0)", {
    let r = WetKM.straightLinear(b: 120, g: 120, r: 120, a: 0)
    return r.alpha == 0 && r.color == SIMD3<Float>(0, 0, 0)
}())
checkBool("divide-then-decode (the old order) would read ≥1.9× too light", {
    let t = encodeTexel(lin: 0.2, a: 0.5)
    let wrong = pow((min(Double(t.v)/255.0/0.5, 1) + 0.055)/1.055, 2.4)   // old order, mirrored
    let right = Double(WetKM.straightLinear(b: t.v, g: t.v, r: t.v, a: t.a).color.x)
    return wrong / right >= 1.9
}())

// --- WetKM: spectral Kubelka-Munk mix (CanvasRenderer.kmMixCPU / wetStampFragment) ---
let kmTables = WetKM.buildTables()
func km(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
    WetKM.mix(a, b, t, basis: kmTables.basis, mat: kmTables.mat)
}
let kmRed = SIMD3<Float>(0.8, 0.1, 0.1), kmBlue = SIMD3<Float>(0.1, 0.1, 0.9)
// Endpoint-exact residual correction: t=0 → a, t=1 → b (the property the residual exists for).
check("KM endpoint t=0", Double(km(kmRed, kmBlue, 0).x), Double(kmRed.x), tol: 1e-3)
check("KM endpoint t=1", Double(km(kmRed, kmBlue, 1).z), Double(kmBlue.z), tol: 1e-3)
// The reason spectral KM exists at all: blue + yellow → GREEN (per-channel KM collapses
// this to ~black; see pro-brush-roadmap Phase 4 + the wet-paint-color-spike).
let by = km(SIMD3<Float>(0.1, 0.1, 0.9), SIMD3<Float>(0.9, 0.9, 0.1), 0.5)
checkBool("KM blue+yellow → green dominant (g>r, g>b)", by.y > by.x && by.y > by.z)
checkBool("KM blue+yellow green is meaningfully green (g > 0.15)", by.y > 0.15)
// KS-space interpolation at t=0.5 is symmetric in its endpoints.
let ab = km(kmRed, kmBlue, 0.5), ba = km(kmBlue, kmRed, 0.5)
checkBool("KM mix symmetric at t=0.5", abs(ab.x - ba.x) < 1e-5 && abs(ab.y - ba.y) < 1e-5 && abs(ab.z - ba.z) < 1e-5)
// White load over white canvas stays white (no drift toward gray).
let ww = km(SIMD3<Float>(1, 1, 1), SIMD3<Float>(1, 1, 1), 0.5)
checkBool("KM white+white ≈ white", ww.x > 0.97 && ww.y > 0.97 && ww.z > 0.97)

// --- StrokeStabilizer (P3 rebuild): passthrough, EMA regression, rate-independence,
// tremor damping, catch-up-on-lift, pressure smoothing ---
func spt(_ x: Double, _ y: Double, t: Double, f: Double = 0.5) -> StrokePoint {
    StrokePoint(position: CGPoint(x: x, y: y), force: CGFloat(f), altitude: .pi / 2, timestamp: t)
}
var stPass = StrokeStabilizer(streamline: 0)
let rawPt = spt(10, 20, t: 0, f: 0.7)
let outPt = stPass.feed(rawPt)
checkBool("stabilizer all-zero is strict passthrough", outPt.position == rawPt.position && outPt.force == rawPt.force)
checkBool("stabilizer passthrough finish() empty", stPass.finish().isEmpty)

// EMA stage must equal the OLD inline smoothedStrokePoint formula (verbatim port).
var stEma = StrokeStabilizer(streamline: 0.5)
_ = stEma.feed(spt(0, 0, t: 0))
let emaOut = stEma.feed(spt(100, 0, t: 1.0 / 120))
let emaDt = min(4.0 / 120.0, 1.0 / 120.0)
let emaTau = max(0.004, 0.5 * 0.12)
let emaFactor = min(1.0, max(0.04, 1.0 - exp(-emaDt / emaTau)))
check("EMA verbatim-port regression", Double(emaOut.position.x), 100.0 * emaFactor, tol: 1e-9)

// Catch-up: a heavily lagged stroke must END exactly at the raw pencil endpoint.
var stCat = StrokeStabilizer(streamline: 0.9, stabilization: 0.7)
_ = stCat.feed(spt(0, 0, t: 0))
for i in 1...20 { _ = stCat.feed(spt(Double(i) * 10, 0, t: Double(i) / 120)) }
let tail = stCat.finish()
checkBool("catch-up emits a tail when lagged", !tail.isEmpty)
check("catch-up ends at the pencil tip", Double(tail.last!.position.x), 200.0, tol: 1e-6)
checkBool("catch-up spacing bounded (≤256 pts)", tail.count <= 256)

// Gaussian stage: same path sampled at 60 vs 240 points must produce the SAME CURVE
// (arc-length weighting = event-rate independent). Compared by nearest-x matching of
// the output paths (<2px vertical deviation), skipping the warm-up head. The raw
// ENDPOINTS legitimately differ slightly (trailing lag depends second-order on
// sampling via the cascaded pass) — endpoint equality is catch-up's contract, which
// snaps to the true raw endpoint exactly and is asserted separately above.
func gaussPath(_ n: Int) -> [CGPoint] {
    var st = StrokeStabilizer(streamline: 0, stabilization: 0.6)
    var out: [CGPoint] = []
    for i in 0...n {
        let s = Double(i) / Double(n)
        out.append(st.feed(spt(s * 400, sin(s * .pi * 4) * 30, t: s)).position)
    }
    return out
}
let path60 = gaussPath(60), path240 = gaussPath(240)
var maxDy = 0.0
// Steady-state body only: the head is window warm-up, the tail (last ~40px) is the
// live lag differential — both are catch-up's/lift's domain, asserted above. Probed
// 2026-07-15: tail-inclusive maxDy ≈ 2.3px (all at x>378/400); body is far tighter.
for pt in path60.dropFirst(10).dropLast(8) {
    if let q = path240.min(by: { abs($0.x - pt.x) < abs($1.x - pt.x) }) {
        maxDy = max(maxDy, abs(Double(q.y - pt.y)))
    }
}
checkBool("gaussian frame-rate independent (curves match <2px, 60 vs 240 samples)", maxDy < 2)

// Tremor damping, measured as WOBBLE ENERGY (mean |second difference| of y — the
// high-frequency curvature noise that reads as "shaky hand"). Max amplitude is the
// wrong metric here: jagged noise inflates arc length, which bounds the window's
// effective sample count; what smoothing actually crushes is curvature noise.
// Measured 9.2× at stabilization 0.8 (5.8× at 0.5) — assert >5× with margin.
// Steady-state only (first 30 points skipped — trailing-window warm-up, as in Krita).
func wobbleEnergy(_ stab: Double) -> Double {
    var st = StrokeStabilizer(streamline: 0, stabilization: CGFloat(stab))
    var ys: [Double] = []
    for i in 0...300 {
        let y = (brushHash01(1, UInt64(i), 0x77) - 0.5) * 12
        let o = st.feed(spt(Double(i) * 4, y, t: Double(i) / 120))
        if i > 30 { ys.append(Double(o.position.y)) }
    }
    var e = 0.0
    for i in 1..<(ys.count - 1) { e += abs(ys[i + 1] - 2 * ys[i] + ys[i - 1]) }
    return e / Double(ys.count - 2)
}
checkBool("gaussian crushes wobble energy >5x", wobbleEnergy(0) / max(wobbleEnergy(0.8), 1e-9) > 5)

// Pressure smoothing: force lags, geometry is untouched.
var stP = StrokeStabilizer(streamline: 0, pressureSmoothing: 0.8)
_ = stP.feed(spt(0, 0, t: 0, f: 0))
let pOut = stP.feed(spt(10, 0, t: 1.0 / 120, f: 1.0))
checkBool("pressure smoothing lags force only", pOut.force < 1.0 && pOut.position.x == 10)

// --- BarrelRotation sensor (cheap-knobs batch): additive, mirrors tiltDirection ---
checkBool("barrelRotation is additive", BrushSensor.barrelRotation.isAdditive)
let rollOpt = sizeOpt(sensors: [press, SensorChannel(sensor: .barrelRotation)])
check("size + roll=0.5 (additive no-op)", rollOpt.value(SensorInput(pressure: 1, rollNorm: 0.5)), 0.5)
var rollState = StrokeDynamicsState(seed: 3)
let rollIn = rollState.advance(x: 0, y: 0, force: 1, altitude: .pi/2, azimuth: 0, dx: 0, dy: 0, dt: 0, roll: .pi)
check("advance normalizes roll π → 0.5", rollIn.rollNorm, 0.5, tol: 1e-9)

// --- P8 grain: composite-time carve (Swift mirror of grainCompositorFragment) ---
// a' = clamp(a − src·depth, 0, 1), applied ONCE to the scratch's accumulated alpha
// (per-dab carving was rejected: overlapping stamps refill the tooth — see the P8
// commit). depth 0 is an exact identity.
func grainCarve(_ a: Double, _ src: Double, _ depth: Double) -> Double {
    min(1, max(0, a - src * depth))
}
check("grain depth 0 is identity (a .37)", grainCarve(0.37, 0.8, 0), 0.37)
checkBool("grain valleys die first at light coverage", grainCarve(0.1, 0.9, 0.7) == 0 && grainCarve(0.1, 0.05, 0.7) > 0)
checkBool("grain monotonic in coverage", grainCarve(0.8, 0.5, 0.7) > grainCarve(0.3, 0.5, 0.7))
checkBool("tooth persists even at full coverage (Procreate Depth semantics)", grainCarve(1.0, 1.0, 0.7) < 1.0)

// --- P4a lightness-map oracle (mirrors lightnessShapedStampFragment MSL) ---
let lmBrush = (r: 0.2, g: 0.55, b: 0.8)   // a teal, z well inside (0.25, 0.75)
let lmZ = LightnessMap.lightness(r: lmBrush.r, g: lmBrush.g, b: lmBrush.b)
check("lightness quad f(0)=0", LightnessMap.quadratic(0, z: lmZ), 0)
check("lightness quad f(1)=1", LightnessMap.quadratic(1, z: lmZ), 1)
check("lightness quad f(0.5)=z", LightnessMap.quadratic(0.5, z: lmZ), lmZ, tol: 1e-12)
// THE invariant: a mid-gray tip pixel reproduces the brush color EXACTLY.
let lmMid = LightnessMap.apply(brushSRGB: lmBrush, tipLuma: 0.5, strength: 1)
check("mid-gray tip == brush color (r)", lmMid.r, lmBrush.r, tol: 1e-9)
check("mid-gray tip == brush color (g)", lmMid.g, lmBrush.g, tol: 1e-9)
check("mid-gray tip == brush color (b)", lmMid.b, lmBrush.b, tol: 1e-9)
// Endpoints: black tip → black, white tip → white (hue collapses at the poles).
let lmB = LightnessMap.apply(brushSRGB: lmBrush, tipLuma: 0, strength: 1)
let lmW = LightnessMap.apply(brushSRGB: lmBrush, tipLuma: 1, strength: 1)
checkBool("black tip → black", lmB.r < 1e-9 && lmB.g < 1e-9 && lmB.b < 1e-9)
checkBool("white tip → white", lmW.r > 1 - 1e-9 && lmW.g > 1 - 1e-9 && lmW.b > 1 - 1e-9)
// strength 0 = off.
let lmOff = LightnessMap.apply(brushSRGB: lmBrush, tipLuma: 0.9, strength: 0)
check("strength 0 leaves brush color", lmOff.g, lmBrush.g, tol: 1e-9)
// Monotonic in tip luma for mid-range z (0.3 / 0.5 / 0.7 — Krita's stable band).
for zTest in [0.3, 0.5, 0.7] {
    var mono = true
    var prev = -1.0
    for i in 0...20 {
        let v = LightnessMap.quadratic(Double(i) / 20, z: zTest)
        if v < prev - 1e-9 { mono = false }
        prev = v
    }
    checkBool("lightness quad monotonic (z=\(zTest))", mono)
}
// Charge half-life (wet reservoir): identity at 1 (infinite), monotonic in charge,
// pinned bounds — the walker's decay is 0.5^(arc/halfLife) on the deposit alpha.
do {
    var b = BrushConfig(color: .black, baseWidth: 30)
    b.wetCharge = 1.0
    checkBool("charge 1 → bottomless", b.wetChargeHalfLife == .infinity)
    b.wetCharge = 0.0
    check("charge 0 half-life floor", Double(b.wetChargeHalfLife), 180.0)
    b.wetCharge = 0.5
    check("charge 0.5 half-life", Double(b.wetChargeHalfLife), 180.0 + 3420 * 0.25)
    var prev = 0.0
    var monotonic = true
    for c in stride(from: 0.0, through: 0.99, by: 0.11) {
        b.wetCharge = CGFloat(c)
        let h = Double(b.wetChargeHalfLife)
        if h < prev { monotonic = false }
        prev = h
    }
    checkBool("charge half-life monotonic", monotonic)
}
// A no-sensor rotationLike CurveOption folds to 0, NOT to its strength — the static nib
// angle must come from BrushConfig.tipAngle (calligraphy bug, caught on device 2026-07-15).
check("no-sensor rotationLike folds to 0",
      CurveOption(sensors: [], fold: .rotationLike, strength: 0.25).value(SensorInput(pressure: 0.8)), 0.0)
// Recentering (coverage-authored art): mean luma → 0.5 → exact brush color; swings both ways.
check("recenter(mean)=0.5", LightnessMap.recenter(0.82, mean: 0.82, neighborhood: 1.0), 0.5)
checkBool("recenter swings both ways",
          LightnessMap.recenter(0.95, mean: 0.82, neighborhood: 1.0) > 0.5 &&
          LightnessMap.recenter(0.6, mean: 0.82, neighborhood: 1.0) < 0.5)
// Neighborhood damping: a texel at the tip BOUNDARY (sparse neighborhood) maps to 0.5 →
// fades with the brush color (no dark halo); the SAME luma amid bright interior keeps
// its full value swing (chalk speckle survives).
check("boundary texel → no halo", LightnessMap.recenter(0.3, mean: 0.82, neighborhood: 0.2), 0.5)
checkBool("interior speckle keeps swing",
          abs(LightnessMap.recenter(0.3, mean: 0.82, neighborhood: 0.95) - 0.5) > 0.2)
// setLightness preserves hue/sat: remap to the SAME L is an identity.
let lmSame = LightnessMap.setLightness(r: lmBrush.r, g: lmBrush.g, b: lmBrush.b, newL: lmZ)
check("setLightness(sameL) identity", lmSame.b, lmBrush.b, tol: 1e-9)

// --- per-dab timing (the PLAN's P1 exit-gate; informational, not a hard assert) ---
// Worst-case dynamic brush: multi-sensor size + flow + rotation + scatter, all non-identity.
// Measures the per-dab CPU cost the dynamics path adds on top of the legacy effectiveWidth call.
// Compile with -O for representative numbers (a debug build over-estimates several×).
do {
    let sizeOpt2 = CurveOption(sensors: [SensorChannel(sensor: .pressure, curve: .gamma(2)),
                                         SensorChannel(sensor: .speed, curve: .gamma(0.5))],
                               combineMode: .multiply, fold: .sizeLike, useSameCurve: false)
    let flowOpt = CurveOption(sensors: [SensorChannel(sensor: .pressure, curve: .gamma(1.5))], fold: .sizeLike)
    let rotOpt2 = CurveOption(sensors: [SensorChannel(sensor: .drawingAngle)], fold: .rotationLike)
    let scatOpt = CurveOption(sensors: [], fold: .sizeLike, strength: 0.6)
    let n = 4000
    var stt = StrokeDynamicsState(seed: 99)
    var acc = 0.0
    let t0 = Date()
    for i in 0..<n {
        let inp = stt.advance(x: Double(i), y: Double(i % 50), force: 0.5 + 0.5 * Double(i % 7) / 7,
                              altitude: 0.8, azimuth: Double(i % 6), dx: 1, dy: 0.2, dt: 0.004)
        acc += sizeOpt2.value(inp) + flowOpt.value(inp) + rotOpt2.value(inp) + scatOpt.value(inp)
    }
    let ms = Date().timeIntervalSince(t0) * 1000
    print(String(format: "TIMING: %d dabs × (advance + 4 CurveOptions) = %.2f ms total, %.0f ns/dab (debug; use -O for real). acc=%.1f",
                 n, ms, ms * 1e6 / Double(n), acc))
    print("  (Per-dab dynamics cost only; the real budget risk is the per-frame O(n) re-walk of the")
    print("   whole point list in generateStampsForStroke — see IMPLEMENTATION-LOG H3 follow-up.)")
}

// --- ColorJitter Darkness (Procreate Stamp/Stroke Color Jitter → Darkness, 2026-07-17) ---
do {
    let dk = ColorJitter(darkness: 1.0)
    let full = dk.applied(toSRGB: (r: 0.8, g: 0.5, b: 0.2), rH: 0.5, rS: 0.5, rB: 0.5, rD: 1.0)
    check("darkness=1 rD=1 → black (r)", full.r, 0)
    check("darkness=1 rD=1 → black (g)", full.g, 0)
    let none = dk.applied(toSRGB: (r: 0.8, g: 0.5, b: 0.2), rH: 0.5, rS: 0.5, rB: 0.5, rD: 0.0)
    check("darkness rD=0 → unchanged (r)", none.r, 0.8, tol: 1e-6)
    let half = ColorJitter(darkness: 0.5).applied(toSRGB: (r: 0.8, g: 0.0, b: 0.0), rH: 0.5, rS: 0.5, rB: 0.5, rD: 1.0)
    checkBool("darkness=0.5 rD=1 darkens toward half V", abs(half.r - 0.4) < 1e-6)
    checkBool("darkness one-sided: never lightens",
              ColorJitter(darkness: 0.7).applied(toSRGB: (r: 0.3, g: 0.3, b: 0.3), rH: 0.5, rS: 0.5, rB: 0.5, rD: 0.2).r <= 0.3 + 1e-9)
    // Back-compat: payload without `darkness` decodes to 0.
    let legacy = try! JSONDecoder().decode(ColorJitter.self,
        from: Data(#"{"hue":0.1,"saturation":0.2,"brightness":0.3}"#.utf8))
    check("legacy ColorJitter decode: darkness=0", legacy.darkness, 0)
    check("legacy ColorJitter decode: hue kept", legacy.hue, 0.1, tol: 1e-9)
}

// --- BrushConfig new-knob Codable round-trip (rotationJitter / randomizedRotation / grainDepthJitter) ---
do {
    var cfg = BrushConfig(color: .black, baseWidth: 20)
    cfg.rotationJitter = 0.4; cfg.randomizedRotation = true; cfg.grainDepthJitter = 0.6
    let data = try! JSONEncoder().encode(cfg)
    let back = try! JSONDecoder().decode(BrushConfig.self, from: data)
    check("rotationJitter round-trip", Double(back.rotationJitter), 0.4, tol: 1e-9)
    checkBool("randomizedRotation round-trip", back.randomizedRotation)
    check("grainDepthJitter round-trip", Double(back.grainDepthJitter), 0.6, tol: 1e-9)
    // Grain Movement/Zoom (2026-07-19): round-trip + legacy defaults (smear + Cropped).
    var g = BrushConfig(color: .black, baseWidth: 20)
    g.grainMovement = 0.8; g.grainZoom = 0.25
    let gback = try! JSONDecoder().decode(BrushConfig.self, from: try! JSONEncoder().encode(g))
    check("grainMovement round-trip", Double(gback.grainMovement), 0.8, tol: 1e-9)
    check("grainZoom round-trip", Double(gback.grainZoom), 0.25, tol: 1e-9)
    var g2 = BrushConfig(color: .black, baseWidth: 20)
    g2.grainRotation = -0.4; g2.grainDepthMinimum = 0.3; g2.grainOffsetJitter = true
    g2.grainBrightness = 0.2; g2.grainContrast = -0.5
    let g2b = try! JSONDecoder().decode(BrushConfig.self, from: try! JSONEncoder().encode(g2))
    check("grainRotation round-trip", Double(g2b.grainRotation), -0.4, tol: 1e-9)
    check("grainDepthMinimum round-trip", Double(g2b.grainDepthMinimum), 0.3, tol: 1e-9)
    checkBool("grainOffsetJitter round-trip", g2b.grainOffsetJitter)
    check("grainBrightness round-trip", Double(g2b.grainBrightness), 0.2, tol: 1e-9)
    check("grainContrast round-trip", Double(g2b.grainContrast), -0.5, tol: 1e-9)
    let legacy2 = try! JSONDecoder().decode(BrushConfig.self, from: Data(#"{"color":{"red":0,"green":0,"blue":0,"alpha":1},"baseWidth":10,"pressureGamma":0.7}"#.utf8))
    check("legacy decode: grainMovement=0 (smear)", Double(legacy2.grainMovement), 0)
    check("legacy decode: grainZoom=1 (Cropped)", Double(legacy2.grainZoom), 1)
    checkBool("legacy decode: offsetJitter off", !legacy2.grainOffsetJitter)
    check("legacy decode: rotation 0", Double(legacy2.grainRotation), 0)
}

print("")
if failures == 0 { print("ALL PASSED") } else { print("\(failures) FAILED"); exit(1) }

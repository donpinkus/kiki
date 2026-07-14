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

print("")
if failures == 0 { print("ALL PASSED") } else { print("\(failures) FAILED"); exit(1) }

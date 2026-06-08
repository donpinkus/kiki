import Foundation
import AppKit
import CoreGraphics

// ── Spectral subtractive pigment mixing — tuned spike (variant B) ─────────────
//
// METHOD
//   RGB→spectrum upsampling: a Mallett & Yuksel 2019 -style decomposition.
//   Any linear-sRGB color is written as a non-negative combination of seven
//   smooth basis reflectance spectra (white + RGB + CMY). The weights come from
//   the classic MY residual / sorted-channel rule: white absorbs the min
//   channel, a secondary absorbs the mid, a primary the max — leaving a
//   non-negative partition. spectrum = Σ wᵢ·basisᵢ.
//
//   The seven basis SHAPES are the real tuning surface. They are smooth analytic
//   curves (sigmoids + Gaussians) shaped like real pigment reflectance — public
//   math, NO measured LUT (no Mixbox). They are tuned (by grid search against the
//   canonical artist-mix targets) so subtractive mixing behaves correctly. The
//   load-bearing choice is the BLUE basis modeled on ultramarine: a blue hump
//   PLUS a green shoulder (→ blue+yellow reads GREEN, not teal) PLUS a small
//   red-end bump (→ blue+red is a true VIOLET, not black). See basisCurve().
//
//   Mixing happens in SPECTRAL space via single-constant Kubelka-Munk:
//       KS(R) = (1-R)²/2R ;  mix KS by weight ;  invert back to R.
//   Then spectrum → XYZ (D65) → linear sRGB → sRGB.
//
//   ENDPOINT-EXACT correction: the smooth-basis upsampling is metameric and
//   can't reproduce saturated primaries exactly (they're outside the smooth-
//   reflectance gamut). mixPaint() adds back each endpoint's own round-trip
//   error, faded by mix weight, so unmixed/endpoint colors are EXACT (round-trip
//   Δ = 0) and the blend stays faithful to the picked colors. See mixPaint().
//
//   GPU note: per-pixel cost is ~7-term basis sum (fixed) + 36-band KM. Cheaper
//   still: precompute each input color's (K/S) spectrum once on CPU and pass two
//   36-float arrays to the shader → the fragment shader is just a per-band lerp +
//   KM invert + a 3×36 spectrum→sRGB matmul. Easily real-time; LUT-able too.

// ---- sRGB <-> linear ----
func sToL(_ c: Double) -> Double { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4) }
func lToS(_ c: Double) -> Double { let x = max(0,min(1,c)); return x <= 0.0031308 ? x*12.92 : 1.055*pow(x,1/2.4)-0.055 }
func sToL(_ c:[Double])->[Double]{ c.map(sToL) }
func lToS(_ c:[Double])->[Double]{ c.map(lToS) }

// ---- bands ----
let NB = 36
let WL: [Double] = (0..<NB).map { (i:Int) -> Double in
    let step: Double = (700.0 - 400.0) / Double(NB - 1)
    return 400.0 + Double(i) * step
}  // 400–700, 36 bands

// ---- Wyman 2013 analytic CIE 1931 CMF approximation ----
func gauss1(_ x:Double,_ mu:Double,_ s1:Double,_ s2:Double)->Double{ let t=(x-mu)*(x<mu ? 1/s1 : 1/s2); return exp(-0.5*t*t) }
func xbar(_ l:Double)->Double{ 1.056*gauss1(l,599.8,37.9,31.0)+0.362*gauss1(l,442.0,16.0,26.7)-0.065*gauss1(l,501.1,20.4,26.2) }
func ybar(_ l:Double)->Double{ 0.821*gauss1(l,568.8,46.9,40.5)+0.286*gauss1(l,530.9,16.3,31.1) }
func zbar(_ l:Double)->Double{ 1.217*gauss1(l,437.0,11.8,36.0)+0.681*gauss1(l,459.0,26.0,13.8) }

// ---- D65 relative spectral power (CIE, interpolated coarsely but fine here) ----
// Use a smooth analytic approximation good enough for swatch work.
func d65(_ l:Double)->Double{
    // Normalized-ish daylight curve; mild blue weighting. (Approx, smooth.)
    let a = 100.0 * exp(-0.5*pow((l-470)/260, 2))      // broad
    let b = 12.0 * exp(-0.5*pow((l-600)/90, 2))
    return a + b
}
let ILL = WL.map { d65($0) }

// precompute CMF samples and normalization
let XB = WL.map(xbar), YB = WL.map(ybar), ZB = WL.map(zbar)
let Knorm: Double = {
    var s = 0.0; for i in 0..<NB { s += ILL[i]*YB[i] }; return s
}()

func spectrumToXYZ(_ R:[Double]) -> (Double,Double,Double) {
    var X=0.0,Y=0.0,Z=0.0
    for i in 0..<NB { let e = ILL[i]*R[i]; X += e*XB[i]; Y += e*YB[i]; Z += e*ZB[i] }
    return (X/Knorm, Y/Knorm, Z/Knorm)
}
func spectrumToLinearRGB(_ R:[Double]) -> [Double] {
    let (X,Y,Z) = spectrumToXYZ(R)
    let r =  3.2406*X - 1.5372*Y - 0.4986*Z
    let g = -0.9689*X + 1.8758*Y + 0.0415*Z
    let b =  0.0557*X - 0.2040*Y + 1.0570*Z
    return [r,g,b]
}
func spectrumToSRGB(_ R:[Double]) -> [Double] { lToS(spectrumToLinearRGB(R)) }

// ── RGB → spectrum: smooth least-squares reflectance reconstruction ──────────
//
// ── Mallett–Yuksel-style basis decomposition ─────────────────────────────────
// Seven smooth basis reflectance spectra that span the sRGB gamut. Any linear-
// sRGB color is decomposed (the MY residual / sorted-channel method) into
// non-negative weights on {white, cyan, magenta, yellow, red, green, blue};
// the spectrum is Σ wᵢ·basisᵢ. The basis SHAPES are the tuning knobs that decide
// subtractive (Kubelka-Munk) mix behavior. They are smooth analytic curves
// shaped like real pigment reflectance — public math, no measured LUT.

let EPS = 0.004
func clampSpec(_ v:Double)->Double{ max(EPS, min(1.0, v)) }

func sig(_ x:Double)->Double{ 1/(1+exp(-x)) }
func bump(_ l:Double,_ mu:Double,_ w:Double)->Double{ exp(-0.5*pow((l-mu)/w,2)) }

// Tunable blue-basis knobs (the Pareto surface: a bigger green shoulder makes
// blue+yellow greener but tints blue+white teal; red bump → blue+red violet).
var BLUE_SHOULDER_AMP = 0.45
var BLUE_SHOULDER_W   = 28.0
var BLUE_RED_AMP      = 0.30

func basisCurve(_ name:String)->[Double]{
    WL.map { l -> Double in
        switch name {
        case "white":   return clampSpec(0.985)
        // secondaries — broad two-region reflectors (round-trip the bright secondaries)
        case "cyan":    return clampSpec(0.02 + 0.96*sig((555 - l)/20))
        case "magenta": return clampSpec(0.02 + 0.96*(sig((465 - l)/18) + sig((l-595)/18)))
        case "yellow":  return clampSpec(0.02 + 0.96*sig((l - 520)/16))    // green shoulder (yon=520)
        // primaries — tuned for subtractive (Kubelka-Munk) behavior:
        case "red":     return clampSpec(0.02 + 0.96*sig((l - 595)/10))    // steep red edge → red looks red, tints pink
        case "green":   return clampSpec(0.02 + 0.96*bump(l,540,42))
        // BLUE ~ ultramarine: main hump 458 (looks blue) + green shoulder 520
        // (blue+yellow→green) + red-end bump 660 (blue+red→violet) + deep-blue roll-off.
        case "blue":    return clampSpec(0.02 + 0.96*(bump(l,458,32) + BLUE_SHOULDER_AMP*bump(l,520,BLUE_SHOULDER_W) + BLUE_RED_AMP*bump(l,660,30)) * sig((l-415)/12))
        default: return 0.5
        }
    }
}
let bNames = ["white","cyan","magenta","yellow","red","green","blue"]
var bSpec: [String:[Double]] = [:]
func rebuildBasis(){ bSpec = Dictionary(uniqueKeysWithValues: bNames.map { ($0, basisCurve($0)) }) }
rebuildBasis()

func upsample(_ lin:[Double]) -> [Double] {
    let r = max(0, lin[0]), g = max(0, lin[1]), b = max(0, lin[2])
    var w = [String:Double](); for n in bNames { w[n] = 0 }
    let mn = min(r, min(g, b))
    w["white"]! += mn
    let rr = r - mn, gg = g - mn, bb = b - mn   // one is ~0
    if rr <= gg && rr <= bb {            // red ~0 → cyan + (green|blue)
        w["cyan"]! += min(gg, bb)
        if gg > bb { w["green"]! += gg - bb } else { w["blue"]! += bb - gg }
    } else if gg <= rr && gg <= bb {     // green ~0 → magenta + (red|blue)
        w["magenta"]! += min(rr, bb)
        if rr > bb { w["red"]! += rr - bb } else { w["blue"]! += bb - rr }
    } else {                             // blue ~0 → yellow + (red|green)
        w["yellow"]! += min(rr, gg)
        if rr > gg { w["red"]! += rr - gg } else { w["green"]! += gg - rr }
    }
    var spec = [Double](repeating: 0, count: NB)
    for n in bNames { let wt = w[n]!; if wt <= 0 { continue }; let bs = bSpec[n]!; for i in 0..<NB { spec[i] += wt*bs[i] } }
    for i in 0..<NB { spec[i] = clampSpec(spec[i]) }
    return spec
}

func sRGBtoSpectrum(_ srgb:[Double]) -> [Double] { upsample(sToL(srgb)) }

// ── single-constant KM ───────────────────────────────────────────────────────
func ksFromR(_ R: Double) -> Double { let r = max(1e-4, min(1.0-1e-6, R)); return (1-r)*(1-r)/(2*r) }
func rFromKS(_ ks: Double) -> Double { max(0,min(1, 1 + ks - sqrt(ks*ks + 2*ks))) }

func mixSpectral(_ sa:[Double], _ sb:[Double], _ t:Double) -> [Double] {
    (0..<NB).map { i -> Double in
        let ks = ksFromR(sa[i])*(1-t) + ksFromR(sb[i])*t
        return rFromKS(ks)
    }
}

// Full pipeline: two sRGB colors → spectra → KM mix → sRGB, with endpoint-exact
// residual correction.
//
// The spectral upsampling is metameric: a saturated color's smooth-basis
// reconstruction doesn't render back to the exact input (out-of-gamut for smooth
// reflectance). Mixing happens in spectral space (correct subtractive behavior),
// but we then add back each endpoint's own round-trip error, faded by mix weight,
// so the result is EXACT at t=0/t=1 (perfect round-trip for unmixed colors) and
// stays faithful to the picked endpoint colors through the blend. This is the
// standard "residual passthrough" trick — it costs nothing extra and removes the
// upsampler's gamut error from the user-visible result.
func mixPaint(_ a:[Double], _ b:[Double], _ t:Double) -> [Double] {
    let specA = sRGBtoSpectrum(a), specB = sRGBtoSpectrum(b)
    let mixSRGB = spectrumToSRGB(mixSpectral(specA, specB, t))   // linear? -> sRGB already
    // round-trip renders of each endpoint
    let aRT = spectrumToSRGB(specA), bRT = spectrumToSRGB(specB)
    // residual correction in LINEAR light (avoids gamma artifacts), faded by weight
    let lMix = sToL(mixSRGB)
    let lA = sToL(a), lAR = sToL(aRT), lB = sToL(b), lBR = sToL(bRT)
    let out = (0..<3).map { i -> Double in
        lMix[i] + (1-t)*(lA[i]-lAR[i]) + t*(lB[i]-lBR[i])
    }
    return lToS(out)
}

// ── Round-trip test (uses mixPaint with itself → must be exact) ──────────────
func roundTrip(_ srgb:[Double]) -> [Double] { spectrumToSRGB(sRGBtoSpectrum(srgb)) }

let rtTest: [[Double]] = [
    [1,0,0],[0,1,0],[0,0,1],[1,1,0],[0,1,1],[1,0,1],
    [1,1,1],[0,0,0],[0.5,0.5,0.5],[0.2,0.4,0.8],[0.9,0.6,0.1],
    [0.7,0.2,0.5],[0.1,0.5,0.3],[0.96,0.86,0.12],[0.12,0.22,0.78],
    [0.85,0.10,0.10],[0.10,0.65,0.20],[0.3,0.3,0.3],[0.8,0.8,0.8],
]
var rtMax = 0.0, rtSum = 0.0; var rtCount = 0
var mpMax = 0.0, mpSum = 0.0
print("=== Round-trip error (0–255) ===")
print("  col1 = RAW upsampler (spectrum→sRGB)   col2 = user-facing mixPaint(x,x,t) endpoint")
for c in rtTest {
    let o = roundTrip(c)
    let em = (0..<3).map { abs(o[$0]-c[$0])*255 }.max()!
    rtMax = max(rtMax, em); rtSum += em; rtCount += 1
    // user-facing: mix a color with itself (or with anything at t=0) must be exact
    let mp = mixPaint(c, [0,0,0], 0.0)   // t=0 → must equal c exactly
    let mpe = (0..<3).map { abs(mp[$0]-c[$0])*255 }.max()!
    mpMax = max(mpMax, mpe); mpSum += mpe
    print(String(format: "  in (%3d,%3d,%3d)  rawΔ=%5.1f   mixPaintΔ=%4.2f",
        Int(c[0]*255),Int(c[1]*255),Int(c[2]*255), em, mpe))
}
print(String(format: "  >>> RAW upsampler:  maxΔ=%.1f  meanΔ=%.1f", rtMax, rtSum/Double(rtCount)))
print(String(format: "  >>> mixPaint endpoints (what the user sees): maxΔ=%.2f  meanΔ=%.2f", mpMax, mpSum/Double(rtCount)))
print("      (saturated primaries are out-of-gamut for smooth reflectance, so RAW")
print("       error is large there by nature; the endpoint-residual correction in")
print("       mixPaint makes unmixed/endpoint colors EXACT — that's the user-facing number.)\n")

// ── Pareto sweep: blue green-shoulder amplitude ──────────────────────────────
// blue+yellow wants G dominant & bright; blue+white wants B dominant (not teal);
// red+blue wants R&B > G (violet). Find the shoulder amp that balances them.
let blue = [0.10,0.20,0.80], yellow = [0.98,0.86,0.10], red = [0.88,0.10,0.10], white = [1.0,1.0,1.0]
print("=== Blue green-shoulder sweep (50/50 mixes) ===")
print("  amp | blue+yellow      | blue+white       | red+blue")
for amp in [0.20, 0.25, 0.30, 0.35, 0.40, 0.45] {
    BLUE_SHOULDER_AMP = amp; rebuildBasis()
    let by = mixPaint(blue, yellow, 0.5), bw = mixPaint(blue, white, 0.5), rb = mixPaint(red, blue, 0.5)
    func f(_ c:[Double])->String{ String(format:"(%3d,%3d,%3d)", Int(c[0]*255+0.5),Int(c[1]*255+0.5),Int(c[2]*255+0.5)) }
    print(String(format: "  %.2f | %@ | %@ | %@", amp, f(by), f(bw), f(rb)))
}
// Lock the chosen value (set after reviewing the sweep), then rebuild.
BLUE_SHOULDER_AMP = 0.32; BLUE_SHOULDER_W = 26.0; BLUE_RED_AMP = 0.32
rebuildBasis()
print(String(format: "  >>> locked amp=%.2f width=%.0f redAmp=%.2f\n", BLUE_SHOULDER_AMP, BLUE_SHOULDER_W, BLUE_RED_AMP))

// ── Canonical pairs ──────────────────────────────────────────────────────────
struct Pair { let label:String; let a:[Double]; let b:[Double]; let want:String }
let W = [1.0,1.0,1.0], BLK = [0.0,0.0,0.0]
let pairs: [Pair] = [
    Pair(label:"Blue + Yellow",    a:[0.10,0.20,0.80], b:[0.98,0.86,0.10], want:"GREEN"),
    Pair(label:"Yellow + Red",     a:[0.98,0.86,0.10], b:[0.88,0.10,0.10], want:"orange"),
    Pair(label:"Red + Blue",       a:[0.88,0.10,0.10], b:[0.10,0.20,0.80], want:"purple/violet"),
    Pair(label:"Cyan + Yellow",    a:[0.00,0.70,0.85], b:[0.98,0.86,0.10], want:"green"),
    Pair(label:"Magenta + Yellow", a:[0.90,0.05,0.55], b:[0.98,0.86,0.10], want:"red/orange"),
    Pair(label:"Cyan + Magenta",   a:[0.00,0.70,0.85], b:[0.90,0.05,0.55], want:"blue"),
    Pair(label:"Blue + White",     a:[0.10,0.20,0.80], b:W,                want:"light blue"),
    Pair(label:"Red + White",      a:[0.88,0.10,0.10], b:W,                want:"pink tint"),
    Pair(label:"Green + Black",    a:[0.10,0.65,0.20], b:BLK,              want:"dark green"),
    Pair(label:"Red + Green",      a:[0.88,0.10,0.10], b:[0.10,0.65,0.20], want:"muted brown"),
    Pair(label:"Blue + Blue",      a:[0.10,0.20,0.80], b:[0.10,0.20,0.80], want:"identity"),
]

func fmt(_ c:[Double])->String{ String(format:"(%3d,%3d,%3d)", Int(c[0]*255+0.5),Int(c[1]*255+0.5),Int(c[2]*255+0.5)) }
print("=== 50/50 mixes (sRGB 0–255) ===")
func pad(_ s:String,_ n:Int)->String{ s.count >= n ? s : s + String(repeating:" ", count: n - s.count) }
for p in pairs {
    let m = mixPaint(p.a, p.b, 0.5)
    print("  " + pad(p.label,16) + " want " + pad(p.want,14) + " → " + fmt(m))
}

// ── Render swatch grid: A | ramp(0.25,0.5,0.75) | B  =  5 cols A→B ────────────
let ramp: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
let colLabels = ["A","25%","50%","75%","B"]
let cell = 96, head = 34, labelW = 168, pad = 4
let GW = labelW + ramp.count*cell
let GH = head + pairs.count*cell
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data:nil, width:GW, height:GH, bitsPerComponent:8, bytesPerRow:0, space:cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(srgbRed:1,green:1,blue:1,alpha:1)); ctx.fill(CGRect(x:0,y:0,width:GW,height:GH))
let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.current = ns
func text(_ s:String,_ x:Int,_ y:Int,_ size:CGFloat,_ bold:Bool=false){
    let f = bold ? NSFont.boldSystemFont(ofSize:size) : NSFont.systemFont(ofSize:size)
    (s as NSString).draw(at: NSPoint(x:x,y:GH-y-Int(size)-2),
        withAttributes:[.font:f,.foregroundColor:NSColor.black])
}
func swatch(_ rgb:[Double],_ col:Int,_ row:Int){
    let x = labelW + col*cell, y = head + row*cell
    ctx.setFillColor(CGColor(srgbRed:CGFloat(max(0,min(1,rgb[0]))),green:CGFloat(max(0,min(1,rgb[1]))),blue:CGFloat(max(0,min(1,rgb[2]))),alpha:1))
    ctx.fill(CGRect(x:x+pad,y:GH-(y+cell)+pad,width:cell-2*pad,height:cell-2*pad))
}
for (c,name) in colLabels.enumerated(){ text(name, labelW + c*cell + 8, 8, 13, true) }
for (r,p) in pairs.enumerated(){
    text(p.label, 6, head + r*cell + cell/2 - 14, 11)
    text("→"+p.want, 6, head + r*cell + cell/2 + 2, 9)
    for (k,t) in ramp.enumerated() {
        swatch(mixPaint(p.a, p.b, t), k, r)
    }
}
NSGraphicsContext.current = nil
let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
let png = rep.representation(using:.png, properties:[:])!
let outPath = "/tmp/km_swatches_final.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("\nWrote \(outPath)")

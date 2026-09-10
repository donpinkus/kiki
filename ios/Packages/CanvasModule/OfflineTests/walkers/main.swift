// Stroke-walk invariants (2026-09-10). Compiled with the BrushHarness file list (needs
// CanvasRenderer.StampInstance — Metal compiles on macOS, no GPU is touched):
//
//   cd ios/Packages/CanvasModule/OfflineTests
//   S=../Sources/CanvasModule
//   swiftc -O -D BRUSH_HARNESS $S/DrawingEngine.swift $S/BrushDynamics.swift \
//     $S/BrushShapeCatalog.swift $S/BrushPresets.swift $S/WetKM.swift $S/BrushFixture.swift \
//     $S/StrokeStabilizer.swift $S/StrokeStampGenerator.swift $S/StampClip.swift \
//     $S/EraserStrokeWalker.swift $S/WetStrokeWalker.swift $S/LightnessMap.swift \
//     $S/CanvasRenderer.swift walkers/main.swift -o /tmp/walkertest && /tmp/walkertest
//
// Asserts:
//   1. incremental == full: a DryStrokeWalker advanced one point at a time then finished
//      produces byte-identical stamps to StrokeStampGenerator.stamps(for:) — for every
//      curated preset and the synthetic dynamics brushes (the live preview IS the
//      committed stroke).
//   2. scale invariance: walking a view-space stroke at `scale` equals walking the
//      canvas-space stroke at 1 (positions/radius × scale, same count/colors) — the
//      BrushHarness replays what the iPad drew, on any iPad.
//   3. eraser walker: batch invariance, first dab at touch-down, no starvation on a
//      tight scribble, width-pullback never opens a gap wider than its own spacing.
//   4. wet walker batch invariance on a blank canvas.
//   5. StampClip bitmap agrees with CGPath.contains(evenOdd) away from the edge.
import Foundation
import CoreGraphics
import simd

var failures = 0
func checkBool(_ name: String, _ ok: Bool, _ detail: String = "") {
    if ok { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)  \(detail)") }
}

typealias Stamp = CanvasRenderer.StampInstance

func pt(_ x: CGFloat, _ y: CGFloat, force: CGFloat, t: TimeInterval, altitude: CGFloat = .pi / 2,
        azimuth: CGFloat = 0) -> StrokePoint {
    StrokePoint(position: CGPoint(x: x, y: y), force: force, altitude: altitude, timestamp: t,
                azimuth: azimuth)
}

/// A wavy stroke with a pressure bell, ~120 Hz samples.
func waveStroke(brush: BrushConfig, points n: Int = 240, length: CGFloat = 600, amp: CGFloat = 40,
                seed: UUID = UUID(uuidString: "0BADCAFE-0000-4000-8000-000000000001")!) -> Stroke {
    var pts: [StrokePoint] = []
    for i in 0..<n {
        let u = CGFloat(i) / CGFloat(n - 1)
        let x = 100 + u * length
        let y = 300 + sin(u * 6 * .pi) * amp
        let f = 0.15 + 0.85 * sin(u * .pi)
        let alt = .pi / 2 - u * 0.6
        pts.append(pt(x, y, force: f, t: TimeInterval(i) / 120, altitude: alt, azimuth: u * 5))
    }
    return Stroke(id: seed, points: pts, brush: brush)
}

/// A scribble that never leaves a 6-pt circle (the starvation case).
func scribble(brush: BrushConfig, points n: Int = 200) -> Stroke {
    var pts: [StrokePoint] = []
    for i in 0..<n {
        let a = CGFloat(i) * 0.9
        pts.append(pt(200 + cos(a) * 3, 200 + sin(a * 1.3) * 3, force: 0.6, t: TimeInterval(i) / 120))
    }
    return Stroke(id: UUID(uuidString: "0BADCAFE-0000-4000-8000-000000000002")!, points: pts, brush: brush)
}

func same(_ a: Stamp, _ b: Stamp, tol: Float = 0) -> Bool {
    func eq(_ x: Float, _ y: Float) -> Bool { tol == 0 ? x == y : abs(x - y) <= tol * max(1, abs(x), abs(y)) }
    return eq(a.center.x, b.center.x) && eq(a.center.y, b.center.y) && eq(a.radius, b.radius)
        && eq(a.rotation, b.rotation) && eq(a.color.x, b.color.x) && eq(a.color.y, b.color.y)
        && eq(a.color.z, b.color.z) && eq(a.color.w, b.color.w) && eq(a.hardness, b.hardness)
        && eq(a.aspect, b.aspect) && eq(a.arcU, b.arcU) && eq(a.grainMul, b.grainMul)
        && a.edgeFlat == b.edgeFlat && eq(a.wetTargetAlpha, b.wetTargetAlpha)
}

func sameList(_ a: [Stamp], _ b: [Stamp], tol: Float = 0) -> (Bool, String) {
    guard a.count == b.count else { return (false, "count \(a.count) vs \(b.count)") }
    for i in 0..<a.count where !same(a[i], b[i], tol: tol) {
        return (false, "stamp \(i): \(a[i]) vs \(b[i])")
    }
    return (true, "")
}

func canvasSpace(_ stroke: Stroke, scale: CGFloat) -> Stroke {
    var brush = stroke.brush
    brush.baseWidth *= scale
    let points = stroke.points.map { p -> StrokePoint in
        var q = p
        q.position = CGPoint(x: p.position.x * scale, y: p.position.y * scale)
        return q
    }
    return Stroke(id: stroke.id, points: points, brush: brush)
}

// Brush battery: every curated preset + synthetic knob combos.
var battery: [(String, BrushConfig)] = CuratedPresetCatalog.all.map {
    ($0.displayName, $0.configure(BrushConfig(color: .black, baseWidth: 16)))
}
do {
    var b = BrushConfig(color: .black, baseWidth: 24)
    b.taper = 0.4; b.taperOpacity = 0.5; battery.append(("taper", b))
    var f = BrushConfig(color: .black, baseWidth: 12); f.fallOff = 0.5; battery.append(("fallOff", f))
    var j = BrushConfig(color: .black, baseWidth: 8); j.spacingJitter = 0.6; j.stampCount = 4
    j.stampCountJitter = 0.5; j.rotationJitter = 0.3; battery.append(("jitter+count", j))
    var s = BrushConfig(color: .black, baseWidth: 40); s.spacing = 0.1; s.flow = 0.4
    s.hardness = 0.2; battery.append(("smooth-big-soft", s))
    for p in BrushPresetCatalog.all {
        var c = BrushConfig(color: .black, baseWidth: 16); c.dynamics = p.dynamics
        battery.append(("dyn:" + p.name, c))
    }
}

// --- 1. incremental == full ---
for (name, brush) in battery {
    let stroke = waveStroke(brush: brush)
    let full = StrokeStampGenerator.stamps(for: stroke, scale: 2.16)
    // Finalization-informed walker (knows totalArc) advanced one point at a time.
    var w = DryStrokeWalker(stroke: stroke, scale: 2.16, clip: nil)
    for k in 1...stroke.points.count {
        w.advance(Stroke(id: stroke.id, points: Array(stroke.points.prefix(k)), brush: brush))
    }
    let inc = w.finish(stroke)
    let (ok, why) = sameList(full, inc)
    checkBool("incremental == full [\(name)]", ok, why)
    // Live walker (built from the first point) matches whenever there is no taper.
    let hasTaper = max(brush.taper, brush.taperStart) > 0 || max(brush.taper, brush.taperEnd) > 0
    if !hasTaper {
        var live = DryStrokeWalker(stroke: Stroke(id: stroke.id, points: [stroke.points[0]], brush: brush),
                                   scale: 2.16, clip: nil)
        for k in 1...stroke.points.count {
            live.advance(Stroke(id: stroke.id, points: Array(stroke.points.prefix(k)), brush: brush))
        }
        let preview = live.previewStamps()
        let (okp, whyp) = sameList(Array(full.prefix(preview.count)), preview)
        // The finish adds only the end cap (× Count copies).
        let capMax = max(1, min(brush.stampCount, 16))
        checkBool("live preview is a prefix of full [\(name)]", okp && preview.count >= full.count - capMax, whyp + " \(preview.count)/\(full.count)")
        let (okf, whyf) = sameList(full, live.finish(stroke))
        checkBool("live walker finish == full [\(name)]", okf, whyf)
    }
    checkBool("all stamps finite [\(name)]", full.allSatisfy {
        $0.center.x.isFinite && $0.center.y.isFinite && $0.radius.isFinite && $0.color.w.isFinite
            && $0.color.w >= 0 && $0.color.w <= 1.0001 && $0.color.x <= $0.color.w + 1e-5
    })
}

// --- 2. scale invariance ---
for (name, brush) in battery {
    let scale: CGFloat = 2.16
    let view = waveStroke(brush: brush)
    let a = StrokeStampGenerator.stamps(for: view, scale: scale)
    let b = StrokeStampGenerator.stamps(for: canvasSpace(view, scale: scale), scale: 1)
    let (ok, why) = sameList(a, b, tol: 2e-3)
    checkBool("scale invariance [\(name)]", ok, why)
}

// --- 3. eraser walker ---
do {
    let brush = BrushConfig(color: .black, baseWidth: 40, pressureGamma: 0.7)
    let stroke = waveStroke(brush: brush)
    var whole = EraserStrokeWalker(brush: brush, scale: 2)
    let all = whole.advance(stroke: stroke, scale: 2, clip: nil)
    var batched = EraserStrokeWalker(brush: brush, scale: 2)
    var acc: [Stamp] = []
    for k in 1...stroke.points.count {
        acc += batched.advance(stroke: Stroke(id: stroke.id, points: Array(stroke.points.prefix(k)), brush: brush),
                               scale: 2, clip: nil)
    }
    let (ok, why) = sameList(all, acc)
    checkBool("eraser batch invariance", ok, why)
    checkBool("eraser first dab at touch-down", all.first.map {
        abs($0.center.x - Float(stroke.points[0].position.x * 2)) < 1e-3 } ?? false)
    // Gap between consecutive dabs never exceeds the larger dab's own spacing (+ε).
    var maxRatio: Float = 0
    for i in 1..<all.count {
        let d = simd_distance(all[i].center, all[i - 1].center)
        let own = max(all[i].radius, all[i - 1].radius) * 2 * Float(EraserStrokeWalker.spacingFraction)
        maxRatio = max(maxRatio, d / max(own, 1))
    }
    checkBool("eraser gaps ≤ own spacing", maxRatio <= 1.02, "max ratio \(maxRatio)")
    var scrub = EraserStrokeWalker(brush: brush, scale: 2)
    let n = scrub.advance(stroke: scribble(brush: brush), scale: 2, clip: nil).count
    checkBool("eraser scribble inside one gap still deposits", n > 5, "dabs \(n)")
    // Single-point stroke (a tap) erases one dot.
    var tap = EraserStrokeWalker(brush: brush, scale: 2)
    let one = Stroke(points: [stroke.points[0]], brush: brush)
    checkBool("eraser tap deposits one dab", tap.advance(stroke: one, scale: 2, clip: nil).count == 1)
}

// --- 4. wet walker batch invariance (blank canvas) ---
do {
    var brush = BrushConfig(color: .black, baseWidth: 30)
    brush.wetEnabled = true; brush.wetStrength = 0.7; brush.wetCharge = 0.5
    let stroke = waveStroke(brush: brush)
    let blank: (Int, Int) -> (color: SIMD3<Float>, alpha: Float)? = { _, _ in nil }
    let blankAvg: (Int, Int, Int) -> (color: SIMD3<Float>, alpha: Float)? = { _, _, _ in nil }
    let mix: (SIMD3<Float>, SIMD3<Float>, Float) -> SIMD3<Float> = { a, b, t in a + (b - a) * t }
    var whole = WetStrokeWalker(startPosition: stroke.points[0].position, brush: brush, scale: 2)
    let all = whole.advance(stroke: stroke, scale: 2, clip: nil, sample: blank, sampleAveraged: blankAvg, mix: mix)
    var batched = WetStrokeWalker(startPosition: stroke.points[0].position, brush: brush, scale: 2)
    var acc: [Stamp] = []
    for k in 1...stroke.points.count {
        acc += batched.advance(stroke: Stroke(id: stroke.id, points: Array(stroke.points.prefix(k)), brush: brush),
                               scale: 2, clip: nil, sample: blank, sampleAveraged: blankAvg, mix: mix)
    }
    let (ok, why) = sameList(all, acc)
    checkBool("wet batch invariance", ok, why)
    // Charge decays in document px: at scale 2 the same view stroke covers 2× the px.
    checkBool("wet charge decays along the stroke", all.last!.wetTargetAlpha < all.first!.wetTargetAlpha)
}

// --- 5. StampClip vs CGPath ---
do {
    let space = CGSize(width: 900, height: 900)
    let path = CGMutablePath()
    path.addEllipse(in: CGRect(x: 100, y: 100, width: 500, height: 400))
    path.addRect(CGRect(x: 200, y: 200, width: 100, height: 100)) // even-odd hole
    let clip = StampClip(path: path, space: space, side: 2048)!
    var agree = 0, total = 0
    var rng = SystemRandomNumberGenerator()
    for _ in 0..<20000 {
        let p = CGPoint(x: CGFloat.random(in: 0..<900, using: &rng), y: CGFloat.random(in: 0..<900, using: &rng))
        let want = path.contains(p, using: .evenOdd)
        // Skip the 1-px band around the edge where the raster rounds.
        var nearEdge = false
        for d in [CGPoint(x: 1, y: 0), CGPoint(x: -1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 0, y: -1)] {
            if path.contains(CGPoint(x: p.x + d.x, y: p.y + d.y), using: .evenOdd) != want { nearEdge = true }
        }
        if nearEdge { continue }
        total += 1
        if clip.contains(p) == want { agree += 1 }
    }
    checkBool("StampClip agrees with CGPath.contains (even-odd, hole)", agree == total, "\(agree)/\(total)")
    checkBool("StampClip outside the space is outside", !clip.contains(CGPoint(x: -5, y: 50)) && !clip.contains(CGPoint(x: 950, y: 50)))
    // Clipped walk drops exactly the outside dabs.
    let brush = BrushConfig(color: .black, baseWidth: 10)
    let stroke = waveStroke(brush: brush)
    let clipped = StrokeStampGenerator.stamps(for: stroke, scale: 1, clip: clip)
    let open = StrokeStampGenerator.stamps(for: stroke, scale: 1)
    let inside = open.filter { path.contains(CGPoint(x: CGFloat($0.center.x), y: CGFloat($0.center.y)), using: .evenOdd) }
    checkBool("clipped walk ≈ inside dabs", abs(clipped.count - inside.count) <= 3, "\(clipped.count) vs \(inside.count) of \(open.count)")
}

print("")
if failures == 0 { print("ALL PASSED") } else { print("\(failures) FAILED"); exit(1) }

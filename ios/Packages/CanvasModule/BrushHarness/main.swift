import Foundation
import CoreGraphics
import ImageIO
import Metal

// BrushHarness — headless brush/color-mixing evaluation on macOS.
//
// Runs the REAL shipped engine (CanvasRenderer + StrokeStampGenerator + WetStrokeWalker,
// compiled from Sources/ — see README.md) against synthetic strokes and recorded fixtures,
// and writes PNGs for visual evaluation. Apple-silicon Macs share the iPad's GPU family,
// so framebuffer fetch works and the WET brush renders here (unlike the iOS Simulator).
//
// Usage:
//   brushharness [--out <dir>] [--filter <substring>] [--fixtures <file-or-dir> ...]
//
// Determinism: synthetic strokes use FIXED UUIDs (the stroke id seeds scatter/jitter),
// and wet batches drain the GPU queue between advances, so identical runs produce
// identical PNGs (modulo GPU float rounding, which is stable on one machine).

// MARK: - Arguments

var outDir = "output"
var filter: String?
var fixturePaths: [String] = []
var argIdx = 1
let argv = CommandLine.arguments
while argIdx < argv.count {
    switch argv[argIdx] {
    case "--out": argIdx += 1; outDir = argv[argIdx]
    case "--filter": argIdx += 1; filter = argv[argIdx]
    case "--fixtures": argIdx += 1; fixturePaths.append(argv[argIdx])
    default: print("unknown arg \(argv[argIdx])"); exit(2)
    }
    argIdx += 1
}
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// MARK: - Helpers

/// Deterministic UUID from a small integer (stroke ids seed scatter/jitter).
func fixedUUID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}

func writePNG(_ image: CGImage, name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png")
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        print("FAIL  could not create \(url.path)"); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { print("FAIL  finalize \(url.path)"); exit(1) }
    print("WROTE \(url.path)")
}

/// Synthesize a stroke along a line from `a` to `b` with an optional perpendicular
/// sine bow (`bow`, in px), a force profile over t∈[0,1], and 120 Hz timestamps.
/// Positions are in CANVAS PIXELS (the harness renders at scale 1, so brush
/// `baseWidth` is also pixels here — on device it's view points × canvasScale).
func synthStroke(id: Int, brush: BrushConfig, from a: CGPoint, to b: CGPoint,
                 bow: CGFloat = 0, points n: Int = 90,
                 force: @escaping (CGFloat) -> CGFloat = { _ in 0.5 },
                 altitude: CGFloat = .pi / 2) -> Stroke {
    let dx = b.x - a.x, dy = b.y - a.y
    let len = max(hypot(dx, dy), 1e-3)
    let (px, py) = (-dy / len, dx / len)   // unit perpendicular
    var pts: [StrokePoint] = []
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n - 1)
        let wobble = bow * sin(t * .pi * 2)
        pts.append(StrokePoint(
            position: CGPoint(x: a.x + dx * t + px * wobble, y: a.y + dy * t + py * wobble),
            force: max(0.02, min(1, force(t))),
            altitude: altitude,
            timestamp: TimeInterval(i) / 120.0))
    }
    return Stroke(id: fixedUUID(id), points: pts, brush: brush)
}

/// A stroke that loops (1.5 circle revolutions) so it crosses itself — shows the
/// flow-vs-opacity "Glaze" split (self-crossing sub-100% strokes must stay flat).
func loopStroke(id: Int, brush: BrushConfig, center: CGPoint, radius: CGFloat) -> Stroke {
    var pts: [StrokePoint] = []
    let n = 140
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(n - 1)
        let ang = t * .pi * 3    // 1.5 revolutions
        pts.append(StrokePoint(
            position: CGPoint(x: center.x + cos(ang) * radius, y: center.y + sin(ang) * radius),
            force: 0.6, altitude: .pi / 2, timestamp: TimeInterval(i) / 120.0))
    }
    return Stroke(id: fixedUUID(id), points: pts, brush: brush)
}

// MARK: - Scene runner

/// Paints strokes into a fresh document and writes the flattened result.
final class Scene {
    let renderer: CanvasRenderer
    let side: Int

    init?(side: Int = 1024) {
        guard let r = CanvasRenderer() else { return nil }
        r.configureDocument(side: side)
        self.renderer = r
        self.side = side
    }

    /// Route a stroke through the same pipeline the app uses: dry strokes through
    /// StrokeStampGenerator → commitStampsToCanvas (the persistence-replay path, which
    /// applies the flow/opacity split exactly like a live stroke's flatten); wet strokes
    /// through WetStrokeWalker → applyWetStamps in touchesMoved-sized batches.
    func paint(_ stroke: Stroke) {
        if stroke.brush.wetEnabled {
            guard renderer.isWetRenderingAvailable else {
                print("SKIP  wet stroke — framebuffer fetch unavailable on this device")
                return
            }
            guard let start = stroke.points.first?.position else { return }
            var walker = WetStrokeWalker(startPosition: start, brush: stroke.brush)
            // Feed points in 2-point batches to mimic per-touchesMoved incremental walks,
            // draining the queue between batches so the CPU pickup samples what the
            // device's ~8ms inter-batch gap would have let the GPU commit.
            var upTo = 1
            while upTo <= stroke.points.count {
                let prefix = Stroke(id: stroke.id,
                                    points: Array(stroke.points.prefix(upTo)),
                                    brush: stroke.brush)
                let stamps = walker.advance(
                    stroke: prefix, scale: 1, clipPath: nil,
                    sample: { [renderer] x, y in
                        let s = renderer.sampleLayerColor(x: x, y: y)
                        if ProcessInfo.processInfo.environment["HARNESS_DEBUG"] != nil {
                            print(String(format: "  emit-sample @(%d,%d) → %@ a=%.2f", x, y,
                                         s.map { String(format: "%.3f %.3f %.3f", $0.color.x, $0.color.y, $0.color.z) } ?? "nil",
                                         s?.alpha ?? -1))
                        }
                        return s
                    },
                    sampleAveraged: { [renderer] x, y in renderer.sampleLayerColorAveraged(x: x, y: y) },
                    mix: { [renderer] a, b, t in renderer.kmMixCPU(a, b, t) })
                if !stamps.isEmpty {
                    renderer.applyWetStamps(stamps)
                    renderer.waitUntilQueueDrained()
                    if ProcessInfo.processInfo.environment["HARNESS_DEBUG"] != nil {
                        let p = stroke.points[upTo - 1].position
                        let s = renderer.sampleLayerColor(x: Int(p.x), y: Int(p.y))
                        print(String(format: "  load %.3f %.3f %.3f | under %@ a=%.2f @x=%.0f",
                                     walker.load.x, walker.load.y, walker.load.z,
                                     s.map { String(format: "%.3f %.3f %.3f", $0.color.x, $0.color.y, $0.color.z) } ?? "nil",
                                     s?.alpha ?? -1, p.x))
                    }
                }
                if upTo == stroke.points.count { break }
                upTo = min(upTo + 2, stroke.points.count)
            }
        } else {
            let stamps = StrokeStampGenerator.stamps(for: stroke, scale: 1)
            renderer.commitStampsToCanvas(stamps,
                                          strokeOpacity: Float(stroke.brush.opacity),
                                          shapeTexture: renderer.shapeTexture(for: stroke.brush.shapeID))
        }
    }

    func snapshot(name: String) {
        renderer.waitUntilQueueDrained()
        guard let image = renderer.flattenedOpaqueCGImage(backgroundImage: nil) else {
            print("FAIL  no snapshot for \(name)"); exit(1)
        }
        writePNG(image, name: name)
    }
}

func runScene(_ name: String, _ body: (Scene) -> Void) {
    if let filter, !name.contains(filter) { return }
    guard let scene = Scene() else {
        print("FAIL  could not create Metal scene (no GPU?)"); exit(1)
    }
    body(scene)
    scene.snapshot(name: name)
}

// MARK: - Brush shorthands

func pen(_ color: CodableColor, width: CGFloat, opacity: CGFloat = 1, flow: CGFloat = 1,
         hardness: CGFloat = 0.5, taper: CGFloat = 0, shape: String? = nil,
         dynamics: BrushDynamics? = nil) -> BrushConfig {
    BrushConfig(color: color, baseWidth: width, opacity: opacity, flow: flow,
                hardness: hardness, taper: taper, shapeID: shape, dynamics: dynamics)
}

func wet(_ color: CodableColor, width: CGFloat, mix: CGFloat, smear: CGFloat,
         smudge: Bool = false) -> BrushConfig {
    BrushConfig(color: color, baseWidth: width, wetEnabled: true,
                wetStrength: mix, wetPickup: smear, wetSmudge: smudge)
}

let red = CodableColor(red: 0.86, green: 0.12, blue: 0.10)
let yellow = CodableColor(red: 0.95, green: 0.85, blue: 0.10)
let blue = CodableColor(red: 0.10, green: 0.20, blue: 0.85)
let teal = CodableColor(red: 0.05, green: 0.55, blue: 0.55)

// MARK: - Synthetic battery

runScene("dry-01-pressure") { s in
    s.paint(synthStroke(id: 1, brush: pen(.black, width: 34), from: CGPoint(x: 100, y: 200), to: CGPoint(x: 924, y: 200),
                        force: { $0 }))                                     // ramp 0→1
    s.paint(synthStroke(id: 2, brush: pen(.black, width: 34), from: CGPoint(x: 100, y: 420), to: CGPoint(x: 924, y: 420),
                        force: { sin($0 * .pi) }))                          // bell
    s.paint(synthStroke(id: 3, brush: pen(.black, width: 34, taper: 0.5), from: CGPoint(x: 100, y: 640), to: CGPoint(x: 924, y: 640),
                        bow: 60, force: { 0.4 + 0.5 * sin($0 * .pi * 4).magnitude }))  // wavy pulses + taper
    s.paint(synthStroke(id: 4, brush: pen(.black, width: 34, hardness: 0.0), from: CGPoint(x: 100, y: 840), to: CGPoint(x: 512, y: 840)))
    s.paint(synthStroke(id: 5, brush: pen(.black, width: 34, hardness: 1.0), from: CGPoint(x: 560, y: 840), to: CGPoint(x: 924, y: 840)))
}

runScene("dry-02-flow-vs-opacity") { s in
    // Self-crossing loops: flow builds within a stroke, opacity is the per-stroke ceiling.
    s.paint(loopStroke(id: 10, brush: pen(teal, width: 40, opacity: 1.0, flow: 0.25), center: CGPoint(x: 260, y: 400), radius: 150))
    s.paint(loopStroke(id: 11, brush: pen(teal, width: 40, opacity: 0.25, flow: 1.0), center: CGPoint(x: 700, y: 400), radius: 150))
    s.paint(synthStroke(id: 12, brush: pen(.black, width: 6), from: CGPoint(x: 100, y: 700), to: CGPoint(x: 924, y: 700)))
    // Overlapping single passes at flow 0.25 (should build up where they cross).
    s.paint(synthStroke(id: 13, brush: pen(teal, width: 40, flow: 0.25), from: CGPoint(x: 200, y: 780), to: CGPoint(x: 824, y: 780)))
    s.paint(synthStroke(id: 14, brush: pen(teal, width: 40, flow: 0.25), from: CGPoint(x: 512, y: 660), to: CGPoint(x: 512, y: 900)))
}

runScene("dry-03-dynamics") { s in
    let dyn = BrushDynamics(
        size: CurveOption(sensors: [SensorChannel(sensor: .pressure, curve: .gamma(2.0))], minValue: 0.15),
        scatter: CurveOption(sensors: [], strength: 0.55),
        colorJitter: ColorJitter(hue: 0.12, saturation: 0.3, brightness: 0.25))
    // Same brush, three stroke ids → three per-stroke jitters (deterministic per id).
    for (i, y) in [(20, CGFloat(250)), (21, 500), (22, 750)] {
        s.paint(synthStroke(id: i, brush: pen(red, width: 30, dynamics: dyn),
                            from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y),
                            bow: 40, force: { sin($0 * .pi) }))
    }
}

runScene("dry-04-shapes") { s in
    // Requires BRUSH_SHAPES_DIR (see README); without it, shaped strokes fall back to round.
    for (i, shape) in ["chalk", "charcoal", "drybrush", "pastel", "ink"].enumerated() {
        let y = CGFloat(150 + i * 180)
        s.paint(synthStroke(id: 30 + i, brush: pen(.black, width: 44, shape: shape),
                            from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y),
                            bow: 50, force: { 0.3 + 0.6 * $0 }))
    }
}

runScene("wet-01-blue-into-yellow") { s in
    // Yellow base patch (full-pressure passes so effectiveWidth == baseWidth — at the
    // default force 0.5 the rows shrink ~40% and leave white gaps), then a wet blue
    // stroke dragged through the patch: the trail should turn GREEN (spectral KM),
    // not gray/black (per-channel mixing).
    for i in 0..<3 {
        s.paint(synthStroke(id: 40 + i, brush: pen(yellow, width: 120),
                            from: CGPoint(x: 250, y: 370 + CGFloat(i) * 80),
                            to: CGPoint(x: 774, y: 370 + CGFloat(i) * 80),
                            force: { _ in 1 }))
    }
    s.paint(synthStroke(id: 45, brush: wet(blue, width: 60, mix: 0.65, smear: 0.5),
                        from: CGPoint(x: 150, y: 450), to: CGPoint(x: 874, y: 450)))
}

runScene("wet-02-smudge") { s in
    // Red + blue patches with a gap; a smudge (no new ink) dragged through both:
    // it should push red into the gap, then contaminate toward blue crossing the patch.
    for i in 0..<3 {
        s.paint(synthStroke(id: 50 + i, brush: pen(red, width: 110),
                            from: CGPoint(x: 140, y: 380 + CGFloat(i) * 80),
                            to: CGPoint(x: 420, y: 380 + CGFloat(i) * 80),
                            force: { _ in 1 }))
        s.paint(synthStroke(id: 55 + i, brush: pen(blue, width: 110),
                            from: CGPoint(x: 620, y: 380 + CGFloat(i) * 80),
                            to: CGPoint(x: 900, y: 380 + CGFloat(i) * 80),
                            force: { _ in 1 }))
    }
    s.paint(synthStroke(id: 59, brush: wet(.black, width: 70, mix: 0.6, smear: 0.85, smudge: true),
                        from: CGPoint(x: 200, y: 460), to: CGPoint(x: 860, y: 460)))
}

runScene("wet-03-mix-sweep") { s in
    // Wet blue over yellow at Mix 0.2 / 0.5 / 0.9 (same smear) — a tuning contact row.
    for (i, mixV) in [CGFloat(0.2), 0.5, 0.9].enumerated() {
        let y = CGFloat(220 + i * 280)
        s.paint(synthStroke(id: 60 + i, brush: pen(yellow, width: 110),
                            from: CGPoint(x: 180, y: y), to: CGPoint(x: 844, y: y),
                            force: { _ in 1 }))
        s.paint(synthStroke(id: 65 + i, brush: wet(blue, width: 55, mix: mixV, smear: 0.5),
                            from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y)))
    }
}

// MARK: - Fixture replay (recorded on iPad via Brush Studio → "Record strokes")
// `BrushFixture` is the module's shared contract type (Sources/CanvasModule/BrushFixture.swift).

func replayFixture(at url: URL) {
    let base = url.deletingPathExtension().lastPathComponent
    if let filter, !base.contains(filter) { return }
    guard let data = try? Data(contentsOf: url) else { print("FAIL  read \(url.path)"); return }
    let fixture: BrushFixture
    do { fixture = try JSONDecoder().decode(BrushFixture.self, from: data) } catch {
        print("FAIL  decode \(url.path): \(error)"); return
    }
    guard let scene = Scene(side: fixture.canvasSide ?? 2048) else { print("FAIL  Metal scene"); return }
    for stroke in fixture.strokes { scene.paint(stroke) }
    scene.snapshot(name: "fixture-\(fixture.name ?? base)")
}

for path in fixturePaths {
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
        print("FAIL  no such fixture path \(path)"); continue
    }
    if isDir.boolValue {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        for f in files.sorted() where f.hasSuffix(".json") {
            replayFixture(at: URL(fileURLWithPath: path).appendingPathComponent(f))
        }
    } else {
        replayFixture(at: URL(fileURLWithPath: path))
    }
}

print("DONE")

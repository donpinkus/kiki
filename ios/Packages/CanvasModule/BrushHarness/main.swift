import Foundation
import CoreGraphics
import CoreText
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

/// Burn row labels into a render so every thumbnail/side-by-side/progression is
/// self-documenting ("which stroke is which setting"). Gray Menlo text, drawn via
/// CoreText into an sRGB context (identity for the sRGB-tagged render — no color
/// shift on the paint pixels). Labels sit in the whitespace between rows, never on
/// the strokes. Deterministic like the rest of the render.
func annotate(_ image: CGImage, labels: [(x: CGFloat, y: CGFloat, text: String)]) -> CGImage {
    guard !labels.isEmpty else { return image }
    let w = image.width, h = image.height
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let font = CTFontCreateWithName("Menlo" as CFString, 19, nil)
    let color = CGColor(srgbRed: 0.44, green: 0.47, blue: 0.53, alpha: 1)
    for l in labels {
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let str = CFAttributedStringCreate(nil, l.text as CFString, attrs as CFDictionary)!
        let line = CTLineCreateWithAttributedString(str)
        // CG bitmap contexts are bottom-left origin; label coords are top-left canvas px.
        ctx.textPosition = CGPoint(x: l.x, y: CGFloat(h) - l.y)
        CTLineDraw(line, ctx)
    }
    return ctx.makeImage() ?? image
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

/// A stroke with deterministic hand-tremor: base path + per-point noise (±amp px),
/// seeded by brushHash01 so runs are identical. Simulates shaky raw pencil input.
func tremorStroke(id: Int, brush: BrushConfig, from a: CGPoint, to b: CGPoint,
                  bow: CGFloat = 0, amp: CGFloat = 6, points n: Int = 140) -> Stroke {
    var st = synthStroke(id: id, brush: brush, from: a, to: b, bow: bow, points: n, force: { _ in 0.7 })
    for i in st.points.indices {
        let nx = CGFloat(brushHash01(UInt64(id), UInt64(i), 0x7E01) - 0.5) * 2 * amp
        let ny = CGFloat(brushHash01(UInt64(id), UInt64(i), 0x7E02) - 0.5) * 2 * amp
        st.points[i].position.x += nx
        st.points[i].position.y += ny
    }
    return st
}

/// Run a stroke's points through the P3 StrokeStabilizer exactly like the device does
/// (feed per point + catch-up tail on lift), returning the stabilized stroke.
func stabilized(_ stroke: Stroke, streamline: CGFloat, stabilization: CGFloat) -> Stroke {
    var st = StrokeStabilizer(streamline: streamline, stabilization: stabilization)
    var pts = stroke.points.map { st.feed($0) }
    pts.append(contentsOf: st.finish())
    return Stroke(id: stroke.id, points: pts, brush: stroke.brush)
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
        if stroke.brush.wetEnabled, !stroke.brush.wetSmudge {
            // Wet INK (P7 core): the whole stroke walks at once (the canvas is pristine
            // for the stroke's duration — the KM under-color is a texture sample, so
            // there is no CPU-pickup staleness and no draining), then commits through
            // the scratch at the opacity ceiling exactly like the device flatten.
            guard let start = stroke.points.first?.position else { return }
            var walker = WetStrokeWalker(startPosition: start, brush: stroke.brush)
            let stamps = walker.advance(
                stroke: stroke, scale: 1, clipPath: nil,
                sample: { [renderer] x, y in renderer.sampleLayerColor(x: x, y: y) },
                sampleAveraged: { [renderer] x, y in renderer.sampleLayerColorAveraged(x: x, y: y) },
                mix: { [renderer] a, b, t in renderer.kmMixCPU(a, b, t) })
            renderer.commitStampsToCanvas(stamps, strokeOpacity: Float(stroke.brush.opacity), wetInk: true)
            return
        }
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
                                          shapeTexture: renderer.shapeTexture(for: stroke.brush.shapeID),
                                          grain: renderer.grainSettings(for: stroke.brush),
                                          lightness: renderer.lightnessSettings(for: stroke.brush),
                                          flip: renderer.flipSettings(for: stroke.brush))
        }
    }

    /// Row labels burnt into the render at snapshot time (top-left canvas coords).
    private var labels: [(x: CGFloat, y: CGFloat, text: String)] = []

    /// Label a row/region of the scene. `y` is the text BASELINE in canvas px —
    /// place it in the whitespace above the row it describes.
    func label(_ text: String, x: CGFloat = 24, y: CGFloat) {
        labels.append((x: x, y: y, text: text))
    }

    func snapshot(name: String) {
        renderer.waitUntilQueueDrained()
        guard let image = renderer.flattenedOpaqueCGImage(backgroundImage: nil) else {
            print("FAIL  no snapshot for \(name)"); exit(1)
        }
        writePNG(annotate(image, labels: labels), name: name)
    }
}

/// scene name → one-line description, written to manifest.json alongside the PNGs.
/// publish-run.sh ships it with the run so the Tests tab can explain each scene.
var sceneDescriptions: [String: String] = [:]

func runScene(_ name: String, _ description: String, _ body: (Scene) -> Void) {
    if let filter, !name.contains(filter) { return }
    guard let scene = Scene() else {
        print("FAIL  could not create Metal scene (no GPU?)"); exit(1)
    }
    sceneDescriptions[name] = description
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

runScene("dry-01-pressure",
         """
         How the tip responds to pressure, taper, and hardness — one control per row.
         - Row 1: pressure ramps 0→1 along the stroke → width should grow left to right.
         - Row 2: pressure rises then falls (bell) → thin–thick–thin.
         - Row 3: pulsing pressure + Taper 0.5 → wavy width with both tips tapered to points.
         - Row 4 left: Hardness 0 → soft, feathered airbrush edge. Right: Hardness 1 → crisp edge.
         """) { s in
    s.label("pressure ramp 0 → 1", y: 160)
    s.label("pressure bell (0 → 1 → 0)", y: 380)
    s.label("pulsing pressure + taper 0.5", y: 545)
    s.label("hardness 0 (soft)", y: 795)
    s.label("hardness 1 (crisp)", x: 560, y: 795)
    s.paint(synthStroke(id: 1, brush: pen(.black, width: 34), from: CGPoint(x: 100, y: 200), to: CGPoint(x: 924, y: 200),
                        force: { $0 }))                                     // ramp 0→1
    s.paint(synthStroke(id: 2, brush: pen(.black, width: 34), from: CGPoint(x: 100, y: 420), to: CGPoint(x: 924, y: 420),
                        force: { sin($0 * .pi) }))                          // bell
    s.paint(synthStroke(id: 3, brush: pen(.black, width: 34, taper: 0.5), from: CGPoint(x: 100, y: 640), to: CGPoint(x: 924, y: 640),
                        bow: 60, force: { 0.4 + 0.5 * sin($0 * .pi * 4).magnitude }))  // wavy pulses + taper
    s.paint(synthStroke(id: 4, brush: pen(.black, width: 34, hardness: 0.0), from: CGPoint(x: 100, y: 840), to: CGPoint(x: 512, y: 840)))
    s.paint(synthStroke(id: 5, brush: pen(.black, width: 34, hardness: 1.0), from: CGPoint(x: 560, y: 840), to: CGPoint(x: 924, y: 840)))
}

runScene("dry-02-flow-vs-opacity",
         """
         The Glaze split — Flow builds up WITHIN a stroke, Opacity is a per-stroke ceiling.
         - Left loop: Flow 0.25, Opacity 1 — the loop crosses itself, so the overlap darkens (flow builds).
         - Right loop: Flow 1, Opacity 0.25 — same self-crossing, but the overlap must stay FLAT (ceiling).
         - Bottom cross: two SEPARATE Flow-0.25 strokes — separate strokes always build where they cross.
         """) { s in
    s.label("flow 0.25 / opacity 1 — overlap builds", y: 205)
    s.label("flow 1 / op 0.25 — overlap stays flat", x: 560, y: 205)
    s.label("two separate flow-0.25 strokes — cross builds", y: 632)
    // Self-crossing loops: flow builds within a stroke, opacity is the per-stroke ceiling.
    s.paint(loopStroke(id: 10, brush: pen(teal, width: 40, opacity: 1.0, flow: 0.25), center: CGPoint(x: 260, y: 400), radius: 150))
    s.paint(loopStroke(id: 11, brush: pen(teal, width: 40, opacity: 0.25, flow: 1.0), center: CGPoint(x: 700, y: 400), radius: 150))
    s.paint(synthStroke(id: 12, brush: pen(.black, width: 6), from: CGPoint(x: 100, y: 700), to: CGPoint(x: 924, y: 700)))
    // Overlapping single passes at flow 0.25 (should build up where they cross).
    s.paint(synthStroke(id: 13, brush: pen(teal, width: 40, flow: 0.25), from: CGPoint(x: 200, y: 780), to: CGPoint(x: 824, y: 780)))
    s.paint(synthStroke(id: 14, brush: pen(teal, width: 40, flow: 0.25), from: CGPoint(x: 512, y: 660), to: CGPoint(x: 512, y: 900)))
}

runScene("dry-03-dynamics",
         """
         Brush dynamics stack: dab size driven by pressure (gamma 2), constant scatter, per-STROKE color jitter.
         All three rows use the IDENTICAL brush — only the stroke changes, so:
         - each row's dabs swell mid-stroke (pressure bell → size),
         - dabs spray around the path (scatter 0.55),
         - each row is a visibly different red (jitter is seeded per stroke, stable on replay).
         """) { s in
    s.label("same brush, stroke #1 — note this row's red", y: 165)
    s.label("stroke #2 — different jittered red", y: 415)
    s.label("stroke #3 — different again", y: 665)
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

runScene("dry-04-shapes",
         """
         The five textured tip shapes, one per row (top to bottom): chalk, charcoal, dry brush, pastel, spray.
         Each stroke ramps pressure 0.3→0.9 (width grows rightward) and the anisotropic tips rotate to
         follow the stroke direction — texture streaks should run ALONG the curve, not across it.
         """) { s in
    for (i, name) in ["chalk", "charcoal", "dry brush", "pastel", "spray"].enumerated() {
        s.label(name, y: CGFloat(150 + i * 180) - 62)
    }
    // Requires BRUSH_SHAPES_DIR (see README); without it, shaped strokes fall back to round.
    for (i, shape) in ["chalk", "charcoal", "drybrush", "pastel", "ink"].enumerated() {
        let y = CGFloat(150 + i * 180)
        s.paint(synthStroke(id: 30 + i, brush: pen(.black, width: 44, shape: shape),
                            from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y),
                            bow: 50, force: { 0.3 + 0.6 * $0 }))
    }
}

runScene("dry-05-aspect",
         """
         Tip aspect ratio (anisotropy): the SAME dab row three times, only Aspect changes.
         - Row 1: Aspect 1.0 — round dabs (the default tip).
         - Row 2: Aspect 0.4 — squashed ellipses.
         - Row 3: Aspect 0.15 — flat blades (the calligraphy-nib footprint).
         Spacing is set wide on purpose so each individual dab footprint is visible.
         """) { s in
    for (i, a) in ["aspect 1.0 (round)", "aspect 0.4 (ellipse)", "aspect 0.15 (blade)"].enumerated() {
        s.label(a, y: CGFloat(230 + i * 280) - 60)
    }
    // P4b anisotropy: same stroke at aspect 1.0 / 0.4 / 0.15, wide spacing so the
    // individual dab footprints are visible (round → ellipse → blade).
    for (i, aspect) in [CGFloat(1.0), 0.4, 0.15].enumerated() {
        var b = pen(.black, width: 70)
        b.aspectRatio = aspect
        b.spacing = 0.9
        s.paint(synthStroke(id: 70 + i, brush: b,
                            from: CGPoint(x: 130, y: CGFloat(230 + i * 280)),
                            to: CGPoint(x: 894, y: CGFloat(230 + i * 280)),
                            force: { _ in 1 }))
    }
}

runScene("dry-06-calligraphy-rotation",
         """
         Proves per-dab ROTATION reaches the GPU, using a flat nib (Aspect 0.2) to make it visible.
         - Row 1: nib held at a FIXED 45° — a real calligraphy pen: the S-curve goes THICK where the
           path crosses the nib and razor-THIN where it runs parallel to it.
         - Row 2: rotation driven by the Distance sensor — the nib angle keeps turning as the stroke
           travels, so the dabs fan through every orientation (the "spinning" proof).
         """) { s in
    s.label("flat nib fixed at 45° — thick/thin from direction", y: 130)
    s.label("nib rotation driven by distance — spins along the stroke", y: 640)
    // The rotation OUTPUT check (handoff item 1): with a flat tip (aspect 0.2), the
    // dabs must visibly rotate. Row 1: classic calligraphy — nib held at a FIXED 45°
    // via the STATIC tipAngle. (Previously used a no-sensor rotationLike CurveOption
    // believing it folds to its strength — it folds to 0, so this row actually rendered
    // a HORIZONTAL blade and the label lied; caught on device 2026-07-15, offline check
    // pins the real fold semantics now.)
    // Row 2: rotation driven by Distance → the nib visibly SPINS along a straight
    // stroke (unambiguous proof the per-dab rotation reaches the GPU).
    var nib = pen(.black, width: 60)
    nib.aspectRatio = 0.2
    nib.spacing = 0.05
    nib.tipAngle = .pi / 4
    s.paint(synthStroke(id: 75, brush: nib,
                        from: CGPoint(x: 120, y: 320), to: CGPoint(x: 904, y: 320),
                        bow: 140, force: { _ in 0.8 }))

    var spinner = pen(teal, width: 60)
    spinner.aspectRatio = 0.2
    spinner.spacing = 0.6
    spinner.dynamics = BrushDynamics(
        rotation: CurveOption(sensors: [SensorChannel(sensor: .distance)], fold: .rotationLike, strength: 1.0))
    s.paint(synthStroke(id: 76, brush: spinner,
                        from: CGPoint(x: 120, y: 720), to: CGPoint(x: 904, y: 720),
                        force: { _ in 0.9 }))
}

runScene("dry-07-stabilization",
         """
         P3 stabilization on identical shaky input (deterministic ±6px hand tremor on an S-curve).
         - Row 1: raw input — every wobble shows.
         - Row 2: Stabilize 0.6 (StreamLine low-pass) — steadier, slight corner-cutting lag.
         - Row 3: Smoothing 0.7 (Gaussian over drawn distance) — clean, confident curvature.
         - Row 4: both together — the inking setup.
         All four rows END at the same right edge: catch-up-on-lift walks the lagged cursor to
         the true pencil-up position (before P3, smoothed strokes stopped short).
         """) { s in
    let base = pen(.black, width: 14)
    func row(_ id: Int, _ y: CGFloat) -> Stroke {
        tremorStroke(id: id, brush: base, from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y), bow: 70)
    }
    s.label("raw tremor input", y: 110)
    s.paint(row(90, 200))
    s.label("stabilize 0.6 (StreamLine)", y: 350)
    s.paint(stabilized(row(91, 440), streamline: 0.6, stabilization: 0))
    s.label("smoothing 0.7 (Gaussian arc-length)", y: 590)
    s.paint(stabilized(row(92, 680), streamline: 0, stabilization: 0.7))
    s.label("both (0.6 + 0.7)", y: 830)
    s.paint(stabilized(row(93, 920), streamline: 0.6, stabilization: 0.7))
}

runScene("dry-08-grain",
         """
         P8 grain: document-space paper tooth carving the dab coverage (soft-HEIGHT composite).
         - Rows 1-3: the same charcoal-flow stroke with PAPER grain at depth 0 / 0.5 / 0.9 —
           more depth = tooth valleys eat more of the paint; pressure (right side) fills them.
         - Row 4: Canvas weave vs Speckle grains side by side (depth 0.7).
         - Row 5: two OVERLAPPING strokes — the tooth pattern is continuous across both because
           grain lives in DOCUMENT space, not stroke space (the dry-media invariant).
         """) { s in
    func chalkStroke(_ id: Int, _ y: CGFloat, depth: CGFloat, grain: String? = "paper",
                     from x0: CGFloat = 120, to x1: CGFloat = 904) -> Stroke {
        var b = pen(.black, width: 56, flow: 0.75)
        b.hardness = 0.7
        b.grainID = grain
        b.grainDepth = depth
        return synthStroke(id: id, brush: b, from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y),
                           force: { 0.25 + 0.7 * $0 })
    }
    s.label("paper, depth 0 (identity)", y: 90)
    s.paint(chalkStroke(100, 150, depth: 0))
    s.label("paper, depth 0.5", y: 270)
    s.paint(chalkStroke(101, 330, depth: 0.5))
    s.label("paper, depth 0.9 (heavier tooth; light starts break up first)", y: 450)
    s.paint(chalkStroke(102, 510, depth: 0.9))
    s.label("canvas weave 0.7", y: 630)
    s.paint(chalkStroke(103, 690, depth: 0.7, grain: "canvasWeave", to: 490))
    s.label("speckle 0.7", x: 540, y: 630)
    s.paint(chalkStroke(104, 690, depth: 0.7, grain: "speckle", from: 540))
    s.label("overlapping strokes — tooth is continuous (document space)", y: 810)
    s.paint(chalkStroke(105, 890, depth: 0.7, to: 640))
    s.paint(chalkStroke(106, 905, depth: 0.7, from: 380))
}

runScene("dry-09-knobs",
         """
         Cheap-knobs batch (Procreate parity, 2026-07-15): three small controls on existing machinery.
         - Row 1: Spacing Jitter 0 vs 0.9 on identical dab rows — even gaps vs organically uneven gaps.
         - Row 2: Pressure Roundness (ratio: pressure): the flat nib squashes with the pressure bell —
           round where pressed hard mid-stroke, blade-thin at the light tips.
         - Row 3: BarrelRotation sensor: the roll angle sweeps half a turn along the stroke and the
           nib visibly follows it (synthesized roll — on device this is Pencil Pro barrel roll).
         """) { s in
    // Row 1: spacing jitter A/B.
    var even = pen(.black, width: 44); even.spacing = 0.9
    var jit = even; jit.spacingJitter = 0.9
    s.label("spacing jitter 0", y: 110)
    s.paint(synthStroke(id: 110, brush: even, from: CGPoint(x: 120, y: 170), to: CGPoint(x: 904, y: 170), force: { _ in 1 }))
    s.label("spacing jitter 0.9", y: 270)
    s.paint(synthStroke(id: 111, brush: jit, from: CGPoint(x: 120, y: 330), to: CGPoint(x: 904, y: 330), force: { _ in 1 }))

    // Row 2: pressure roundness — ratio driven by pressure on a flat nib.
    var nib = pen(teal, width: 56)
    nib.aspectRatio = 1.0
    nib.spacing = 0.8
    nib.dynamics = BrushDynamics(
        ratio: CurveOption(sensors: [SensorChannel(sensor: .pressure)], minValue: 0.12))
    s.label("pressure roundness — squashes at the light ends, round when pressed", y: 450)
    s.paint(synthStroke(id: 112, brush: nib, from: CGPoint(x: 120, y: 530), to: CGPoint(x: 904, y: 530),
                        force: { sin($0 * .pi) }))

    // Row 3: barrel-roll → rotation (synthesized roll ramp over the stroke).
    var roller = pen(.black, width: 56)
    roller.aspectRatio = 0.18
    roller.spacing = 0.7
    roller.dynamics = BrushDynamics(
        rotation: CurveOption(sensors: [SensorChannel(sensor: .barrelRotation)], fold: .rotationLike, strength: 1.0))
    var rollerStroke = synthStroke(id: 113, brush: roller, from: CGPoint(x: 120, y: 780), to: CGPoint(x: 904, y: 780),
                                   force: { _ in 0.9 })
    for i in rollerStroke.points.indices {
        let t = CGFloat(i) / CGFloat(rollerStroke.points.count - 1)
        rollerStroke.points[i].rollAngle = t * .pi   // half a turn across the stroke
    }
    s.label("barrel roll sweeps 0 → π along the stroke — nib follows", y: 700)
    s.paint(rollerStroke)
}

runScene("dry-10-lightness-tips",
         """
         P4a lightness-map tips: the shaped tip's grayscale becomes a VALUE map instead of
         being thrown away — dark tip pixels darken the ink, light ones lighten it, mid-gray
         reproduces the brush color exactly (the oracle invariant). One cheap fragment turns a
         flat color stroke into a value-modulated mass the img2img model reads as form.
         - Rows: the same teal charcoal stroke at Tip Lightness 0 (flat, today) / 0.6 / 1.0.
         - Bottom: chalk tip in red at 1.0 — internal light/dark structure from the tip art.
         """) { s in
    for (i, strength) in [CGFloat(0), 0.6, 1.0].enumerated() {
        var b = pen(teal, width: 60, flow: 0.9, shape: "charcoal")
        b.tipLightness = strength
        s.label(String(format: "charcoal, tip lightness %.1f", strength), y: CGFloat(110 + i * 230))
        s.paint(synthStroke(id: 120 + i, brush: b,
                            from: CGPoint(x: 120, y: CGFloat(170 + i * 230)),
                            to: CGPoint(x: 904, y: CGFloat(170 + i * 230)),
                            bow: 40, force: { 0.35 + 0.55 * $0 }))
    }
    var r = pen(red, width: 60, flow: 0.9, shape: "chalk")
    r.tipLightness = 1.0
    s.label("chalk in red, tip lightness 1.0", y: 800)
    s.paint(synthStroke(id: 123, brush: r,
                        from: CGPoint(x: 120, y: 870), to: CGPoint(x: 904, y: 870),
                        bow: 40, force: { 0.35 + 0.55 * $0 }))
}

runScene("dry-11-count-scatter",
         """
         Cheap-knobs batch 2 (Procreate Stroke Path / Shape): stamp Count and the scatter split.
         - Row 1: isotropic Scatter 0.5, Count 1 — the baseline spray.
         - Row 2: SAME scatter, Count 4 — four stamps per spacing point, each with its own
           scatter draw: a denser cluster texture at the same walk rate.
         - Row 3: Count 4 + Count Jitter 0.9 — the per-dab copy count varies randomly, so
           density breathes along the stroke.
         - Row 4: LATERAL scatter only (⊥ stroke) — dabs spread ACROSS the path, edges fuzz,
           the along-path rhythm stays even.
         - Row 5: LINEAR scatter only (∥ stroke) — dabs bunch and gap ALONG the path, the
           stroke's width stays clean.
         """) { s in
    func sprayBase(_ width: CGFloat = 34) -> BrushConfig {
        var b = pen(.black, width: width, flow: 0.85)
        b.hardness = 0.85
        b.spacing = 1.1
        return b
    }
    var iso = sprayBase()
    iso.dynamics = BrushDynamics(scatter: CurveOption(sensors: [], strength: 0.5))
    s.label("scatter 0.5, count 1", y: 100)
    s.paint(synthStroke(id: 130, brush: iso, from: CGPoint(x: 120, y: 160), to: CGPoint(x: 904, y: 160), force: { _ in 1 }))

    var counted = iso
    counted.stampCount = 4
    s.label("scatter 0.5, count 4 — clustered spray, same walk", y: 260)
    s.paint(synthStroke(id: 131, brush: counted, from: CGPoint(x: 120, y: 320), to: CGPoint(x: 904, y: 320), force: { _ in 1 }))

    var jittered = counted
    jittered.stampCountJitter = 0.9
    s.label("count 4, count jitter 0.9 — density breathes", y: 420)
    s.paint(synthStroke(id: 132, brush: jittered, from: CGPoint(x: 120, y: 480), to: CGPoint(x: 904, y: 480), force: { _ in 1 }))

    var lat = sprayBase(26)
    lat.spacing = 0.5
    lat.dynamics = BrushDynamics(scatterLateral: CurveOption(sensors: [], strength: 0.9))
    s.label("lateral scatter only — spread ACROSS the path", y: 580)
    s.paint(synthStroke(id: 133, brush: lat, from: CGPoint(x: 120, y: 660), to: CGPoint(x: 904, y: 660), bow: 60, force: { _ in 1 }))

    var lin = sprayBase(26)
    lin.spacing = 0.5
    lin.dynamics = BrushDynamics(scatterLinear: CurveOption(sensors: [], strength: 0.9))
    s.label("linear scatter only — bunch/gap ALONG the path", y: 790)
    s.paint(synthStroke(id: 134, brush: lin, from: CGPoint(x: 120, y: 870), to: CGPoint(x: 904, y: 870), bow: 60, force: { _ in 1 }))
}

runScene("dry-12-orientation-flips",
         """
         Cheap-knobs batch 2 (Procreate Shape): signed follow-stroke Rotation and Flip X/Y.
         - Rows 1-3: the same flat charcoal nib (aspect 0.25) on the same S-curve with the
           Rotation knob at +1 / 0 / −1: follows the stroke (thick-thin calligraphy) /
           held upright (thick where the path is horizontal) / INVERSE-follows (the
           thick/thin pattern mirrors row 1).
         - Row 4: drybrush dabs, unflipped vs Flip X vs Flip Y (spaced out so single stamps
           are inspectable — the streak pattern mirrors accordingly).
         """) { s in
    for (i, follow) in [CGFloat(1), 0, -1].enumerated() {
        var nib = pen(i == 1 ? teal : .black, width: 56, shape: "charcoal")
        nib.aspectRatio = 0.25
        nib.spacing = 0.15
        nib.rotationFollow = follow
        s.label(String(format: "rotation %+.0f — %@", follow,
                       follow == 1 ? "follows the stroke" : follow == 0 ? "held upright" : "inverse-follows"),
                y: CGFloat(95 + i * 230))
        s.paint(synthStroke(id: 140 + i, brush: nib,
                            from: CGPoint(x: 120, y: CGFloat(160 + i * 230)),
                            to: CGPoint(x: 904, y: CGFloat(160 + i * 230)),
                            bow: 90, force: { _ in 0.85 }))
    }
    func flipRow(_ id: Int, from x0: CGFloat, to x1: CGFloat, flipX: Bool, flipY: Bool) {
        var b = pen(.black, width: 62, shape: "drybrush")
        b.spacing = 1.3
        b.rotationFollow = 0   // upright dabs so the mirror is inspectable
        b.flipX = flipX
        b.flipY = flipY
        s.paint(synthStroke(id: id, brush: b, from: CGPoint(x: x0, y: 880), to: CGPoint(x: x1, y: 880), force: { _ in 1 }))
    }
    s.label("plain", y: 800)
    s.label("flip X", x: 400, y: 800)
    s.label("flip Y", x: 690, y: 800)
    flipRow(145, from: 120, to: 310, flipX: false, flipY: false)
    flipRow(146, from: 400, to: 590, flipX: true, flipY: false)
    flipRow(147, from: 690, to: 880, flipX: false, flipY: true)
}

runScene("dry-13-falloff",
         """
         Fall Off (Procreate Stroke Path): the stroke's paint runs out over drawn distance —
         a per-dab flow multiplier over cumulative arc length, independent of speed or dab
         density. All three rows are the SAME long serpentine stroke:
         - Row 1: fall off 0 — never dies (constant ink to the end).
         - Row 2: fall off 0.5 — fades over roughly the document width.
         - Row 3: fall off 1.0 — dries out within a few hundred px, like a drying marker.
         """) { s in
    for (i, k) in [CGFloat(0), 0.5, 1.0].enumerated() {
        var b = pen(.black, width: 34, flow: 0.9)
        b.fallOff = k
        s.label(String(format: "fall off %.1f", k), y: CGFloat(120 + i * 300))
        s.paint(synthStroke(id: 150 + i, brush: b,
                            from: CGPoint(x: 120, y: CGFloat(200 + i * 300)),
                            to: CGPoint(x: 904, y: CGFloat(200 + i * 300)),
                            bow: 90, force: { _ in 0.8 }))
    }
}

runScene("dry-14-presets",
         """
         Curated preset gallery (preset-library v1): each row is one preset from
         CuratedPresetCatalog drawn with the SAME input stroke (pressure bell, gentle S) —
         the full recipes users get from the popover's Presets grid. Color/size are the
         only inputs kept from the "user"; everything else is the preset. Left column ink
         blue, right column warm sepia, purely for visual variety.
         """) { s in
    let inkBlue = CodableColor(red: 0.16, green: 0.22, blue: 0.45)
    let sepia = CodableColor(red: 0.42, green: 0.28, blue: 0.16)
    let presets = CuratedPresetCatalog.all
    for (i, preset) in presets.enumerated() {
        let col = i % 2, row = i / 2
        let x0: CGFloat = col == 0 ? 60 : 540
        let x1: CGFloat = col == 0 ? 480 : 960
        let y = CGFloat(150 + row * 190)
        let base = BrushConfig(color: col == 0 ? inkBlue : sepia, baseWidth: 30)
        var b = preset.configure(base)
        // Stabilization is a live-input stage (MetalCanvasView), not a stamp-gen stage —
        // zero it so the gallery shows tip/texture character, not the input filter.
        b.streamline = 0; b.stabilization = 0
        s.label(preset.displayName, x: x0 - 30, y: y - 60)
        s.paint(synthStroke(id: 160 + i, brush: b,
                            from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y),
                            bow: 45, force: { 0.25 + 0.7 * sin($0 * .pi) }))
    }
}

runScene("dry-15-dab-color-jitter",
         """
         P6 per-dab color jitter ("Stamp Color Jitter" — the pastel/oil sparkle). Every dab
         draws its own HSV shift, vs. the per-STROKE jitter that shifts a whole stroke once.
         - Row 1: no jitter — flat ochre reference.
         - Row 2: per-STROKE jitter, three separate strokes — each stroke is one coherent
           shade, no variation within a stroke.
         - Row 3: per-DAB jitter (brightness-led) — value sparkle WITHIN a single stroke.
         - Row 4: per-dab, hue+sat cranked (0.05/0.3/0.25) — exaggerated to make the per-dab
           independence unmistakable (not a shipping look).
         - Row 5: Darkness x pressure (P6): a pressure bell darkens the ink mid-stroke while
           the width stays constant — the 6B-pencil "press harder, darker graphite" move.
         """) { s in
    let ochre = CodableColor(red: 0.78, green: 0.55, blue: 0.2)
    func dabbed(_ id: Int, _ y: CGFloat, dyn: BrushDynamics?, from x0: CGFloat = 120, to x1: CGFloat = 904) -> Stroke {
        var b = pen(ochre, width: 44, flow: 0.95)
        b.hardness = 0.75
        b.spacing = 0.45
        b.dynamics = dyn
        return synthStroke(id: id, brush: b, from: CGPoint(x: x0, y: y), to: CGPoint(x: x1, y: y), force: { _ in 0.9 })
    }
    s.label("no jitter", y: 100)
    s.paint(dabbed(170, 160, dyn: nil))
    s.label("per-STROKE jitter — 3 strokes, one shade each", y: 280)
    s.paint(dabbed(171, 340, dyn: BrushDynamics(colorJitter: ColorJitter(hue: 0.03, saturation: 0.25, brightness: 0.2)), to: 380))
    s.paint(dabbed(172, 340, dyn: BrushDynamics(colorJitter: ColorJitter(hue: 0.03, saturation: 0.25, brightness: 0.2)), from: 390, to: 640))
    s.paint(dabbed(173, 340, dyn: BrushDynamics(colorJitter: ColorJitter(hue: 0.03, saturation: 0.25, brightness: 0.2)), from: 650))
    s.label("per-DAB jitter — sparkle within one stroke (brightness-led)", y: 460)
    s.paint(dabbed(174, 520, dyn: BrushDynamics(dabColorJitter: ColorJitter(hue: 0.008, saturation: 0.1, brightness: 0.18))))
    s.label("per-dab, exaggerated hue+sat (diagnostic, not a look)", y: 640)
    s.paint(dabbed(175, 700, dyn: BrushDynamics(dabColorJitter: ColorJitter(hue: 0.05, saturation: 0.3, brightness: 0.25))))
    // Darkness: pressure bell → ink darkens toward the middle of the stroke where
    // pressure peaks (the 6B pencil move), width constant.
    var dark = pen(ochre, width: 44, flow: 0.95)
    dark.hardness = 0.75
    dark.spacing = 0.3
    dark.dynamics = BrushDynamics(
        size: CurveOption(sensors: [], strength: 1.0),   // constant width — isolate the color effect
        darkness: CurveOption(sensors: [SensorChannel(sensor: .pressure)], maxValue: 0.65))
    s.label("darkness x pressure bell — darker where pressed, width constant", y: 820)
    s.paint(synthStroke(id: 176, brush: dark, from: CGPoint(x: 120, y: 880), to: CGPoint(x: 904, y: 880),
                        force: { sin($0 * .pi) }))
}

runScene("dry-16-wiggle-deposit",
         """
         Regression pin for the arc-carry stamp walk (device bug, 2026-07-15): scribbling
         inside a radius SMALLER than the stamp gap must still deposit ink. The old walk
         measured "distance since last stamp" as the straight-line distance from the last
         stamp point, so an in-place wiggle never crossed the spacing threshold — Spray
         Paint deposited its first dab and then nothing.
         - Left: a tight 12px-radius scribble (many oscillations) with a wide-spaced pen —
           must be a dense PILE of dabs, not a single dot.
         - Right: the same scribble with the Spray Paint preset — a growing cluster.
         Both accumulate arc length while barely moving; one dab each = the old bug.
         """) { s in
    // Tight wiggle: 60 oscillations within a 12px radius.
    func wiggle(id: Int, brush: BrushConfig, cx: CGFloat, cy: CGFloat) -> Stroke {
        var pts: [StrokePoint] = []
        for i in 0...240 {
            let t = Double(i) / 240.0
            let ang = t * 60 * 2 * Double.pi
            pts.append(StrokePoint(
                position: CGPoint(x: cx + CGFloat(cos(ang)) * 12 * CGFloat(0.4 + 0.6 * t),
                                  y: cy + CGFloat(sin(ang * 0.9)) * 12 * CGFloat(0.4 + 0.6 * t)),
                force: 0.8, altitude: .pi / 2, timestamp: t, azimuth: 0))
        }
        return Stroke(id: fixedUUID(id), points: pts, brush: brush)
    }
    var wide = pen(.black, width: 40, flow: 0.5)
    wide.hardness = 0.7
    wide.spacing = 0.9   // 36px gap >> 12px wiggle radius — the failing regime
    s.label("wide-spaced pen, 12px wiggle — must PILE UP", y: 330)
    s.paint(wiggle(id: 180, brush: wide, cx: 280, cy: 500))

    var spray = CuratedPresetCatalog.preset(for: "spraypaint")!.configure(
        BrushConfig(color: CodableColor(red: 0.16, green: 0.22, blue: 0.45), baseWidth: 34))
    spray.streamline = 0; spray.stabilization = 0
    s.label("spray paint preset, same wiggle — growing cluster", x: 560, y: 330)
    s.paint(wiggle(id: 181, brush: spray, cx: 740, cy: 500))
}

runScene("dry-17-taper",
         """
         Richer taper (Procreate Taper pane essentials). All rows are the same stroke.
         - Row 1: legacy symmetric taper 0.5, size only — the pre-2026-07-16 behavior
           (regression reference; must match older renders of taper strokes).
         - Row 2: START-only taper 0.7 — thin entry, blunt exit.
         - Row 3: END-only taper 0.7 — blunt entry, thin exit.
         - Row 4: symmetric taper 0.5 + taper OPACITY 1.0 — the tips fade out to nothing
           instead of ending as thin-but-solid points (compare row 1's tips).
         """) { s in
    func row(_ id: Int, _ y: CGFloat, start: CGFloat, end: CGFloat, both: CGFloat, opac: CGFloat) {
        var b = pen(.black, width: 40)
        b.taper = both
        b.taperStart = start
        b.taperEnd = end
        b.taperOpacity = opac
        s.paint(synthStroke(id: id, brush: b, from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y),
                            bow: 40, force: { _ in 0.85 }))
    }
    s.label("symmetric taper 0.5 (legacy reference)", y: 110)
    row(460, 190, start: 0, end: 0, both: 0.5, opac: 0)
    s.label("start-only taper 0.7 — thin entry, blunt exit", y: 330)
    row(461, 410, start: 0.7, end: 0, both: 0, opac: 0)
    s.label("end-only taper 0.7 — blunt entry, thin exit", y: 550)
    row(462, 630, start: 0, end: 0.7, both: 0, opac: 0)
    s.label("taper 0.5 + taper opacity 1.0 — tips FADE, not just thin", y: 770)
    row(463, 850, start: 0, end: 0, both: 0.5, opac: 1.0)
}

runScene("dry-18-moving-grain",
         """
         Grain modes A/B (P8 "Moving", 2026-07-16). Same paper grain, same strokes.
         - Row 1: FIXED (document-space) grain, two overlapping strokes — the tooth
           pattern is CONTINUOUS across both (the dry-media invariant from dry-08).
         - Row 2: MOVING grain, the same two overlapping strokes — each stroke carries
           its OWN streaks; the pattern does NOT line up across the overlap.
         - Row 3: MOVING grain on an S-curve — the streaks FOLLOW the bend (the tooth is
           anchored to arc length, not the paper).
         """) { s in
    func grainBrush(moving: Bool) -> BrushConfig {
        var b = pen(.black, width: 56, flow: 0.75)
        b.hardness = 0.7
        b.grainID = "paper"
        b.grainDepth = 0.65
        b.grainMoving = moving
        return b
    }
    s.label("fixed grain — tooth continuous across overlapping strokes", y: 110)
    s.paint(synthStroke(id: 470, brush: grainBrush(moving: false),
                        from: CGPoint(x: 120, y: 190), to: CGPoint(x: 700, y: 190), force: { 0.3 + 0.6 * $0 }))
    s.paint(synthStroke(id: 471, brush: grainBrush(moving: false),
                        from: CGPoint(x: 350, y: 205), to: CGPoint(x: 904, y: 205), force: { 0.3 + 0.6 * $0 }))
    s.label("MOVING grain — each stroke carries its own streaks", y: 380)
    s.paint(synthStroke(id: 472, brush: grainBrush(moving: true),
                        from: CGPoint(x: 120, y: 460), to: CGPoint(x: 700, y: 460), force: { 0.3 + 0.6 * $0 }))
    s.paint(synthStroke(id: 473, brush: grainBrush(moving: true),
                        from: CGPoint(x: 350, y: 475), to: CGPoint(x: 904, y: 475), force: { 0.3 + 0.6 * $0 }))
    s.label("MOVING grain on an S-curve — streaks follow the bend", y: 650)
    s.paint(synthStroke(id: 474, brush: grainBrush(moving: true),
                        from: CGPoint(x: 120, y: 800), to: CGPoint(x: 904, y: 800),
                        bow: 90, force: { _ in 0.75 }))
}

runScene("dry-19-grain-curve",
         """
         Grain strength as a CurveOption (P8 leftover): per-dab depth multiplier on
         MOVING grain. Both rows: the same moving-grain stroke with a pressure BELL
         (light → hard → light).
         - Row 1: constant grain (no curve) — even tooth end to end; only width follows
           the bell.
         - Row 2: grain driven by INVERTED pressure (hard press → multiplier ≈ 0) — the
           pressed MIDDLE fills in smooth while the light ends stay toothy: the classic
           pencil-on-paper response, now sensor-driven per dab.
         """) { s in
    func grainStroke(_ id: Int, _ y: CGFloat, curve: CurveOption?) -> Stroke {
        var b = pen(.black, width: 60, flow: 0.9)
        b.hardness = 0.7
        b.grainID = "paper"
        b.grainDepth = 0.7
        b.grainMoving = true
        b.dynamics = curve.map { BrushDynamics(grain: $0) }
        return synthStroke(id: id, brush: b, from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y),
                           force: { 0.15 + 0.8 * sin($0 * .pi) })
    }
    s.label("constant grain — even tooth, width follows the pressure bell", y: 180)
    s.paint(grainStroke(480, 300, curve: nil))
    s.label("grain x INVERTED pressure — pressed middle fills SMOOTH, light ends toothy", y: 560)
    s.paint(grainStroke(481, 680, curve: CurveOption(
        sensors: [SensorChannel(sensor: .pressure,
                                curve: ResponseCurve(points: [ResponseCurve.Point(0, 1), ResponseCurve.Point(1, 0)]))],
        useSameCurve: false)))
}

runScene("wet-01-blue-into-yellow",
         """
         Spectral pigment mixing (Kubelka-Munk): a WET blue stroke dragged left-to-right through a
         yellow patch. Expected: blue entering, a GREEN transition band where blue meets yellow
         (per-channel RGB mixing would give gray/black), then the brush's carried load converges to
         yellow — it exits the patch depositing yellow, not blue.
         The patch is built from three overlapping passes; the wet stroke runs along the MIDDLE band
         only — the outer bands are untouched paint, there as a before/after reference.
         """) { s in
    s.label("wet blue stroke dragged along the MIDDLE band →", y: 250)
    s.label("untouched", y: 377)
    s.label("untouched", y: 537)
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

runScene("wet-02-smudge",
         """
         Smudge = push existing paint, add NO new ink. One smudge stroke dragged left-to-right through
         a red patch, across the white gap, into a blue patch. Expected: red gets dragged into the gap
         as a tail that thins and dies (the carried load depletes over blank canvas), then a small red
         contamination appears where the smudge enters the blue.
         Each patch is three overlapping passes; the smudge runs along the MIDDLE band only — the top
         and bottom bands are untouched paint for comparison.
         """) { s in
    s.label("red patch", y: 305)
    s.label("blue patch", x: 620, y: 305)
    s.label("smudge runs along the MIDDLE band only — outer bands are untouched reference", y: 690)
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

runScene("wet-04-smudge-translucent",
         """
         Regression guard for the 2026-07-15 device bug: smudging TRANSLUCENT paint must keep it
         translucent. The patch is 40%-opacity red; a smudge drags through it and off the right edge.
         Expected: inside the patch the smudge is nearly invisible (40% pushed through 40%), and the
         drag-off tail is a translucent wisp that fades out. BROKEN would be: an opaque dark-red track.
         The patch is three overlapping passes; the smudge runs along the MIDDLE band only. Judge the
         result by comparing the smudged middle band against the untouched outer bands beside it —
         identical pink = the 40% opacity was preserved.
         """) { s in
    s.label("40%-opacity red patch", y: 305)
    s.label("untouched (reference)", x: 640, y: 383)
    s.label("untouched (reference)", x: 640, y: 543)
    s.label("smudge runs along the MIDDLE band, then drags off the right edge", y: 690)
    // Donald's 2026-07-15 report: smudging 40%-opacity red turned it fully opaque
    // instead of pushing translucent paint. The smudge crosses the 40% patch and
    // drags off onto blank canvas. CORRECT behavior: the smudged area stays ~40%
    // (light pink over white), and the drag-off tail is translucent and fades out.
    // BROKEN behavior: the stroke path turns deep opaque red.
    for i in 0..<3 {
        s.paint(synthStroke(id: 80 + i, brush: pen(red, width: 120, opacity: 0.4),
                            from: CGPoint(x: 140, y: 380 + CGFloat(i) * 80),
                            to: CGPoint(x: 560, y: 380 + CGFloat(i) * 80),
                            force: { _ in 1 }))
    }
    s.paint(synthStroke(id: 84, brush: wet(.black, width: 70, mix: 0.6, smear: 0.85, smudge: true),
                        from: CGPoint(x: 220, y: 460), to: CGPoint(x: 900, y: 460)))
}

runScene("wet-03-mix-sweep",
         """
         Tuning sweep for the Mix knob (deposit strength): the same wet-blue-over-yellow drag three
         times, only Mix changes — 0.2 / 0.5 / 0.9 top to bottom (Smear fixed LOW at 0.12 so the
         carried load survives the whole crossing — since the wet-ink-through-scratch rework the
         load picks up the TRUE canvas color, so high Smear converges to yellow within a few dabs
         and would mask Mix entirely). Higher Mix = stronger blue deposit against the yellow.
         """) { s in
    for (i, m) in ["mix 0.2", "mix 0.5", "mix 0.9"].enumerated() {
        s.label(m, y: CGFloat(220 + i * 280) - 80)
    }
    // Wet blue over yellow at Mix 0.2 / 0.5 / 0.9 (same LOW smear) — a tuning contact row.
    for (i, mixV) in [CGFloat(0.2), 0.5, 0.9].enumerated() {
        let y = CGFloat(220 + i * 280)
        s.paint(synthStroke(id: 60 + i, brush: pen(yellow, width: 110),
                            from: CGPoint(x: 180, y: y), to: CGPoint(x: 844, y: y),
                            force: { _ in 1 }))
        s.paint(synthStroke(id: 65 + i, brush: wet(blue, width: 55, mix: mixV, smear: 0.12),
                            from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y)))
    }
}

runScene("wet-05-smear-sweep",
         """
         Tuning sweep for the Smear knob (load pickup rate) — the counterpart of wet-03:
         the same wet-blue-over-yellow drag three times, only Smear changes — 0.1 / 0.4 / 0.8
         top to bottom (Mix fixed at 0.7 so every row deposits strongly; what changes is how
         fast the CARRIED LOAD surrenders to the yellow it crosses).
         - Smear 0.1: the blue survives most of the crossing — long blue→green trail.
         - Smear 0.4: converges mid-patch — green band in the middle, yellow exit.
         - Smear 0.8: the load is yellow within a few dabs — blue dies almost immediately.
         Since the wet-ink rework the load samples the TRUE canvas, so Smear is the honest
         reservoir-persistence dial (until P7's finite Charge lands).
         """) { s in
    for (i, m) in ["smear 0.1", "smear 0.4", "smear 0.8"].enumerated() {
        s.label(m, y: CGFloat(220 + i * 280) - 80)
    }
    for (i, smearV) in [CGFloat(0.1), 0.4, 0.8].enumerated() {
        let y = CGFloat(220 + i * 280)
        s.paint(synthStroke(id: 190 + i, brush: pen(yellow, width: 110),
                            from: CGPoint(x: 180, y: y), to: CGPoint(x: 844, y: y),
                            force: { _ in 1 }))
        s.paint(synthStroke(id: 195 + i, brush: wet(blue, width: 55, mix: 0.7, smear: smearV),
                            from: CGPoint(x: 120, y: y), to: CGPoint(x: 904, y: y)))
    }
}

runScene("wet-06-mix-x-opacity",
         """
         Mix sweep × OPACITY grid: every cell is the same wet-blue-over-yellow drag.
         - Columns: stroke Opacity 100% / 50% / 10% (the per-stroke alpha ceiling from the
           wet-ink-through-scratch rework — at 10% the stroke is a barely-there glaze).
         - Rows: Mix 0.2 / 0.5 / 0.9 (deposit strength; Smear fixed low at 0.12).
         Expect each column to keep the SAME color story as the full-opacity Mix sweep
         (wet-03) but fade as a whole toward the right — opacity must scale the entire
         glaze uniformly, never re-tint or wash the mix itself.
         """) { s in
    let opacities: [CGFloat] = [1.0, 0.5, 0.1]
    let mixes: [CGFloat] = [0.2, 0.5, 0.9]
    for (c, op) in opacities.enumerated() {
        s.label("opacity \(Int(op * 100))%", x: CGFloat(60 + c * 330), y: 100)
    }
    for (r, mixV) in mixes.enumerated() {
        let y = CGFloat(230 + r * 300)
        s.label(String(format: "mix %.1f", mixV), y: y - 70)
        for (c, op) in opacities.enumerated() {
            let x0 = CGFloat(40 + c * 330)
            s.paint(synthStroke(id: 200 + r * 10 + c, brush: pen(yellow, width: 70),
                                from: CGPoint(x: x0 + 45, y: y), to: CGPoint(x: x0 + 260, y: y),
                                force: { _ in 1 }))
            var b = wet(blue, width: 34, mix: mixV, smear: 0.12)
            b.opacity = op
            s.paint(synthStroke(id: 250 + r * 10 + c, brush: b,
                                from: CGPoint(x: x0, y: y), to: CGPoint(x: x0 + 300, y: y)))
        }
    }
}

runScene("wet-07-smear-x-opacity",
         """
         Smear sweep × OPACITY grid — the wet-05 counterpart of wet-06.
         - Columns: stroke Opacity 100% / 50% / 10%.
         - Rows: Smear 0.1 / 0.4 / 0.8 (load pickup rate; Mix fixed at 0.7).
         The blue→green→yellow convergence DISTANCE must depend only on the row (Smear);
         the column (opacity) only scales how strongly the whole glaze reads. If the
         convergence point shifts with opacity, opacity is leaking into the load walk.
         """) { s in
    let opacities: [CGFloat] = [1.0, 0.5, 0.1]
    let smears: [CGFloat] = [0.1, 0.4, 0.8]
    for (c, op) in opacities.enumerated() {
        s.label("opacity \(Int(op * 100))%", x: CGFloat(60 + c * 330), y: 100)
    }
    for (r, smearV) in smears.enumerated() {
        let y = CGFloat(230 + r * 300)
        s.label(String(format: "smear %.1f", smearV), y: y - 70)
        for (c, op) in opacities.enumerated() {
            let x0 = CGFloat(40 + c * 330)
            s.paint(synthStroke(id: 300 + r * 10 + c, brush: pen(yellow, width: 70),
                                from: CGPoint(x: x0 + 45, y: y), to: CGPoint(x: x0 + 260, y: y),
                                force: { _ in 1 }))
            var b = wet(blue, width: 34, mix: 0.7, smear: smearV)
            b.opacity = op
            s.paint(synthStroke(id: 350 + r * 10 + c, brush: b,
                                from: CGPoint(x: x0, y: y), to: CGPoint(x: x0 + 300, y: y)))
        }
    }
}

runScene("wet-08-overlap-opacity",
         """
         Partial-opacity wet strokes OVERLAPPING — the Glaze semantics under test.
         - Top left: blue 50% crossed by yellow 50% (two separate strokes). The overlap
           must stack like two watercolor glazes: denser (α 0.5 → 0.75) and KM-tinted
           green-ish — the second stroke mixes against what the first left behind.
         - Top right: the same cross at 10% + 10% — the same story, whisper-faint.
         - Bottom left: ONE 50% blue stroke that crosses ITSELF (a loop). The self-
           crossing must stay FLAT — same density everywhere (the per-stroke ceiling is
           applied once at flatten, not per pass). If the loop's crossing darkens, the
           Glaze split broke.
         - Bottom right: TWO 50% blue strokes crossing — unlike the loop, this SHOULD
           darken at the overlap (separate strokes always stack). The pair is the
           discriminator: flat loop + stacking X = correct; both flat or both stacking
           = a bug.
         """) { s in
    // Top left: blue 50% + yellow 50% cross.
    var blue50 = wet(blue, width: 44, mix: 0.7, smear: 0.15)
    blue50.opacity = 0.5
    var yellow50 = wet(yellow, width: 44, mix: 0.7, smear: 0.15)
    yellow50.opacity = 0.5
    s.label("blue 50% × yellow 50% — overlap stacks, KM tint", y: 120)
    s.paint(synthStroke(id: 400, brush: blue50, from: CGPoint(x: 260, y: 160), to: CGPoint(x: 260, y: 400), force: { _ in 0.8 }))
    s.paint(synthStroke(id: 401, brush: yellow50, from: CGPoint(x: 100, y: 280), to: CGPoint(x: 420, y: 280), force: { _ in 0.8 }))

    // Top right: same at 10%.
    var blue10 = blue50; blue10.opacity = 0.1
    var yellow10 = yellow50; yellow10.opacity = 0.1
    s.label("10% × 10%", x: 600, y: 120)
    s.paint(synthStroke(id: 402, brush: blue10, from: CGPoint(x: 760, y: 160), to: CGPoint(x: 760, y: 400), force: { _ in 0.8 }))
    s.paint(synthStroke(id: 403, brush: yellow10, from: CGPoint(x: 600, y: 280), to: CGPoint(x: 920, y: 280), force: { _ in 0.8 }))

    // Bottom left: ONE self-crossing 50% blue loop — must stay flat.
    var loopPts: [StrokePoint] = []
    for i in 0...160 {
        let t = Double(i) / 160.0
        let theta = -0.6 * Double.pi + t * 3.0 * Double.pi   // 1.5 turns → guaranteed self-cross
        loopPts.append(StrokePoint(
            position: CGPoint(x: 260 + 110 * CGFloat(cos(theta)) + CGFloat(t * 60),
                              y: 740 + 110 * CGFloat(sin(theta))),
            force: 0.8, altitude: .pi / 2, timestamp: t, azimuth: 0))
    }
    s.label("ONE 50% stroke self-crossing — must stay FLAT", y: 560)
    s.paint(Stroke(id: fixedUUID(404), points: loopPts, brush: blue50))

    // Bottom right: TWO 50% blue strokes crossing — SHOULD stack.
    s.label("TWO 50% strokes crossing — should darken", x: 580, y: 560)
    s.paint(synthStroke(id: 405, brush: blue50, from: CGPoint(x: 640, y: 620), to: CGPoint(x: 900, y: 880), force: { _ in 0.8 }))
    s.paint(synthStroke(id: 406, brush: blue50, from: CGPoint(x: 900, y: 620), to: CGPoint(x: 640, y: 880), force: { _ in 0.8 }))
}

runScene("wet-09-charge-sweep",
         """
         Charge sweep (P7 Wet Mix vocabulary): the paint reservoir runs out over drawn
         distance. The same long wet drag (blue over white, then THROUGH a yellow patch at
         the far end), only Charge changes — 1.0 / 0.5 / 0.15 top to bottom (Mix 0.8,
         Smear 0.15, full opacity).
         - Charge 1.0: bottomless — full-strength ink the whole way, strong entry into
           the yellow.
         - Charge 0.5: the deposit visibly dries over the crossing (~1000px half-life).
         - Charge 0.15: dries to a faint tint within a few hundred px; by the yellow patch
           it deposits almost nothing (the patch stays clean).
         """) { s in
    for (i, c) in [CGFloat(1.0), 0.5, 0.15].enumerated() {
        let y = CGFloat(220 + i * 280)
        s.label(String(format: "charge %.2f", c), y: y - 80)
        s.paint(synthStroke(id: 410 + i, brush: pen(yellow, width: 100),
                            from: CGPoint(x: 700, y: y), to: CGPoint(x: 944, y: y),
                            force: { _ in 1 }))
        var b = wet(blue, width: 44, mix: 0.8, smear: 0.15)
        b.wetCharge = c
        s.paint(synthStroke(id: 415 + i, brush: b,
                            from: CGPoint(x: 80, y: y), to: CGPoint(x: 990, y: y)))
    }
}

runScene("wet-10-refill-sweep",
         """
         Refill sweep (Painter "resaturation"): the brush re-loads its own ink over
         distance, so picked-up color DISSIPATES. Each row: a blue wet drag THROUGH a
         yellow patch in the middle, continuing over white — only Refill changes
         (0 / 0.15 / 0.5; Mix 0.8, Smear 0.6 so the crossing contaminates hard).
         - Refill 0: exits the patch green and STAYS green to the end (today's behavior).
         - Refill 0.15: exits green, fades back to pure blue over a few hundred px.
         - Refill 0.5: barely turns — the ink re-asserts within a few dabs, and even
           inside the patch the deposit stays blue-green rather than going full yellow.
         """) { s in
    for (i, r) in [CGFloat(0.0), 0.15, 0.5].enumerated() {
        let y = CGFloat(220 + i * 280)
        s.label(String(format: "refill %.2f", r), y: y - 80)
        s.paint(synthStroke(id: 430 + i, brush: pen(yellow, width: 100),
                            from: CGPoint(x: 330, y: y), to: CGPoint(x: 600, y: y),
                            force: { _ in 1 }))
        var b = wet(blue, width: 44, mix: 0.8, smear: 0.6)
        b.wetRefill = r
        s.paint(synthStroke(id: 435 + i, brush: b,
                            from: CGPoint(x: 80, y: y), to: CGPoint(x: 990, y: y)))
    }
}

runScene("wet-11-charge-refill-invariants",
         """
         Invariant pins for the Charge/Refill dials.
         - Row 1: SMUDGE IMMUNITY. Two identical red patches, each smudged rightward with
           an identical drag — left with default knobs, right with Charge 0.15 + Refill
           0.9. Charge and Refill are INK-mode concepts (smudge has no ink to refill or
           deplete): the two smudge tails must be pixel-identical. Any difference = the
           guards broke.
         - Row 2: REFILL EQUILIBRIUM. A blue drag through a LONG yellow patch at
           Smear 0.6 / Refill 0.3: inside the patch pickup and refill fight to a steady
           PARTIAL green — the trail must never converge to full yellow no matter how
           long the crossing (compare wet-05's smear rows, which do converge), and must
           return to blue after the exit.
         """) { s in
    // Row 1: smudge immunity A/B.
    func smudgeCell(_ idBase: Int, x0: CGFloat, charge: CGFloat, refill: CGFloat) {
        s.paint(synthStroke(id: idBase, brush: pen(red, width: 90),
                            from: CGPoint(x: x0, y: 240), to: CGPoint(x: x0 + 180, y: 240),
                            force: { _ in 1 }))
        var b = wet(red, width: 50, mix: 0.6, smear: 0.85, smudge: true)
        b.wetCharge = charge
        b.wetRefill = refill
        s.paint(synthStroke(id: idBase + 1, brush: b,
                            from: CGPoint(x: x0 + 20, y: 240), to: CGPoint(x: x0 + 400, y: 240)))
    }
    s.label("smudge, default knobs", y: 130)
    smudgeCell(440, x0: 60, charge: 1.0, refill: 0.0)
    s.label("smudge, charge 0.15 + refill 0.9 — must be IDENTICAL", x: 540, y: 130)
    smudgeCell(444, x0: 560, charge: 0.15, refill: 0.9)

    // Row 2: refill equilibrium through a LONG crossing.
    s.label("smear 0.6 / refill 0.3 through a LONG patch — steady partial green, never full yellow", y: 560)
    s.paint(synthStroke(id: 450, brush: pen(yellow, width: 100),
                        from: CGPoint(x: 200, y: 660), to: CGPoint(x: 850, y: 660),
                        force: { _ in 1 }))
    var eq = wet(blue, width: 44, mix: 0.8, smear: 0.6)
    eq.wetRefill = 0.3
    s.paint(synthStroke(id: 451, brush: eq,
                        from: CGPoint(x: 60, y: 660), to: CGPoint(x: 990, y: 660)))
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
    let sceneName = "fixture-\(fixture.name ?? base)"
    sceneDescriptions[sceneName] = "Recorded on-device fixture (\(fixture.strokes.count) strokes) replayed through the current engine."
    scene.snapshot(name: sceneName)
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

// Scene manifest for publish-run.sh → the Tests tab's per-scene descriptions.
if let manifest = try? JSONEncoder().encode(sceneDescriptions) {
    try? manifest.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("manifest.json"))
}

print("DONE")

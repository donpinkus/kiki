import Foundation
import CoreGraphics

// MARK: - Brush Studio live preview
//
// Headless single-stroke renderer behind the Brush Studio's preview strip. Runs the REAL
// engine — the same path BrushHarness uses (StrokeStampGenerator → commitStampsToCanvas for
// dry strokes, WetStrokeWalker for wet) — into a private offscreen document, so what the
// strip shows IS what the brush paints. Never touches the drawing canvas or its hot path;
// the internal waitUntilCompleted/QueueDrained calls are fine at preview cadence (debounced
// knob changes), which is why this class must never be driven per-frame.

@MainActor
public final class BrushPreviewRenderer {

    /// Preview band size in document px. 1024 wide keeps the strip crisp on iPad;
    /// 320 tall fits the max brush width (100 px) plus the stroke's sine bow.
    public static let bandWidth = 1024
    public static let bandHeight = 320

    private let renderer: CanvasRenderer?
    private let side = BrushPreviewRenderer.bandWidth

    public init() {
        renderer = CanvasRenderer()
        renderer?.configureDocument(side: side)
    }

    /// Render one S-curve stroke (pressure ramping light → firm) with the given brush.
    /// Returns a wide band image, or nil when rendering is unavailable (no Metal, or a
    /// smudge brush on a GPU without framebuffer fetch — e.g. the iOS Simulator).
    public func render(_ brush: BrushConfig) -> CGImage? {
        guard let renderer else { return nil }
        renderer.clearAllLayers()

        var config = brush
        // The strip shows brush character, not absolute scale — keep hairlines visible.
        config.baseWidth = max(config.baseWidth, 6)

        let midY = CGFloat(side) / 2
        if config.wetEnabled, config.wetSmudge {
            // A smudge stroke over blank paper shows nothing — give it paint to drag.
            guard renderer.isWetRenderingAvailable else { return nil }
            paintSmudgeBase(renderer, midY: midY)
        }

        let stroke = stabilize(previewStroke(config, midY: midY))
        paint(stroke, into: renderer)
        renderer.waitUntilQueueDrained()

        guard let full = renderer.flattenedOpaqueCGImage(backgroundImage: nil) else { return nil }
        let band = CGRect(x: 0, y: (side - Self.bandHeight) / 2,
                          width: side, height: Self.bandHeight)
        return full.cropping(to: band) ?? full
    }

    // MARK: - Stroke synthesis

    /// An S-curve across the band with pressure sweeping 0.08 → 1.0, upright pencil,
    /// 120 Hz timestamps. Deterministic, so re-renders differ only by the brush.
    private func previewStroke(_ brush: BrushConfig, midY: CGFloat) -> Stroke {
        let a = CGPoint(x: 70, y: midY)
        let b = CGPoint(x: CGFloat(side) - 70, y: midY)
        let bow: CGFloat = 55
        let n = 130
        var pts: [StrokePoint] = []
        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            pts.append(StrokePoint(
                position: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + bow * sin(t * .pi * 2)),
                force: 0.08 + 0.92 * t,
                altitude: .pi / 2,
                timestamp: TimeInterval(i) / 120.0))
        }
        return Stroke(id: Self.strokeUUID(0), points: pts, brush: brush)
    }

    /// Run the points through the P3 StrokeStabilizer exactly like the device does.
    private func stabilize(_ stroke: Stroke) -> Stroke {
        guard stroke.brush.streamline > 0 || stroke.brush.stabilization > 0 else { return stroke }
        var st = StrokeStabilizer(streamline: stroke.brush.streamline,
                                  stabilization: stroke.brush.stabilization)
        var pts = stroke.points.map { st.feed($0) }
        pts.append(contentsOf: st.finish())
        return Stroke(id: stroke.id, points: pts, brush: stroke.brush)
    }

    /// Three soft color bands for the smudge preview to drag through.
    private func paintSmudgeBase(_ renderer: CanvasRenderer, midY: CGFloat) {
        let colors: [CodableColor] = [
            CodableColor(red: 0.85, green: 0.25, blue: 0.2),
            CodableColor(red: 0.95, green: 0.75, blue: 0.2),
            CodableColor(red: 0.25, green: 0.45, blue: 0.85),
        ]
        for (i, color) in colors.enumerated() {
            // Adjacent bars (width ≈ gap) form one continuous tri-color block, so the
            // smudge stroke reads as colors smearing into each other, not isolated dabs.
            let x = CGFloat(side) * (0.335 + 0.165 * CGFloat(i))
            let brush = BrushConfig(color: color, baseWidth: 240, opacity: 1, flow: 1,
                                    hardness: 0.7, spacing: 0.15)
            var pts: [StrokePoint] = []
            for j in 0..<24 {
                let t = CGFloat(j) / 23
                pts.append(StrokePoint(
                    position: CGPoint(x: x, y: midY - 110 + 220 * t),
                    force: 0.7, altitude: .pi / 2, timestamp: TimeInterval(j) / 120.0))
            }
            paint(Stroke(id: Self.strokeUUID(10 + i), points: pts, brush: brush), into: renderer)
        }
        renderer.waitUntilQueueDrained()
    }

    // MARK: - Paint routing (mirrors BrushHarness Scene.paint)

    private func paint(_ stroke: Stroke, into renderer: CanvasRenderer) {
        if stroke.brush.wetEnabled, !stroke.brush.wetSmudge {
            // Wet INK: whole stroke walks at once (KM under-color is a texture sample),
            // then commits through the scratch at the opacity ceiling like a device flatten.
            guard let start = stroke.points.first?.position else { return }
            var walker = WetStrokeWalker(startPosition: start, brush: stroke.brush)
            let stamps = walker.advance(
                stroke: stroke, scale: 1, clipPath: nil,
                sample: { [renderer] x, y in renderer.sampleLayerColor(x: x, y: y) },
                sampleAveraged: { [renderer] x, y, r in renderer.sampleLayerColorAveraged(x: x, y: y, radius: r) },
                mix: { [renderer] a, b, t in renderer.kmMixCPU(a, b, t) })
            renderer.commitStampsToCanvas(stamps, strokeOpacity: Float(stroke.brush.opacity), wetInk: true)
            return
        }
        if stroke.brush.wetEnabled {
            // Smudge: incremental walk in touchesMoved-sized batches, draining between
            // batches so the CPU pickup sees what the GPU committed (device-faithful).
            guard renderer.isWetRenderingAvailable,
                  let start = stroke.points.first?.position else { return }
            var walker = WetStrokeWalker(startPosition: start, brush: stroke.brush)
            var upTo = 1
            while upTo <= stroke.points.count {
                let prefix = Stroke(id: stroke.id,
                                    points: Array(stroke.points.prefix(upTo)),
                                    brush: stroke.brush)
                let stamps = walker.advance(
                    stroke: prefix, scale: 1, clipPath: nil,
                    sample: { [renderer] x, y in renderer.sampleLayerColor(x: x, y: y) },
                    sampleAveraged: { [renderer] x, y, r in renderer.sampleLayerColorAveraged(x: x, y: y, radius: r) },
                    mix: { [renderer] a, b, t in renderer.kmMixCPU(a, b, t) })
                if !stamps.isEmpty {
                    renderer.applyWetStamps(stamps)
                    renderer.waitUntilQueueDrained()
                }
                if upTo == stroke.points.count { break }
                upTo = min(upTo + 4, stroke.points.count)
            }
            return
        }
        let stamps = StrokeStampGenerator.stamps(for: stroke, scale: 1)
        renderer.commitStampsToCanvas(stamps,
                                      strokeOpacity: Float(stroke.brush.opacity),
                                      shapeTexture: renderer.shapeTexture(for: stroke.brush.shapeID),
                                      grain: renderer.grainSettings(for: stroke.brush),
                                      lightness: renderer.lightnessSettings(for: stroke.brush),
                                      flip: renderer.flipSettings(for: stroke.brush))
    }

    /// Deterministic UUID (spacing jitter etc. are seeded by stroke id — a stable id
    /// keeps re-renders identical so only knob changes alter the image).
    private static func strokeUUID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-BB00-4000-8000-%012d", n)) ?? UUID()
    }
}

import Foundation
import CoreGraphics

/// Stroke stabilization (P3 rebuild, 2026-07-15) — pure and UIKit-free so OfflineTests
/// asserts the math and BrushHarness renders it (per `feedback_verify_shader_color_offline`).
///
/// Three independent stages, mirroring Procreate's Stabilization section on Krita-verified
/// mechanics (research doc 10 §3, `13-procreate-parity.md`):
///
///  1. **StreamLine** (`streamline` ∈ [0,1]) — the time-constant low-pass cursor that pulls
///     the drawn position toward the raw pencil position. The EXACT formula previously
///     inlined in `MetalCanvasView.smoothedStrokePoint` (tau = streamline·0.12s, dt clamped
///     to 4 frames — frame-rate independent), moved verbatim; `streamline == 0` is a strict
///     passthrough.
///  2. **Smoothing** (`stabilization` ∈ [0,1]) — Gaussian-weighted average over trailing
///     ARC LENGTH (Krita `kis_tool_freehand_helper.cpp:516-607`): weights depend on the
///     distance drawn, not on event timing, so 60/120/240 Hz sampling of the same path
///     produce the same curve. This is what gives clean C1-ish curvature (the shape klein
///     reads) instead of a lagged polyline.
///  3. **Pressure smoothing** (`pressureSmoothing` ∈ [0,1]) — the same time-constant
///     low-pass applied to force only (Procreate "StreamLine → Pressure"); conservative,
///     never touches geometry.
///
/// **Catch-up on lift**: both position stages lag the pencil by design, so on touch-up the
/// stroke would stop short of where the pencil actually ended (worse the higher the
/// settings — the pre-rebuild behavior). `finish()` emits a spaced chain of points from the
/// lagged cursor to the true raw endpoint (Krita's catch-up), so every stroke ends exactly
/// where the pencil lifted.
struct StrokeStabilizer {

    private let streamline: CGFloat
    private let stabilization: CGFloat
    private let pressureSmoothing: CGFloat

    // StreamLine state (identical to the old MetalCanvasView ivars).
    private var cursor: CGPoint?
    private var lastTime: TimeInterval?
    // Pressure low-pass state.
    private var forceCursor: CGFloat?
    /// One trailing Gaussian-over-arc-length averaging window. Applied TWICE in series
    /// (stage 2): a single pass over harshly jittery input is starved by noise-inflated
    /// arc length (few effective samples in the window); cascading two passes squares
    /// the transfer function and kills the residual high frequency — the standard
    /// cheap approximation of a wider clean kernel. Catch-up covers the added lag.
    private struct GaussianArcWindow {
        private var window: [(pos: CGPoint, arc: CGFloat)] = []
        private var arcLength: CGFloat = 0

        mutating func feed(_ p: CGPoint, sigma: CGFloat) -> CGPoint {
            if let last = window.last {
                arcLength += hypot(p.x - last.pos.x, p.y - last.pos.y)
            }
            window.append((pos: p, arc: arcLength))
            // Prune beyond 3σ of trailing arc (bounded memory, bounded lag).
            let cutoff = arcLength - sigma * 3
            if let firstKept = window.firstIndex(where: { $0.arc >= cutoff }), firstKept > 0 {
                window.removeFirst(firstKept)
            }
            var sumW: CGFloat = 0, sx: CGFloat = 0, sy: CGFloat = 0
            for entry in window {
                let d = arcLength - entry.arc
                let w = exp(-(d * d) / (2 * sigma * sigma))
                sumW += w
                sx += entry.pos.x * w
                sy += entry.pos.y * w
            }
            return sumW > 0 ? CGPoint(x: sx / sumW, y: sy / sumW) : p
        }
    }

    private var gaussA = GaussianArcWindow()
    private var gaussB = GaussianArcWindow()
    /// Last RAW input point (catch-up target).
    private var lastRaw: StrokePoint?
    /// Last point actually emitted (catch-up start + spacing bookkeeping).
    private var lastEmitted: StrokePoint?

    /// σ in canvas/view points for the Gaussian stage at stabilization == 1.
    /// Tuned in the harness (dry-07): 30pt left visible micro-wobble on ±6px tremor at
    /// 0.7; 48pt reads as "confident" through the whole range without going soupy
    /// (catch-up covers the extra lag). Squared response below gives fine control at
    /// the low end where small σ changes matter most.
    private static let maxSigma: CGFloat = 48

    init(streamline: CGFloat, stabilization: CGFloat = 0, pressureSmoothing: CGFloat = 0) {
        self.streamline = max(0, min(1, streamline))
        self.stabilization = max(0, min(1, stabilization))
        self.pressureSmoothing = max(0, min(1, pressureSmoothing))
    }

    /// True when every stage is off — callers may skip feeding entirely (the default pen
    /// must stay byte-identical to the pre-stabilizer path).
    var isPassthrough: Bool { streamline == 0 && stabilization == 0 && pressureSmoothing == 0 }

    /// Process one raw input point → one output point (same cadence as the input, like the
    /// old inline smoothing — stamp generation interpolates between points by arc length).
    mutating func feed(_ raw: StrokePoint) -> StrokePoint {
        lastRaw = raw
        var point = raw

        // Stage 1 — StreamLine (verbatim port of smoothedStrokePoint's math).
        if streamline > 0 {
            let prev = cursor ?? point.position
            let dt = min(4.0 / 120.0, lastTime.map { max(0, point.timestamp - $0) } ?? (1.0 / 120.0))
            let tau = max(0.004, Double(streamline) * 0.12) // seconds
            let factor = CGFloat(min(1.0, max(0.04, 1.0 - exp(-dt / tau))))
            point.position = CGPoint(
                x: prev.x + (point.position.x - prev.x) * factor,
                y: prev.y + (point.position.y - prev.y) * factor
            )
        }
        cursor = point.position
        lastTime = point.timestamp

        // Stage 2 — Gaussian over trailing arc length, two passes in series.
        if stabilization > 0 {
            let sigma = stabilization * stabilization * Self.maxSigma + 2
            let once = gaussA.feed(point.position, sigma: sigma)
            point.position = gaussB.feed(once, sigma: sigma)
        }

        // Stage 3 — pressure low-pass (geometry untouched; same time-constant form).
        if pressureSmoothing > 0 {
            let prevF = forceCursor ?? point.force
            let dt = min(4.0 / 120.0, lastTime.map { max(0, point.timestamp - $0) } ?? (1.0 / 120.0))
            let tau = max(0.004, Double(pressureSmoothing) * 0.10)
            let factor = CGFloat(min(1.0, max(0.04, 1.0 - exp(-dt / tau))))
            point.force = prevF + (point.force - prevF) * factor
        }
        forceCursor = point.force

        lastEmitted = point
        return point
    }

    /// Catch-up on lift: a spaced chain of points from the lagged output position to the
    /// TRUE raw endpoint, carrying the final force/tilt forward. Returns [] when nothing
    /// lags (passthrough, or the cursor already reached the pencil). Call once, on touch-up,
    /// and append the results to the stroke before the final flatten.
    func finish() -> [StrokePoint] {
        guard let raw = lastRaw, let from = lastEmitted else { return [] }
        let dx = raw.position.x - from.position.x
        let dy = raw.position.y - from.position.y
        let dist = hypot(dx, dy)
        guard dist > 0.5 else { return [] }

        // ~2pt spacing keeps the tail as dense as normal 120Hz input; cap the count so a
        // pathological gap can't emit thousands of points.
        let steps = min(256, max(1, Int(ceil(dist / 2))))
        var out: [StrokePoint] = []
        out.reserveCapacity(steps)
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            var p = raw // final force/altitude/azimuth carried through the tail
            p.position = CGPoint(x: from.position.x + dx * t, y: from.position.y + dy * t)
            // Nudge timestamps forward so downstream dt math stays monotonic.
            p.timestamp = raw.timestamp + TimeInterval(i) * 0.0005
            out.append(p)
        }
        return out
    }
}

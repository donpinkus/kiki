#if DEBUG
import CanvasModule
import CoreGraphics
import Foundation
import os

/// Physical-device self-test for the magic wand's SAM pipeline, launched with
/// `-KikiWandSelfTest 1` (readable via `ipad.sh logs`). Exists because the iOS
/// SIMULATOR's Core ML backend returns all-zero mask logits for SAM's decoder
/// (verified 2026-07-19 on the 18.3.1 + 26.5 runtimes, CPU and GPU compute
/// units, while the identical .mlmodelc files produce correct masks on macOS),
/// so end-to-end SAM verification needs real hardware. Renders the same
/// synthetic scene as the offline harness (blue circle + red square on white),
/// encodes, decodes a one-point prompt, and logs mask stats.
enum WandSelfTest {
    private static let log = Logger(subsystem: "com.kiki.app", category: "WandSelfTest")

    static func runIfRequested() {
        guard UserDefaults.standard.bool(forKey: "KikiWandSelfTest") else { return }
        Task.detached(priority: .userInitiated) {
            do {
                let clock = ContinuousClock()
                var start = clock.now
                let segmenter = try SAM2Segmenter.bundled()
                log.info("self-test: models loaded in \(String(describing: clock.now - start))")

                let scene = makeScene()
                start = clock.now
                try await segmenter.encode(scene)
                log.info("self-test: encode \(String(describing: clock.now - start))")

                start = clock.now
                let result = try await segmenter.mask(for: [WandSample(x: 280, y: 400, positive: true)])
                let decodeTime = clock.now - start
                let mask = MaskContour.binaryMask(
                    fromLogits: result.logits, width: result.width, height: result.height,
                    upsampledSide: 1024)
                let area = mask.reduce(0) { $0 + Int($1) }
                let inside = mask[400 * 1024 + 280]
                let outside = mask[400 * 1024 + 700]
                let path = MaskContour.path(fromBinary: mask, side: 1024)
                // Expected (from the macOS harness): area ≈ 61.5k, inside=1, outside=0.
                log.info("self-test: decode \(String(describing: decodeTime)) score=\(result.score) area=\(area) inside=\(inside) outside=\(outside) path=\(path == nil ? "nil" : "ok")")
                let pass = area > 30_000 && area < 120_000 && inside == 1 && outside == 0 && path != nil
                log.info("self-test: \(pass ? "PASS" : "FAIL")")
            } catch {
                log.error("self-test FAILED: \(String(describing: error))")
            }
        }
    }

    private static func makeScene() -> CGImage {
        let side = 1024
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        // CG origin bottom-left; the prompt (280, 400) is in top-left coords.
        ctx.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.9, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: 280 - 140, y: 624 - 140, width: 280, height: 280))
        ctx.setFillColor(CGColor(red: 0.9, green: 0.2, blue: 0.15, alpha: 1))
        ctx.fill(CGRect(x: 620, y: 444, width: 280, height: 280))
        return ctx.makeImage()!
    }
}
#endif

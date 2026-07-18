import AVFoundation
import OSLog
import Sentry
import UIKit

private let recorderLog = Logger(subsystem: "com.kiki.app", category: "VideoRecorder")

/// Records two frame-locked H.264 tracks per drawing session — the user's canvas
/// and the generated result — to temp MP4s via `AVAssetWriter`. A paired frame is
/// appended to BOTH tracks whenever either source changes (canvas dirty-tick or a
/// new generated frame), so the tracks are always equal length and trivially
/// composable side-by-side. Frames are only appended on change, so idle time is
/// removed and the result plays back as a continuous timelapse.
///
/// All work runs on a private serial queue — never on the Metal/main hot path.
/// `UIImage` is `Sendable`, so callers hand frames in directly.
final class DrawingVideoRecorder {

    private let queue = DispatchQueue(label: "com.kiki.video-recorder")
    private let side: Int
    private let fps: Int32

    private var canvas: TrackWriter?
    private var generated: TrackWriter?
    private var canvasTempURL: URL?
    private var generatedTempURL: URL?
    private var frameIndex: Int64 = 0
    private var lastCanvas: CVPixelBuffer?
    private var lastGenerated: CVPixelBuffer?
    private var blank: CVPixelBuffer?
    private var started = false

    /// `side` is the per-track square edge; `fps` is the playback rate (the
    /// capture cadence is real-time-sparse, so 12 fps yields a sped-up timelapse).
    init(side: Int = 768, fps: Int = 12) {
        self.side = side
        self.fps = Int32(fps)
    }

    func start() {
        queue.async {
            self.lastCanvas = nil
            self.lastGenerated = nil
            self.blank = nil
            self.started = self.makeWritersLocked()
            if !self.started {
                // Without this the recorder silently drops every frame while
                // the UI still offers the replay — must be loud.
                recorderLog.error("Recorder start failed: AVAssetWriter setup unsuccessful")
                SentrySDK.capture(message: "replay.recorder_start_failed") { scope in
                    scope.setLevel(.error)
                }
            }
        }
    }

    /// Create a fresh pair of track writers (a new segment) on temp files, and
    /// reset the per-segment frame index. Preserves `lastCanvas`/`lastGenerated`
    /// so a segment created by `checkpoint()` continues visually from where the
    /// previous one ended.
    private func makeWritersLocked() -> Bool {
        let dir = FileManager.default.temporaryDirectory
        let canvasURL = dir.appendingPathComponent("rec-canvas-\(UUID().uuidString).mp4")
        let generatedURL = dir.appendingPathComponent("rec-generated-\(UUID().uuidString).mp4")
        guard let c = TrackWriter(url: canvasURL, side: side),
              let g = TrackWriter(url: generatedURL, side: side) else { return false }
        canvas = c
        generated = g
        canvasTempURL = canvasURL
        generatedTempURL = generatedURL
        frameIndex = 0
        return true
    }

    /// Seed the generated pane's "last frame" without appending anything —
    /// used at session start with the drawing's saved generated image so a
    /// resumed session's first frames don't render a white generated pane.
    /// No-op once a real generated frame exists.
    func seedGenerated(_ image: UIImage) {
        queue.async {
            guard self.started, self.lastGenerated == nil,
                  let buffer = self.pixelBuffer(from: image) else { return }
            self.lastGenerated = buffer
        }
    }

    /// Call when the canvas visibly changed (passes the capture-loop dirty check).
    func canvasChanged(_ image: UIImage) {
        queue.async {
            guard self.started, let buffer = self.pixelBuffer(from: image) else { return }
            self.lastCanvas = buffer
            self.appendPair()
        }
    }

    /// Call when a new generated frame arrived.
    func generatedChanged(_ image: UIImage) {
        queue.async {
            guard self.started, let buffer = self.pixelBuffer(from: image) else { return }
            self.lastGenerated = buffer
            self.appendPair()
        }
    }

    /// Append the current (canvas, generated) pair at the next frame slot. Both
    /// tracks advance together so they stay frame-locked. We don't start writing
    /// until the first canvas frame exists; the generated pane shows a blank frame
    /// for any leading window before the first generation arrives.
    private func appendPair() {
        guard let canvas, let generated, let canvasBuffer = lastCanvas else { return }
        guard canvas.isReady, generated.isReady else { return }
        guard let generatedBuffer = lastGenerated ?? blankBuffer() else { return }
        let time = CMTime(value: frameIndex, timescale: fps)
        canvas.append(canvasBuffer, at: time)
        generated.append(generatedBuffer, at: time)
        frameIndex += 1
    }

    /// Finalize the current segment and immediately start a new one so recording
    /// continues uninterrupted. Returns the finalized segment's temp URLs (to hand
    /// to `RecordingStore.appendSegment`), or nil if nothing new was captured since
    /// the last checkpoint.
    func checkpoint() async -> (canvas: URL, generated: URL)? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.started, self.frameIndex >= 2,
                      let oldCanvas = self.canvas, let oldGenerated = self.generated,
                      let oldCanvasURL = self.canvasTempURL, let oldGeneratedURL = self.generatedTempURL else {
                    recorderLog.info("checkpoint: no segment (started=\(self.started) frames=\(self.frameIndex))")
                    continuation.resume(returning: nil)
                    return
                }
                // Swap in fresh writers FIRST so any queued appends land in the new
                // segment, never in the one being finalized.
                if !self.makeWritersLocked() {
                    self.started = false
                }
                let group = DispatchGroup()
                group.enter(); oldCanvas.finish { group.leave() }
                group.enter(); oldGenerated.finish { group.leave() }
                group.notify(queue: self.queue) {
                    continuation.resume(returning: (oldCanvasURL, oldGeneratedURL))
                }
            }
        }
    }

    /// Finalize the current segment and stop. Returns its temp URLs, or nil if
    /// too few frames were captured.
    func finish() async -> (canvas: URL, generated: URL)? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.started, self.frameIndex >= 2,
                      let canvas = self.canvas, let generated = self.generated,
                      let canvasURL = self.canvasTempURL, let generatedURL = self.generatedTempURL else {
                    recorderLog.info("finish: no segment (started=\(self.started) frames=\(self.frameIndex))")
                    self.teardownLocked(deleteTemps: true)
                    continuation.resume(returning: nil)
                    return
                }
                self.started = false
                let group = DispatchGroup()
                group.enter(); canvas.finish { group.leave() }
                group.enter(); generated.finish { group.leave() }
                group.notify(queue: self.queue) {
                    self.canvas = nil
                    self.generated = nil
                    self.canvasTempURL = nil
                    self.generatedTempURL = nil
                    continuation.resume(returning: (canvasURL, generatedURL))
                }
            }
        }
    }

    /// Discard the in-progress recording (e.g. an empty drawing).
    func cancel() {
        queue.async {
            self.canvas?.cancel()
            self.generated?.cancel()
            self.teardownLocked(deleteTemps: true)
        }
    }

    private func teardownLocked(deleteTemps: Bool) {
        if deleteTemps {
            [canvasTempURL, generatedTempURL].compactMap { $0 }.forEach {
                try? FileManager.default.removeItem(at: $0)
            }
        }
        canvas = nil
        generated = nil
        canvasTempURL = nil
        generatedTempURL = nil
        lastCanvas = nil
        lastGenerated = nil
        blank = nil
        started = false
    }

    // MARK: - Pixel buffers

    /// Render a UIImage into a `side`×`side` BGRA buffer, aspect-filling on white.
    private func pixelBuffer(from image: UIImage) -> CVPixelBuffer? {
        guard let cgImage = image.cgImage, let buffer = makeBuffer() else { return nil }
        draw(cgImage, into: buffer)
        return buffer
    }

    /// A white square buffer used for the generated pane before the first
    /// generation arrives.
    private func blankBuffer() -> CVPixelBuffer? {
        if let blank { return blank }
        guard let buffer = makeBuffer() else { return nil }
        fillWhite(buffer)
        blank = buffer
        return buffer
    }

    private func makeBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                         kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        return status == kCVReturnSuccess ? pb : nil
    }

    private func context(for buffer: CVPixelBuffer) -> CGContext? {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
    }

    private func draw(_ cgImage: CGImage, into buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = context(for: buffer) else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
        let imageW = CGFloat(cgImage.width), imageH = CGFloat(cgImage.height)
        let scale = max(CGFloat(side) / imageW, CGFloat(side) / imageH)
        let drawW = imageW * scale, drawH = imageH * scale
        let rect = CGRect(x: (CGFloat(side) - drawW) / 2, y: (CGFloat(side) - drawH) / 2, width: drawW, height: drawH)
        ctx.draw(cgImage, in: rect)
    }

    private func fillWhite(_ buffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = context(for: buffer) else { return }
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))
    }
}

/// One H.264 video track backed by an `AVAssetWriter`. Write-as-you-go: each
/// frame is appended and encoded to disk immediately, so memory stays bounded.
private final class TrackWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    var isReady: Bool { input.isReadyForMoreMediaData }

    init?(url: URL, side: Int) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: side,
            AVVideoHeightKey: side,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side,
            kCVPixelBufferHeightKey as String: side,
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
        self.input = input
        self.adaptor = adaptor
    }

    func append(_ buffer: CVPixelBuffer, at time: CMTime) {
        _ = adaptor.append(buffer, withPresentationTime: time)
    }

    func finish(completion: @escaping () -> Void) {
        input.markAsFinished()
        writer.finishWriting(completionHandler: completion)
    }

    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }
}

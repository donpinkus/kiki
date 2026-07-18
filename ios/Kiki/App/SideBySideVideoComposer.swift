import AVFoundation
import CoreGraphics
import UIKit

/// How the two recorded panes are arranged in the exported replay, sized to
/// fit common Instagram aspect ratios.
enum ReplayLayout: String, CaseIterable, Identifiable {
    /// Two squares side by side — 2:1 landscape (Instagram feed).
    case horizontal
    /// Two squares stacked — 9:16 portrait (Instagram Reels / Stories).
    case vertical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .horizontal: return "Side by side"
        case .vertical: return "Stacked"
        }
    }

    /// Output canvas size, chosen to drop straight into Instagram.
    var renderSize: CGSize {
        switch self {
        case .horizontal: return CGSize(width: 1080, height: 540)   // 2:1 feed
        case .vertical: return CGSize(width: 1080, height: 1920)    // 9:16 reel
        }
    }

    /// Preview aspect ratio (width / height).
    var aspectRatio: CGFloat { renderSize.width / renderSize.height }
}

/// How the replay timeline is scaled.
enum ReplaySpeed: Equatable {
    /// Fixed multiplier (2 = twice as fast).
    case multiplier(Double)
    /// Scale the drawn content so content + final hold total `seconds` —
    /// sized so the exported video never splits when shared to Instagram /
    /// TikTok. Never slower than real time (short recordings just come out
    /// shorter than the target). The animation tail is skipped in this mode
    /// (fixed 3s freeze-hold only) so the target is exact.
    case fitTotal(seconds: Double)
}

/// Composes the two recorded tracks (canvas + generated) into one replay MP4 in
/// the chosen layout and playback speed, on demand. The tracks are equal length
/// and frame-locked by construction, so this is a layout + time-scale pass.
enum SideBySideVideoComposer {

    enum ComposeError: Error {
        case missingTrack
        case exportSetupFailed
        case exportFailed(Error?)
    }

    /// A composed-but-not-encoded replay. Hand `composition` + `videoComposition`
    /// straight to an `AVPlayerItem` for instant preview (no export pass), or run
    /// it through `export(...)` to encode an MP4. The watermark is burned only at
    /// export (`AVVideoCompositionCoreAnimationTool` is export-only — attaching
    /// it to a player item throws), so previews overlay the watermark in SwiftUI.
    struct BuiltReplay {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition
        let layout: ReplayLayout
    }

    /// Stitch the recorded segments into a playable composition. `side` is the
    /// per-track source edge (matches the recorder).
    static func build(
        canvasSegments: [URL],
        generatedSegments: [URL],
        generatedVideoURL: URL? = nil,
        layout: ReplayLayout = .horizontal,
        speed: ReplaySpeed = .multiplier(1),
        side: Int = 768
    ) async throws -> BuiltReplay {
        guard !canvasSegments.isEmpty, canvasSegments.count == generatedSegments.count else {
            throw ComposeError.missingTrack
        }

        let composition = AVMutableComposition()
        guard let canvasComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let generatedComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposeError.exportSetupFailed
        }

        // Stitch the per-checkpoint segments back-to-back into each track.
        var cursor = CMTime.zero
        var lastCanvasTrack: AVAssetTrack?
        var lastGeneratedTrack: AVAssetTrack?
        var lastSegmentDuration = CMTime.zero
        for (canvasURL, generatedURL) in zip(canvasSegments, generatedSegments) {
            let canvasAsset = AVURLAsset(url: canvasURL)
            let generatedAsset = AVURLAsset(url: generatedURL)
            guard let canvasTrack = try await canvasAsset.loadTracks(withMediaType: .video).first,
                  let generatedTrack = try await generatedAsset.loadTracks(withMediaType: .video).first else {
                continue
            }
            // Segments are equal length per pair; min() guards rounding skew.
            let dur = try await min(canvasAsset.load(.duration), generatedAsset.load(.duration))
            guard dur.isValid, dur > .zero else { continue }
            let range = CMTimeRange(start: .zero, duration: dur)
            try canvasComp.insertTimeRange(range, of: canvasTrack, at: cursor)
            try generatedComp.insertTimeRange(range, of: generatedTrack, at: cursor)
            cursor = cursor + dur
            lastCanvasTrack = canvasTrack
            lastGeneratedTrack = generatedTrack
            lastSegmentDuration = dur
        }
        guard cursor > .zero else { throw ComposeError.missingTrack }
        let baseDuration = cursor
        let baseRange = CMTimeRange(start: .zero, duration: baseDuration)

        // How long the final frame holds at the end (freeze or animation floor).
        let holdSeconds = 3.0

        // Resolve the effective multiplier. `fitTotal` sizes content so
        // content + hold hits the target; clamped to ≥1 so short recordings
        // play at real speed instead of slow motion.
        let effectiveMultiplier: Double
        let useAnimationTail: Bool
        switch speed {
        case .multiplier(let m):
            effectiveMultiplier = max(m, 0.01)
            useAnimationTail = true
        case .fitTotal(let totalSeconds):
            let contentTarget = max(totalSeconds - holdSeconds, 0.5)
            effectiveMultiplier = max(baseDuration.seconds / contentTarget, 1.0)
            useAnimationTail = false
        }

        // Speed: scale both tracks' timelines to 1/multiplier of their duration.
        var finalDuration: CMTime
        if effectiveMultiplier != 1 {
            let scaled = CMTimeMultiplyByFloat64(baseDuration, multiplier: 1.0 / effectiveMultiplier)
            canvasComp.scaleTimeRange(baseRange, toDuration: scaled)
            generatedComp.scaleTimeRange(baseRange, toDuration: scaled)
            finalDuration = scaled
        } else {
            finalDuration = baseDuration
        }

        let renderSize = layout.renderSize

        // Tail: append the generated animation (canvas frozen on the final drawing
        // | animation playing in the generated pane), or — if there's no animation
        // (or the mode wants an exact total) — hold the final frame. Real-time,
        // not sped up.
        let oneFrame = CMTime(value: 1, timescale: 12)
        let tailStart = finalDuration
        var tailGeneratedTransform: CGAffineTransform?
        // Best-effort: a tail failure must NEVER blank the whole replay. On any
        // error we reset to the pre-tail duration; the instruction below is
        // clamped to `finalDuration`, so partial inserts past it aren't rendered.
        if lastSegmentDuration > oneFrame, let lastCanvasTrack {
            do {
                let lastFrameRange = CMTimeRange(start: lastSegmentDuration - oneFrame, duration: oneFrame)
                var appendedAnimation = false

                if useAnimationTail, let generatedVideoURL {
                    let animAsset = AVURLAsset(url: generatedVideoURL)
                    let animTrack = try? await animAsset.loadTracks(withMediaType: .video).first
                    // Use the TRACK's own range — the asset duration can exceed it,
                    // which would make insertTimeRange throw.
                    let animRange = try? await animTrack?.load(.timeRange)
                    if let animTrack, let animRange, animRange.duration.isValid, animRange.duration > .zero {
                        try generatedComp.insertTimeRange(animRange, of: animTrack, at: tailStart)
                        try canvasComp.insertTimeRange(lastFrameRange, of: lastCanvasTrack, at: tailStart)
                        canvasComp.scaleTimeRange(CMTimeRange(start: tailStart, duration: oneFrame), toDuration: animRange.duration)
                        // The animation isn't 768²; fit it into the generated pane.
                        let animSize = (try? await animTrack.load(.naturalSize)) ?? CGSize(width: side, height: side)
                        tailGeneratedTransform = fitTransform(sourceSize: animSize, into: generatedPaneRect(for: layout, render: renderSize))
                        finalDuration = tailStart + animRange.duration
                        appendedAnimation = true
                    }
                }

                if !appendedAnimation, let lastGeneratedTrack {
                    let hold = CMTime(seconds: holdSeconds, preferredTimescale: 600)
                    try canvasComp.insertTimeRange(lastFrameRange, of: lastCanvasTrack, at: tailStart)
                    try generatedComp.insertTimeRange(lastFrameRange, of: lastGeneratedTrack, at: tailStart)
                    let frozen = CMTimeRange(start: tailStart, duration: oneFrame)
                    canvasComp.scaleTimeRange(frozen, toDuration: hold)
                    generatedComp.scaleTimeRange(frozen, toDuration: hold)
                    finalDuration = tailStart + hold
                }
            } catch {
                // Drop the tail, keep the main replay.
                finalDuration = tailStart
                tailGeneratedTransform = nil
            }
        }

        // Layout: position each pane within the render canvas. Uncovered areas
        // (the vertical layout's side margins) render black — intentional letterbox.
        let src = CGFloat(side)
        let (canvasTransform, generatedTransform) = transforms(for: layout, source: src, render: renderSize)

        let canvasInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: canvasComp)
        canvasInstruction.setTransform(canvasTransform, at: .zero)
        let generatedInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: generatedComp)
        generatedInstruction.setTransform(generatedTransform, at: .zero)
        // The appended animation has its own size, so re-fit the generated pane
        // from the tail onward.
        if let tailGeneratedTransform {
            generatedInstruction.setTransform(tailGeneratedTransform, at: tailStart)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: finalDuration)
        instruction.layerInstructions = [generatedInstruction, canvasInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        return BuiltReplay(composition: composition, videoComposition: videoComposition, layout: layout)
    }

    /// Encode a built replay to `outputURL` (overwritten if present), burning
    /// the watermark when requested. Mutates `built.videoComposition` — pass a
    /// fresh `build(...)` result, never one currently attached to a player.
    static func export(_ built: BuiltReplay, outputURL: URL, watermark: Bool) async throws {
        if watermark {
            built.videoComposition.animationTool = watermarkTool(
                renderSize: built.videoComposition.renderSize,
                layout: built.layout
            )
        }

        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposeError.exportSetupFailed
        }
        export.videoComposition = built.videoComposition
        export.outputURL = outputURL
        export.outputFileType = .mp4

        await withCheckedContinuation { continuation in
            export.exportAsynchronously { continuation.resume() }
        }
        guard export.status == .completed else {
            throw ComposeError.exportFailed(export.error)
        }
    }

    /// Affine transforms that scale each square source pane to fit and position
    /// it within the render canvas. A `[scale 0 0 scale tx ty]` matrix maps a
    /// source point (x,y) to (scale·x + tx, scale·y + ty).
    private static func transforms(
        for layout: ReplayLayout,
        source: CGFloat,
        render: CGSize
    ) -> (canvas: CGAffineTransform, generated: CGAffineTransform) {
        switch layout {
        case .horizontal:
            let pane = render.width / 2          // 540
            let scale = pane / source
            return (place(scale: scale, tx: 0, ty: 0),
                    place(scale: scale, tx: pane, ty: 0))
        case .vertical:
            let pane = render.height / 2         // 960
            let scale = pane / source
            let x = (render.width - pane) / 2    // center horizontally (letterbox sides)
            return (place(scale: scale, tx: x, ty: 0),
                    place(scale: scale, tx: x, ty: pane))
        }
    }

    private static func place(scale: CGFloat, tx: CGFloat, ty: CGFloat) -> CGAffineTransform {
        var t = CGAffineTransform(scaleX: scale, y: scale)
        t.tx = tx
        t.ty = ty
        return t
    }

    /// The destination rect of the generated (right/bottom) pane in the render
    /// canvas — used to fit the appended animation, which may not be square.
    private static func generatedPaneRect(for layout: ReplayLayout, render: CGSize) -> CGRect {
        switch layout {
        case .horizontal:
            let pane = render.width / 2
            return CGRect(x: pane, y: 0, width: pane, height: pane)
        case .vertical:
            let pane = render.height / 2
            return CGRect(x: (render.width - pane) / 2, y: pane, width: pane, height: pane)
        }
    }

    /// Aspect-fit a source of `sourceSize` centered within `rect`.
    private static func fitTransform(sourceSize: CGSize, into rect: CGRect) -> CGAffineTransform {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return .identity }
        let scale = min(rect.width / sourceSize.width, rect.height / sourceSize.height)
        let drawW = sourceSize.width * scale
        let drawH = sourceSize.height * scale
        return place(
            scale: scale,
            tx: rect.minX + (rect.width - drawW) / 2,
            ty: rect.minY + (rect.height - drawH) / 2
        )
    }

    // MARK: - Watermark

    /// Core Animation overlay tool that burns a small "Drawn with Kiki" + app-icon
    /// watermark into the top-right corner of the composed video.
    private static func watermarkTool(renderSize: CGSize, layout: ReplayLayout) -> AVVideoCompositionCoreAnimationTool {
        let videoLayer = CALayer()
        videoLayer.frame = CGRect(origin: .zero, size: renderSize)
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: renderSize)
        parent.addSublayer(videoLayer)
        if let mark = watermarkLayer(in: renderSize, layout: layout) {
            parent.addSublayer(mark)
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
    }

    /// Renders the text + rounded icon into a single image and returns a layer
    /// positioned top-right. Core Animation uses a bottom-left origin, so the top
    /// edge is the high-y end. Kept small and slightly translucent to stay discreet.
    private static func watermarkLayer(in size: CGSize, layout: ReplayLayout) -> CALayer? {
        let scaleBase = max(size.width, size.height)
        // Inset from the top/right corner. Proportional so it reads as a real
        // margin at the video's native resolution (a literal few px is invisible
        // once Instagram scales 1080-wide footage onto a phone).
        let margin = scaleBase * 0.02
        // The vertical/story layout needs extra right clearance so the mark
        // doesn't sit under Instagram's "..." / close (X) buttons in the top-right.
        let rightMargin = margin + (layout == .vertical ? 160 : 0)
        let iconSize = scaleBase * 0.04
        let fontSize = scaleBase * 0.0165
        let gap = iconSize * 0.3
        // Padding inside the rendered image so the drop shadow isn't clipped.
        let pad = ceil(fontSize * 0.18)

        // "Drawn with " in a dark blue-grey; "Kiki" in a vivid icon purple.
        let attributed = NSMutableAttributedString(
            string: "Drawn with Kiki",
            attributes: [
                .font: roundedFont(ofSize: fontSize, weight: .bold),
                .foregroundColor: UIColor(red: 0.15, green: 0.17, blue: 0.24, alpha: 1),
            ]
        )
        let kikiRange = (attributed.string as NSString).range(of: "Kiki")
        if kikiRange.location != NSNotFound {
            attributed.addAttribute(
                .foregroundColor,
                value: UIColor(hue: 0.75, saturation: 0.85, brightness: 0.92, alpha: 1),
                range: kikiRange
            )
        }
        let textSize = attributed.size()
        let contentW = pad + textSize.width + gap + iconSize + pad
        let contentH = max(iconSize, textSize.height) + pad * 2
        let textOrigin = CGPoint(x: pad, y: (contentH - textSize.height) / 2)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: contentW, height: contentH), format: format)
        let image = renderer.image { ctx in
            let cg = ctx.cgContext

            // Pass 1: tight white drop shadow — high contrast for the dark text,
            // especially where it strays over the darker generated pane.
            cg.setShadow(
                offset: CGSize(width: 0, height: max(1, fontSize * 0.05)),
                blur: fontSize * 0.08,
                color: UIColor.white.cgColor
            )
            attributed.draw(at: textOrigin)

            // Pass 2: soft, even, low-opacity white halo (no offset) so the TOPS of
            // the letters stay legible too.
            cg.setShadow(
                offset: .zero,
                blur: max(2, fontSize * 0.1),
                color: UIColor.white.withAlphaComponent(0.5).cgColor
            )
            attributed.draw(at: textOrigin)

            if let icon = UIImage(named: "kiki_mark") {
                let iconRect = CGRect(x: pad + textSize.width + gap, y: (contentH - iconSize) / 2, width: iconSize, height: iconSize)
                cg.saveGState()
                UIBezierPath(roundedRect: iconRect, cornerRadius: iconSize * 0.22).addClip()
                icon.draw(in: iconRect)
                cg.restoreGState()
            }
        }

        let layer = CALayer()
        layer.contents = image.cgImage
        layer.contentsGravity = .resizeAspect
        layer.opacity = 0.9
        layer.frame = CGRect(
            x: size.width - rightMargin - contentW,
            // 5px lower than the top margin (CA origin is bottom-left, so subtract).
            y: size.height - margin - contentH - 5,
            width: contentW,
            height: contentH
        )
        return layer
    }

    /// SF Pro Rounded at the given weight — friendlier and more legible than the
    /// default system font for a watermark. Falls back to the system font if the
    /// rounded design isn't available.
    private static func roundedFont(ofSize size: CGFloat, weight: UIFont.Weight) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }
}

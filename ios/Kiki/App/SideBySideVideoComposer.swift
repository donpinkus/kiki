import AVFoundation
import CoreGraphics

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

/// Composes the two recorded tracks (canvas + generated) into one replay MP4 in
/// the chosen layout and playback speed, on demand. The tracks are equal length
/// and frame-locked by construction, so this is a layout + time-scale pass.
enum SideBySideVideoComposer {

    enum ComposeError: Error {
        case missingTrack
        case exportSetupFailed
        case exportFailed(Error?)
    }

    /// Build the replay and write it to `outputURL` (overwritten if present).
    /// `side` is the per-track source edge (matches the recorder); `speed` scales
    /// the timeline (2 = twice as fast).
    static func compose(
        canvasURL: URL,
        generatedURL: URL,
        outputURL: URL,
        layout: ReplayLayout = .horizontal,
        speed: Double = 1,
        side: Int = 768
    ) async throws {
        let canvasAsset = AVURLAsset(url: canvasURL)
        let generatedAsset = AVURLAsset(url: generatedURL)

        guard let canvasTrack = try await canvasAsset.loadTracks(withMediaType: .video).first,
              let generatedTrack = try await generatedAsset.loadTracks(withMediaType: .video).first else {
            throw ComposeError.missingTrack
        }

        // Both tracks are equal length; min() guards against any rounding skew.
        let baseDuration = try await min(canvasAsset.load(.duration), generatedAsset.load(.duration))
        let baseRange = CMTimeRange(start: .zero, duration: baseDuration)

        let composition = AVMutableComposition()
        guard let canvasComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let generatedComp = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ComposeError.exportSetupFailed
        }
        try canvasComp.insertTimeRange(baseRange, of: canvasTrack, at: .zero)
        try generatedComp.insertTimeRange(baseRange, of: generatedTrack, at: .zero)

        // Speed: scale both tracks' timelines to 1/speed of their duration.
        let finalDuration: CMTime
        if speed != 1, speed > 0 {
            let scaled = CMTimeMultiplyByFloat64(baseDuration, multiplier: 1.0 / speed)
            canvasComp.scaleTimeRange(baseRange, toDuration: scaled)
            generatedComp.scaleTimeRange(baseRange, toDuration: scaled)
            finalDuration = scaled
        } else {
            finalDuration = baseDuration
        }

        // Layout: position each pane within the render canvas. Uncovered areas
        // (the vertical layout's side margins) render black — intentional letterbox.
        let renderSize = layout.renderSize
        let src = CGFloat(side)
        let (canvasTransform, generatedTransform) = transforms(for: layout, source: src, render: renderSize)

        let canvasInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: canvasComp)
        canvasInstruction.setTransform(canvasTransform, at: .zero)
        let generatedInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: generatedComp)
        generatedInstruction.setTransform(generatedTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: finalDuration)
        instruction.layerInstructions = [generatedInstruction, canvasInstruction]

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        try? FileManager.default.removeItem(at: outputURL)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw ComposeError.exportSetupFailed
        }
        export.videoComposition = videoComposition
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
}

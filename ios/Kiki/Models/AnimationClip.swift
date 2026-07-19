import SwiftData
import UIKit

/// One generated animation (Animate screen output). Every completed
/// generation is saved as a clip — the screen's history strip is a
/// `@Query` over these, newest first. Inputs are stored alongside the MP4
/// so selecting an old clip can restore the setup that produced it.
@Model
final class AnimationClip {

    @Attribute(.unique) var id: UUID
    var createdAt: Date

    // MARK: - Inputs

    /// Motion prompt used for this generation ("" = server default).
    var prompt: String
    /// LTX frame count (duration = numFrames / fps).
    var numFrames: Int
    var fps: Int
    var seed: Int?
    @Attribute(.externalStorage) var startKeyframeData: Data?
    /// nil when the clip was generated from a single (start) keyframe.
    @Attribute(.externalStorage) var endKeyframeData: Data?
    /// The drawing the start keyframe came from, when it came from the
    /// library (drives the per-drawing replay/share integration).
    var sourceDrawingID: UUID?

    // MARK: - Output

    @Attribute(.externalStorage) var videoData: Data?
    /// First decoded video frame — the history-strip thumbnail.
    @Attribute(.externalStorage) var thumbnailData: Data?

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        prompt: String = "",
        numFrames: Int = 145,
        fps: Int = 24,
        seed: Int? = nil,
        sourceDrawingID: UUID? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.prompt = prompt
        self.numFrames = numFrames
        self.fps = fps
        self.seed = seed
        self.sourceDrawingID = sourceDrawingID
    }
}

extension AnimationClip {

    var thumbnail: UIImage? {
        guard let data = thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var durationSeconds: Double {
        Double(numFrames) / Double(max(fps, 1))
    }
}

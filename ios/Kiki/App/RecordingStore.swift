import Foundation

/// Maps a drawing id to the on-disk MP4s for its two timelapse tracks, stored
/// under Application Support so they're persistent and URL-addressable for
/// AVFoundation (playback / compose / share). Tracks are recorded to temp
/// partials and atomically moved here on finalize.
///
/// This is deliberately separate from the ephemeral backend idle-animation MP4
/// (`AppCoordinator.currentVideoMP4URL`), which lives in the temp dir and is
/// deleted on resume.
struct RecordingStore {
    static let shared = RecordingStore()

    private let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Recordings", isDirectory: true)
    }

    /// Directory holding one drawing's recordings.
    func directory(for drawingId: UUID) -> URL {
        root.appendingPathComponent(drawingId.uuidString, isDirectory: true)
    }

    /// The two finalized track URLs (may not exist on disk yet).
    func urls(for drawingId: UUID) -> (canvas: URL, generated: URL) {
        let dir = directory(for: drawingId)
        return (dir.appendingPathComponent("canvas.mp4"),
                dir.appendingPathComponent("generated.mp4"))
    }

    /// True when both finalized tracks exist — i.e. there's a shareable video.
    func hasRecording(_ drawingId: UUID) -> Bool {
        let (canvas, generated) = urls(for: drawingId)
        let fm = FileManager.default
        return fm.fileExists(atPath: canvas.path) && fm.fileExists(atPath: generated.path)
    }

    /// Atomically replace the drawing's stored tracks with the given temp files.
    /// Replacing is intentional: re-opening a drawing and drawing more produces a
    /// fresh recording that supersedes the prior one.
    func finalize(canvasTemp: URL, generatedTemp: URL, for drawingId: UUID) throws {
        let dir = directory(for: drawingId)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (canvasDest, generatedDest) = urls(for: drawingId)
        try replaceItem(at: canvasDest, with: canvasTemp)
        try replaceItem(at: generatedDest, with: generatedTemp)
    }

    /// Remove a drawing's recordings (called when the drawing is deleted).
    func delete(_ drawingId: UUID) {
        try? FileManager.default.removeItem(at: directory(for: drawingId))
    }

    private func replaceItem(at dest: URL, with src: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: src, to: dest)
    }
}

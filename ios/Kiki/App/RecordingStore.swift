import Foundation

/// Stores a drawing's timelapse recording as an ordered list of MP4 *segments*
/// per track, under Application Support (persistent, URL-addressable for
/// AVFoundation). Segments accumulate as the session is checkpointed (so the
/// replay can be shared mid-drawing) and are stitched back together at compose
/// time.
///
/// Files: `Recordings/<drawingId>/{canvas,generated}-<index>.mp4`.
///
/// Distinct from the ephemeral backend idle-animation MP4
/// (`AppCoordinator.currentVideoMP4URL`), which lives in the temp dir.
struct RecordingStore {
    static let shared = RecordingStore()

    private let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        root = base.appendingPathComponent("Recordings", isDirectory: true)
    }

    func directory(for drawingId: UUID) -> URL {
        root.appendingPathComponent(drawingId.uuidString, isDirectory: true)
    }

    private func canvasURL(_ drawingId: UUID, _ index: Int) -> URL {
        directory(for: drawingId).appendingPathComponent("canvas-\(index).mp4")
    }

    private func generatedURL(_ drawingId: UUID, _ index: Int) -> URL {
        directory(for: drawingId).appendingPathComponent("generated-\(index).mp4")
    }

    /// True once at least one finalized segment pair exists — i.e. there's a
    /// shareable recording.
    func hasRecording(_ drawingId: UUID) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: canvasURL(drawingId, 0).path)
            && fm.fileExists(atPath: generatedURL(drawingId, 0).path)
    }

    /// The ordered segment URLs for each track (parallel arrays, equal length).
    func segmentURLs(for drawingId: UUID) -> (canvas: [URL], generated: [URL]) {
        let fm = FileManager.default
        var canvas: [URL] = []
        var generated: [URL] = []
        var index = 0
        while fm.fileExists(atPath: canvasURL(drawingId, index).path),
              fm.fileExists(atPath: generatedURL(drawingId, index).path) {
            canvas.append(canvasURL(drawingId, index))
            generated.append(generatedURL(drawingId, index))
            index += 1
        }
        return (canvas, generated)
    }

    /// Append a finalized segment (moving the temp files into place).
    func appendSegment(canvasTemp: URL, generatedTemp: URL, for drawingId: UUID) throws {
        let dir = directory(for: drawingId)
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var index = 0
        while fm.fileExists(atPath: canvasURL(drawingId, index).path) { index += 1 }
        try fm.moveItem(at: canvasTemp, to: canvasURL(drawingId, index))
        try fm.moveItem(at: generatedTemp, to: generatedURL(drawingId, index))
    }

    /// Remove a drawing's recording (called when the drawing is deleted).
    func delete(_ drawingId: UUID) {
        try? FileManager.default.removeItem(at: directory(for: drawingId))
    }
}

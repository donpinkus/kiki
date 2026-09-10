import Foundation

/// One layer's raw texture bytes for undo/redo, LZ4-compressed on a utility queue
/// right after capture.
///
/// Before 2026-09-10 every undo entry held the raw 16 MB (2048² × BGRA8) forever:
/// 30 strokes = 480 MB, plus a mirrored redo stack, plus whole-stack entries for
/// layer-structure ops — count-bounded, never byte-bounded, and never released on
/// memory pressure (the app already runs SAM + 16 MB layers; jetsam is a real
/// concern on 4 GB iPads). Mostly-transparent layers compress 10–50× under LZ4, so
/// the same depth now costs tens of MB; dense layers fall back to the byte budget in
/// `MetalCanvasView` (oldest entries dropped).
///
/// The capture itself stays synchronous on the main thread (`texture.getBytes`, a
/// few ms) so the snapshot is exact; only the compression is deferred. `data()`
/// decompresses on demand (~5 ms for 16 MB) — undo/redo are cold paths.
final class LayerSnapshotBlob: @unchecked Sendable {
    private let lock = NSLock()
    private var raw: Data?
    private var compressed: Data?
    /// Uncompressed byte count (what `restore` will hand back).
    let rawCount: Int

    private static let queue = DispatchQueue(label: "com.kiki.canvas.undo-compress", qos: .utility)

    init(raw: Data) {
        self.raw = raw
        rawCount = raw.count
        Self.queue.async { [self] in compress() }
    }

    private func compress() {
        let source: Data? = lock.withLock { raw }
        guard let source else { return }
        guard let packed = try? (source as NSData).compressed(using: .lz4) as Data else { return }
        lock.withLock {
            // Only swap if nobody released us meanwhile (raw nil = already swapped).
            if raw != nil {
                compressed = packed
                raw = nil
            }
        }
    }

    /// Current resident size (raw until compression lands, then the packed size).
    var footprint: Int {
        lock.withLock { compressed?.count ?? raw?.count ?? 0 }
    }

    /// The original bytes (decompressing if needed). nil only if decompression fails.
    func data() -> Data? {
        lock.withLock {
            if let raw { return raw }
            if let compressed {
                return try? (compressed as NSData).decompressed(using: .lz4) as Data
            }
            return nil
        }
    }
}

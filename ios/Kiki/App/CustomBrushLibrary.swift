import Foundation
import Observation
import CanvasModule

/// A user-authored brush: a full BrushConfig snapshot under a name. The stored color and
/// baseWidth are incidental (applying keeps the user's current color/size — see
/// AppCoordinator.applySavedBrush); everything else is the brush's character.
struct SavedBrush: Codable, Identifiable {
    let id: UUID
    var name: String
    var config: BrushConfig
    var savedAt: Date
}

/// On-device persistence for named custom brushes ("Save as brush" in the Brush Studio).
/// A JSON file in Application Support — BrushConfig is append-only Codable, so brushes
/// saved by older builds keep decoding.
@Observable
final class CustomBrushLibrary {
    private(set) var brushes: [SavedBrush] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("custom-brushes.json")
        load()
    }

    @discardableResult
    func add(name: String, config: BrushConfig) -> SavedBrush {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedBrush(id: UUID(),
                               name: trimmed.isEmpty ? "Untitled brush" : trimmed,
                               config: config,
                               savedAt: Date())
        brushes.insert(saved, at: 0)
        persist()
        return saved
    }

    /// Overwrite an existing brush's config in place (keep name + id).
    func update(_ id: UUID, config: BrushConfig) {
        guard let i = brushes.firstIndex(where: { $0.id == id }) else { return }
        brushes[i].config = config
        persist()
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = brushes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        brushes[i].name = trimmed
        persist()
    }

    func delete(_ id: UUID) {
        brushes.removeAll { $0.id == id }
        persist()
    }

    func brush(for id: UUID) -> SavedBrush? {
        brushes.first { $0.id == id }
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            brushes = try JSONDecoder().decode([SavedBrush].self, from: data)
        } catch {
            // Never silently destroy the user's brushes: park the unreadable file and
            // start empty; the .corrupt copy stays recoverable.
            try? FileManager.default.moveItem(
                at: fileURL, to: fileURL.appendingPathExtension("corrupt"))
            brushes = []
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(brushes) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

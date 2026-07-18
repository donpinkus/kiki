import UIKit
import Observation
import CanvasModule

/// A user-imported brush asset: a grayscale tip shape or a grain tile.
struct BrushAsset: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        case shape, grain
    }
    let id: String          // "user-<uuid>" — also stored in BrushConfig.shapeID/grainID
    var name: String
    let kind: Kind
    let importedAt: Date
}

/// On-device store for user-imported brush tips + grains ("Import" in the Studio's
/// Shape/Grain Source groups). Files live where the engine looks for them
/// (`BrushAssetStore.directory`): `shapes/<id>.png` and `grains/<id>.png`, with an
/// `index.json` carrying the display names. The renderer loads unknown ids lazily, so
/// importing needs no engine registration — writing the PNG is enough.
@Observable
final class BrushAssetLibrary {
    private(set) var assets: [BrushAsset] = []

    var shapes: [BrushAsset] { assets.filter { $0.kind == .shape } }
    var grains: [BrushAsset] { assets.filter { $0.kind == .grain } }

    static let directory: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BrushAssets")
        for sub in ["shapes", "grains"] {
            try? FileManager.default.createDirectory(
                at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        return dir
    }()

    private var indexURL: URL { Self.directory.appendingPathComponent("index.json") }

    init() {
        // Point the engine at the store (idempotent; also inherited by every
        // CanvasRenderer instance — canvas, pad, preview).
        BrushAssetStore.directory = Self.directory
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([BrushAsset].self, from: data) {
            assets = decoded
        }
    }

    /// Import an image as a shape or grain. Converted to grayscale-friendly PNG and
    /// downscaled (tips work best ≤1024²; grains tile at native size, capped too).
    /// Returns the new asset (its id goes straight into the brush config).
    @discardableResult
    func importImage(_ image: UIImage, kind: BrushAsset.Kind, name: String? = nil) -> BrushAsset? {
        let maxSide: CGFloat = 1024
        let scaled = Self.downscaled(image, maxSide: maxSide)
        guard let png = scaled.pngData() else { return nil }
        let id = "user-\(UUID().uuidString.lowercased())"
        let url = Self.directory
            .appendingPathComponent(kind == .shape ? "shapes" : "grains")
            .appendingPathComponent("\(id).png")
        do {
            try png.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        let count = assets.filter { $0.kind == kind }.count + 1
        let asset = BrushAsset(id: id,
                               name: name ?? (kind == .shape ? "Shape \(count)" : "Grain \(count)"),
                               kind: kind,
                               importedAt: Date())
        assets.append(asset)
        persist()
        return asset
    }

    func rename(_ id: String, to name: String) {
        guard let i = assets.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        assets[i].name = trimmed
        persist()
    }

    func delete(_ id: String) {
        guard let asset = assets.first(where: { $0.id == id }) else { return }
        let url = Self.directory
            .appendingPathComponent(asset.kind == .shape ? "shapes" : "grains")
            .appendingPathComponent("\(id).png")
        try? FileManager.default.removeItem(at: url)
        assets.removeAll { $0.id == id }
        thumbnailCache[id] = nil
        persist()
    }

    /// Thumbnail for the picker chips — decoded + downscaled once, then cached (the
    /// full asset can be 1024²; chips are ~26 pt and re-render on selection changes).
    private var thumbnailCache: [String: UIImage] = [:]

    func image(for asset: BrushAsset) -> UIImage? {
        if let cached = thumbnailCache[asset.id] { return cached }
        let url = Self.directory
            .appendingPathComponent(asset.kind == .shape ? "shapes" : "grains")
            .appendingPathComponent("\(asset.id).png")
        guard let full = UIImage(contentsOfFile: url.path) else { return nil }
        let thumb = Self.downscaled(full, maxSide: 64)
        thumbnailCache[asset.id] = thumb
        return thumb
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(assets) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let target = CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // sRGB (CanvasModule CLAUDE.md convention)
        format.scale = 1
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }
}

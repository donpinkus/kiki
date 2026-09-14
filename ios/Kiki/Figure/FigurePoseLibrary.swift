import Foundation
import UIKit

/// A named starting pose: bind-relative joint deltas for the bundled rig
/// (same encoding as `FigurePose.joints`), optionally with a turntable yaw so
/// side-on poses open side-on. Bundled as `figure_poses.json`, produced by
/// `ios/scripts/figure-poses/extract_poses.py` from CC0 animation clips.
struct FigurePosePreset: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let category: String
    var yaw: Double?
    let joints: [String: [Float]]

    static func == (a: FigurePosePreset, b: FigurePosePreset) -> Bool { a.id == b.id }
}

/// Loads the bundled pose presets once and renders their thumbnails on device
/// (a small orthographic bake of each pose — no thumbnail assets to maintain).
@MainActor
enum FigurePoseLibrary {
    static let resourceName = "figure_poses"

    private struct File: Codable {
        let version: Int
        let poses: [FigurePosePreset]
    }

    static let presets: [FigurePosePreset] = {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(File.self, from: data) else { return [] }
        return file.poses
    }()

    /// Presets grouped by category, in file order (first appearance wins).
    static var categories: [(name: String, presets: [FigurePosePreset])] {
        var order: [String] = []
        var groups: [String: [FigurePosePreset]] = [:]
        for p in presets {
            if groups[p.category] == nil { order.append(p.category) }
            groups[p.category, default: []].append(p)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    static func preset(id: String) -> FigurePosePreset? {
        presets.first { $0.id == id }
    }

    // MARK: - Thumbnails

    private static var thumbnails: [String: UIImage] = [:]
    private static var scenes: [FigureBody: FigureScene] = [:]

    /// ~230 px tall figure on a transparent 256² tile; cached per preset+body.
    static func thumbnail(for preset: FigurePosePreset, body: FigureBody) -> UIImage? {
        let key = "\(body.rawValue)/\(preset.id)"
        if let cached = thumbnails[key] { return cached }
        let scene: FigureScene
        if let s = scenes[body] {
            scene = s
        } else {
            guard let s = try? FigureScene(body: body) else { return nil }
            scenes[body] = s
            scene = s
        }
        var pose = FigurePose()
        pose.body = body
        pose.heightPx = 1900
        pose.yaw = preset.yaw ?? 0
        pose.joints = preset.joints
        scene.apply(pose)
        guard let cg = scene.render(side: 256) else { return nil }
        let image = UIImage(cgImage: cg)
        thumbnails[key] = image
        return image
    }

    /// Drop cached renders (memory warning).
    static func purge() {
        thumbnails.removeAll()
        scenes.removeAll()
    }
}

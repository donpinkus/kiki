import Foundation

/// One selectable brush tip. `round` is the engine's original procedural soft circle
/// (no texture); every other shape is a grayscale PNG in `Resources/BrushShapes` where
/// luminance = coverage (white = full paint, black = none).
public struct BrushShapeDescriptor: Identifiable, Equatable, Sendable {
    /// Stable id, also persisted in `BrushConfig.shapeID`. For textured shapes this
    /// matches the PNG filename (without extension).
    public let id: String
    /// Human-facing name shown in the shape picker.
    public let displayName: String
    /// PNG resource name (no extension) in `Resources/BrushShapes`, or nil for the
    /// procedural round brush.
    public let resourceName: String?
    /// Blobby dry-media tips randomize their rotation PER DAB (2026-07-16): repeating
    /// the same art in the same orientation every stamp reads as discernible stamps —
    /// a random spin fuses overlaps into an organic mass (the Procreate/Krita chalk
    /// construction). Directional tips (dry brush streaks) keep their orientation.
    public let rotationJitter: Bool

    public init(id: String, displayName: String, resourceName: String?, rotationJitter: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.resourceName = resourceName
        self.rotationJitter = rotationJitter
    }

    public var isProcedural: Bool { resourceName == nil }
}

/// The ordered set of brush shapes the app exposes. Single source of truth for both the
/// renderer (which loads the textures) and the UI (which lists them).
///
/// **Adding a shape:** drop a grayscale PNG into `Resources/BrushShapes/` and add one
/// entry here with `resourceName` = the filename (no extension). No shader/plumbing change.
public enum BrushShapeCatalog {
    public static let roundID = "round"

    public static let all: [BrushShapeDescriptor] = [
        BrushShapeDescriptor(id: roundID, displayName: "Round", resourceName: nil),
        BrushShapeDescriptor(id: "chalk", displayName: "Chalk", resourceName: "chalk", rotationJitter: true),
        BrushShapeDescriptor(id: "charcoal", displayName: "Charcoal", resourceName: "charcoal", rotationJitter: true),
        BrushShapeDescriptor(id: "drybrush", displayName: "Dry Brush", resourceName: "drybrush"),
        BrushShapeDescriptor(id: "pastel", displayName: "Pastel", resourceName: "pastel", rotationJitter: true),
        BrushShapeDescriptor(id: "ink", displayName: "Spray", resourceName: "ink"),
        // Cloned Procreate tips (2026-07-18, brush-target sessions): extracted from
        // Shape Editor screenshots. See documents/research/krita-brush/16-brush-clones.md.
        BrushShapeDescriptor(id: "stucco", displayName: "Stucco", resourceName: "stucco"),
        BrushShapeDescriptor(id: "nightjar", displayName: "Blob", resourceName: "nightjar"),
        BrushShapeDescriptor(id: "oldbeach", displayName: "Knife", resourceName: "oldbeach"),
    ]

    public static func descriptor(for id: String?) -> BrushShapeDescriptor {
        guard let id else { return all[0] }
        return all.first { $0.id == id } ?? all[0]
    }

    /// True if this shape should orient its stamps to the stroke direction. Textured
    /// (non-round) shapes are anisotropic, so following the stroke reads as real media
    /// (e.g. dry-brush streaks run along the line, not across it).
    public static func orientsToStroke(_ id: String?) -> Bool {
        !descriptor(for: id).isProcedural
    }
}

// MARK: - User-imported assets

/// Location of user-imported brush assets: `shapes/<id>.png` (grayscale tips, luma =
/// coverage) and `grains/<id>.png` (grayscale grain tiles). The renderer resolves any
/// shape/grain id that isn't in the built-in catalogs against this directory, lazily.
/// The app points it at Application Support/BrushAssets; the BrushHarness inherits the
/// `BRUSH_USER_ASSETS_DIR` env default so fixtures with imported assets can replay.
public enum BrushAssetStore {
    public static var directory: URL? =
        ProcessInfo.processInfo.environment["BRUSH_USER_ASSETS_DIR"].map { URL(fileURLWithPath: $0) }
}

// MARK: - Grain catalog (P8)

/// One selectable grain texture. Grains are either PROCEDURAL (generated at renderer
/// init from deterministic hash noise, tileable 256²) or IMAGE-BASED (`resourceName`:
/// a grayscale PNG in `Resources/BrushGrains`, tiling at its own pixel size — the ship
/// vehicle for cloned Procreate grains; `BRUSH_GRAINS_DIR` env for the harness).
/// `nativeScale` is the default UV multiplier applied on top of
/// `BrushConfig.grainScale` (bigger = coarser features on canvas; the plan's guidance
/// is to stay in the COARSE value-grain band that survives img2img).
public struct GrainDescriptor: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let nativeScale: CGFloat
    /// PNG resource name (no extension) in `Resources/BrushGrains`, or nil = procedural.
    public let resourceName: String?

    public init(id: String, displayName: String, nativeScale: CGFloat, resourceName: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.nativeScale = nativeScale
        self.resourceName = resourceName
    }
}

public enum GrainCatalog {
    public static let all: [GrainDescriptor] = [
        GrainDescriptor(id: "paper", displayName: "Paper", nativeScale: 1.0),
        GrainDescriptor(id: "canvasWeave", displayName: "Canvas", nativeScale: 1.2),
        GrainDescriptor(id: "speckle", displayName: "Speckle", nativeScale: 1.6),
    ]
    public static func descriptor(for id: String?) -> GrainDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

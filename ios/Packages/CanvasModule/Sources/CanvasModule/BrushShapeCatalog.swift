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
        BrushShapeDescriptor(id: "chalk", displayName: "Chalk", resourceName: "chalk"),
        BrushShapeDescriptor(id: "charcoal", displayName: "Charcoal", resourceName: "charcoal"),
        BrushShapeDescriptor(id: "drybrush", displayName: "Dry Brush", resourceName: "drybrush"),
        BrushShapeDescriptor(id: "pastel", displayName: "Pastel", resourceName: "pastel"),
        BrushShapeDescriptor(id: "ink", displayName: "Spray", resourceName: "ink"),
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

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
        // Clone-brush tips (2026-07-18). NOTE: these are the Procreate Shape Editor
        // captures used DIRECTLY (owner call — the Kontext-generated variations came out
        // either too-identical or over-drifted, so we ship the uploads "for now").
        // IP follow-up (replace with true originals) is still OPEN — see
        // documents/research/krita-brush/16-brush-clones.md.
        BrushShapeDescriptor(id: "stucco", displayName: "Stucco", resourceName: "stucco"),
        BrushShapeDescriptor(id: "nightjar", displayName: "Blob", resourceName: "nightjar"),
        BrushShapeDescriptor(id: "oldbeach", displayName: "Knife", resourceName: "oldbeach"),
        // Stock shape library: Donald's Procreate Shape Library captures, used directly
        // (same "for now" call + open IP follow-up as the clone tips above).
        BrushShapeDescriptor(id: "lib_chinese_ink", displayName: "Chinese Ink", resourceName: "lib_chinese_ink"),
        BrushShapeDescriptor(id: "lib_ink_sponge", displayName: "Ink Sponge", resourceName: "lib_ink_sponge"),
        BrushShapeDescriptor(id: "lib_ink_dry", displayName: "Ink Dry", resourceName: "lib_ink_dry"),
        BrushShapeDescriptor(id: "lib_ink2", displayName: "Ink 2", resourceName: "lib_ink2"),
        BrushShapeDescriptor(id: "lib_ink_grain", displayName: "Ink Grain", resourceName: "lib_ink_grain"),
        BrushShapeDescriptor(id: "lib_ink_pounce", displayName: "Ink Pounce", resourceName: "lib_ink_pounce"),
        BrushShapeDescriptor(id: "lib_char_disc", displayName: "Charcoal Disc", resourceName: "lib_char_disc"),
        BrushShapeDescriptor(id: "lib_flat_brush", displayName: "Flat Brush", resourceName: "lib_flat_brush"),
        BrushShapeDescriptor(id: "lib_flat_marker", displayName: "Flat Marker", resourceName: "lib_flat_marker"),
        BrushShapeDescriptor(id: "lib_flat_brush2", displayName: "Flat Brush 2", resourceName: "lib_flat_brush2"),
        BrushShapeDescriptor(id: "lib_small_point", displayName: "Small Point", resourceName: "lib_small_point"),
        BrushShapeDescriptor(id: "lib_ultra_soft", displayName: "Ultra Soft", resourceName: "lib_ultra_soft"),
        BrushShapeDescriptor(id: "lib_soft", displayName: "Soft", resourceName: "lib_soft"),
        BrushShapeDescriptor(id: "lib_medium", displayName: "Medium", resourceName: "lib_medium"),
        BrushShapeDescriptor(id: "lib_medium_hard", displayName: "Medium Hard", resourceName: "lib_medium_hard"),
        BrushShapeDescriptor(id: "lib_hard", displayName: "Hard", resourceName: "lib_hard"),
        BrushShapeDescriptor(id: "lib_halftone", displayName: "Halftone", resourceName: "lib_halftone"),
        BrushShapeDescriptor(id: "lib_char_block", displayName: "Charcoal Block", resourceName: "lib_char_block"),
        BrushShapeDescriptor(id: "lib_char_macro", displayName: "Charcoal Macro", resourceName: "lib_char_macro"),
        BrushShapeDescriptor(id: "lib_char_shards", displayName: "Charcoal Shards", resourceName: "lib_char_shards"),
        BrushShapeDescriptor(id: "lib_char_soft", displayName: "Charcoal Soft", resourceName: "lib_char_soft"),
        BrushShapeDescriptor(id: "lib_char_wisp", displayName: "Charcoal Wisp", resourceName: "lib_char_wisp"),
        BrushShapeDescriptor(id: "lib_cloud", displayName: "Cloud", resourceName: "lib_cloud"),
        BrushShapeDescriptor(id: "lib_splash", displayName: "Splash", resourceName: "lib_splash"),
        BrushShapeDescriptor(id: "lib_splatter", displayName: "Splatter", resourceName: "lib_splatter"),
        BrushShapeDescriptor(id: "lib_oil_smear", displayName: "Oil Smear", resourceName: "lib_oil_smear"),
        BrushShapeDescriptor(id: "lib_palette", displayName: "Palette Knife", resourceName: "lib_palette"),
        BrushShapeDescriptor(id: "lib_paint_flakes", displayName: "Paint Flakes", resourceName: "lib_paint_flakes"),
        BrushShapeDescriptor(id: "lib_ridge", displayName: "Ridge Print", resourceName: "lib_ridge"),
        BrushShapeDescriptor(id: "lib_acrylic_square", displayName: "Acrylic Square", resourceName: "lib_acrylic_square"),
        BrushShapeDescriptor(id: "lib_leaves", displayName: "Leaves", resourceName: "lib_leaves"),
        BrushShapeDescriptor(id: "lib_rocks", displayName: "Rocks", resourceName: "lib_rocks"),
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
        // Cloned Procreate grains (2026-07-18): extracted from the targets' Grain Source
        // pane thumbnails, INVERTED (their Multiply/Height blends hole-punch where the
        // grain is dark; our carve removes paint where src is bright). Same "direct
        // capture, IP follow-up open" status as the shape tips.
        GrainDescriptor(id: "stuccoGrain", displayName: "Plaster", nativeScale: 1.0, resourceName: "stuccoGrain"),
        GrainDescriptor(id: "oldbeachGrain", displayName: "Concrete", nativeScale: 1.0, resourceName: "oldbeachGrain"),
        // Stock grain library (2026-07-19): Donald's Procreate Grain Editor captures,
        // used directly (same "for now" + open IP follow-up as the shape library).
        // Extraction: card crop → INVERT (Procreate bright = paint; our carve bright =
        // removed) → autocontrast. No name labels existed — names are descriptive.
        GrainDescriptor(id: "lib_bark", displayName: "Bark", nativeScale: 1.0, resourceName: "lib_bark"),
        GrainDescriptor(id: "lib_mulch", displayName: "Mulch", nativeScale: 1.0, resourceName: "lib_mulch"),
        GrainDescriptor(id: "lib_plaster_mottle", displayName: "Plaster Mottle", nativeScale: 1.0, resourceName: "lib_plaster_mottle"),
        GrainDescriptor(id: "lib_pitted_concrete", displayName: "Pitted Concrete", nativeScale: 1.0, resourceName: "lib_pitted_concrete"),
        GrainDescriptor(id: "lib_fine_tooth", displayName: "Fine Tooth", nativeScale: 1.0, resourceName: "lib_fine_tooth"),
        GrainDescriptor(id: "lib_slate", displayName: "Slate", nativeScale: 1.0, resourceName: "lib_slate"),
        GrainDescriptor(id: "lib_laid_paper", displayName: "Laid Paper", nativeScale: 1.0, resourceName: "lib_laid_paper"),
        GrainDescriptor(id: "lib_pebbled_emboss", displayName: "Pebbled Emboss", nativeScale: 1.0, resourceName: "lib_pebbled_emboss"),
        GrainDescriptor(id: "lib_scratchy_fiber", displayName: "Scratchy Fiber", nativeScale: 1.0, resourceName: "lib_scratchy_fiber"),
        GrainDescriptor(id: "lib_salt_spray", displayName: "Salt Spray", nativeScale: 1.0, resourceName: "lib_salt_spray"),
        GrainDescriptor(id: "lib_burlap", displayName: "Burlap", nativeScale: 1.0, resourceName: "lib_burlap"),
        GrainDescriptor(id: "lib_bokeh_dots", displayName: "Bokeh Dots", nativeScale: 1.0, resourceName: "lib_bokeh_dots"),
        GrainDescriptor(id: "lib_granite", displayName: "Granite", nativeScale: 1.0, resourceName: "lib_granite"),
        GrainDescriptor(id: "lib_laid_ridges", displayName: "Laid Ridges", nativeScale: 1.0, resourceName: "lib_laid_ridges"),
        GrainDescriptor(id: "lib_crackle_stone", displayName: "Crackle Stone", nativeScale: 1.0, resourceName: "lib_crackle_stone"),
        GrainDescriptor(id: "lib_felt", displayName: "Felt", nativeScale: 1.0, resourceName: "lib_felt"),
        GrainDescriptor(id: "lib_chalk_scumble", displayName: "Chalk Scumble", nativeScale: 1.0, resourceName: "lib_chalk_scumble"),
        GrainDescriptor(id: "lib_fleece", displayName: "Fleece", nativeScale: 1.0, resourceName: "lib_fleece"),
        GrainDescriptor(id: "lib_lava_pores", displayName: "Lava Pores", nativeScale: 1.0, resourceName: "lib_lava_pores"),
        GrainDescriptor(id: "lib_smoke", displayName: "Smoke", nativeScale: 1.0, resourceName: "lib_smoke"),
        GrainDescriptor(id: "lib_soft_clouds", displayName: "Soft Clouds", nativeScale: 1.0, resourceName: "lib_soft_clouds"),
        GrainDescriptor(id: "lib_faint_paper", displayName: "Faint Paper", nativeScale: 1.0, resourceName: "lib_faint_paper"),
        GrainDescriptor(id: "lib_marble_flow", displayName: "Marble Flow", nativeScale: 1.0, resourceName: "lib_marble_flow"),
        GrainDescriptor(id: "lib_dark_stone", displayName: "Dark Stone", nativeScale: 1.0, resourceName: "lib_dark_stone"),
        GrainDescriptor(id: "lib_leather", displayName: "Leather", nativeScale: 1.0, resourceName: "lib_leather"),
        GrainDescriptor(id: "lib_dry_wisps", displayName: "Dry Wisps", nativeScale: 1.0, resourceName: "lib_dry_wisps"),
        GrainDescriptor(id: "lib_wool_loops", displayName: "Wool Loops", nativeScale: 1.0, resourceName: "lib_wool_loops"),
        GrainDescriptor(id: "lib_caustics", displayName: "Caustics", nativeScale: 1.0, resourceName: "lib_caustics"),
        GrainDescriptor(id: "lib_scraped_metal", displayName: "Scraped Metal", nativeScale: 1.0, resourceName: "lib_scraped_metal"),
        GrainDescriptor(id: "lib_grunge_blooms", displayName: "Grunge Blooms", nativeScale: 1.0, resourceName: "lib_grunge_blooms"),
        GrainDescriptor(id: "lib_starfield", displayName: "Starfield", nativeScale: 1.0, resourceName: "lib_starfield"),
        GrainDescriptor(id: "lib_rock_strata", displayName: "Rock Strata", nativeScale: 1.0, resourceName: "lib_rock_strata"),
        GrainDescriptor(id: "lib_handmade_paper", displayName: "Handmade Paper", nativeScale: 1.0, resourceName: "lib_handmade_paper"),
        GrainDescriptor(id: "lib_mottled_felt", displayName: "Mottled Felt", nativeScale: 1.0, resourceName: "lib_mottled_felt"),
        GrainDescriptor(id: "lib_watercolor_bloom", displayName: "Watercolor Bloom", nativeScale: 1.0, resourceName: "lib_watercolor_bloom"),
        GrainDescriptor(id: "lib_impasto", displayName: "Impasto", nativeScale: 1.0, resourceName: "lib_impasto"),
    ]
    public static func descriptor(for id: String?) -> GrainDescriptor? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

import Foundation

struct PromptStyle: Identifiable, Equatable {
    let id: String
    let name: String
    let promptSuffix: String
}

extension PromptStyle {

    static let none = PromptStyle(
        id: "none",
        name: "None",
        promptSuffix: ""
    )

    static let pastelAnimation = PromptStyle(
        id: "pastel_animation",
        name: "Pastel Animation",
        promptSuffix: " as a frame from a soft pastel animated film, clean shapes, expressive character posing, gentle camera composition, warm natural light, hand-painted backgrounds"
    )

    static let cinematicLiveAction = PromptStyle(
        id: "cinematic_live_action",
        name: "Cinematic",
        promptSuffix: " as a cinematic live-action film frame, dramatic motivated lighting, shallow depth of field, natural lens perspective, rich color grade, atmospheric detail"
    )

    static let threeDAnimation = PromptStyle(
        id: "3d_render",
        name: "3D Animation",
        promptSuffix: " as a frame from a polished 3D animated feature, expressive stylized forms, clean rigged character shapes, global illumination, soft cinematic lighting"
    )

    static let editorialPhoto = PromptStyle(
        id: "editorial_photo",
        name: "Editorial Photo",
        promptSuffix: " as an editorial photojournalism frame, natural available light, handheld documentary realism, believable lens perspective, candid composition, crisp subject detail"
    )

    static let animeAction = PromptStyle(
        id: "anime_action",
        name: "Anime Action",
        promptSuffix: " as a dynamic cel anime frame, bold silhouettes, clean line art, expressive motion pose, speed-line energy, punchy color, dramatic camera angle"
    )

    static let motionComic = PromptStyle(
        id: "graphic_ink",
        name: "Motion Comic",
        promptSuffix: " as a motion comic frame, bold inked outlines, graphic shadows, cinematic panel composition, limited animation staging, halftone texture, energetic action cues"
    )

    static let pixelArt = PromptStyle(
        id: "pixel_art",
        name: "Pixel Art Game",
        promptSuffix: " as a pixel art game cinematic frame, crisp square pixels, limited palette, readable silhouette, tileable environmental detail, sharp edges, no blur"
    )

    static let claymation = PromptStyle(
        id: "claymation",
        name: "Claymation",
        promptSuffix: " as a claymation stop-motion frame, rounded sculpted forms, tactile fingerprints, miniature set lighting, physical materials, handmade character appeal"
    )

    static let paperCutout = PromptStyle(
        id: "paper_cutout",
        name: "Paper Cutout",
        promptSuffix: " as a paper cutout stop-motion frame, layered flat shapes, clean cut edges, subtle paper fibers, stacked shadows, handmade tabletop animation look"
    )

    static let neonSciFi = PromptStyle(
        id: "neon_sci_fi",
        name: "Neon Sci-Fi",
        promptSuffix: " as a neon science-fiction film frame, luminous colored lighting, sleek reflective surfaces, atmospheric haze, dramatic contrast, futuristic production design"
    )

    static let lowPoly = PromptStyle(
        id: "low_poly",
        name: "Low Poly Game",
        promptSuffix: " as a low-poly game cutscene frame, faceted geometry, simplified forms, matte materials, crisp silhouettes, vibrant lighting, readable scene staging"
    )

    static let isometricDiorama = PromptStyle(
        id: "isometric_diorama",
        name: "Miniature Diorama",
        promptSuffix: " as a miniature diorama animation frame, tiny physical set pieces, tilt-shift depth, carefully staged props, soft practical lighting, tactile scale"
    )

    static let feltPuppet = PromptStyle(
        id: "felt_puppet",
        name: "Felt Puppet",
        promptSuffix: " as a felt puppet show frame, soft fabric texture, stitched details, expressive puppet shapes, simple practical set, warm studio lighting"
    )

    static let collageAnimation = PromptStyle(
        id: "collage_animation",
        name: "Collage Animation",
        promptSuffix: " as a cutout collage animation frame, mixed photographic textures, paper fragments, visible torn edges, playful scale shifts, layered stop-motion composition"
    )

    static let technicalExplainer = PromptStyle(
        id: "technical_explainer",
        name: "Technical Explainer",
        promptSuffix: " as a clean technical explainer animation frame, precise simplified geometry, annotated-feeling layout without readable text, flat colors, crisp motion-graphics design"
    )

    static let studioCommercial = PromptStyle(
        id: "studio_commercial",
        name: "Studio Commercial",
        promptSuffix: " as a polished studio commercial frame, premium product lighting, seamless backdrop, clean reflections, controlled shadows, glossy advertising finish"
    )

    static let musicVideo = PromptStyle(
        id: "music_video",
        name: "Music Video",
        promptSuffix: " as a high-energy music video frame, saturated colored stage lighting, practical haze, rhythmic composition, glossy highlights, bold stylized mood"
    )

    static let vhsCamcorder = PromptStyle(
        id: "vhs_camcorder",
        name: "VHS Camcorder",
        promptSuffix: " as a vintage VHS camcorder frame, analog video noise, slight color bleed, harsh on-camera light, soft focus, timestamp-free home-video texture"
    )

    static let nightVision = PromptStyle(
        id: "night_vision",
        name: "Night Vision",
        promptSuffix: " as a night-vision video frame, monochrome green infrared look, high sensor grain, glowing highlights, deep shadows, documentary surveillance texture"
    )

    static let akira = PromptStyle(
        id: "akira",
        name: "Akira",
        promptSuffix: " in the style of Akira, 1980s Japanese cyberpunk anime film frame, dense hand-painted city atmosphere, dramatic red highlights, detailed mechanical design, sharp cel shading"
    )

    static let halo = PromptStyle(
        id: "halo",
        name: "Halo",
        promptSuffix: " in the style of Halo game cinematics, military science-fiction design, clean hard-surface armor forms, epic alien megastructure scale, cool green and blue lighting"
    )

    static let westworld = PromptStyle(
        id: "westworld",
        name: "Westworld",
        promptSuffix: " in the style of Westworld, prestige sci-fi western film frame, sunlit desert atmosphere, elegant production design, uncanny android realism, restrained cinematic color grade"
    )

    static let worldOfWarcraft = PromptStyle(
        id: "world_of_warcraft",
        name: "World of Warcraft",
        promptSuffix: " in the style of World of Warcraft concept art, heroic fantasy silhouettes, oversized armor shapes, chunky stylized forms, saturated painterly color, epic environment scale"
    )

    static let starCraft = PromptStyle(
        id: "starcraft",
        name: "StarCraft",
        promptSuffix: " in the style of StarCraft concept art, gritty space-opera military sci-fi, bulky armor design, alien organic forms, industrial megastructures, dramatic rim lighting"
    )

    static let pixarFeature = PromptStyle(
        id: "pixar_feature",
        name: "Pixar Feature",
        promptSuffix: " in Pixar feature animation style, appealing stylized proportions, expressive character shapes, polished 3D materials, soft cinematic lighting, warm family-film color design"
    )

    static let spiderVerse = PromptStyle(
        id: "spider_verse",
        name: "Spider-Verse",
        promptSuffix: " in the style of Spider-Verse animation, comic-book 3D and 2D hybrid frame, halftone dots, chromatic offset, graphic ink lines, saturated kinetic color"
    )

    static let arcane = PromptStyle(
        id: "arcane",
        name: "Arcane",
        promptSuffix: " in the style of Arcane, painterly 3D animation frame, hand-painted texture detail, dramatic brushy lighting, sharp facial planes, cinematic game-fantasy mood"
    )

    static let legoStopMotion = PromptStyle(
        id: "lego_stop_motion",
        name: "LEGO Stop Motion",
        promptSuffix: " in LEGO stop-motion style, plastic brick-built forms, toy-scale set design, glossy studs, simple practical lighting, playful physical animation staging"
    )

    static let matcapModel = PromptStyle(
        id: "matcap_model",
        name: "Matcap Model",
        promptSuffix: " as an untextured 3D modeling viewport matcap render, smooth gray clay material, no surface textures, clean sculpted forms, studio rim light, ZBrush preview look"
    )

    /// All available styles, in display order.
    static let allStyles: [PromptStyle] = [
        none,
        editorialPhoto,
        cinematicLiveAction,
        threeDAnimation,
        pastelAnimation,
        animeAction,
        claymation,
        lowPoly,
        pixelArt,
        paperCutout,
        motionComic,
        isometricDiorama,
        feltPuppet,
        collageAnimation,
        technicalExplainer,
        studioCommercial,
        musicVideo,
        vhsCamcorder,
        nightVision,
        neonSciFi,
        akira,
        halo,
        westworld,
        worldOfWarcraft,
        starCraft,
        pixarFeature,
        spiderVerse,
        arcane,
        legoStopMotion,
        matcapModel
    ]

    /// The default style for new drawings.
    static let `default` = pastelAnimation

    /// Look up a style by its persistence ID. Falls back to default if not found.
    static func from(id: String?) -> PromptStyle {
        guard let id else { return .default }
        switch id {
        case "studio_ghibli":
            return .pastelAnimation
        case "watercolor":
            return .pastelAnimation
        case "oil_painting":
            return .cinematicLiveAction
        case "charcoal_sketch":
            return .motionComic
        case "risograph", "woodblock_print", "stained_glass":
            return .motionComic
        case "blueprint":
            return .technicalExplainer
        case "analog_collage":
            return .collageAnimation
        case "embroidered_textile":
            return .feltPuppet
        default:
            return allStyles.first { $0.id == id } ?? .default
        }
    }
}

import Foundation

struct PromptStyle: Identifiable, Equatable {
    /// Picker section a style belongs to. `nil` for styles that only appear
    /// in the Featured rail (None, Beautiful Paint, Concept Art).
    enum Category: String, CaseIterable {
        case animation
        case materials
        case stylized
        case painting

        var displayName: String {
            switch self {
            case .animation: return "Animation"
            case .materials: return "Real Materials"
            case .stylized: return "Stylized"
            case .painting: return "Painting Media"
            }
        }
    }

    let id: String
    let name: String
    let promptSuffix: String
    var category: Category?
    /// Shown in the Featured section at the top of the picker (one pick per
    /// category, plus the category-less favorites). Featured styles with a
    /// category also appear in their own section.
    var isFeatured: Bool = false
}

extension PromptStyle {

    static let none = PromptStyle(
        id: "none",
        name: "None",
        promptSuffix: "",
        category: nil,
        isFeatured: true
    )

    static let beautifulPaint = PromptStyle(
        id: "beautiful_paint",
        name: "Beautiful Paint",
        promptSuffix: " as beautiful stylized concept art by a professional artist, no people",
        category: nil,
        isFeatured: true
    )

    static let conceptArt = PromptStyle(
        id: "concept_art",
        name: "Concept Art",
        promptSuffix: " as professional concept art, dramatic lighting",
        category: nil,
        isFeatured: true
    )

    // MARK: Animation

    static let handPaintedAnimation = PromptStyle(
        id: "hand_painted_animation",
        name: "Hand-Painted Animation",
        promptSuffix: " as a beautiful hand-painted animation still, no text",
        category: .animation,
        isFeatured: true
    )

    static let ghibliCel = PromptStyle(
        id: "ghibli_cel",
        name: "Ghibli Cel",
        promptSuffix: " as a studio ghibli animation cel, plain background",
        category: .animation
    )

    // MARK: Real Materials

    static let paperCraft = PromptStyle(
        id: "paper_craft",
        name: "Paper Craft",
        promptSuffix: " as a layered paper craft artwork",
        category: .materials,
        isFeatured: true
    )

    static let clayModel = PromptStyle(
        id: "clay_model",
        name: "Clay Model",
        promptSuffix: " as a handmade clay model",
        category: .materials
    )

    static let feltCraft = PromptStyle(
        id: "felt_craft",
        name: "Felt Craft",
        promptSuffix: " as a needle-felted wool craft",
        category: .materials
    )

    static let bronzeSculpture = PromptStyle(
        id: "bronze_sculpture",
        name: "Bronze Sculpture",
        promptSuffix: " as a bronze sculpture",
        category: .materials
    )

    // MARK: Stylized

    static let neonGlow = PromptStyle(
        id: "neon_glow",
        name: "Neon Glow",
        promptSuffix: " as a neon glow illustration",
        category: .stylized,
        isFeatured: true
    )

    static let popArt = PromptStyle(
        id: "pop_art",
        name: "Pop Art",
        promptSuffix: " as a vibrant pop art illustration",
        category: .stylized
    )

    static let darkFantasy = PromptStyle(
        id: "dark_fantasy",
        name: "Dark Fantasy",
        promptSuffix: " as dark fantasy concept art, moody atmosphere, glowing accents",
        category: .stylized
    )

    static let chalkboard = PromptStyle(
        id: "chalkboard",
        name: "Chalkboard",
        promptSuffix: " as a colorful chalk drawing on a blackboard",
        category: .stylized
    )

    static let sticker = PromptStyle(
        id: "sticker",
        name: "Sticker",
        promptSuffix: " as a glossy sticker illustration",
        category: .stylized
    )

    // MARK: Painting Media

    static let watercolor = PromptStyle(
        id: "watercolor",
        name: "Watercolor",
        promptSuffix: " as a watercolor painting",
        category: .painting,
        isFeatured: true
    )

    static let oilPainting = PromptStyle(
        id: "oil_painting",
        name: "Oil Painting",
        promptSuffix: " as a detailed oil painting",
        category: .painting
    )

    static let gouache = PromptStyle(
        id: "gouache",
        name: "Gouache",
        promptSuffix: " as a gouache illustration",
        category: .painting
    )

    static let coloredPencil = PromptStyle(
        id: "colored_pencil",
        name: "Colored Pencil",
        promptSuffix: " as a colored pencil drawing",
        category: .painting
    )

    /// All available styles. Order = style-preview generation order, so the
    /// Featured rail (listed first) fills in before the section tiles.
    static let allStyles: [PromptStyle] = [
        none,
        beautifulPaint,
        conceptArt,
        handPaintedAnimation,
        paperCraft,
        neonGlow,
        watercolor,
        ghibliCel,
        clayModel,
        feltCraft,
        bronzeSculpture,
        popArt,
        darkFantasy,
        chalkboard,
        sticker,
        oilPainting,
        gouache,
        coloredPencil
    ]

    /// Featured rail, in display order.
    static let featuredStyles: [PromptStyle] = allStyles.filter(\.isFeatured)

    /// Section members for one category, in `allStyles` order.
    static func styles(in category: Category) -> [PromptStyle] {
        allStyles.filter { $0.category == category }
    }

    /// The default style for new drawings.
    static let `default` = beautifulPaint

    /// Look up a style by its persistence ID. Falls back to default if not found.
    /// Drawings saved under a now-removed style id map to the closest current
    /// style, or fall through to the default.
    static func from(id: String?) -> PromptStyle {
        guard let id else { return .default }
        switch id {
        case "studio_ghibli":
            return .ghibliCel
        case "pastel_animation":
            return .handPaintedAnimation
        default:
            return allStyles.first { $0.id == id } ?? .default
        }
    }
}

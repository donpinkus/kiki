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

    static let beautifulPaint = PromptStyle(
        id: "beautiful_paint",
        name: "Beautiful Paint",
        promptSuffix: " as beautiful stylized concept art by a professional artist, no people"
    )

    static let studioCommercial = PromptStyle(
        id: "studio_commercial",
        name: "Studio Commercial",
        promptSuffix: " as a polished studio commercial frame, premium product lighting, seamless backdrop, clean reflections, controlled shadows, glossy advertising finish"
    )

    static let pixarMovie = PromptStyle(
        id: "pixar_movie",
        name: "Pixar Movie",
        promptSuffix: " as a Pixar movie still, no text"
    )

    static let pastelAnimation = PromptStyle(
        id: "pastel_animation",
        name: "Pastel Animation",
        promptSuffix: " as a frame from a soft pastel animated film, clean shapes, expressive character posing, gentle camera composition, warm natural light, hand-painted backgrounds"
    )

    static let legoStopMotion = PromptStyle(
        id: "lego_stop_motion",
        name: "LEGO Stop Motion",
        promptSuffix: " in LEGO stop-motion style, plastic brick-built forms, toy-scale set design, glossy studs, simple practical lighting, playful physical animation staging"
    )

    /// All available styles, in display order.
    static let allStyles: [PromptStyle] = [
        none,
        beautifulPaint,
        studioCommercial,
        pixarMovie,
        pastelAnimation,
        legoStopMotion
    ]

    /// The default style for new drawings.
    static let `default` = beautifulPaint

    /// Look up a style by its persistence ID. Falls back to default if not found.
    /// Drawings saved under a now-removed style id fall through to the default.
    static func from(id: String?) -> PromptStyle {
        guard let id else { return .default }
        switch id {
        case "studio_ghibli", "watercolor":
            return .pastelAnimation
        default:
            return allStyles.first { $0.id == id } ?? .default
        }
    }
}

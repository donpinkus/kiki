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

    static let studioGhibli = PromptStyle(
        id: "studio_ghibli",
        name: "Studio Ghibli",
        promptSuffix: " in the style of studio ghibli, cel shaded, smooth contours, graphic novel, concept art, ink and water color, pastel color pallete"
    )

    static let render3D = PromptStyle(
        id: "3d_render",
        name: "3D Render",
        promptSuffix: " in the style of cinema4D render, octane render, brilliant irridescent materials, global illuminated, mograph 3d render"
    )

    /// All available styles, in display order.
    static let allStyles: [PromptStyle] = [none, studioGhibli, render3D]

    /// The default style (first in list).
    static let `default` = studioGhibli

    /// Look up a style by its persistence ID. Falls back to default if not found.
    static func from(id: String?) -> PromptStyle {
        guard let id else { return .default }
        return allStyles.first { $0.id == id } ?? .default
    }
}

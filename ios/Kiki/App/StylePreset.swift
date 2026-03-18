enum StylePreset: String, CaseIterable {
    case photoreal = "Photoreal"
    case anime = "Anime"
    case watercolor = "Watercolor"
    case storybook = "Storybook"
    case fantasy = "Fantasy"
    case ink = "Ink"
    case neon = "Neon"

    /// Maps to the backend's expected style preset key.
    var apiKey: String { rawValue.lowercased() }
}

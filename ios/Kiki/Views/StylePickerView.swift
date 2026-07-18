import SwiftUI

struct StylePickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    /// (title, members) for every picker section, in display order.
    private var sections: [(title: String, styles: [PromptStyle])] {
        var result: [(String, [PromptStyle])] = [("Featured", PromptStyle.featuredStyles)]
        for category in PromptStyle.Category.allCases {
            let members = PromptStyle.styles(in: category)
            if !members.isEmpty {
                result.append((category.displayName, members))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 14) {
                            Text(section.title)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                            LazyVGrid(columns: columns, spacing: 20) {
                                ForEach(section.styles) { style in
                                    StyleTile(
                                        style: style,
                                        preview: coordinator.stylePreviewController.previews[style.id],
                                        isSelected: coordinator.selectedStyle == style
                                    ) {
                                        coordinator.selectedStyle = style
                                        dismiss()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }
            .navigationTitle("Choose Style")
            .navigationBarTitleDisplayMode(.large)
            // Match RootView's hidden status bar. Without this, presenting the
            // fullScreenCover hands status-bar-appearance ownership to the modal,
            // toggling the presenting view's top safe-area inset (~32 pt). That
            // wobble changes the canvas bounds and triggers a relayout on
            // dismiss — harmless now that the document resolution is fixed, but
            // this also avoids a visible canvas-frame jump during the transition.
            .statusBarHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Tile

private struct StyleTile: View {
    let style: PromptStyle
    let preview: StylePreviewController.PreviewState?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                header
                previewCard
                    .aspectRatio(1, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )
            }
        }
        .buttonStyle(.plain)
    }

    private var generatedPreview: UIImage? {
        guard case .ready(let image) = preview else { return nil }
        return image
    }

    private var hasGeneratedPreview: Bool {
        generatedPreview != nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(style.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
                Spacer(minLength: 0)
            }
            suffixText
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // Always reserves two lines so every tile's image starts at the same
    // y-offset. Empty suffix falls back to an italic placeholder.
    private var suffixText: Text {
        let trimmed = style.promptSuffix.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return Text("no extra text").italic()
        }
        return Text(trimmed)
    }

    private var previewCard: some View {
        ZStack {
            StyleStaticThumbnail(style: style)
                .opacity(hasGeneratedPreview ? 0 : 1)
                .rotation3DEffect(
                    .degrees(hasGeneratedPreview ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0),
                    perspective: 0.65
                )

            Group {
                if let generatedPreview {
                    Image(uiImage: generatedPreview)
                        .resizable()
                        .scaledToFill()
                } else {
                    StyleStaticThumbnail(style: style)
                        .hidden()
                }
            }
            .opacity(hasGeneratedPreview ? 1 : 0)
            .rotation3DEffect(
                .degrees(hasGeneratedPreview ? 0 : -180),
                axis: (x: 0, y: 1, z: 0),
                perspective: 0.65
            )
        }
        .overlay(alignment: .topTrailing) {
            previewStatusBadge
                .padding(8)
        }
        .clipped()
        .animation(.spring(response: 0.46, dampingFraction: 0.82), value: hasGeneratedPreview)
    }

    @ViewBuilder
    private var previewStatusBadge: some View {
        switch preview {
        case .ready:
            EmptyView()
        case .failed:
            badge(systemName: "exclamationmark.triangle.fill", tint: .orange)
        case .loading, .none:
            loadingBadge
        }
    }

    private var loadingBadge: some View {
        ProgressView()
            .controlSize(.small)
            .tint(.white)
            .padding(7)
            .background(.black.opacity(0.42), in: Circle())
            .accessibilityLabel("Loading preview")
    }

    private func badge(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(7)
            .background(tint.opacity(0.92), in: Circle())
    }
}

// MARK: - Static Thumbnail

private struct StyleStaticThumbnail: View {
    let style: PromptStyle

    private var assetName: String {
        "style_thumbnail_\(style.id)"
    }

    private var spec: StyleThumbnailSpec {
        StyleThumbnailSpec.spec(for: style.id)
    }

    var body: some View {
        if let image = UIImage(named: assetName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityHidden(true)
        } else {
            fallbackThumbnail
        }
    }

    private var fallbackThumbnail: some View {
        ZStack {
            LinearGradient(
                colors: spec.colors,
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            motif

            Image(systemName: spec.symbolName)
                .font(.system(size: 44, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white.opacity(0.9))
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var motif: some View {
        switch spec.motif {
        case .circles:
            ZStack {
                Circle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 128, height: 128)
                    .offset(x: -54, y: -48)
                Circle()
                    .stroke(.white.opacity(0.2), lineWidth: 10)
                    .frame(width: 118, height: 118)
                    .offset(x: 58, y: 52)
            }
        case .diagonalStripes:
            HStack(spacing: 16) {
                ForEach(0..<7, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 5)
                        .fill(.white.opacity(0.14))
                        .frame(width: 16, height: 190)
                        .rotationEffect(.degrees(28))
                }
            }
        case .grid:
            VStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { _ in
                    HStack(spacing: 10) {
                        ForEach(0..<5, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(.white.opacity(0.14))
                                .frame(width: 14, height: 14)
                        }
                    }
                }
            }
        case .panels:
            VStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0..<2, id: \.self) { column in
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.white.opacity(row == column ? 0.2 : 0.12))
                                .frame(width: 58, height: 40)
                        }
                    }
                }
            }
            .rotationEffect(.degrees(-8))
        case .scanlines:
            VStack(spacing: 5) {
                ForEach(0..<18, id: \.self) { _ in
                    Rectangle()
                        .fill(.white.opacity(0.11))
                        .frame(height: 2)
                }
            }
        case .triangles:
            ZStack {
                Triangle()
                    .fill(.white.opacity(0.16))
                    .frame(width: 118, height: 104)
                    .offset(x: -42, y: 28)
                Triangle()
                    .stroke(.white.opacity(0.22), lineWidth: 8)
                    .frame(width: 108, height: 96)
                    .rotationEffect(.degrees(180))
                    .offset(x: 54, y: -32)
            }
        }
    }
}

private struct StyleThumbnailSpec {
    enum Motif {
        case circles
        case diagonalStripes
        case grid
        case panels
        case scanlines
        case triangles
    }

    let colors: [Color]
    let symbolName: String
    let motif: Motif

    static func spec(for id: String) -> StyleThumbnailSpec {
        switch id {
        case "none":
            return StyleThumbnailSpec(colors: [rgb(0.68, 0.70, 0.74), rgb(0.34, 0.36, 0.4)], symbolName: "slash.circle", motif: .diagonalStripes)
        case "beautiful_paint":
            return StyleThumbnailSpec(colors: [rgb(0.36, 0.52, 0.78), rgb(0.86, 0.66, 0.42)], symbolName: "paintbrush.pointed.fill", motif: .circles)
        case "concept_art":
            return StyleThumbnailSpec(colors: [rgb(0.26, 0.3, 0.42), rgb(0.9, 0.62, 0.3)], symbolName: "sparkles", motif: .triangles)
        case "hand_painted_animation":
            return StyleThumbnailSpec(colors: [rgb(0.95, 0.68, 0.74), rgb(0.56, 0.78, 0.92)], symbolName: "paintpalette.fill", motif: .circles)
        case "ghibli_cel":
            return StyleThumbnailSpec(colors: [rgb(0.62, 0.8, 0.62), rgb(0.92, 0.9, 0.78)], symbolName: "leaf.fill", motif: .circles)
        case "paper_craft":
            return StyleThumbnailSpec(colors: [rgb(0.92, 0.62, 0.5), rgb(0.62, 0.5, 0.78)], symbolName: "scissors", motif: .panels)
        case "clay_model":
            return StyleThumbnailSpec(colors: [rgb(0.8, 0.56, 0.44), rgb(0.52, 0.36, 0.3)], symbolName: "hand.raised.fill", motif: .circles)
        case "felt_craft":
            return StyleThumbnailSpec(colors: [rgb(0.94, 0.72, 0.6), rgb(0.66, 0.82, 0.72)], symbolName: "circle.hexagongrid.fill", motif: .grid)
        case "bronze_sculpture":
            return StyleThumbnailSpec(colors: [rgb(0.55, 0.42, 0.22), rgb(0.28, 0.22, 0.14)], symbolName: "trophy.fill", motif: .circles)
        case "neon_glow":
            return StyleThumbnailSpec(colors: [rgb(0.08, 0.06, 0.16), rgb(0.9, 0.2, 0.62)], symbolName: "bolt.fill", motif: .scanlines)
        case "pop_art":
            return StyleThumbnailSpec(colors: [rgb(0.96, 0.76, 0.1), rgb(0.86, 0.22, 0.5)], symbolName: "burst.fill", motif: .triangles)
        case "dark_fantasy":
            return StyleThumbnailSpec(colors: [rgb(0.12, 0.12, 0.2), rgb(0.44, 0.2, 0.5)], symbolName: "moon.stars.fill", motif: .triangles)
        case "chalkboard":
            return StyleThumbnailSpec(colors: [rgb(0.16, 0.24, 0.2), rgb(0.3, 0.4, 0.36)], symbolName: "scribble.variable", motif: .scanlines)
        case "sticker":
            return StyleThumbnailSpec(colors: [rgb(0.5, 0.78, 0.94), rgb(0.94, 0.94, 0.96)], symbolName: "seal.fill", motif: .circles)
        case "watercolor":
            return StyleThumbnailSpec(colors: [rgb(0.62, 0.78, 0.92), rgb(0.94, 0.78, 0.84)], symbolName: "drop.fill", motif: .circles)
        case "oil_painting":
            return StyleThumbnailSpec(colors: [rgb(0.66, 0.5, 0.3), rgb(0.3, 0.42, 0.5)], symbolName: "paintbrush.fill", motif: .diagonalStripes)
        case "gouache":
            return StyleThumbnailSpec(colors: [rgb(0.86, 0.7, 0.56), rgb(0.5, 0.66, 0.62)], symbolName: "paintbrush.pointed.fill", motif: .panels)
        case "colored_pencil":
            return StyleThumbnailSpec(colors: [rgb(0.94, 0.66, 0.4), rgb(0.46, 0.68, 0.86)], symbolName: "pencil.tip", motif: .diagonalStripes)
        default:
            return StyleThumbnailSpec(colors: [rgb(0.28, 0.34, 0.42), rgb(0.52, 0.6, 0.7)], symbolName: "wand.and.stars", motif: .circles)
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red, green: green, blue: blue)
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

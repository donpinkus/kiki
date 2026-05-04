import SwiftUI

struct StylePickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(PromptStyle.allStyles) { style in
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
                .padding(24)
            }
            .navigationTitle("Choose Style")
            .navigationBarTitleDisplayMode(.large)
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
        case "editorial_photo":
            return StyleThumbnailSpec(colors: [rgb(0.16, 0.18, 0.2), rgb(0.64, 0.55, 0.43)], symbolName: "camera.fill", motif: .circles)
        case "cinematic_live_action":
            return StyleThumbnailSpec(colors: [rgb(0.08, 0.1, 0.16), rgb(0.93, 0.5, 0.25)], symbolName: "film.fill", motif: .scanlines)
        case "3d_render":
            return StyleThumbnailSpec(colors: [rgb(0.36, 0.5, 0.9), rgb(0.74, 0.35, 0.86)], symbolName: "cube.fill", motif: .triangles)
        case "pastel_animation":
            return StyleThumbnailSpec(colors: [rgb(0.95, 0.68, 0.74), rgb(0.56, 0.78, 0.92)], symbolName: "paintpalette.fill", motif: .circles)
        case "anime_action":
            return StyleThumbnailSpec(colors: [rgb(0.95, 0.16, 0.22), rgb(0.1, 0.12, 0.23)], symbolName: "bolt.fill", motif: .diagonalStripes)
        case "claymation":
            return StyleThumbnailSpec(colors: [rgb(0.82, 0.46, 0.28), rgb(0.96, 0.72, 0.38)], symbolName: "circle.fill", motif: .circles)
        case "low_poly":
            return StyleThumbnailSpec(colors: [rgb(0.14, 0.56, 0.5), rgb(0.88, 0.78, 0.28)], symbolName: "triangle.fill", motif: .triangles)
        case "pixel_art":
            return StyleThumbnailSpec(colors: [rgb(0.18, 0.22, 0.5), rgb(0.25, 0.78, 0.87)], symbolName: "square.grid.3x3.fill", motif: .grid)
        case "paper_cutout":
            return StyleThumbnailSpec(colors: [rgb(0.95, 0.85, 0.55), rgb(0.86, 0.32, 0.34)], symbolName: "scissors", motif: .panels)
        case "graphic_ink":
            return StyleThumbnailSpec(colors: [rgb(0.08, 0.08, 0.09), rgb(0.86, 0.86, 0.82)], symbolName: "bubble.left.and.bubble.right.fill", motif: .panels)
        case "isometric_diorama":
            return StyleThumbnailSpec(colors: [rgb(0.45, 0.64, 0.46), rgb(0.89, 0.76, 0.48)], symbolName: "shippingbox.fill", motif: .grid)
        case "felt_puppet":
            return StyleThumbnailSpec(colors: [rgb(0.68, 0.18, 0.35), rgb(0.93, 0.58, 0.38)], symbolName: "theatermasks.fill", motif: .circles)
        case "collage_animation":
            return StyleThumbnailSpec(colors: [rgb(0.28, 0.18, 0.42), rgb(0.92, 0.66, 0.28)], symbolName: "square.stack.3d.up.fill", motif: .panels)
        case "technical_explainer":
            return StyleThumbnailSpec(colors: [rgb(0.12, 0.46, 0.78), rgb(0.28, 0.84, 0.74)], symbolName: "slider.horizontal.3", motif: .grid)
        case "studio_commercial":
            return StyleThumbnailSpec(colors: [rgb(0.92, 0.9, 0.84), rgb(0.18, 0.22, 0.26)], symbolName: "camera.aperture", motif: .circles)
        case "music_video":
            return StyleThumbnailSpec(colors: [rgb(0.95, 0.1, 0.62), rgb(0.16, 0.1, 0.8)], symbolName: "music.note", motif: .diagonalStripes)
        case "vhs_camcorder":
            return StyleThumbnailSpec(colors: [rgb(0.2, 0.22, 0.25), rgb(0.63, 0.2, 0.42)], symbolName: "video.fill", motif: .scanlines)
        case "night_vision":
            return StyleThumbnailSpec(colors: [rgb(0.02, 0.12, 0.05), rgb(0.22, 0.72, 0.24)], symbolName: "eye.fill", motif: .scanlines)
        case "neon_sci_fi":
            return StyleThumbnailSpec(colors: [rgb(0.04, 0.07, 0.22), rgb(0.0, 0.85, 0.9), rgb(0.9, 0.1, 0.85)], symbolName: "sparkles", motif: .diagonalStripes)
        case "akira":
            return StyleThumbnailSpec(colors: [rgb(0.78, 0.04, 0.04), rgb(0.08, 0.08, 0.11)], symbolName: "bolt.fill", motif: .scanlines)
        case "halo":
            return StyleThumbnailSpec(colors: [rgb(0.08, 0.28, 0.2), rgb(0.26, 0.7, 0.52)], symbolName: "shield.fill", motif: .triangles)
        case "westworld":
            return StyleThumbnailSpec(colors: [rgb(0.86, 0.58, 0.26), rgb(0.24, 0.18, 0.14)], symbolName: "sun.max.fill", motif: .circles)
        case "world_of_warcraft":
            return StyleThumbnailSpec(colors: [rgb(0.08, 0.34, 0.68), rgb(0.93, 0.62, 0.15)], symbolName: "flame.fill", motif: .triangles)
        case "starcraft":
            return StyleThumbnailSpec(colors: [rgb(0.1, 0.16, 0.3), rgb(0.48, 0.72, 0.95)], symbolName: "star.fill", motif: .scanlines)
        case "pixar_feature":
            return StyleThumbnailSpec(colors: [rgb(0.3, 0.58, 0.9), rgb(0.96, 0.76, 0.32)], symbolName: "lightbulb.fill", motif: .circles)
        case "spider_verse":
            return StyleThumbnailSpec(colors: [rgb(0.08, 0.12, 0.65), rgb(0.95, 0.12, 0.2)], symbolName: "sparkle", motif: .grid)
        case "arcane":
            return StyleThumbnailSpec(colors: [rgb(0.15, 0.12, 0.35), rgb(0.88, 0.48, 0.2)], symbolName: "wand.and.stars", motif: .panels)
        case "lego_stop_motion":
            return StyleThumbnailSpec(colors: [rgb(0.94, 0.78, 0.04), rgb(0.1, 0.38, 0.82)], symbolName: "square.grid.2x2.fill", motif: .grid)
        case "matcap_model":
            return StyleThumbnailSpec(colors: [rgb(0.42, 0.44, 0.48), rgb(0.84, 0.86, 0.88)], symbolName: "circle.fill", motif: .triangles)
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

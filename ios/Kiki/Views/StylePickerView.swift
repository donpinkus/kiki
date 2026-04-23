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
                previewImage
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

    @ViewBuilder
    private var previewImage: some View {
        switch preview {
        case .ready(let image):
            Image(uiImage: image)
                .resizable()
                .transition(.opacity)
        case .failed:
            ZStack {
                Color(.systemGray5)
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
        case .loading, .none:
            ShimmerView(cornerRadius: 12)
        }
    }
}

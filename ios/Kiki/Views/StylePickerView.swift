import SwiftUI

struct StylePickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(PromptStyle.allStyles) { style in
                        StyleRow(
                            style: style,
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

// MARK: - Style Row

private struct StyleRow: View {
    let style: PromptStyle
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 16) {
                // Placeholder thumbnail
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemGray5))
                    .frame(width: 120, height: 80)
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(style.name)
                            .font(.headline)

                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    if !style.promptSuffix.isEmpty {
                        Text(style.promptSuffix.trimmingCharacters(in: .whitespaces))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                }

                Spacer()
            }
            .padding(12)
            .background(
                isSelected ? Color.accentColor.opacity(0.08) : Color(.systemGray6),
                in: RoundedRectangle(cornerRadius: 16)
            )
        }
        .buttonStyle(.plain)
    }
}

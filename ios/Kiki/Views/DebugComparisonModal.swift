import SwiftUI

struct DebugComparisonModal: View {
    let data: ComparisonData
    @Environment(\.dismiss) private var dismiss

    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
    ]

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            LazyVGrid(columns: columns, spacing: 12) {
                cell(image: data.snapshotImage, label: "Original Sketch")
                cell(image: data.lineartImage, label: "Lineart")
                cell(image: data.generatedImage, label: "Generated (CN: \(formatted(data.controlNetStrength)))")
                cell(image: data.comparisonImage, label: "Generated (CN: 0)")
            }
            .padding(16)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(16)
        }
    }

    private func cell(image: UIImage, label: String) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func formatted(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.001
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }
}

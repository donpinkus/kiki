import SwiftUI

struct DebugComparisonModal: View {
    let data: ComparisonData
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let cellSize = min(
                (geo.size.width - 12 - 32) / 2,
                (geo.size.height - 12 - 80) / 2
            )

            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        cell(image: data.snapshotImage, label: "Original Sketch", size: cellSize)
                        cell(image: data.lineartImage, label: "Lineart", size: cellSize)
                    }
                    HStack(spacing: 12) {
                        cell(image: data.generatedImage, label: "Generated (CN: \(formatted(data.controlNetStrength)))", size: cellSize)
                        cell(image: data.comparisonImage, label: "Generated (CN: 0)", size: cellSize)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(20)
            }
        }
    }

    private func cell(image: UIImage, label: String, size: CGFloat) -> some View {
        VStack(spacing: 6) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: size, maxHeight: size - 20)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: size)
    }

    private func formatted(_ value: Double) -> String {
        abs(value - value.rounded()) < 0.001
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }
}

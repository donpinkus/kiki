import SwiftUI

/// Pose-mode "Poses" popover: bundled presets as a categorized thumbnail grid.
/// Tapping one replaces the figure's joints (placement, body and orbit are kept
/// unless the preset carries its own yaw).
struct FigurePosePickerView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 10)]

    var body: some View {
        let body = coordinator.figure.body
        let categories = FigurePoseLibrary.categories
        ScrollView {
            if categories.isEmpty {
                ContentUnavailableView("No poses bundled", systemImage: "figure.stand",
                                       description: Text("figure_poses.json is missing or empty."))
                    .padding()
            }
            VStack(alignment: .leading, spacing: 14) {
                ForEach(categories, id: \.name) { category in
                    Text(category.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(category.presets) { preset in
                            Button {
                                coordinator.figure.applyPreset(preset)
                                dismiss()
                            } label: {
                                VStack(spacing: 4) {
                                    PoseThumbnail(preset: preset, body: body)
                                    Text(preset.name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(12)
        }
        .frame(width: 440, height: 480)
    }
}

/// One tile: the bake runs in a task after the cell appears (not inside the
/// grid's body pass), so the popover opens immediately and tiles fill in.
private struct PoseThumbnail: View {
    let preset: FigurePosePreset
    let body_: FigureBody
    @State private var image: UIImage?

    init(preset: FigurePosePreset, body: FigureBody) {
        self.preset = preset
        self.body_ = body
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.94))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
            } else {
                Image(systemName: "figure.stand")
                    .foregroundStyle(.tertiary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .task(id: "\(body_.rawValue)/\(preset.id)") {
            image = FigurePoseLibrary.thumbnail(for: preset, body: body_)
        }
    }
}

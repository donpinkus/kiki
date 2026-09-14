import SwiftUI

/// Pose mode chrome (owner direction 2026-09-13: "we don't need the drawing UI
/// until you've placed or cleared your pose"). While a figure is being posed
/// the drawing screen swaps its top bar for `FigurePoseTopBar` and docks
/// `FigurePosePanel` on the left; the canvas keeps the rest of the width.
///
/// Dark, always-dark chrome like the rest of the drawing screen (`KikiTheme`).

// MARK: - Top bar

struct FigurePoseTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.figure.cancel()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KikiTheme.icon)
                    .padding(.horizontal, 14)
                    .frame(height: KikiTheme.buttonDiameter)
                    .background(Capsule().fill(KikiTheme.buttonCircle))
            }

            Spacer()

            VStack(spacing: 1) {
                Text(coordinator.figure.isEditingExisting ? "Edit pose" : "Pose figure")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("Drag a joint · drag empty space to turn · two fingers move, scale, rotate")
                    .font(.caption)
                    .foregroundStyle(KikiTheme.iconDim)
            }

            Spacer()

            Button {
                coordinator.figure.commit()
            } label: {
                Label(coordinator.figure.isEditingExisting ? "Save" : "Place", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: KikiTheme.buttonDiameter)
                    .background(Capsule().fill(Color.accentColor))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(KikiTheme.barBackground)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Left panel

struct FigurePosePanel: View {
    @Environment(AppCoordinator.self) private var coordinator

    static let width: CGFloat = 300
    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8),
                           GridItem(.flexible(), spacing: 8)]

    var body: some View {
        @Bindable var figure = coordinator.figure
        // Read the revision so the View row / highlight refresh on every change.
        let _ = coordinator.figure.poseRevision
        let body = coordinator.figure.body
        let selected = coordinator.figure.selectedPresetID
        let currentView = coordinator.figure.currentView

        VStack(alignment: .leading, spacing: 0) {
            // Body + view: the two whole-figure choices, above the poses.
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Body")
                Picker("Body", selection: $figure.body) {
                    ForEach(FigureBody.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                sectionLabel("View")
                HStack(spacing: 6) {
                    ForEach(FigureController.View.allCases) { view in
                        Button {
                            coordinator.figure.setView(view)
                        } label: {
                            Text(view.label)
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 32)
                                .foregroundStyle(currentView == view ? Color.white : KikiTheme.icon)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(currentView == view ? Color.accentColor : KikiTheme.buttonCircle)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(Color.white.opacity(0.08))

            // Poses: always visible, scrollable, current one highlighted.
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10, pinnedViews: [.sectionHeaders]) {
                    ForEach(FigurePoseLibrary.categories, id: \.name) { category in
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(category.presets) { preset in
                                    Button {
                                        coordinator.figure.applyPreset(preset)
                                    } label: {
                                        PoseTile(preset: preset, body: body, isSelected: preset.id == selected)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                        } header: {
                            sectionLabel(category.name)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(KikiTheme.sidebarBackground)
                        }
                    }
                }
                .padding(.top, 6)
                .padding(.bottom, 12)
            }

            Divider().overlay(Color.white.opacity(0.08))

            Button {
                coordinator.figure.resetPose()
            } label: {
                Label("Reset pose", systemImage: "arrow.counterclockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KikiTheme.icon)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 10).fill(KikiTheme.buttonCircle))
            }
            .buttonStyle(.plain)
            .padding(14)
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(KikiTheme.sidebarBackground)
        .environment(\.colorScheme, .dark)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(KikiTheme.iconDim)
    }
}

/// One pose tile: thumbnail baked after the cell appears (not in the grid's
/// body pass), name below, accent ring when it's the figure's current pose.
private struct PoseTile: View {
    let preset: FigurePosePreset
    let figureBody: FigureBody
    let isSelected: Bool
    @State private var image: UIImage?

    init(preset: FigurePosePreset, body: FigureBody, isSelected: Bool) {
        self.preset = preset
        self.figureBody = body
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: isSelected ? 0.22 : 0.15))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(2)
                } else {
                    Image(systemName: "figure.stand")
                        .foregroundStyle(KikiTheme.iconDim)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )
            Text(preset.name)
                .font(.caption2)
                .lineLimit(1)
                .foregroundStyle(isSelected ? Color.white : KikiTheme.icon)
        }
        .task(id: "\(figureBody.rawValue)/\(preset.id)") {
            image = FigurePoseLibrary.thumbnail(for: preset, body: figureBody)
        }
    }
}

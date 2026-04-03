import SwiftUI
import CanvasModule

struct DrawingTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showAdvancedParameters = false

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            // MARK: Left — Gallery
            Button {
                coordinator.navigateToGallery()
            } label: {
                Label("Gallery", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
            }

            Spacer()

            // MARK: Center — Style, Prompt, Generate, Settings
            Button {
                coordinator.showStylePicker = true
            } label: {
                Text(coordinator.selectedStyle.name)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            TextField("Describe what you want…", text: $coordinator.promptText)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .frame(minWidth: 120, maxWidth: 400)

            Button {
                coordinator.generate()
            } label: {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        coordinator.canvasViewModel.isEmpty || coordinator.isGenerating
                            ? Color.accentColor.opacity(0.4)
                            : Color.accentColor,
                        in: Circle()
                    )
                    .overlay(alignment: .topTrailing) {
                        if coordinator.hasUnsavedChanges && !coordinator.isGenerating {
                            Circle()
                                .fill(.orange)
                                .frame(width: 8, height: 8)
                        }
                    }
            }
            .disabled(coordinator.canvasViewModel.isEmpty || coordinator.isGenerating)

            Button {
                showAdvancedParameters = true
            } label: {
                Image(systemName: coordinator.advancedParameters.isDefault
                    ? "slider.horizontal.3"
                    : "slider.horizontal.2.gobackward")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 36, height: 36)
            }
            .popover(isPresented: $showAdvancedParameters) {
                AdvancedParametersPanel()
                    .frame(width: 400, height: 600)
            }

            Spacer()

            // MARK: Right — Pen, Eraser, Reset Transform
            toolButton(icon: "pencil.tip", tool: .brush)
            toolButton(icon: "eraser", tool: .eraser)

            if !coordinator.canvasViewModel.isDefaultTransform {
                actionButton(
                    icon: "arrow.counterclockwise",
                    action: coordinator.canvasViewModel.resetViewTransform,
                    disabled: false
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Helpers

    private func toolButton(icon: String, tool: DrawingTool) -> some View {
        Button {
            coordinator.currentTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(coordinator.currentTool == tool ? Color.accentColor : .primary)
                .frame(width: 36, height: 36)
        }
    }

    private func actionButton(icon: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 36, height: 36)
        }
        .disabled(disabled)
    }
}

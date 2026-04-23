import SwiftUI
import CanvasModule

struct DrawingTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showSettings = false

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            // MARK: Left — Settings, Gallery
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
            }
            .tint(Color.primary)
            .popover(isPresented: $showSettings) {
                SettingsPanel()
                    .frame(width: 400, height: 600)
            }

            Button {
                coordinator.navigateToGallery()
            } label: {
                Text("Gallery")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
            }
            .tint(Color.primary)

            Spacer()

            // MARK: Center — Style, Prompt
            if coordinator.drawingLayout != .splitScreen {
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
            }

            Spacer()

            // MARK: Right — Pen, Eraser, Lasso, Reset Transform, Layers
            toolButton(icon: "pencil.tip", tool: .brush)
            toolButton(icon: "eraser", tool: .eraser)
            toolButton(icon: "lasso", tool: .lasso)

            if coordinator.canvasViewModel.hasLassoSelection {
                Button {
                    coordinator.canvasViewModel.clearLasso()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            }

            if !coordinator.canvasViewModel.isDefaultTransform {
                actionButton(
                    icon: "arrow.counterclockwise",
                    action: coordinator.canvasViewModel.resetViewTransform,
                    disabled: false
                )
            }

            Button {
                coordinator.showLayerPanel.toggle()
            } label: {
                Image(systemName: "square.on.square")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
            }
            .popover(isPresented: $coordinator.showLayerPanel) {
                LayerPanelView()
                    .frame(width: 260, height: 400)
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

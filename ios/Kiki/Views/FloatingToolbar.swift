import SwiftUI

struct FloatingToolbar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showAdvancedParameters = false

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            toolButton(icon: "pencil.tip", tool: .brush)
            toolButton(icon: "eraser", tool: .eraser)

            Divider()
                .frame(height: 24)

            Slider(value: $coordinator.toolSize, in: 1...100, step: 1)
                .frame(width: 120)

            Text("\(Int(coordinator.toolSize))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)

            Divider()
                .frame(height: 24)

            actionButton(
                icon: "arrow.uturn.backward",
                action: coordinator.undo,
                disabled: !coordinator.canvasViewModel.canUndo
            )
            actionButton(
                icon: "arrow.uturn.forward",
                action: coordinator.redo,
                disabled: !coordinator.canvasViewModel.canRedo
            )

            Divider()
                .frame(height: 24)

            actionButton(
                icon: "trash",
                action: coordinator.clear,
                disabled: coordinator.canvasViewModel.isEmpty
            )

            if !coordinator.canvasViewModel.isDefaultTransform {
                Divider()
                    .frame(height: 24)

                actionButton(
                    icon: "arrow.counterclockwise",
                    action: coordinator.canvasViewModel.resetViewTransform,
                    disabled: false
                )
            }

            Divider()
                .frame(height: 24)

            Button {
                coordinator.triggerMode = (coordinator.triggerMode == .auto) ? .manual : .auto
            } label: {
                Image(systemName: coordinator.triggerMode == .auto ? "bolt.fill" : "hand.tap.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(coordinator.triggerMode == .auto ? Color.accentColor : .primary)
                    .frame(width: 36, height: 36)
            }

            Divider()
                .frame(height: 24)

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
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Private

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

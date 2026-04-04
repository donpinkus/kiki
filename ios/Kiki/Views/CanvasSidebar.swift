import SwiftUI
import CanvasModule

struct CanvasSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isDraggingSlider = false

    private let widthRange = BrushConfig.widthRange

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 12) {
            // Vertical size slider
            Slider(value: $coordinator.toolSize, in: widthRange) { editing in
                isDraggingSlider = editing
            }
            .frame(width: 120)
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 120)
            .overlay(alignment: .trailing) {
                if isDraggingSlider {
                    let divisor = CanvasViewModel.penCursorDivisor
                    let displaySize = max(coordinator.toolSize / divisor, 4)
                    let containerSize = max(displaySize + 16, 32)
                    Circle()
                        .stroke(.primary, lineWidth: 1)
                        .frame(width: displaySize, height: displaySize)
                        .frame(width: containerSize, height: containerSize)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .offset(x: containerSize / 2 + 20)
                }
            }

            Divider()
                .frame(width: 24)

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
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

    // MARK: - Helpers

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

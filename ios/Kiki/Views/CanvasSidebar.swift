import SwiftUI
import CanvasModule

struct CanvasSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isDraggingSize = false
    @State private var isDraggingOpacity = false
    @State private var showColorPicker = false

    private let widthRange = BrushConfig.widthRange

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 12) {
            // Color swatch — tap to show disk picker popover
            Button {
                showColorPicker.toggle()
            } label: {
                Circle()
                    .fill(coordinator.currentColor)
                    .frame(width: 30, height: 30)
                    .overlay(Circle().stroke(.primary.opacity(0.3), lineWidth: 1.5))
            }
            .popover(isPresented: $showColorPicker) {
                DiskColorPicker(color: $coordinator.currentColor)
            }
            .frame(width: 36, height: 36)

            Divider().frame(width: 24)

            // Vertical size slider
            Slider(value: $coordinator.toolSize, in: widthRange) { editing in
                isDraggingSize = editing
            }
            .frame(width: 120)
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 120)
            .overlay(alignment: .trailing) {
                if isDraggingSize {
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

            Divider().frame(width: 24)

            // Opacity slider (brush only)
            Slider(value: $coordinator.toolOpacity, in: 0.05...1.0) { editing in
                isDraggingOpacity = editing
            }
            .frame(width: 100)
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 100)
            .overlay(alignment: .trailing) {
                if isDraggingOpacity {
                    Text("\(Int(coordinator.toolOpacity * 100))%")
                        .font(.caption2.weight(.medium).monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .offset(x: 50)
                }
            }
            .disabled(coordinator.currentTool == .eraser)
            .opacity(coordinator.currentTool == .eraser ? 0.3 : 1)

            Divider().frame(width: 24)

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

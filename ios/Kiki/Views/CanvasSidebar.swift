import SwiftUI
import CanvasModule

struct CanvasSidebar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var isDraggingSize = false
    @State private var isDraggingOpacity = false

    private let widthRange = BrushConfig.widthRange

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 12) {
            // Vertical size slider
            Slider(value: $coordinator.toolSize, in: widthRange) { editing in
                isDraggingSize = editing
            }
            .frame(width: 120)
            .rotationEffect(.degrees(-90))
            .frame(width: 30, height: 120)
            .overlay(alignment: .trailing) {
                if isDraggingSize {
                    // Show the configured size at rest (force=1, perp tilt) so the
                    // preview matches the actual stamp diameter the user will get.
                    let displaySize = max(coordinator.toolSize, 4)
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
        .background(
            .ultraThinMaterial,
            in: UnevenRoundedRectangle(
                cornerRadii: .init(topLeading: 0, bottomLeading: 0, bottomTrailing: 16, topTrailing: 16)
            )
        )
        .shadow(color: .black.opacity(0.15), radius: 8, x: 2, y: 0)
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
        .tint(Color.primary)
        .disabled(disabled)
    }
}

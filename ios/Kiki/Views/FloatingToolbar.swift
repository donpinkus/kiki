import SwiftUI
import CanvasModule

struct FloatingToolbar: View {

    let viewModel: CanvasViewModel
    @State private var isVisible = true
    @State private var hideTask: Task<Void, Never>?

    private let autoHideDelay: Duration = .seconds(3)

    var body: some View {
        VStack {
            Spacer()

            if isVisible {
                toolbar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 24)
        .animation(.easeInOut(duration: 0.25), value: isVisible)
        .onAppear { scheduleHide() }
    }

    // MARK: - Subviews

    private var toolbar: some View {
        HStack(spacing: 16) {
            toolbarButton(icon: "paintbrush.pointed", label: "Brush") {
                showAndScheduleHide()
            }

            toolbarButton(icon: "eraser", label: "Eraser") {
                showAndScheduleHide()
            }

            Divider()
                .frame(height: 24)

            toolbarButton(icon: "arrow.uturn.backward", label: "Undo", disabled: !viewModel.canUndo) {
                viewModel.undo()
                showAndScheduleHide()
            }

            toolbarButton(icon: "arrow.uturn.forward", label: "Redo", disabled: !viewModel.canRedo) {
                viewModel.redo()
                showAndScheduleHide()
            }

            Divider()
                .frame(height: 24)

            toolbarButton(icon: "trash", label: "Clear") {
                viewModel.clear()
                showAndScheduleHide()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
        .onTapGesture { showAndScheduleHide() }
    }

    private func toolbarButton(
        icon: String,
        label: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: - Auto-hide

    private func showAndScheduleHide() {
        isVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: autoHideDelay)
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}

#Preview {
    ZStack {
        Color.white
        FloatingToolbar(viewModel: CanvasViewModel())
    }
}

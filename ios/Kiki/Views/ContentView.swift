import SwiftUI
import CanvasModule
import ResultModule

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var toolbarVisible = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                CanvasView(viewModel: coordinator.canvasViewModel)
                    .frame(width: geometry.size.width * coordinator.dividerPosition)

                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)

                ResultView()
            }
        }
        .ignoresSafeArea(.keyboard)
        .overlay(alignment: .bottomLeading) {
            toolbarOverlay
                .padding(16)
        }
        .onChange(of: coordinator.canvasViewModel.canUndo) {
            showAndScheduleHide()
        }
        .onChange(of: coordinator.canvasViewModel.isEmpty) {
            showAndScheduleHide()
        }
        .onAppear {
            scheduleHide()
        }
    }

    // MARK: - Private

    @ViewBuilder
    private var toolbarOverlay: some View {
        if toolbarVisible {
            FloatingToolbar(onInteraction: showAndScheduleHide)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else {
            Button {
                showAndScheduleHide()
            } label: {
                Image(systemName: "pencil.and.outline")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(.ultraThinMaterial, in: Circle())
                    .shadow(color: .black.opacity(0.1), radius: 4, y: 2)
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    private func showAndScheduleHide() {
        withAnimation(.easeIn(duration: 0.2)) {
            toolbarVisible = true
        }
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                toolbarVisible = false
            }
        }
    }
}

#Preview {
    ContentView()
        .environment(AppCoordinator())
}

import SwiftUI
import CanvasModule
import ResultModule

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        GeometryReader { geometry in
            HStack(spacing: 0) {
                CanvasView(viewModel: coordinator.canvasViewModel)
                    .frame(width: geometry.size.width * coordinator.dividerPosition)
                    .ignoresSafeArea(.keyboard)

                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    ResultView(state: coordinator.resultState)

                    promptBar(promptText: $coordinator.promptText)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            FloatingToolbar()
                .padding(16)
        }
    }

    // MARK: - Private

    private func promptBar(promptText: Binding<String>) -> some View {
        HStack(spacing: 12) {
            TextField("Describe what you want…", text: promptText)
                .textFieldStyle(.plain)
                .font(.subheadline)

            Button {
                coordinator.generate()
            } label: {
                Image(systemName: coordinator.isGenerating ? "hourglass" : "arrow.trianglehead.2.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        coordinator.canvasViewModel.isEmpty || coordinator.isGenerating
                            ? Color.accentColor.opacity(0.4)
                            : Color.accentColor,
                        in: Circle()
                    )
            }
            .disabled(coordinator.canvasViewModel.isEmpty || coordinator.isGenerating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

#Preview {
    ContentView()
        .environment(AppCoordinator())
}

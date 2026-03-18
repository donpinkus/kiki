import SwiftUI
import CanvasModule
import ResultModule

struct ContentView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
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

                    PromptBar()
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            FloatingToolbar()
                .padding(16)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppCoordinator())
}

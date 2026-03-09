import SwiftUI
import CanvasModule
import NetworkModule
import ResultModule

struct ContentView: View {

    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                canvasPane
                    .frame(width: geometry.size.width * 0.55)

                Divider()

                resultPane
                    .frame(width: geometry.size.width * 0.45)
            }
        }
        .ignoresSafeArea(.keyboard)
        .statusBarHidden()
        .onAppear {
            let baseURL = URL(string: "http://localhost:3000")!
            let apiClient = APIClient(baseURL: baseURL)
            coordinator.start(apiClient: apiClient)
        }
    }

    // MARK: - Subviews

    private var canvasPane: some View {
        ZStack {
            CanvasView(viewModel: coordinator.canvasViewModel)

            FloatingToolbar(viewModel: coordinator.canvasViewModel)
        }
    }

    private var resultPane: some View {
        ResultView(viewModel: coordinator.resultViewModel)
    }
}

#Preview {
    ContentView()
        .environment(AppCoordinator())
}

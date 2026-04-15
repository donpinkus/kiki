import SwiftUI

struct RootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch coordinator.currentScreen {
            case .signIn:
                SignInView()
            case .gallery:
                GalleryView()
            case .drawing:
                DrawingView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.currentScreen)
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhaseChange(newPhase)
        }
    }
}

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
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.25), value: coordinator.currentScreen)
        .onAppear {
            // didSet on AppCoordinator.currentScreen handles subsequent
            // navigation, but doesn't fire for the initial value set during
            // init. Emit one explicit screen event for the entry screen.
            Analytics.screen(coordinator.currentScreen.analyticsName)
        }
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhaseChange(newPhase)
        }
    }
}

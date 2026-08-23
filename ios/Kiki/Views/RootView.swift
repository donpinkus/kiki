import SwiftUI

struct RootView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var coordinator = coordinator
        return Group {
            switch coordinator.currentScreen {
            case .signIn:
                SignInView()
            case .gallery:
                GalleryView()
            case .drawing:
                DrawingView()
            case .animate:
                AnimateView()
            case .replay:
                SpeedPaintReplayView()
            }
        }
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.25), value: coordinator.currentScreen)
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhaseChange(newPhase)
        }
        .fullScreenCover(isPresented: $coordinator.showPaywall) {
            PaywallView()
                .environment(coordinator)
        }
    }
}

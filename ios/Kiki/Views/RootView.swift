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
            }
        }
        .statusBarHidden(true)
        .animation(.easeInOut(duration: 0.25), value: coordinator.currentScreen)
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhaseChange(newPhase)
        }
        .fullScreenCover(isPresented: $coordinator.devShowReplayFromGallery) {
            // TEMP DEBUG (black-preview bisect): replay modal presented with
            // no canvas/drawing view ever created. Remove when closed.
            SpeedPaintReplayView()
                .environment(coordinator)
        }
        .fullScreenCover(isPresented: $coordinator.showPaywall) {
            PaywallView()
                .environment(coordinator)
        }
    }
}

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
        // No cross-fade into the replay screen: the fade puts the whole
        // subtree behind an animated-opacity group, and an AVPlayerLayer
        // created inside one composites to NOTHING on iPadOS 26 hardware —
        // the same masked/faded-video failure the black-preview hunt mapped
        // (frames delivered, geometry correct, screen gray). The replay page
        // therefore cuts in without animation.
        .animation(
            coordinator.currentScreen == .replay ? nil : .easeInOut(duration: 0.25),
            value: coordinator.currentScreen
        )
        .onChange(of: scenePhase) { _, newPhase in
            coordinator.handleScenePhaseChange(newPhase)
        }
        .fullScreenCover(isPresented: $coordinator.showPaywall) {
            PaywallView()
                .environment(coordinator)
        }
    }
}

import SwiftUI

struct RootView: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        Group {
            switch coordinator.currentScreen {
            case .gallery:
                GalleryView()
            case .drawing:
                DrawingView()
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.currentScreen)
    }
}

import SwiftUI
import SwiftData

@main
struct KikiApp: App {
    private let container: ModelContainer
    @State private var coordinator: AppCoordinator

    init() {
        let container = try! ModelContainer(for: Drawing.self)
        self.container = container
        _coordinator = State(initialValue: AppCoordinator(modelContext: container.mainContext))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .modelContainer(container)
        }
    }
}

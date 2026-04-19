import SwiftUI
import SwiftData
import Sentry

@main
struct KikiApp: App {
    private let container: ModelContainer
    @State private var coordinator: AppCoordinator

    init() {
        SentrySDK.start { options in
            options.dsn = "https://ea583825f3a2331b0f211a94db5ab2f2@o4511242315169792.ingest.us.sentry.io/4511243617042432"
            options.tracesSampleRate = 1.0
            options.enableAutoSessionTracking = true
            options.debug = false
        }
        print("[Sentry] SDK initialized")

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

import SwiftUI
import SwiftData
import Sentry
import PostHog

@main
struct KikiApp: App {
    private let container: ModelContainer
    @State private var coordinator: AppCoordinator

    init() {
        SentrySDK.start { options in
            options.dsn = "https://ea583825f3a2331b0f211a94db5ab2f2@o4511242315169792.ingest.us.sentry.io/4511243617042432"
            options.tracesSampleRate = 1.0
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.enableAutoPerformanceTracing = true
            options.debug = false
        }

        // PostHog — product analytics (events, funnels, cohorts). Paired with
        // Sentry which owns crashes/errors/APM. Project token is "write-only"
        // per PostHog docs — safe to embed in the app binary, same as the
        // Sentry DSN above.
        let posthogConfig = PostHogConfig(
            apiKey: "phc_vWiC8bcuN2EUq6jfuUfU24yGUqS3y2Pi8V4Ec5mUe84w",
            host: "https://us.i.posthog.com"
        )
        // Auto-captured screen events use UIKit view-controller class names,
        // which on SwiftUI all collapse to `UIHostingController<...>` —
        // useless. Disable and emit explicit screen events from
        // AppCoordinator's `currentScreen` didSet.
        posthogConfig.captureScreenViews = false
        PostHogSDK.shared.setup(posthogConfig)

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

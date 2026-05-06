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
            // Temporarily true while diagnosing why session replays aren't
            // appearing in Sentry. Flip back to false once that's working.
            options.debug = true

            // Phase 1: capture full sessions, including sketch + prompt +
            // result image, to understand what users actually do. Revisit
            // masking + sample rate before any public/TestFlight build.
            options.sessionReplay.sessionSampleRate = 1.0
            options.sessionReplay.onErrorSampleRate = 1.0
            options.sessionReplay.maskAllText = false
            options.sessionReplay.maskAllImages = false

            // Sentry Logs product — turns `SentrySDK.logger.X(...)` calls
            // (used by the `Log` facade in `Phase.swift`) into queryable
            // log entries in Sentry's Logs UI. Cross-stack queries like
            // `user_id:X phase:preparing` need iOS to populate the same
            // attribute schema the backend + pod do. See
            // `flux-klein-server/sentry_init.py` for the pod-side mirror.
            options.enableLogs = true

            // Belt-and-suspenders attribute injection: the `Log` facade
            // already injects `phase` (TaskLocal) + `stream_id` (static)
            // at emit time. This callback catches any direct
            // `SentrySDK.logger.X` calls (or future auto-instrumented
            // logs) and adds `stream_id`. `phase` is a TaskLocal that
            // doesn't cross thread boundaries, so this callback can't
            // backfill it — that's why `Log.emit` is the source of truth
            // for `phase`.
            options.beforeSendLog = { log in
                if let streamId = StreamContext.streamId,
                   log.attributes["stream_id"] == nil {
                    log.attributes["stream_id"] = SentryAttribute(string: streamId)
                }
                return log
            }
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

        // First user-journey log of every cold launch. Carries `app_version`
        // so we can correlate "user reports app got stuck on X" with the
        // build they were on. Sentry user.id isn't set yet (not signed in
        // until later) — `auth.signed_in` follows.
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        Log.info("app.launched", attributes: [
            "event": "app.launched",
            "app_version": appVersion ?? "unknown",
            "build_number": buildNumber ?? "unknown",
        ])

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

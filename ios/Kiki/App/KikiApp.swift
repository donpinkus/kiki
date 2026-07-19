import SwiftUI
import SwiftData
import Sentry

@main
struct KikiApp: App {
    private let container: ModelContainer
    @State private var coordinator: AppCoordinator

    init() {
        // TEMP DEBUG (sim bisect for the black replay preview): launch with
        // -KikiDisableSentry to boot without Sentry. Remove when closed.
        let disableSentry = ProcessInfo.processInfo.arguments.contains("-KikiDisableSentry")
        if !disableSentry {
        SentrySDK.start { options in
            options.dsn = "https://ea583825f3a2331b0f211a94db5ab2f2@o4511242315169792.ingest.us.sentry.io/4511243617042432"
            options.tracesSampleRate = 1.0
            options.enableAutoSessionTracking = true
            options.attachStacktrace = true
            options.enableAutoPerformanceTracing = true
            options.debug = false

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
            // `model-servers/shared/sentry_init.py` for the pod-side mirror.
            options.enableLogs = true

            // Belt-and-suspenders attribute injection: the `Log` facade
            // already injects `phase` (a lock-based imperative global —
            // see `Phase.swift`) + `stream_id` (static) at emit time.
            // This callback catches any direct `SentrySDK.logger.X` calls
            // (or future auto-instrumented logs) and adds `stream_id`;
            // the `Log` facade remains the source of truth for `phase`.
            options.beforeSendLog = { log in
                if let streamId = StreamContext.streamId,
                   log.attributes["stream_id"] == nil {
                    log.attributes["stream_id"] = SentryAttribute(string: streamId)
                }
                return log
            }
        }
        }

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

        let container = try! ModelContainer(for: Drawing.self, AnimationClip.self, SavedObject.self)
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

import Foundation
import PostHog

/// Typed wrapper around PostHog for product events.
///
/// **Division of concerns** (mirrors backend `analytics/index.ts`):
/// - Sentry — crashes, errors, APM traces (see `KikiApp.swift` SentrySDK.start)
/// - PostHog — product events (this file) — funnels, cohorts, retention
///
/// **Usage:**
/// ```
/// Analytics.track(.drawingOpened, properties: ["drawing_id": id])
/// Analytics.identify(userId: "...", email: "...")  // on sign-in
/// Analytics.reset()                                // on sign-out
/// ```
///
/// Event names live in the `AnalyticsEvent` enum so there is one place to
/// grep for "what do we track". Don't add `PostHogSDK.shared.capture` calls
/// at arbitrary sites — always go through `Analytics.track`.
///
/// **Privacy:** never pass prompt text, image bytes, or identity tokens as
/// event properties. The signed-in user's email is the only PII we attach,
/// and only as a *person property* via `identify(userId:email:)` — not on
/// individual events. Apple private-relay addresses are expected and fine.
enum AnalyticsEvent: String {
    // Auth
    case userSignedIn = "user.signed_in"
    case userSignedOut = "user.signed_out"

    // Navigation
    case galleryOpened = "gallery.opened"

    // Drawings
    case drawingCreated = "drawing.created"
    case drawingOpened = "drawing.opened"
    case drawingSaved = "drawing.saved"
    case drawingClosed = "drawing.closed"

    // Stream lifecycle
    case streamStarted = "stream.started"
    case streamFirstFrame = "stream.first_frame"
    case streamEnded = "stream.ended"
    case streamReconnect = "stream.reconnect"
    case streamFailed = "stream.failed"
    case streamWarmingStalled = "stream.warming_stalled"

    // Drawing controls
    case styleSelected = "style.selected"
    case promptChanged = "prompt.changed"

    // QuickShape (stroke recognizer)
    case strokeSnapCommitted = "stroke.snap.committed"
    case strokeSnapAbstained = "stroke.snap.abstained"
    case strokeSnapUndoneWithin2s = "stroke.snap.undone_within_2s"
    case strokeSnapPreviewCanceled = "stroke.snap.preview_canceled"
}

enum Analytics {
    /// Capture an event. No-op if PostHog wasn't initialized (e.g. missing API
    /// key in local dev). Property values should be `String`, number, or
    /// `Bool` — PostHog serializes them as JSON.
    static func track(_ event: AnalyticsEvent, properties: [String: Any]? = nil) {
        PostHogSDK.shared.capture(event.rawValue, properties: properties)
    }

    /// Bind future events to a signed-in user. PostHog stitches prior
    /// anonymous activity on this device to `userId` so pre-sign-in funnels
    /// stay intact. When `email` is provided it's stored as a PostHog
    /// *person property*, which surfaces email in the PostHog UI next to
    /// every event from this user without duplicating it per-event.
    static func identify(userId: String, email: String? = nil) {
        if let email {
            PostHogSDK.shared.identify(userId, userProperties: ["email": email])
        } else {
            PostHogSDK.shared.identify(userId)
        }
    }

    /// Forget the current user identity. Call on sign-out so the next user
    /// on this device starts a fresh anonymous session.
    static func reset() {
        PostHogSDK.shared.reset()
    }

    /// Emit an explicit screen event with a meaningful name. We disable
    /// PostHog's auto screen-capture in `KikiApp` because on SwiftUI it
    /// records `UIHostingController<ModifiedContent<AnyView, RootModifier>>`
    /// for every screen. Call this from `AppCoordinator.currentScreen` didSet.
    static func screen(_ name: String, properties: [String: Any]? = nil) {
        PostHogSDK.shared.screen(name, properties: properties)
    }
}

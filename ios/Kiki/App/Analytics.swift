import Foundation

/// Typed wrapper for product events, sent to the Kiki Insights microsite.
///
/// **Division of concerns** (mirrors backend `analytics/index.ts`):
/// - Sentry — crashes, errors, structured logs (see `KikiApp.swift` SentrySDK.start)
/// - Kiki Insights — product events (this file) — per-user timelines, replays
///
/// **Usage:**
/// ```
/// Analytics.track(.drawingOpened, properties: ["drawing_id": id])
/// ```
///
/// Event names live in the `AnalyticsEvent` enum so there is one place to
/// grep for "what do we track". Don't call `InsightsSink.shared.record`
/// at arbitrary sites — always go through `Analytics.track`.
///
/// **Privacy:** never pass prompt text, image bytes, or identity tokens as
/// event properties. Insights derives `user_id` server-side from the JWT,
/// so no PII is attached client-side.
enum AnalyticsEvent: String {
    // Auth
    case userSignedIn = "user.signed_in"
    case userSignedOut = "user.signed_out"

    // App lifecycle (powers the Insights login/session timeline — Apple sign-in
    // fires once, so "opens" are the real per-use signal).
    case appForegrounded = "app.foregrounded"
    case appBackgrounded = "app.backgrounded"

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

    // Subscription / paywall
    case paywallShown = "paywall.shown"
    case subscriptionPurchased = "subscription.purchased"
    case subscriptionRestored = "subscription.restored"

    // Share / export
    case imageShared = "image.shared"
    case videoShared = "video.shared"

    // Speed-paint replay diagnostics — the replay pipeline is device-only
    // (AVFoundation), so its forensics ship as events: store contents on
    // every modal open, composition stats per build, and player-item load
    // failures (the "black preview" class of bug).
    case replayDiag = "replay.diag"
    case replayDiagFile = "replay.diag.file"
    case replayBuilt = "replay.built"
    case replayPreviewFailed = "replay.preview_failed"

    // Errors surfaced to the user. Fired whenever any error banner/message
    // becomes visible (drawing-view red banner, sign-in failure text).
    // Properties: `message` (the verbatim string shown), `surface`
    // ("drawing_banner" | "sign_in"). Kiki Insights highlights these red in
    // the user timeline so UX problems jump out when scanning a session.
    case errorBannerShown = "error.banner_shown"
}

enum Analytics {
    /// Capture an event. Best-effort, off the hot path, no-op until the
    /// Insights sink is configured. Property values should be `String`,
    /// number, or `Bool` — they're serialized as JSON.
    static func track(_ event: AnalyticsEvent, properties: [String: Any]? = nil) {
        Task { await InsightsSink.shared.record(name: event.rawValue, properties: properties) }
    }
}

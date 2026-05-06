import Foundation
import os
import OSLog
import Sentry

// MARK: - Phase

/// Cross-stack `phase` log attribute — iOS side. Same vocabulary as
/// `flux-klein-server/sentry_init.py` (Python ContextVar) and
/// `backend/src/modules/observability/phase.ts` (Node AsyncLocalStorage).
///
/// Every Sentry log emitted via `Log.X(...)` (the `Log` facade below)
/// carries `phase: <value>` from the active phase. The phase is set
/// imperatively via `Phase.set(.drawing)` at the moments we know the
/// user-perceived state has changed (stream.startup_begin → preparing,
/// first frame → drawing, video preview begins → animating, etc.).
///
/// Imperative state rather than `@TaskLocal` because iOS's stream
/// lifecycle is delegate-driven (URLSession WS callbacks fire on
/// URLSession's queue, NOT a user Task — TaskLocal propagation breaks
/// across that boundary). Single-active-stream lets us get away with
/// a static. Thread-safe via `OSAllocatedUnfairLock`.
///
/// Logs emitted while no phase is set carry no `phase` attribute,
/// filterable as `!has:phase` in Sentry's Logs UI (catches lifecycle
/// gaps — log lines we forgot to wrap in a phase transition).
enum Phase: String {
    case preparing
    case drawing
    case animating
    case reconnecting
    case sessionEnding = "session_ending"

    private static let lock = OSAllocatedUnfairLock<Phase?>(initialState: nil)

    static var current: Phase? {
        lock.withLock { $0 }
    }

    static func set(_ phase: Phase?) {
        lock.withLock { $0 = phase }
    }
}

// MARK: - StreamContext

/// iOS-issued per-startStream UUID prefix (set by `AppCoordinator.startStream`).
/// Read at log-emit time by `Log` so every log line emitted while a stream is
/// active carries `stream_id`. Cross-stack, this joins iOS logs to backend
/// `streamId` and (initially) pod `stream_id` BOOT_ENV value.
///
/// Thread-safe global: stream lifecycle is single-active (one stream attempt
/// at a time, set on `startStream`, cleared on tear-down). Sentry's
/// `beforeSendLog` callback runs off the main thread and would deadlock on
/// `@MainActor`, so we use `OSAllocatedUnfairLock`. iPadOS 17+ targets are
/// guaranteed `OSAllocatedUnfairLock`.
enum StreamContext {
    private static let lock = OSAllocatedUnfairLock<String?>(initialState: nil)

    static var streamId: String? {
        lock.withLock { $0 }
    }

    static func set(_ id: String?) {
        lock.withLock { $0 = id }
    }
}

// MARK: - Log facade

/// Thin logging facade fanning out to:
///   - `os.log` (Console.app, Xcode console — for local debugging)
///   - `SentrySDK.logger.X` (Sentry Logs product — for cross-stack debugging)
///
/// Auto-injects `phase` (from `Phase.current` TaskLocal) and `stream_id`
/// (from `StreamContext`) so every iOS log line carries the cross-stack
/// correlation attributes. Existing `streamLog.info(...)` call sites
/// migrate via search-and-replace to `Log.streamInfo(...)`.
///
/// **Convention:** structured fields go into the `attributes` dict with
/// snake_case keys (`drawing_id`, `error_code`, …), matching the
/// cross-stack convention. The `event` attribute uses dot notation
/// (`stream.first_frame`, `auth.signed_in`).
enum Log {
    /// Mirrors AppCoordinator's existing `streamLog` os.log Logger so Console.app
    /// debugging keeps working. Subsystem matches the bundle ID convention.
    private static let osLog = Logger(subsystem: "com.donpinkus.Kiki", category: "stream")

    static func info(_ message: String, attributes: [String: Any] = [:]) {
        emit(level: .info, message: message, attributes: attributes)
    }

    static func warn(_ message: String, attributes: [String: Any] = [:]) {
        emit(level: .warn, message: message, attributes: attributes)
    }

    static func error(_ message: String, attributes: [String: Any] = [:]) {
        emit(level: .error, message: message, attributes: attributes)
    }

    private enum Level {
        case info, warn, error
    }

    private static func emit(level: Level, message: String, attributes: [String: Any]) {
        var attrs = attributes
        // Pull TaskLocal/Static at emit time — we can't rely on
        // `beforeSendLog` for `phase` because that callback runs off-thread
        // and TaskLocal values don't cross thread boundaries.
        if let phase = Phase.current {
            attrs["phase"] = phase.rawValue
        }
        if let streamId = StreamContext.streamId {
            attrs["stream_id"] = streamId
        }

        // os.log fan-out — keeps Console.app + Xcode console working as before.
        switch level {
        case .info:
            osLog.info("\(message, privacy: .public)")
        case .warn:
            osLog.warning("\(message, privacy: .public)")
        case .error:
            osLog.error("\(message, privacy: .public)")
        }

        // Sentry Logs fan-out. No-op when `enableLogs = false` (e.g. local dev
        // without DSN) — Sentry SDK gates internally.
        switch level {
        case .info:
            SentrySDK.logger.info(message, attributes: attrs)
        case .warn:
            SentrySDK.logger.warn(message, attributes: attrs)
        case .error:
            SentrySDK.logger.error(message, attributes: attrs)
        }
    }
}

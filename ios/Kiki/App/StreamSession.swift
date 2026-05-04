import UIKit
import Sentry
import CanvasModule
import NetworkModule

/// Orchestrates real-time streaming generation: captures canvas frames,
/// sends them over WebSocket, and delivers generated images back.
///
/// Config changes (prompt, steps, seed) are applied automatically —
/// the capture loop sends a config update before the next frame whenever it
/// detects a change.
@MainActor
final class StreamSession {

    // MARK: - Types

    /// UI-facing stream state. Server status messages drive transitions —
    /// a bare WS open is just a breadcrumb. The `.warming` case carries
    /// `startedAt` (the original pod-warm-cycle origin, server-supplied
    /// via `warmingStartedAt`) for a continuous progress bar across
    /// multiple status updates and reconnect attempts. `nil` means we
    /// haven't received the timestamp yet — the UI must NOT render a
    /// 0%-filled bar in that window or it looks like the warm-up is
    /// restarting on each reconnect.
    enum StreamReadiness: Equatable {
        case disconnected
        case warming(message: String, startedAt: Date?)
        case ready
        case failed(message: String)
        /// Backend reaper terminated the pod after 30 min of no frame activity.
        /// User can resume by tapping the right-pane overlay or starting to draw.
        /// No message carried — the UI uses a hardcoded title.
        case idleTimeout
    }

    // MARK: - Properties

    private let url: URL
    private let request: URLRequest
    private var client: StreamWebSocketClient
    private let canvasViewModel: CanvasViewModel
    private var captureTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    /// Subscribes to `client.connectionEvents`; turns an explicit
    /// `.disconnected` event into a `attemptReconnect()` call. This is the
    /// load-bearing reconnect trigger — `receiveTask`'s post-loop branch is
    /// cleanup-only.
    private var connectionEventTask: Task<Void, Never>?
    /// Owns one in-flight reconnect cycle. Set when `attemptReconnect()`
    /// schedules `runReconnect`, cleared when that task finishes. The
    /// non-nil check inside `attemptReconnect()` makes scheduling idempotent.
    private var reconnectTask: Task<Void, Never>?

    /// How often to capture and send frames (default ~2 FPS for FLUX.2-klein).
    var captureInterval: TimeInterval = 0.5

    /// Current desired config. Set by AppCoordinator whenever prompt/settings
    /// change. The capture loop detects changes and sends them automatically.
    var config: StreamConfig

    /// Last config actually sent to the server (used for change detection).
    private var lastSentConfig: StreamConfig?

    /// JPEG bytes of the last successfully sent frame. Used to skip sending
    /// identical frames when the canvas hasn't changed. Cleared on config
    /// change so the unchanged sketch re-generates under the new prompt.
    private var lastSentJpegData: Data?

    /// Current readiness, observed by AppCoordinator. The warm-up start time
    /// lives inside `.warming(startedAt:)` itself — `warm()` carries it
    /// forward across consecutive warming transitions.
    private(set) var readiness: StreamReadiness = .disconnected

    // MARK: - Preview mode (style picker)

    /// Pauses the capture loop so the normal stream doesn't push frames
    /// while the picker is driving the pod for previews.
    private var isCapturePaused = false

    /// Continuations for in-flight preview requests, keyed by the
    /// `requestId` that was sent in the config. Responses are paired by
    /// requestId (via the pod's `frame_meta` preamble) rather than by
    /// arrival order, so stale or out-of-order frames can't land on the
    /// wrong tile.
    private var pendingPreviewContinuations: [String: CheckedContinuation<UIImage, Error>] = [:]

    enum PreviewError: Error { case invalidImage, cancelled }

    /// Called when a new generated image frame is received.
    var onImageReceived: ((UIImage) -> Void)?

    /// Called for every event from the video pod (idle-state animation):
    /// streamed frames, the final MP4, or a cancellation.
    var onVideoEvent: ((StreamWebSocketClient.VideoEvent) -> Void)?

    /// Called when stream readiness changes.
    var onReadinessChanged: ((StreamReadiness) -> Void)?

    // MARK: - Reconnection

    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 5
    private var isStopped = false

    // MARK: - Stats

    private var framesSent = 0
    private var framesReceived = 0

    /// Monotonic counter incremented every time `connectAndRun()` runs (initial
    /// connect + each reconnect). Tagged into breadcrumbs so back-to-back
    /// connect attempts within one StreamSession are distinguishable in
    /// post-hoc trace reading.
    private var connectionAttemptId = 0
    /// Forensic-capture watchdog. When readiness enters `.warming(...)`, we
    /// schedule a Task that fires `SentrySDK.capture` + `Analytics.track`
    /// after 180s — forces upload of the breadcrumb buffer for stuck-on-
    /// Connecting cases that would otherwise sit silently on the device until
    /// the user force-quits. Cancelled and reset on every readiness transition
    /// (substate progress restarts the timer; final states cancel it).
    /// 180s threshold: forensic, not alerting — user-reported symptom is
    /// "stuck for minutes". Avoids cold-start `warming_model` false-positives.
    private var warmingWatchdogTask: Task<Void, Never>?
    /// Wall-clock of the most recent successful frame received, used to log
    /// "elapsed since last frame" on unexpected disconnect.
    private var lastFrameReceivedAt: Date?
    /// Wall-clock of when the current connect attempt started, for elapsed
    /// timing on the receive-loop end and reconnect breadcrumbs.
    private var currentConnectStartedAt: Date?

    private static let captureSize = CGSize(width: 768, height: 768)

    // MARK: - Lifecycle

    init(url: URL, canvasViewModel: CanvasViewModel, config: StreamConfig) {
        self.url = url
        self.request = URLRequest(url: url)
        self.client = StreamWebSocketClient(url: url)
        self.canvasViewModel = canvasViewModel
        self.config = config
    }

    /// Init with a URLRequest — use this to pass auth headers (Authorization: Bearer).
    init(request: URLRequest, canvasViewModel: CanvasViewModel, config: StreamConfig) {
        self.url = request.url ?? URL(string: "about:blank")!
        self.request = request
        self.client = StreamWebSocketClient(request: request)
        self.canvasViewModel = canvasViewModel
        self.config = config
    }

    // MARK: - Control

    func start() async {
        Self.breadcrumb(category: "stream.lifecycle", message: "Starting", data: [
            "url": url.absoluteString,
            "prompt": config.prompt ?? "(none)",
        ])
        self.isStopped = false
        self.reconnectAttempts = 0
        self.framesSent = 0
        self.framesReceived = 0
        self.lastSentJpegData = nil

        do {
            try await connectAndRunOnce()
        } catch {
            // Tear down the partially-set-up client before scheduling
            // reconnect. See `connectAndRunOnce`'s failure-cleanup contract.
            await client.disconnect()
            if !isStopped {
                attemptReconnect()
            } else {
                Self.breadcrumb(category: "stream.lifecycle", message: "Not reconnecting — session stopped")
            }
        }
    }

    // MARK: - Preview mode

    /// Pause the normal capture loop so the preview controller has the
    /// pod to itself. No drain needed — stale in-flight responses from
    /// before the pause don't carry a requestId and are routed to
    /// `onImageReceived` normally.
    func enterPreviewMode() {
        isCapturePaused = true
        Self.breadcrumb(category: "stream.preview", message: "Entered preview mode")
    }

    /// Resume the normal capture loop. Clears `lastSentConfig` and
    /// `lastSentJpegData` so the next tick re-pushes the live config
    /// (e.g. the newly-selected style) and re-sends the current sketch.
    /// Any preview continuations still waiting are failed so callers
    /// unwind cleanly.
    func exitPreviewMode() {
        let stranded = pendingPreviewContinuations
        pendingPreviewContinuations = [:]
        for (_, cont) in stranded {
            cont.resume(throwing: PreviewError.cancelled)
        }
        isCapturePaused = false
        lastSentConfig = nil
        lastSentJpegData = nil
        Self.breadcrumb(category: "stream.preview", message: "Exited preview mode", data: [
            "cancelledContinuations": stranded.count,
        ])
    }

    /// Send one preview frame and await its generated image. The
    /// `requestId` (passed inside `config`) is echoed back by the pod so
    /// responses pair deterministically regardless of arrival order.
    ///
    /// Order matters: register the continuation BEFORE sending. The previous
    /// "send then register" version raced — if the pod responded between
    /// `sendFrame` returning and the continuation landing in the map, the
    /// receive loop would find no match and route the frame to
    /// `onImageReceived` (the live result pane) as a stale frame. The
    /// preview tile would then shimmer until the 20 s timeout.
    func sendPreview(jpeg: Data, config: StreamConfig) async throws -> UIImage {
        guard let requestId = config.requestId else {
            preconditionFailure("sendPreview requires config.requestId to be set")
        }

        return try await withCheckedThrowingContinuation { cont in
            pendingPreviewContinuations[requestId] = cont
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.client.sendConfig(config)
                    try await self.client.sendFrame(jpeg)
                } catch {
                    // Send failed — fail the continuation if it's still pending.
                    // (Receive loop may have already resolved it; that's fine.)
                    if let stranded = self.pendingPreviewContinuations.removeValue(forKey: requestId) {
                        stranded.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Capture a JPEG at the same size/quality the normal capture loop uses.
    /// Used by the preview controller so preview and live frames match.
    func captureFrameJPEG() -> Data? {
        guard let snapshot = canvasViewModel.captureSnapshot() else { return nil }
        guard let resized = resizeImage(snapshot.image, to: Self.captureSize) else { return nil }
        return resized.jpegData(compressionQuality: 0.7)
    }

    func stop(finalReadiness: StreamReadiness = .disconnected) {
        Self.breadcrumb(category: "stream.lifecycle", message: "Stopping", data: [
            "framesSent": framesSent,
            "framesReceived": framesReceived,
        ])
        isStopped = true
        cancelStreamingTasks()
        reconnectTask?.cancel()
        reconnectTask = nil
        Task { await client.disconnect() }
        setReadiness(finalReadiness)
    }

    // MARK: - Connection

    /// Connect the WS, send the initial config, and start the child consumer
    /// tasks (capture/receive/video/status/connection-event). Returns as soon
    /// as setup succeeds — does NOT block for the session lifetime. Throws on
    /// any failure during connect/sendConfig.
    ///
    /// Failure-cleanup contract: if this throws, the caller MUST call
    /// `await client.disconnect()` before discarding the client. The throw
    /// can happen mid-handshake (no internal state to clean) or after
    /// `connect()` succeeded but before `startReceiveLoop()` ran (the
    /// client's internal receive loop and `URLSessionWebSocketTask` are
    /// alive and will leak otherwise).
    private func connectAndRunOnce() async throws {
        connectionAttemptId += 1
        let attemptId = connectionAttemptId
        currentConnectStartedAt = Date()
        warm(message: "Connecting…")
        Self.breadcrumb(category: "stream.connection", message: "connectAndRun begin", data: [
            "attemptId": attemptId,
            "reconnectAttempt": reconnectAttempts,
            "url": url.absoluteString,
        ])
        let tx = SentrySDK.startTransaction(name: "stream.connection", operation: "stream.connection")
        tx.setData(value: attemptId, key: "attemptId")

        let connectStart = Date()
        do {
            try await client.connect()
            let connectMs = Int(Date().timeIntervalSince(connectStart) * 1000)
            // NOTE: do NOT reset reconnectAttempts here. A bare URLSession WS
            // handshake is not a stable-connection signal — sendConfig can
            // still fail post-handshake, and the orchestrator may take ~96 s
            // to declare the session usable. Resetting here previously caused
            // an infinite retry loop because runReconnect's catch would loop
            // back, increment attempts, hit a fresh handshake, reset to 0,
            // and the maxReconnectAttempts cap would never trip. Reset is now
            // gated on the backend's `.ready` state (see handleState).
            // WS open is just a breadcrumb — don't change readiness here.
            // The server's status=ready (or status=provisioning, or type=error)
            // is what actually drives the next transition, via statusTask.
            Self.breadcrumb(category: "stream.connection", message: "Connected to server", data: [
                "attemptId": attemptId,
                "connectMs": connectMs,
            ])

            try await client.sendConfig(config)
            lastSentConfig = config
            Self.breadcrumb(category: "stream.config", message: "Initial config sent", data: [
                "attemptId": attemptId,
            ])
            tx.finish()

            startReceiveLoop()
            startCaptureLoop()
        } catch {
            let elapsedMs = Int(Date().timeIntervalSince(connectStart) * 1000)
            Self.breadcrumb(category: "error.connection", message: "Connection failed", data: [
                "attemptId": attemptId,
                "elapsedMs": elapsedMs,
                "error": error.localizedDescription,
                "stopped": isStopped,
            ], level: .error)
            tx.finish(status: .internalError)
            throw error
        }
    }

    /// Schedule a reconnect attempt. Idempotent: if a reconnect is already
    /// running, this is a no-op; if readiness is `.failed` (attempts
    /// exhausted), also a no-op so stale events don't reschedule. Synchronous
    /// fire-and-forget — the reconnect runs on `reconnectTask`, NOT on the
    /// caller's task. That's load-bearing: previously this was `async` and
    /// invoked from inside `receiveTask`, so the cancel-streaming-tasks step
    /// inside the reconnect cancelled its own caller, the post-sleep
    /// `Task.isCancelled` guard returned, and the UI stuck on "Connecting…".
    /// Marked `internal` so the test target can drive it directly via
    /// `@testable import` (Layer 1 idempotency test).
    func attemptReconnect() {
        guard !isStopped else {
            Self.breadcrumb(category: "stream.retry", message: "Reconnect skipped — session stopped")
            return
        }
        if case .failed = readiness {
            // Attempts already exhausted; don't reschedule from stale events.
            return
        }
        if reconnectTask != nil {
            // Coalesce: another disconnect signal landed while a reconnect is
            // already in flight. The active task will keep retrying.
            return
        }
        reconnectTask = Task { [weak self] in
            await self?.runReconnect()
            self?.reconnectTask = nil
        }
    }

    /// Reconnect retry loop. Owns: backoff schedule, max-attempts cap, client
    /// replacement. Each iteration cancels the streaming tasks, sleeps with
    /// exponential backoff, builds a fresh client, runs `connectAndRunOnce`.
    /// On success: returns. On failure: tears down the partially-set-up
    /// client, increments backoff, retries.
    private func runReconnect() async {
        while !isStopped, !Task.isCancelled {
            reconnectAttempts += 1
            let delay = pow(2.0, Double(reconnectAttempts - 1))  // 1, 2, 4, 8, 16s
            Self.breadcrumb(category: "stream.retry", message: "Reconnect attempt", data: [
                "attempt": reconnectAttempts,
                "max": Self.maxReconnectAttempts,
                "backoffSec": delay,
            ])
            Analytics.track(.streamReconnect, properties: [
                "attempt": reconnectAttempts,
                "backoff_sec": delay,
            ])

            if reconnectAttempts > Self.maxReconnectAttempts {
                SentrySDK.capture(message: "stream.reconnect.exhausted") { scope in
                    scope.setLevel(.error)
                    scope.setTag(value: String(Self.maxReconnectAttempts), key: "maxAttempts")
                }
                setReadiness(.failed(message: "Unable to connect. Please restart the app."))
                return
            }

            let tx = SentrySDK.startTransaction(name: "stream.reconnect", operation: "stream.reconnect")
            tx.setData(value: reconnectAttempts, key: "attempt")
            tx.setData(value: delay, key: "backoffSec")

            cancelStreamingTasks()
            warm(message: "Connecting…")

            try? await Task.sleep(for: .seconds(delay))
            guard !isStopped, !Task.isCancelled else {
                Self.breadcrumb(category: "stream.retry", message: "Reconnect cancelled during backoff", data: [
                    "stopped": isStopped,
                    "taskCancelled": Task.isCancelled,
                ])
                tx.finish(status: .cancelled)
                return
            }

            Self.breadcrumb(category: "stream.retry", message: "Reconnecting", data: ["url": url.absoluteString])
            self.client = StreamWebSocketClient(request: request)
            tx.finish()

            do {
                try await connectAndRunOnce()
                return  // success — drop out of loop
            } catch {
                // Tear down the partially-set-up client so its receive loop
                // and WS task don't linger. If `connect()` succeeded but
                // `sendConfig` failed, the client is `.connected` with an
                // active receiveLoopTask — disconnect() shuts both down.
                await client.disconnect()
                continue  // back off again
            }
        }
    }

    // MARK: - Capture Loop

    private func startCaptureLoop() {
        captureTask = Task.detached { [weak self] in
            Self.breadcrumb(category: "stream.lifecycle", message: "Capture loop started")
            var count = 0
            // Tracks whether the previous tick was suppressed by the dirty
            // check, so we breadcrumb only the idle/resume transitions
            // (zero spam during steady-state drawing or steady-state idle).
            // The transition to idle is the iPad-side counterpart of the
            // image pod's `queue drained` log — together they confirm the
            // trigger boundary.
            var lastTickSkipped = false
            while !Task.isCancelled {
                guard let self else { break }

                let stopped = await self.isStopped
                if stopped { break }

                // Skip while the style picker is driving the pod for previews.
                let paused = await self.isCapturePaused
                if paused {
                    try? await Task.sleep(for: .milliseconds(150))
                    continue
                }

                // Send config update if it changed since last send
                await self.sendConfigIfChanged()

                let jpeg: Data? = await MainActor.run {
                    guard let snapshot = self.canvasViewModel.captureSnapshot() else { return nil }
                    guard let resized = self.resizeImage(snapshot.image, to: Self.captureSize) else { return nil }
                    guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }
                    // Skip if the rendered output hasn't changed since last send.
                    // Catches all visual changes: mid-stroke, eraser, lasso, undo.
                    if data == self.lastSentJpegData { return nil }
                    return data
                }

                if let jpeg {
                    do {
                        try await self.client.sendFrame(jpeg)
                        await MainActor.run { self.lastSentJpegData = jpeg }
                        count += 1
                        await self.setFramesSent(count)
                        if lastTickSkipped {
                            Self.breadcrumb(category: "stream.capture", message: "resumed (canvas changed)")
                            lastTickSkipped = false
                        }
                    } catch {
                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "sendFrame", key: "op")
                            scope.setExtra(value: count, key: "frameCount")
                        }
                    }
                } else if !lastTickSkipped {
                    Self.breadcrumb(category: "stream.capture", message: "idle (canvas unchanged)")
                    lastTickSkipped = true
                }

                let interval = await self.captureInterval
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            Self.breadcrumb(category: "stream.lifecycle", message: "Capture loop ended", data: ["framesSent": count])
        }
    }

    /// Compare current config to what was last sent; if different, send an update.
    /// Also clears `lastSentStrokeCount` so the unchanged sketch gets re-sent
    /// under the new prompt (the dirty check would otherwise suppress it).
    private func sendConfigIfChanged() async {
        let current = config
        guard current != lastSentConfig else { return }
        do {
            try await client.sendConfig(current)
            lastSentConfig = current
            lastSentJpegData = nil
            Self.breadcrumb(category: "stream.config", message: "Config auto-sent", data: [
                "prompt": current.prompt ?? "(none)",
            ])
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "sendConfig", key: "op")
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        let attemptId = connectionAttemptId
        receiveTask = Task { [weak self] in
            Self.breadcrumb(category: "stream.lifecycle", message: "Receive loop started", data: [
                "attemptId": attemptId,
            ])
            guard let self else { return }
            let frames = await client.receivedFrames
            var count = 0
            for await frame in frames {
                guard !Task.isCancelled else { break }
                guard let image = UIImage(data: frame.data) else { continue }
                count += 1
                self.setFramesReceived(count)
                self.lastFrameReceivedAt = Date()
                // Route by requestId: preview responses pair with the
                // continuation that sent them. Everything else (live
                // stream, stale pre-pause responses) goes to the normal
                // result pane.
                if let requestId = frame.requestId,
                   let cont = self.pendingPreviewContinuations.removeValue(forKey: requestId) {
                    cont.resume(returning: image)
                } else {
                    self.onImageReceived?(image)
                }
            }
            let stopped = self.isStopped
            let now = Date()
            let lastFrameAgeMs = self.lastFrameReceivedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
            let connectAgeMs = self.currentConnectStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
            if !Task.isCancelled, !stopped {
                // Reconnect is driven by `connectionEventTask` (subscribes to
                // `client.connectionEvents`), not by this branch. Receive-loop
                // exit and the disconnect event always pair today, but if a
                // future client refactor finishes the frames stream without a
                // matching event, this Sentry capture will surface it.
                SentrySDK.capture(message: "stream.receive.unexpected_end") { scope in
                    scope.setLevel(.warning)
                    scope.setExtra(value: count, key: "frames")
                    scope.setExtra(value: attemptId, key: "attemptId")
                    scope.setExtra(value: lastFrameAgeMs, key: "lastFrameAgeMs")
                    scope.setExtra(value: connectAgeMs, key: "connectAgeMs")
                }
                Self.breadcrumb(category: "stream.lifecycle", message: "Receive loop unexpected end", data: [
                    "attemptId": attemptId,
                    "frames": count,
                    "lastFrameAgeMs": lastFrameAgeMs,
                    "connectAgeMs": connectAgeMs,
                ], level: .warning)
            } else {
                Self.breadcrumb(category: "stream.lifecycle", message: "Receive loop ended", data: [
                    "attemptId": attemptId,
                    "cancelled": Task.isCancelled,
                    "stopped": stopped,
                    "frames": count,
                    "lastFrameAgeMs": lastFrameAgeMs,
                    "connectAgeMs": connectAgeMs,
                ])
            }
        }

        videoTask = Task { [weak self] in
            guard let self else { return }
            let events = await client.videoEvents
            for await event in events {
                guard !Task.isCancelled else { break }
                Self.breadcrumb(category: "stream.video", message: "video event", data: [
                    "case": String(describing: event),
                ])
                await MainActor.run {
                    self.onVideoEvent?(event)
                }
            }
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            let statuses = await client.serverStatuses
            for await status in statuses {
                guard !Task.isCancelled else { break }
                Self.breadcrumb(category: "stream.status", message: "Server status", data: [
                    "type": status.type,
                    "state": status.state ?? "",
                    "message": status.message ?? "",
                ])
                await MainActor.run {
                    if status.type == "state", let stateRaw = status.state,
                       let state = ProvisionState(rawValue: stateRaw) {
                        self.handleState(
                            state,
                            replacementCount: status.replacementCount ?? 0,
                            failureCategory: status.failureCategory.flatMap { FailureCategory(rawValue: $0) },
                            warmingStartedAt: status.warmingStartedAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000) },
                            message: status.message
                        )
                    } else if status.type == "error" {
                        // Out-of-band error (auth, entitlement, rate-limit,
                        // relay failure). Distinct from state=failed, which
                        // comes through the state flow.
                        SentrySDK.capture(message: "stream.server_error") { scope in
                            scope.setLevel(.error)
                            scope.setExtra(value: status.message ?? "(no message)", key: "serverMessage")
                        }
                        self.reconnectAttempts = 0
                        self.setReadiness(.failed(message: status.message ?? "Server error"))
                    }
                }
            }
        }

        connectionEventTask = Task { [weak self] in
            guard let self else { return }
            let events = await client.connectionEvents
            for await event in events {
                guard !Task.isCancelled else { break }
                switch event {
                case .disconnected(let info):
                    Self.breadcrumb(category: "stream.connection", message: "Disconnect event", data: [
                        "message": info.message ?? "(none)",
                    ], level: .warning)
                    self.attemptReconnect()
                }
            }
        }
    }

    /// Map a server state event to UI readiness. Non-terminal states use
    /// state-code mappings (the codes ARE the meaning — "Connecting...",
    /// "Finding GPU..." are not invented). For `.failed`, use the real
    /// error message bubbled up from the source — no client-side
    /// category-to-string translation that fabricates a cause.
    private func handleState(
        _ state: ProvisionState,
        replacementCount: Int,
        failureCategory: FailureCategory?,
        warmingStartedAt: Date?,
        message: String?
    ) {
        switch state {
        case .queued, .findingGpu, .creatingPod, .fetchingImage, .warmingModel, .connecting:
            self.warm(message: displayText(for: state, replacementCount: replacementCount), serverStartedAt: warmingStartedAt)
        case .ready:
            self.setReadiness(.ready)
            // Reset retry budget here (not on bare WS handshake): `.ready`
            // means the orchestrator has provisioned, warmed, and declared
            // the session usable. That's the canonical stable-connection
            // signal; failures before this point should still count against
            // maxReconnectAttempts so the cap actually trips.
            self.reconnectAttempts = 0
            // Re-send config now that the server is ready to accept it.
            self.lastSentConfig = nil
        case .failed:
            self.reconnectAttempts = 0
            self.setReadiness(.failed(message: message ?? "Something went wrong"))
        case .terminated:
            // Idle reaper sends terminated + idle_timeout. Stop the session
            // cleanly so attemptReconnect doesn't fight the deliberate close;
            // user resumes via coordinator.resumeStream() (tap-to-resume on
            // the overlay or starting a stroke).
            //
            // Other terminated paths (manual abort, replaceSession cleanup of
            // old pod) carry no failureCategory and fall through to
            // .disconnected as before.
            if failureCategory == .idleTimeout {
                self.stop(finalReadiness: .idleTimeout)
            } else {
                self.setReadiness(.disconnected)
            }
        }
    }

    // MARK: - Private

    private func setFramesSent(_ count: Int) {
        framesSent = count
    }

    private func setFramesReceived(_ count: Int) {
        framesReceived = count
    }

    /// Cancel the I/O child tasks (capture/receive/video/status/connection-event).
    /// Does NOT touch `reconnectTask` — safe to call from inside a running
    /// reconnect. Calling this from `runReconnect` previously cancelled the
    /// reconnect's own task (when invoked via `await self.attemptReconnect()`
    /// from inside `receiveTask`); splitting reconnectTask out fixes that
    /// self-cancellation. `stop()` cancels reconnectTask separately.
    private func cancelStreamingTasks() {
        captureTask?.cancel()
        captureTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        statusTask?.cancel()
        statusTask = nil
        videoTask?.cancel()
        videoTask = nil
        connectionEventTask?.cancel()
        connectionEventTask = nil
    }

    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Transition to `.warming`. The server's `warmingStartedAt` (when
    /// present) is authoritative — it's the original pod-warm-cycle start,
    /// stable across reconnects, so the progress bar resumes correctly even
    /// after a fresh session is created (e.g. on gallery↔drawing navigation).
    /// Carries forward an existing readiness's startedAt when the server
    /// hasn't supplied one yet (e.g. the pre-WS-open "Connecting…" call).
    /// Never falls back to `Date()` — a fresh fallback timestamp would
    /// render the progress bar at 0%, which looks like a restart.
    private func warm(message: String, serverStartedAt: Date? = nil) {
        let startedAt: Date?
        if let serverStartedAt {
            startedAt = serverStartedAt
        } else if case .warming(_, let existing) = readiness {
            startedAt = existing
        } else {
            startedAt = nil
        }
        applyReadiness(.warming(message: message, startedAt: startedAt))
    }

    /// Transition to a terminal/stable state (`.ready`, `.disconnected`,
    /// `.failed`). Anything that calls this is implicitly ending the
    /// current warm-up cycle.
    private func setReadiness(_ readiness: StreamReadiness) {
        applyReadiness(readiness)
    }

    /// Shared transition: log breadcrumb, dedup, fire callback. Direct
    /// callers should use `warm()` or `setReadiness()` — this is private
    /// implementation detail.
    private func applyReadiness(_ new: StreamReadiness) {
        Self.breadcrumb(category: "stream.state", message: "Readiness", data: [
            "state": String(describing: new),
        ])
        guard new != readiness else { return }
        readiness = new
        onReadinessChanged?(new)

        // Manage the warming watchdog. Every transition cancels any pending
        // watchdog; entering `.warming` schedules a fresh one. Substate progress
        // (queued → finding_gpu → ...) resets the timer naturally. Terminal
        // states (.ready/.failed/.disconnected/.idleTimeout) just cancel.
        // Cleanup on `stop()` happens via `setReadiness(.disconnected)` →
        // applyReadiness, so no need to touch `cancelStreamingTasks`.
        warmingWatchdogTask?.cancel()
        warmingWatchdogTask = nil
        if case .warming(let message, _) = new {
            let snapshot = (
                message: message,
                framesSent: framesSent,
                framesReceived: framesReceived,
                reconnectAttempts: reconnectAttempts
            )
            warmingWatchdogTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(180))
                guard !Task.isCancelled, self != nil else { return }
                SentrySDK.capture(message: "stream.warming_stalled") { scope in
                    scope.setLevel(.warning)
                    scope.setExtra(value: snapshot.message, key: "substateMessage")
                    scope.setExtra(value: snapshot.framesSent, key: "framesSent")
                    scope.setExtra(value: snapshot.framesReceived, key: "framesReceived")
                    scope.setExtra(value: snapshot.reconnectAttempts, key: "reconnectAttempts")
                }
                Analytics.track(.streamWarmingStalled, properties: [
                    "substate_message": snapshot.message,
                    "frames_sent": snapshot.framesSent,
                    "frames_received": snapshot.framesReceived,
                    "reconnect_attempts": snapshot.reconnectAttempts,
                ])
            }
        }
    }

    // MARK: - Breadcrumb helper

    nonisolated private static func breadcrumb(
        category: String,
        message: String,
        data: [String: Any]? = nil,
        level: SentryLevel = .info
    ) {
        let crumb = Breadcrumb()
        crumb.category = category
        crumb.message = message
        crumb.level = level
        if let data { crumb.data = data }
        SentrySDK.addBreadcrumb(crumb)
    }
}

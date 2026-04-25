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
    /// `startedAt` for a continuous progress bar across multiple status
    /// updates and reconnect attempts.
    enum StreamReadiness: Equatable {
        case disconnected
        case warming(message: String, startedAt: Date)
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

    /// Called when stream readiness changes.
    var onReadinessChanged: ((StreamReadiness) -> Void)?

    // MARK: - Reconnection

    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 5
    private var isStopped = false

    // MARK: - Stats

    private var framesSent = 0
    private var framesReceived = 0

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

        await connectAndRun()
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
        cancelAllTasks()
        Task { await client.disconnect() }
        setReadiness(finalReadiness)
    }

    // MARK: - Connection

    private func connectAndRun() async {
        warm(message: "Connecting…")
        let tx = SentrySDK.startTransaction(name: "stream.connection", operation: "stream.connection")

        do {
            try await client.connect()
            reconnectAttempts = 0
            // WS open is just a breadcrumb — don't change readiness here.
            // The server's status=ready (or status=provisioning, or type=error)
            // is what actually drives the next transition, via statusTask.
            Self.breadcrumb(category: "stream.connection", message: "Connected to server")

            try await client.sendConfig(config)
            lastSentConfig = config
            Self.breadcrumb(category: "stream.config", message: "Initial config sent")
            tx.finish()

            startReceiveLoop()
            startCaptureLoop()
        } catch {
            Self.breadcrumb(category: "error.connection", message: "Connection failed", data: [
                "error": error.localizedDescription,
                "stopped": isStopped,
            ], level: .error)
            tx.finish(status: .internalError)
            if !isStopped {
                await attemptReconnect()
            } else {
                Self.breadcrumb(category: "stream.lifecycle", message: "Not reconnecting — session stopped")
            }
        }
    }

    private func attemptReconnect() async {
        guard !isStopped else {
            Self.breadcrumb(category: "stream.retry", message: "Reconnect skipped — session stopped")
            return
        }
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

        cancelAllTasks()
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
        await connectAndRun()
    }

    // MARK: - Capture Loop

    private func startCaptureLoop() {
        captureTask = Task.detached { [weak self] in
            Self.breadcrumb(category: "stream.lifecycle", message: "Capture loop started")
            var count = 0
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
                    } catch {
                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "sendFrame", key: "op")
                            scope.setExtra(value: count, key: "frameCount")
                        }
                    }
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
        receiveTask = Task { [weak self] in
            Self.breadcrumb(category: "stream.lifecycle", message: "Receive loop started")
            guard let self else { return }
            let frames = await client.receivedFrames
            var count = 0
            for await frame in frames {
                guard !Task.isCancelled else { break }
                guard let image = UIImage(data: frame.data) else { continue }
                count += 1
                self.setFramesReceived(count)
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
            if !Task.isCancelled, !stopped {
                SentrySDK.capture(message: "stream.receive.unexpected_end") { scope in
                    scope.setLevel(.warning)
                    scope.setExtra(value: count, key: "frames")
                }
                await self.attemptReconnect()
            } else {
                Self.breadcrumb(category: "stream.lifecycle", message: "Receive loop ended", data: [
                    "cancelled": Task.isCancelled,
                    "stopped": stopped,
                    "frames": count,
                ])
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
                            failureCategory: status.failureCategory.flatMap { FailureCategory(rawValue: $0) }
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
    }

    /// Map a server state event to UI readiness. Any non-terminal state
    /// produces `.warming` with display text derived locally; `ready` and
    /// `failed` are terminal transitions.
    private func handleState(
        _ state: ProvisionState,
        replacementCount: Int,
        failureCategory: FailureCategory?
    ) {
        switch state {
        case .queued, .findingGpu, .creatingPod, .fetchingImage, .warmingModel, .connecting:
            self.warm(message: displayText(for: state, replacementCount: replacementCount))
        case .ready:
            self.setReadiness(.ready)
            // Re-send config now that the server is ready to accept it.
            self.lastSentConfig = nil
        case .failed:
            self.reconnectAttempts = 0
            self.setReadiness(.failed(message: displayText(for: failureCategory)))
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

    private func cancelAllTasks() {
        captureTask?.cancel()
        captureTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        statusTask?.cancel()
        statusTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func resizeImage(_ image: UIImage, to size: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// Transition to `.warming`. If we're already in `.warming`, the existing
    /// `startedAt` is carried forward so the progress bar stays continuous
    /// across multiple status updates and reconnect attempts. Otherwise a
    /// fresh `Date()` starts the warm-up cycle.
    private func warm(message: String) {
        let startedAt: Date
        if case .warming(_, let existing) = readiness {
            startedAt = existing
        } else {
            startedAt = Date()
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

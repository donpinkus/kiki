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

    /// Internal WebSocket-and-server state. Captures literal transitions
    /// (TCP open, server status messages, retry exhaustion). The `.connected`
    /// case fires twice on a cold start — once for WS open and once for the
    /// server's `status=ready` — so this enum on its own is not safe for UI
    /// to consume directly. UI should observe `readiness` instead.
    private enum ConnectionState {
        case disconnected
        case connecting
        case provisioning(message: String)
        case connected
        case error(String)
    }

    /// UI-facing stream state. Hides backend pod vocabulary (provisioning,
    /// reprovisioning) behind a single `.warming` case, and absorbs the
    /// double-`.connected` quirk: only an explicit `status=ready` from the
    /// server transitions to `.ready`; a bare WS open does not.
    enum StreamReadiness: Equatable {
        case disconnected
        case warming(message: String, startedAt: Date)
        case ready
        case failed(message: String)
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

    /// Internal connection state — drives readiness translation, not exposed.
    private var connectionState: ConnectionState = .disconnected

    /// Current readiness, observed by AppCoordinator.
    private(set) var readiness: StreamReadiness = .disconnected

    /// Tracks the start of the current warm-up cycle so the UI's progress bar
    /// is continuous across multiple `provisioning` status updates and reconnect
    /// attempts. Cleared on the explicit `status=ready` server message,
    /// `.disconnected`, or `.failed` — not on bare WS-open transitions.
    private var warmupStartedAt: Date?

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

    func stop() {
        Self.breadcrumb(category: "stream.lifecycle", message: "Stopping", data: [
            "framesSent": framesSent,
            "framesReceived": framesReceived,
        ])
        isStopped = true
        cancelAllTasks()
        Task { await client.disconnect() }
        updateConnectionState(.disconnected)
    }

    // MARK: - Connection

    private func connectAndRun() async {
        updateConnectionState(.connecting)
        let tx = SentrySDK.startTransaction(name: "stream.connection", operation: "stream.connection")

        do {
            try await client.connect()
            reconnectAttempts = 0
            Self.breadcrumb(category: "stream.connection", message: "Connected to server")
            updateConnectionState(.connected)

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
            updateConnectionState(.error("Unable to connect. Please restart the app."))
            return
        }

        let tx = SentrySDK.startTransaction(name: "stream.reconnect", operation: "stream.reconnect")
        tx.setData(value: reconnectAttempts, key: "attempt")
        tx.setData(value: delay, key: "backoffSec")

        cancelAllTasks()
        updateConnectionState(.connecting)

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
            for await frameData in frames {
                guard !Task.isCancelled else { break }
                if let image = UIImage(data: frameData) {
                    count += 1
                    await self.setFramesReceived(count)
                    await MainActor.run {
                        self.onImageReceived?(image)
                    }
                }
            }
            let stopped = await self.isStopped
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
                    "status": status.status,
                    "message": status.message ?? "",
                ])
                await MainActor.run {
                    if status.type == "status" && (status.status == "provisioning" || status.status == "reprovisioning") {
                        self.updateConnectionState(.provisioning(message: status.message ?? "Provisioning GPU..."))
                    } else if status.type == "status" && status.status == "ready" {
                        // Pod is genuinely ready. Clear warm-up tracking so a
                        // future reconnect/replacement starts a fresh cycle.
                        self.warmupStartedAt = nil
                        self.updateConnectionState(.connected)
                        // Re-send config now that the server is ready to accept it.
                        // The initial config may have been sent during provisioning.
                        self.lastSentConfig = nil
                    } else if (status.type == "status" && status.status == "error") || status.type == "error" {
                        // Server-sent error (e.g. provisioning failed). Reset
                        // reconnect counter since the next connection is a fresh
                        // provision, not a reconnect to a dead session.
                        SentrySDK.capture(message: "stream.server_error") { scope in
                            scope.setLevel(.error)
                            scope.setExtra(value: status.message ?? "(no message)", key: "serverMessage")
                        }
                        self.reconnectAttempts = 0
                        self.updateConnectionState(.error(status.message ?? "Server error"))
                    }
                }
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

    private func updateConnectionState(_ state: ConnectionState) {
        Self.breadcrumb(category: "stream.state", message: "State", data: ["state": String(describing: state)])
        connectionState = state

        let newReadiness: StreamReadiness
        switch state {
        case .disconnected:
            warmupStartedAt = nil
            newReadiness = .disconnected
        case .connecting:
            if warmupStartedAt == nil { warmupStartedAt = Date() }
            newReadiness = .warming(message: "Connecting…", startedAt: warmupStartedAt ?? Date())
        case .provisioning(let message):
            if warmupStartedAt == nil { warmupStartedAt = Date() }
            newReadiness = .warming(message: message, startedAt: warmupStartedAt ?? Date())
        case .connected:
            // `.connected` fires twice on a cold start: once when the WS opens
            // (pod may still be cold) and once when the server sends
            // `status=ready` (pod actually ready). The receive loop clears
            // warmupStartedAt before calling here on the latter, so its
            // presence distinguishes the two: keep warming if still set,
            // transition to .ready only after the server confirms.
            if warmupStartedAt != nil {
                newReadiness = readiness  // still warming; no change
            } else {
                newReadiness = .ready
            }
        case .error(let msg):
            warmupStartedAt = nil
            newReadiness = .failed(message: msg)
        }

        guard newReadiness != readiness else { return }
        readiness = newReadiness
        onReadinessChanged?(newReadiness)
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

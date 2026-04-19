import UIKit
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

    enum ConnectionState {
        case disconnected
        case connecting
        /// Backend is provisioning a dedicated GPU pod for this session.
        /// `message` is a human-readable progress string like
        /// "Creating pod..." or "Downloading model...". Shown to the user
        /// during the ~3–5 min cold-start wait.
        case provisioning(message: String)
        case connected
        case error(String)
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
    private var reconnectTask: Task<Void, Never>?

    /// How often to capture and send frames (default ~2 FPS for FLUX.2-klein).
    var captureInterval: TimeInterval = 0.5

    /// Current desired config. Set by AppCoordinator whenever prompt/settings
    /// change. The capture loop detects changes and sends them automatically.
    var config: StreamConfig

    /// Last config actually sent to the server (used for change detection).
    private var lastSentConfig: StreamConfig?

    /// `strokeCount` of the canvas snapshot at the last successful frame send.
    /// If the current snapshot's `strokeCount` matches, the canvas hasn't
    /// changed — skip the send so the pod's input buffer goes idle and can
    /// switch to video generation. Reset to `nil` whenever config changes so
    /// the unchanged sketch re-renders under the new prompt.
    private var lastSentStrokeCount: Int?

    /// Current connection state, observed by AppCoordinator.
    private(set) var connectionState: ConnectionState = .disconnected

    /// Called when a new generated image frame is received.
    var onImageReceived: ((UIImage) -> Void)?

    /// Called when the pod emits a video-animation event (LTXV-generated
    /// animation of the last generated still, played while the user is idle).
    var onVideoEvent: ((StreamWebSocketClient.VideoEvent) -> Void)?

    /// Called when connection state changes.
    var onConnectionStateChanged: ((ConnectionState) -> Void)?

    // MARK: - Reconnection

    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3
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
        print("[Stream] Starting: url=\(url.absoluteString), prompt=\(config.prompt ?? "(none)")")
        self.isStopped = false
        self.reconnectAttempts = 0
        self.framesSent = 0
        self.framesReceived = 0
        self.lastSentStrokeCount = nil

        await connectAndRun()
    }

    func stop() {
        print("[Stream] Stopping (sent=\(framesSent), received=\(framesReceived))")
        isStopped = true
        cancelAllTasks()
        Task { await client.disconnect() }
        updateConnectionState(.disconnected)
    }

    // MARK: - Connection

    private func connectAndRun() async {
        updateConnectionState(.connecting)

        do {
            try await client.connect()
            reconnectAttempts = 0
            print("[Stream] Connected to server")
            updateConnectionState(.connected)

            try await client.sendConfig(config)
            lastSentConfig = config
            print("[Stream] Initial config sent")

            startReceiveLoop()
            startVideoLoop()
            startCaptureLoop()
        } catch {
            print("[Stream] Connection failed: \(error)")
            if !isStopped {
                await attemptReconnect()
            }
        }
    }

    private func attemptReconnect() async {
        guard !isStopped else { return }
        reconnectAttempts += 1
        print("[Stream] Reconnect attempt \(reconnectAttempts)/\(Self.maxReconnectAttempts)")

        if reconnectAttempts > Self.maxReconnectAttempts {
            print("[Stream] Giving up after \(Self.maxReconnectAttempts) retries")
            updateConnectionState(.error("Connection lost after \(Self.maxReconnectAttempts) retries"))
            return
        }

        cancelAllTasks()

        let delay = pow(2.0, Double(reconnectAttempts - 1))
        updateConnectionState(.connecting)

        try? await Task.sleep(for: .seconds(delay))
        guard !isStopped, !Task.isCancelled else { return }

        self.client = StreamWebSocketClient(request: request)
        await connectAndRun()
    }

    // MARK: - Capture Loop

    private func startCaptureLoop() {
        captureTask = Task.detached { [weak self] in
            print("[Stream] Capture loop started")
            var count = 0
            while !Task.isCancelled {
                guard let self else { break }

                let stopped = await self.isStopped
                if stopped { break }

                // Send config update if it changed since last send
                await self.sendConfigIfChanged()

                let result: (Data, Int)? = await MainActor.run {
                    guard let snapshot = self.canvasViewModel.captureSnapshot() else { return nil }
                    // Dirty check: skip if the canvas hasn't changed since the
                    // last successful send. `strokeCount` increments on every
                    // stroke-end, erase, undo, redo, clear, and background change.
                    if snapshot.strokeCount == self.lastSentStrokeCount {
                        return nil
                    }
                    guard let resized = self.resizeImage(snapshot.image, to: Self.captureSize) else { return nil }
                    guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }
                    return (data, snapshot.strokeCount)
                }

                if let (jpeg, strokeCount) = result {
                    do {
                        try await self.client.sendFrame(jpeg)
                        await MainActor.run { self.lastSentStrokeCount = strokeCount }
                        count += 1
                        await self.setFramesSent(count)
                        if count == 1 || count % 30 == 0 {
                            print("[Stream] Sent frame \(count) (\(jpeg.count) bytes)")
                        }
                    } catch {
                        print("[Stream] Send error: \(error)")
                    }
                } else if count == 0 {
                    print("[Stream] captureSnapshot returned nil or unchanged (canvas empty?)")
                }

                let interval = await self.captureInterval
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            print("[Stream] Capture loop ended (sent \(count) frames)")
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
            lastSentStrokeCount = nil
            print("[Stream] Config auto-sent: prompt=\(current.prompt ?? "(none)")")
        } catch {
            print("[Stream] Config send error: \(error)")
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            print("[Stream] Receive loop started")
            guard let self else { return }
            let frames = await client.receivedFrames
            var count = 0
            for await frameData in frames {
                guard !Task.isCancelled else { break }
                if let image = UIImage(data: frameData) {
                    count += 1
                    await self.setFramesReceived(count)
                    if count <= 3 || count % 30 == 0 {
                        print("[Stream] Received frame \(count) (\(frameData.count) bytes, \(Int(image.size.width))x\(Int(image.size.height)))")
                    }
                    await MainActor.run {
                        self.onImageReceived?(image)
                    }
                }
            }
            let stopped = await self.isStopped
            if !Task.isCancelled, !stopped {
                print("[Stream] Receive stream ended unexpectedly, attempting reconnect")
                await self.attemptReconnect()
            }
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            let statuses = await client.serverStatuses
            for await status in statuses {
                guard !Task.isCancelled else { break }
                print("[Stream] Server status: \(status.status) \(status.message ?? "")")
                await MainActor.run {
                    if status.type == "status" && (status.status == "provisioning" || status.status == "reprovisioning") {
                        self.updateConnectionState(.provisioning(message: status.message ?? "Provisioning GPU..."))
                    } else if status.type == "status" && status.status == "ready" {
                        self.updateConnectionState(.connected)
                        // Re-send config now that the server is ready to accept it.
                        // The initial config may have been sent during provisioning.
                        self.lastSentConfig = nil
                    } else if (status.type == "status" && status.status == "error") || status.type == "error" {
                        self.updateConnectionState(.error(status.message ?? "Server error"))
                    }
                }
            }
        }
    }

    // MARK: - Video Loop

    private func startVideoLoop() {
        videoTask = Task { [weak self] in
            guard let self else { return }
            let events = await client.videoEvents
            for await event in events {
                guard !Task.isCancelled else { break }
                await MainActor.run {
                    self.onVideoEvent?(event)
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
        videoTask?.cancel()
        videoTask = nil
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
        print("[Stream] State: \(state)")
        connectionState = state
        onConnectionStateChanged?(state)
    }
}

import UIKit
import CanvasModule
import NetworkModule

/// Orchestrates real-time streaming generation: captures canvas frames,
/// sends them over WebSocket, and delivers generated images back.
@MainActor
final class StreamSession {

    // MARK: - Types

    enum ConnectionState {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    // MARK: - Properties

    private let url: URL
    private var client: StreamWebSocketClient
    private let canvasViewModel: CanvasViewModel
    private var captureTask: Task<Void, Never>?
    private var receiveTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?

    /// How often to capture and send frames (default ~7 FPS).
    var captureInterval: TimeInterval = 0.150

    /// Denoising strength for img2img (0.0 = keep original, 1.0 = full generation).
    var strength: Double = 0.5

    /// Current prompt (cached for reconnection).
    private var currentPrompt: String?

    /// Current connection state, observed by AppCoordinator.
    private(set) var connectionState: ConnectionState = .disconnected

    /// Called when a new generated image frame is received.
    var onImageReceived: ((UIImage) -> Void)?

    /// Called when connection state changes.
    var onConnectionStateChanged: ((ConnectionState) -> Void)?

    // MARK: - Reconnection

    private var reconnectAttempts = 0
    private static let maxReconnectAttempts = 3
    private var isStopped = false

    // MARK: - Capture Pause

    /// Track last canvas change to pause capture on inactivity.
    private var lastCanvasChangeTime = Date()
    private var canvasObservationTask: Task<Void, Never>?
    private static let inactivityPauseInterval: TimeInterval = 0.5
    /// After pausing, send one final frame to ensure last state is processed.
    private var sentFinalFrame = false

    // MARK: - Lifecycle

    init(url: URL, canvasViewModel: CanvasViewModel) {
        self.url = url
        self.client = StreamWebSocketClient(url: url)
        self.canvasViewModel = canvasViewModel
    }

    // MARK: - Control

    func start(prompt: String?, strength: Double) async {
        self.strength = strength
        self.currentPrompt = prompt
        self.isStopped = false
        self.reconnectAttempts = 0

        await connectAndRun()
    }

    func stop() {
        isStopped = true
        cancelAllTasks()
        Task { await client.disconnect() }
        updateConnectionState(.disconnected)
    }

    func updateConfig(prompt: String?, strength: Double? = nil) {
        if let s = strength { self.strength = s }
        if let p = prompt { self.currentPrompt = p }
        let config = StreamConfig(prompt: currentPrompt, strength: self.strength)
        Task { try? await client.sendConfig(config) }
    }

    // MARK: - Connection

    private func connectAndRun() async {
        updateConnectionState(.connecting)

        do {
            try await client.connect()
            reconnectAttempts = 0
            updateConnectionState(.connected)

            let config = StreamConfig(prompt: currentPrompt, strength: strength)
            try await client.sendConfig(config)

            startReceiveLoop()
            startCaptureLoop()
            startCanvasObservation()
        } catch {
            if !isStopped {
                await attemptReconnect()
            }
        }
    }

    private func attemptReconnect() async {
        guard !isStopped else { return }
        reconnectAttempts += 1

        if reconnectAttempts > Self.maxReconnectAttempts {
            updateConnectionState(.error("Connection lost after \(Self.maxReconnectAttempts) retries"))
            return
        }

        cancelAllTasks()

        // Exponential backoff: 1s, 2s, 4s
        let delay = pow(2.0, Double(reconnectAttempts - 1))
        updateConnectionState(.connecting)

        try? await Task.sleep(for: .seconds(delay))
        guard !isStopped, !Task.isCancelled else { return }

        // Create a fresh client for the new connection
        self.client = StreamWebSocketClient(url: url)
        await connectAndRun()
    }

    // MARK: - Capture Loop

    private func startCaptureLoop() {
        captureTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                let timeSinceLastChange = Date().timeIntervalSince(self.lastCanvasChangeTime)
                let isInactive = timeSinceLastChange > Self.inactivityPauseInterval

                if isInactive && self.sentFinalFrame {
                    // Paused: wait a bit before checking again
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }

                if let snapshot = self.canvasViewModel.captureSnapshot() {
                    if let resized = self.resizeImage(snapshot.image, to: CGSize(width: 512, height: 512)),
                       let jpeg = resized.jpegData(compressionQuality: 0.7) {
                        try? await self.client.sendFrame(jpeg)
                    }
                }

                if isInactive {
                    self.sentFinalFrame = true
                }

                try? await Task.sleep(for: .milliseconds(Int(self.captureInterval * 1000)))
            }
        }
    }

    // MARK: - Canvas Observation (for pause/resume)

    private func startCanvasObservation() {
        canvasObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.canvasViewModel.canvasChanges {
                guard !Task.isCancelled else { return }
                self.lastCanvasChangeTime = Date()
                self.sentFinalFrame = false
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let frames = await client.receivedFrames
            for await frameData in frames {
                guard !Task.isCancelled else { break }
                if let image = UIImage(data: frameData) {
                    self.onImageReceived?(image)
                }
            }
            // Stream ended — attempt reconnection
            if !Task.isCancelled, !self.isStopped {
                await self.attemptReconnect()
            }
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            let statuses = await client.serverStatuses
            for await status in statuses {
                guard !Task.isCancelled else { break }
                if status.type == "status" && status.status == "error" {
                    self.updateConnectionState(.error(status.message ?? "Server error"))
                }
            }
        }
    }

    // MARK: - Private

    private func cancelAllTasks() {
        captureTask?.cancel()
        captureTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        statusTask?.cancel()
        statusTask = nil
        canvasObservationTask?.cancel()
        canvasObservationTask = nil
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
        connectionState = state
        onConnectionStateChanged?(state)
    }
}

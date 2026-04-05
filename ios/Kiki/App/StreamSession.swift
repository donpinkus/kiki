import UIKit
import os
import CanvasModule
import NetworkModule

private let logger = Logger(subsystem: "com.kiki.app", category: "StreamSession")

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

    private var lastCanvasChangeTime = Date()
    private var canvasObservationTask: Task<Void, Never>?
    private static let inactivityPauseInterval: TimeInterval = 0.5
    private var sentFinalFrame = false

    // MARK: - Stats

    private var framesSent = 0
    private var framesReceived = 0

    // MARK: - Lifecycle

    init(url: URL, canvasViewModel: CanvasViewModel) {
        self.url = url
        self.client = StreamWebSocketClient(url: url)
        self.canvasViewModel = canvasViewModel
    }

    // MARK: - Control

    func start(prompt: String?, strength: Double) async {
        logger.info("Starting stream: url=\(self.url.absoluteString), prompt=\(prompt ?? "(none)"), strength=\(strength)")
        self.strength = strength
        self.currentPrompt = prompt
        self.isStopped = false
        self.reconnectAttempts = 0
        self.framesSent = 0
        self.framesReceived = 0

        await connectAndRun()
    }

    func stop() {
        logger.info("Stopping stream (sent=\(self.framesSent), received=\(self.framesReceived))")
        isStopped = true
        cancelAllTasks()
        Task { await client.disconnect() }
        updateConnectionState(.disconnected)
    }

    func updateConfig(prompt: String?, strength: Double? = nil) {
        if let s = strength { self.strength = s }
        if let p = prompt { self.currentPrompt = p }
        let config = StreamConfig(prompt: currentPrompt, strength: self.strength)
        logger.info("Updating config: prompt=\(self.currentPrompt ?? "(none)"), strength=\(self.strength)")
        Task { try? await client.sendConfig(config) }
    }

    // MARK: - Connection

    private func connectAndRun() async {
        updateConnectionState(.connecting)

        do {
            try await client.connect()
            reconnectAttempts = 0
            logger.info("Connected to StreamDiffusion server")
            updateConnectionState(.connected)

            let config = StreamConfig(prompt: currentPrompt, strength: strength)
            try await client.sendConfig(config)
            logger.info("Initial config sent")

            startReceiveLoop()
            startCaptureLoop()
            startCanvasObservation()
        } catch {
            logger.error("Connection failed: \(error.localizedDescription)")
            if !isStopped {
                await attemptReconnect()
            }
        }
    }

    private func attemptReconnect() async {
        guard !isStopped else { return }
        reconnectAttempts += 1
        logger.warning("Reconnect attempt \(self.reconnectAttempts)/\(Self.maxReconnectAttempts)")

        if reconnectAttempts > Self.maxReconnectAttempts {
            logger.error("Giving up after \(Self.maxReconnectAttempts) retries")
            updateConnectionState(.error("Connection lost after \(Self.maxReconnectAttempts) retries"))
            return
        }

        cancelAllTasks()

        let delay = pow(2.0, Double(reconnectAttempts - 1))
        updateConnectionState(.connecting)

        try? await Task.sleep(for: .seconds(delay))
        guard !isStopped, !Task.isCancelled else { return }

        self.client = StreamWebSocketClient(url: url)
        await connectAndRun()
    }

    // MARK: - Capture Loop

    private func startCaptureLoop() {
        // Run on background thread. Only hop to MainActor for captureSnapshot()
        // and resizeImage() which use UIGraphicsImageRenderer (main thread only).
        // Task.sleep on background does NOT block the main thread.
        captureTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }

                let isStopped = await self.isStopped
                if isStopped { break }

                let timeSinceLastChange = await Date().timeIntervalSince(self.lastCanvasChangeTime)
                let inactivityThreshold = await Self.inactivityPauseInterval
                let isInactive = timeSinceLastChange > inactivityThreshold
                let alreadySentFinal = await self.sentFinalFrame

                if isInactive && alreadySentFinal {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }

                // Capture + resize on main thread (UIGraphicsImageRenderer requirement)
                let jpeg: Data? = await MainActor.run {
                    guard let snapshot = self.canvasViewModel.captureSnapshot() else { return nil }
                    guard let resized = self.resizeImage(snapshot.image, to: CGSize(width: 512, height: 512)) else { return nil }
                    return resized.jpegData(compressionQuality: 0.7)
                }

                if let jpeg {
                    try? await self.client.sendFrame(jpeg)
                    let count = await self.incrementFramesSent()
                    if count % 10 == 1 {
                        logger.info("Capture: sent frame \(count) (\(jpeg.count) bytes)")
                    }
                }

                if isInactive {
                    await MainActor.run { self.sentFinalFrame = true }
                }

                let interval = await self.captureInterval
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
        }
    }

    // MARK: - Canvas Observation (for pause/resume)

    private func startCanvasObservation() {
        canvasObservationTask = Task { [weak self] in
            guard let self else { return }
            let changes = await self.canvasViewModel.canvasChanges
            for await _ in changes {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.lastCanvasChangeTime = Date()
                    self.sentFinalFrame = false
                }
            }
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        // Run on background thread. Only hop to MainActor for UI callbacks.
        receiveTask = Task { [weak self] in
            guard let self else { return }
            let frames = await client.receivedFrames
            for await frameData in frames {
                guard !Task.isCancelled else { break }
                if let image = UIImage(data: frameData) {
                    let count = await self.incrementFramesReceived()
                    if count % 10 == 1 {
                        logger.info("Receive: got frame \(count) (\(frameData.count) bytes)")
                    }
                    await MainActor.run {
                        self.onImageReceived?(image)
                    }
                }
            }
            // Stream ended — attempt reconnection
            let stopped = await self.isStopped
            if !Task.isCancelled, !stopped {
                logger.warning("Receive stream ended unexpectedly, attempting reconnect")
                await self.attemptReconnect()
            }
        }

        statusTask = Task { [weak self] in
            guard let self else { return }
            let statuses = await client.serverStatuses
            for await status in statuses {
                guard !Task.isCancelled else { break }
                if status.type == "status" && status.status == "error" {
                    logger.error("Server status error: \(status.message ?? "unknown")")
                    await MainActor.run {
                        self.updateConnectionState(.error(status.message ?? "Server error"))
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func incrementFramesSent() -> Int {
        framesSent += 1
        return framesSent
    }

    private func incrementFramesReceived() -> Int {
        framesReceived += 1
        return framesReceived
    }

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
        logger.info("Connection state: \(String(describing: state))")
        connectionState = state
        onConnectionStateChanged?(state)
    }
}

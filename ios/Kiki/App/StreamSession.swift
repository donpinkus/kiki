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

    /// t_index_list controlling creativity vs fidelity.
    var tIndexList: [Int] = [20, 30]

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

    func start(prompt: String?, tIndexList: [Int]) async {
        print("[Stream] Starting: url=\(url.absoluteString), prompt=\(prompt ?? "(none)"), tIndexList=\(tIndexList)")
        self.tIndexList = tIndexList
        self.currentPrompt = prompt
        self.isStopped = false
        self.reconnectAttempts = 0
        self.framesSent = 0
        self.framesReceived = 0

        await connectAndRun()
    }

    func stop() {
        print("[Stream] Stopping (sent=\(framesSent), received=\(framesReceived))")
        isStopped = true
        cancelAllTasks()
        Task { await client.disconnect() }
        updateConnectionState(.disconnected)
    }

    func updateConfig(prompt: String?, tIndexList: [Int]? = nil) {
        if let t = tIndexList { self.tIndexList = t }
        if let p = prompt { self.currentPrompt = p }
        let config = StreamConfig(prompt: currentPrompt, tIndexList: self.tIndexList)
        print("[Stream] Config update: prompt=\(currentPrompt ?? "(none)"), tIndexList=\(self.tIndexList)")
        Task { try? await client.sendConfig(config) }
    }

    // MARK: - Connection

    private func connectAndRun() async {
        updateConnectionState(.connecting)

        do {
            try await client.connect()
            reconnectAttempts = 0
            print("[Stream] Connected to server")
            updateConnectionState(.connected)

            let config = StreamConfig(prompt: currentPrompt, tIndexList: tIndexList)
            try await client.sendConfig(config)
            print("[Stream] Initial config sent")

            startReceiveLoop()
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

        self.client = StreamWebSocketClient(url: url)
        await connectAndRun()
    }

    // MARK: - Capture Loop

    private func startCaptureLoop() {
        // Run on background. Only hop to MainActor for captureSnapshot/resizeImage
        // (UIGraphicsImageRenderer requires main thread). Task.sleep on background
        // does NOT block the main thread, so receive loop can process frames freely.
        //
        // No inactivity pause — captures continuously while connected.
        // The server's similarity filter skips redundant frames.
        captureTask = Task.detached { [weak self] in
            print("[Stream] Capture loop started")
            var count = 0
            while !Task.isCancelled {
                guard let self else { break }

                let stopped = await self.isStopped
                if stopped { break }

                // Capture + resize on main thread
                let jpeg: Data? = await MainActor.run {
                    guard let snapshot = self.canvasViewModel.captureSnapshot() else { return nil }
                    guard let resized = self.resizeImage(snapshot.image, to: CGSize(width: 512, height: 512)) else { return nil }
                    return resized.jpegData(compressionQuality: 0.7)
                }

                if let jpeg {
                    do {
                        try await self.client.sendFrame(jpeg)
                        count += 1
                        await self.setFramesSent(count)
                        if count == 1 || count % 30 == 0 {
                            print("[Stream] Sent frame \(count) (\(jpeg.count) bytes)")
                            let b64 = jpeg.base64EncodedString()
                            print("[Stream] SENT frame \(count) — paste in browser:")
                            print("data:image/jpeg;base64,\(b64)")
                        }
                    } catch {
                        print("[Stream] Send error: \(error)")
                    }
                } else if count == 0 {
                    print("[Stream] captureSnapshot returned nil (canvas empty?)")
                }

                let interval = await self.captureInterval
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
            }
            print("[Stream] Capture loop ended (sent \(count) frames)")
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
                if status.type == "status" && status.status == "error" {
                    await MainActor.run {
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
        print("[Stream] State: \(state)")
        connectionState = state
        onConnectionStateChanged?(state)
    }
}

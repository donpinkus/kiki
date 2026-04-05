import Foundation

/// WebSocket client for real-time streaming communication with the StreamDiffusion backend.
/// Uses native `URLSessionWebSocketTask` — no third-party dependencies.
public actor StreamWebSocketClient {

    // MARK: - Types

    public enum State: Sendable {
        case disconnected
        case connecting
        case connected
        case disconnecting
    }

    /// Status message received from the server.
    public struct ServerStatus: Decodable, Sendable {
        public let type: String
        public let status: String
        public let message: String?
    }

    // MARK: - Properties

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

    public private(set) var state: State = .disconnected

    // Outbound stream of received image frames (binary JPEG data)
    private let framesContinuation: AsyncStream<Data>.Continuation
    public let receivedFrames: AsyncStream<Data>

    // Status updates from server
    private let statusContinuation: AsyncStream<ServerStatus>.Continuation
    public let serverStatuses: AsyncStream<ServerStatus>

    // MARK: - Lifecycle

    public init(url: URL) {
        self.url = url
        self.session = URLSession(configuration: .default)

        var frameCont: AsyncStream<Data>.Continuation!
        self.receivedFrames = AsyncStream { frameCont = $0 }
        self.framesContinuation = frameCont

        var statusCont: AsyncStream<ServerStatus>.Continuation!
        self.serverStatuses = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont
    }

    // MARK: - Connection

    public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting

        let wsTask = session.webSocketTask(with: url)
        self.task = wsTask
        wsTask.resume()

        // Wait for initial server status message to confirm connection
        let message = try await wsTask.receive()
        switch message {
        case .string(let text):
            if let data = text.data(using: .utf8),
               let status = try? JSONDecoder().decode(ServerStatus.self, from: data) {
                statusContinuation.yield(status)
            }
        case .data:
            break
        @unknown default:
            break
        }

        state = .connected
        startReceiveLoop()
    }

    public func disconnect() {
        guard state == .connected || state == .connecting else { return }
        state = .disconnecting

        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil

        state = .disconnected
        framesContinuation.finish()
        statusContinuation.finish()
    }

    // MARK: - Sending

    public func sendConfig(_ config: StreamConfig) async throws {
        guard state == .connected, let task else { return }
        let data = try JSONEncoder().encode(config)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await task.send(.string(text))
    }

    public func sendFrame(_ jpegData: Data) async throws {
        guard state == .connected, let task else { return }
        try await task.send(.data(jpegData))
    }

    // MARK: - Receiving

    private func startReceiveLoop() {
        receiveLoopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.task else { break }
                    let message = try await task.receive()

                    switch message {
                    case .data(let data):
                        // Binary frame: generated image JPEG
                        await self.framesContinuation.yield(data)

                    case .string(let text):
                        // Text frame: status/error JSON
                        if let data = text.data(using: .utf8),
                           let status = try? JSONDecoder().decode(ServerStatus.self, from: data) {
                            await self.statusContinuation.yield(status)
                        }

                    @unknown default:
                        break
                    }
                } catch {
                    // Connection closed or error — exit loop
                    if !Task.isCancelled {
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleDisconnect() {
        state = .disconnected
        task = nil
        receiveLoopTask = nil
        framesContinuation.finish()
        statusContinuation.finish()
    }
}

import Foundation

/// WebSocket client for real-time streaming communication with the generation backend.
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

    private let framesContinuation: AsyncStream<Data>.Continuation
    public let receivedFrames: AsyncStream<Data>

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
        print("[StreamWS] Connecting to \(url.absoluteString)")

        let wsTask = session.webSocketTask(with: url)
        self.task = wsTask
        wsTask.resume()

        // Wait for initial server status message to confirm connection
        let message = try await wsTask.receive()
        switch message {
        case .string(let text):
            print("[StreamWS] Initial message: \(text)")
            // Check for error response (backend sends this if upstream is unavailable)
            if text.contains("\"type\":\"error\"") {
                let errorMsg = text  // Keep for error message
                wsTask.cancel(with: .normalClosure, reason: nil)
                self.task = nil
                state = .disconnected
                throw URLError(.cannotConnectToHost, userInfo: [
                    NSLocalizedDescriptionKey: "Server error: \(errorMsg)"
                ])
            }
            if let data = text.data(using: .utf8),
               let status = try? JSONDecoder().decode(ServerStatus.self, from: data) {
                statusContinuation.yield(status)
            }
        case .data(let data):
            print("[StreamWS] Initial binary: \(data.count) bytes")
        @unknown default:
            break
        }

        state = .connected
        print("[StreamWS] Connected")
        startReceiveLoop()
    }

    public func disconnect() {
        guard state == .connected || state == .connecting else { return }
        print("[StreamWS] Disconnecting")
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

    public func sendConfig<C: Encodable & Sendable>(_ config: C) async throws {
        guard state == .connected, let task else {
            print("[StreamWS] sendConfig skipped: state=\(state)")
            return
        }
        let data = try JSONEncoder().encode(config)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await task.send(.string(text))
        print("[StreamWS] Config sent")
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
                        // Raw binary frame (may not be used if backend wraps in JSON)
                        await self.framesContinuation.yield(data)

                    case .string(let text):
                        // Backend wraps JPEG as JSON text: {"type":"frame","data":"<base64>"}
                        // to avoid iOS URLSessionWebSocketTask binary frame issues.
                        if let jsonData = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let type = json["type"] as? String {
                            if type == "frame", let b64 = json["data"] as? String,
                               let imageData = Data(base64Encoded: b64) {
                                await self.framesContinuation.yield(imageData)
                            } else if type == "status" || type == "error" {
                                if let status = try? JSONDecoder().decode(ServerStatus.self, from: jsonData) {
                                    print("[StreamWS] Server status: \(status.status) \(status.message ?? "")")
                                    await self.statusContinuation.yield(status)
                                }
                            }
                        }

                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        print("[StreamWS] Receive error: \(error)")
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleDisconnect() {
        print("[StreamWS] Unexpected disconnect")
        state = .disconnected
        task = nil
        receiveLoopTask = nil
        framesContinuation.finish()
        statusContinuation.finish()
    }
}

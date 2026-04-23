import Foundation
import Sentry

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

    /// A message from the server about the provision state machine.
    /// `type == "state"` carries a full state event; `type == "error"` is an
    /// out-of-band failure (auth, entitlement, rate-limit, relay error) that
    /// happens outside the state flow.
    public struct ServerStatus: Decodable, Sendable {
        public let type: String
        public let state: String?            // present for type=="state"
        public let stateEnteredAt: Int64?    // ms epoch, type=="state"
        public let replacementCount: Int?    // type=="state"
        public let failureCategory: String?  // type=="state" && state=="failed"
        public let message: String?          // present for type=="error"
    }

    // MARK: - Properties

    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

    public private(set) var state: State = .disconnected

    private let framesContinuation: AsyncStream<Data>.Continuation
    public let receivedFrames: AsyncStream<Data>

    private let statusContinuation: AsyncStream<ServerStatus>.Continuation
    public let serverStatuses: AsyncStream<ServerStatus>

    // MARK: - Lifecycle

    /// Create a client for a URL (no auth headers).
    public init(url: URL) {
        self.request = URLRequest(url: url)
        self.session = URLSession(configuration: .default)

        var frameCont: AsyncStream<Data>.Continuation!
        self.receivedFrames = AsyncStream { frameCont = $0 }
        self.framesContinuation = frameCont

        var statusCont: AsyncStream<ServerStatus>.Continuation!
        self.serverStatuses = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont
    }

    // MARK: - Connection

    /// Create a client for a URLRequest — use this to pass auth headers
    /// (Authorization: Bearer <jwt>) on the WebSocket upgrade.
    public init(request: URLRequest) {
        self.request = request
        self.session = URLSession(configuration: .default)

        var frameCont: AsyncStream<Data>.Continuation!
        self.receivedFrames = AsyncStream { frameCont = $0 }
        self.framesContinuation = frameCont

        var statusCont: AsyncStream<ServerStatus>.Continuation!
        self.serverStatuses = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont
    }

    public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        Self.breadcrumb(category: "ws.connection", message: "Connecting", data: [
            "url": request.url?.absoluteString ?? "<nil>",
        ])

        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()

        // Wait for initial server status message to confirm connection
        let message = try await wsTask.receive()
        switch message {
        case .string(let text):
            Self.breadcrumb(category: "ws.handshake", message: "Initial string message", data: ["length": text.count])
            // Check for error response (backend sends this if upstream is unavailable)
            if text.contains("\"type\":\"error\"") {
                let errorMsg = text  // Keep for error message
                wsTask.cancel(with: .normalClosure, reason: nil)
                self.task = nil
                state = .disconnected
                let err = URLError(.cannotConnectToHost, userInfo: [
                    NSLocalizedDescriptionKey: "Server error: \(errorMsg)"
                ])
                SentrySDK.capture(error: err) { scope in
                    scope.setTag(value: "ws.connect.server_error", key: "op")
                    scope.setExtra(value: errorMsg, key: "serverMessage")
                }
                throw err
            }
            if let data = text.data(using: .utf8),
               let status = try? JSONDecoder().decode(ServerStatus.self, from: data) {
                statusContinuation.yield(status)
            }
        case .data(let data):
            Self.breadcrumb(category: "ws.handshake", message: "Initial binary message", data: ["bytes": data.count])
        @unknown default:
            break
        }

        state = .connected
        Self.breadcrumb(category: "ws.connection", message: "Connected")
        startReceiveLoop()
    }

    public func disconnect() {
        guard state == .connected || state == .connecting else { return }
        Self.breadcrumb(category: "ws.lifecycle", message: "Disconnecting")
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
            Self.breadcrumb(category: "ws.config", message: "sendConfig skipped", data: ["state": String(describing: state)])
            return
        }
        let data = try JSONEncoder().encode(config)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        try await task.send(.string(text))
        Self.breadcrumb(category: "ws.config", message: "Config sent")
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
                            } else if type == "state" || type == "error" {
                                if let status = try? JSONDecoder().decode(ServerStatus.self, from: jsonData) {
                                    Self.breadcrumb(category: "ws.status", message: "Server status", data: [
                                        "type": status.type,
                                        "state": status.state ?? "",
                                        "message": status.message ?? "",
                                    ])
                                    await self.statusContinuation.yield(status)
                                }
                            }
                        }

                    @unknown default:
                        break
                    }
                } catch {
                    if !Task.isCancelled {
                        SentrySDK.capture(error: error) { scope in
                            scope.setTag(value: "ws.receive", key: "op")
                        }
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleDisconnect() {
        SentrySDK.capture(message: "ws.unexpected_disconnect") { scope in
            scope.setLevel(.warning)
        }
        state = .disconnected
        task = nil
        receiveLoopTask = nil
        framesContinuation.finish()
        statusContinuation.finish()
    }

    // MARK: - Breadcrumb helper

    private static func breadcrumb(
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

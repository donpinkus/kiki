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
        /// Whether the pod's LTXV video pipeline loaded successfully.
        /// Only present on `"ready"` status messages; `nil` on older pods.
        public let videoReady: Bool?

        enum CodingKeys: String, CodingKey {
            case type, status, message
            case videoReady = "video_ready"
        }
    }

    /// Video-generation messages from the pod. Emitted only while the pod is
    /// idle and running LTXV animation on the last generated still. Any img2img
    /// frame arriving on `receivedFrames` should cause the client to discard
    /// in-flight video and revert to normal streaming display.
    public enum VideoEvent: Sendable {
        /// A single decoded video frame as JPEG. Sent as they are ready.
        case frame(Data)
        /// The complete animation as an MP4 blob, intended for smooth looping.
        case complete(Data)
        /// Pod aborted generation (user resumed drawing).
        case cancelled
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

    private let videoEventsContinuation: AsyncStream<VideoEvent>.Continuation
    public let videoEvents: AsyncStream<VideoEvent>

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

        var videoCont: AsyncStream<VideoEvent>.Continuation!
        self.videoEvents = AsyncStream { videoCont = $0 }
        self.videoEventsContinuation = videoCont
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

        var videoCont: AsyncStream<VideoEvent>.Continuation!
        self.videoEvents = AsyncStream { videoCont = $0 }
        self.videoEventsContinuation = videoCont
    }

    public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        print("[StreamWS] Connecting to \(request.url?.absoluteString ?? "<nil>")")

        let wsTask = session.webSocketTask(with: request)
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
        videoEventsContinuation.finish()
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
                            } else if type == "video_frame", let b64 = json["data"] as? String,
                                      let imageData = Data(base64Encoded: b64) {
                                await self.videoEventsContinuation.yield(.frame(imageData))
                            } else if type == "video_complete", let b64 = json["data"] as? String,
                                      let mp4Data = Data(base64Encoded: b64) {
                                await self.videoEventsContinuation.yield(.complete(mp4Data))
                            } else if type == "video_cancelled" {
                                await self.videoEventsContinuation.yield(.cancelled)
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
        videoEventsContinuation.finish()
    }
}

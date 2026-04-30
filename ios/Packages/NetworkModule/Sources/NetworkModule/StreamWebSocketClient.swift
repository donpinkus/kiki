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
        /// Ms epoch when the current pod-warm cycle began. Stable across all
        /// state transitions for a given session — drives the warm-up progress
        /// bar so reconnecting clients resume instead of restarting.
        public let warmingStartedAt: Int64?  // type=="state"
        public let replacementCount: Int?    // type=="state"
        public let failureCategory: String?  // type=="state" && state=="failed"
        // Real error message from the source. Populated for type=="error"
        // and for type=="state" when state=="failed". Client renders verbatim
        // — no category-to-string mapping that fabricates a cause.
        public let message: String?
    }

    /// A generated image frame from the pod. `requestId` is set when the
    /// pod preceded the binary with a `frame_meta` text message (used for
    /// style-preview correlation). Normal streaming frames have nil.
    public struct ReceivedFrame: Sendable {
        public let requestId: String?
        public let data: Data
    }

    /// Events from the video pod path: streamed JPEG frames during
    /// generation, the final MP4 for smooth looping, and cancellation
    /// notices. The same correlation `requestId` propagates through every
    /// event so the UI can match them to a specific trigger.
    public enum VideoEvent: Sendable {
        case frame(requestId: String?, image: Data, index: Int?, total: Int?)
        case complete(requestId: String?, mp4: Data, fps: Int?, frames: Int?)
        case cancelled(requestId: String?, atStep: Int?, error: String?)
    }

    // MARK: - Properties

    private let request: URLRequest
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var receiveLoopTask: Task<Void, Never>?

    public private(set) var state: State = .disconnected

    private let framesContinuation: AsyncStream<ReceivedFrame>.Continuation
    public let receivedFrames: AsyncStream<ReceivedFrame>

    private let statusContinuation: AsyncStream<ServerStatus>.Continuation
    public let serverStatuses: AsyncStream<ServerStatus>

    private let videoContinuation: AsyncStream<VideoEvent>.Continuation
    public let videoEvents: AsyncStream<VideoEvent>

    /// Most recent `frame_meta` from the pod, waiting to be paired with
    /// the next binary frame. Cleared each time a binary is emitted.
    private var pendingFrameMetaRequestId: String?

    /// Wall-clock of the most recent successful `task.receive()` (any kind:
    /// status, frame, video). Used to log "time since last receive" on
    /// disconnect so we can characterize the failure (idle drop vs immediate).
    private var lastReceiveAt: Date?
    /// Wall-clock when `connect()` was called, for "time-to-first-message"
    /// diagnostics on the WS handshake path.
    private var connectStartedAt: Date?

    // MARK: - Lifecycle

    /// Create a client for a URL (no auth headers).
    public init(url: URL) {
        self.request = URLRequest(url: url)
        self.session = URLSession(configuration: .default)

        var frameCont: AsyncStream<ReceivedFrame>.Continuation!
        self.receivedFrames = AsyncStream { frameCont = $0 }
        self.framesContinuation = frameCont

        var statusCont: AsyncStream<ServerStatus>.Continuation!
        self.serverStatuses = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont

        var videoCont: AsyncStream<VideoEvent>.Continuation!
        self.videoEvents = AsyncStream { videoCont = $0 }
        self.videoContinuation = videoCont
    }

    // MARK: - Connection

    /// Create a client for a URLRequest — use this to pass auth headers
    /// (Authorization: Bearer <jwt>) on the WebSocket upgrade.
    public init(request: URLRequest) {
        self.request = request
        self.session = URLSession(configuration: .default)

        var frameCont: AsyncStream<ReceivedFrame>.Continuation!
        self.receivedFrames = AsyncStream { frameCont = $0 }
        self.framesContinuation = frameCont

        var statusCont: AsyncStream<ServerStatus>.Continuation!
        self.serverStatuses = AsyncStream { statusCont = $0 }
        self.statusContinuation = statusCont

        var videoCont: AsyncStream<VideoEvent>.Continuation!
        self.videoEvents = AsyncStream { videoCont = $0 }
        self.videoContinuation = videoCont
    }

    public func connect() async throws {
        guard state == .disconnected else { return }
        state = .connecting
        connectStartedAt = Date()
        Self.breadcrumb(category: "ws.connection", message: "Connecting", data: [
            "url": request.url?.absoluteString ?? "<nil>",
        ])

        let wsTask = session.webSocketTask(with: request)
        self.task = wsTask
        wsTask.resume()

        // Wait for initial server status message to confirm connection
        let firstReceiveStart = Date()
        let message = try await wsTask.receive()
        let firstReceiveMs = Int(Date().timeIntervalSince(firstReceiveStart) * 1000)
        lastReceiveAt = Date()
        switch message {
        case .string(let text):
            Self.breadcrumb(category: "ws.handshake", message: "Initial string message", data: [
                "length": text.count,
                "firstReceiveMs": firstReceiveMs,
            ])
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
        videoContinuation.finish()
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

                    await self.markReceived()
                    switch message {
                    case .data(let data):
                        // Raw binary frame (may not be used if backend wraps in JSON)
                        await self.yieldFrame(data)

                    case .string(let text):
                        // Backend wraps JPEG as JSON text: {"type":"frame","data":"<base64>"}
                        // to avoid iOS URLSessionWebSocketTask binary frame issues.
                        if let jsonData = text.data(using: .utf8),
                           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                           let type = json["type"] as? String {
                            if type == "frame", let b64 = json["data"] as? String,
                               let imageData = Data(base64Encoded: b64) {
                                await self.yieldFrame(imageData)
                            } else if type == "frame_meta" {
                                // Preamble to the next binary frame. Stores the
                                // requestId so the next yielded frame carries it.
                                await self.setPendingFrameMeta(json["requestId"] as? String)
                            } else if type == "state" || type == "error" {
                                if let status = try? JSONDecoder().decode(ServerStatus.self, from: jsonData) {
                                    Self.breadcrumb(category: "ws.status", message: "Server status", data: [
                                        "type": status.type,
                                        "state": status.state ?? "",
                                        "message": status.message ?? "",
                                    ])
                                    await self.statusContinuation.yield(status)
                                }
                            } else if type == "video_frame_data", let b64 = json["data"] as? String,
                                      let imageData = Data(base64Encoded: b64) {
                                let meta = json["meta"] as? [String: Any] ?? [:]
                                let event = StreamWebSocketClient.VideoEvent.frame(
                                    requestId: meta["requestId"] as? String,
                                    image: imageData,
                                    index: meta["index"] as? Int,
                                    total: meta["total"] as? Int
                                )
                                Self.breadcrumb(category: "ws.video", message: "video_frame", data: [
                                    "bytes": imageData.count,
                                    "index": (meta["index"] as? Int) ?? -1,
                                    "total": (meta["total"] as? Int) ?? -1,
                                ])
                                await self.videoContinuation.yield(event)
                            } else if type == "video_complete_data", let b64 = json["data"] as? String,
                                      let mp4Data = Data(base64Encoded: b64) {
                                let meta = json["meta"] as? [String: Any] ?? [:]
                                let event = StreamWebSocketClient.VideoEvent.complete(
                                    requestId: meta["requestId"] as? String,
                                    mp4: mp4Data,
                                    fps: meta["fps"] as? Int,
                                    frames: meta["frames"] as? Int
                                )
                                Self.breadcrumb(category: "ws.video", message: "video_complete", data: [
                                    "bytes": mp4Data.count,
                                    "frames": (meta["frames"] as? Int) ?? -1,
                                ])
                                await self.videoContinuation.yield(event)
                            } else if type == "video_cancelled" {
                                let event = StreamWebSocketClient.VideoEvent.cancelled(
                                    requestId: json["requestId"] as? String,
                                    atStep: json["atStep"] as? Int,
                                    error: json["error"] as? String
                                )
                                Self.breadcrumb(category: "ws.video", message: "video_cancelled", data: [
                                    "atStep": (json["atStep"] as? Int) ?? -1,
                                    "error": (json["error"] as? String) ?? "",
                                ])
                                await self.videoContinuation.yield(event)
                            }
                            // Other types (video_frame, video_complete preambles)
                            // are intentionally ignored — the *_data wrappers
                            // above carry their meta as a sibling field.
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

    private func setPendingFrameMeta(_ requestId: String?) {
        pendingFrameMetaRequestId = requestId
    }

    private func markReceived() {
        lastReceiveAt = Date()
    }

    private func yieldFrame(_ data: Data) {
        let requestId = pendingFrameMetaRequestId
        pendingFrameMetaRequestId = nil
        framesContinuation.yield(ReceivedFrame(requestId: requestId, data: data))
    }

    private func handleDisconnect() {
        let now = Date()
        let lastReceiveAgeMs = lastReceiveAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        let connectAgeMs = connectStartedAt.map { Int(now.timeIntervalSince($0) * 1000) } ?? -1
        Self.breadcrumb(category: "ws.disconnect", message: "Unexpected disconnect", data: [
            "lastReceiveAgeMs": lastReceiveAgeMs,
            "connectAgeMs": connectAgeMs,
        ], level: .warning)
        SentrySDK.capture(message: "ws.unexpected_disconnect") { scope in
            scope.setLevel(.warning)
            scope.setExtra(value: lastReceiveAgeMs, key: "lastReceiveAgeMs")
            scope.setExtra(value: connectAgeMs, key: "connectAgeMs")
        }
        state = .disconnected
        task = nil
        receiveLoopTask = nil
        framesContinuation.finish()
        statusContinuation.finish()
        videoContinuation.finish()
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

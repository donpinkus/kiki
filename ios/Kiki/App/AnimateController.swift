import AVFoundation
import Foundation
import NetworkModule
import SwiftData
import SwiftUI
import Sentry

/// State + backend session for the Animate screen.
///
/// Owns its own WebSocket to the backend's `/v1/animate` route (opened when
/// the screen appears, closed when it disappears — completely independent of
/// the drawing stream). Reuses `StreamWebSocketClient`, which already parses
/// the whole `video_*` message family.
///
/// Flow per generation:
///   generate() → animate_request (keyframes as ≤1024px JPEG base64)
///   ← video_started        (isGenerating = true, authoritative)
///   ← video_frame_data ×N  (live preview frames while the MP4 encodes)
///   ← video_complete_data  (MP4 → saved as an AnimationClip + played)
///   ← video_cancelled      (reset; error string surfaced when present)
@MainActor
@Observable
final class AnimateController {

    // MARK: - Setup inputs

    /// Start keyframe (required to generate). Position 0.0.
    var startKeyframe: UIImage?
    /// Optional end keyframe. Position 1.0.
    var endKeyframe: UIImage?
    /// Motion prompt ("" = server default, shown as placeholder). Persisted
    /// across launches so a half-written prompt survives an app restart.
    var prompt = "" {
        didSet { UserDefaults.standard.set(prompt, forKey: "animatePrompt") }
    }
    /// Duration preset in seconds; mapped to LTX frame counts (24 fps,
    /// (n-1) % 8 == 0): 2s → 49, 4s → 97, 6s → 145. Persisted.
    var durationSeconds = 6 {
        didSet { UserDefaults.standard.set(durationSeconds, forKey: "animateDurationSeconds") }
    }
    static let durationOptions = [2, 4, 6]
    /// The drawing the start keyframe came from (nil = Photos import or
    /// gallery-entry without a source drawing).
    var sourceDrawingID: UUID?

    /// Preview player audio. LTX generates an audio track that ranges from
    /// delightful to noise — user's last choice persists.
    var isMuted = UserDefaults.standard.bool(forKey: "animateMuted") {
        didSet { UserDefaults.standard.set(isMuted, forKey: "animateMuted") }
    }

    /// Motion-ideas panel visibility (lives here rather than view @State so
    /// it survives view identity changes and is reachable from the dev
    /// bridge).
    var showMotionExamples = false

    /// Swap the start and end keyframes (reverses a morph).
    func swapKeyframes() {
        guard let end = endKeyframe else { return }
        let start = startKeyframe
        startKeyframe = end
        endKeyframe = start
        // The swapped-in start no longer corresponds to the source drawing.
        sourceDrawingID = nil
    }

    // MARK: - Session state

    enum Availability: String {
        case unknown, off, warming, ready
    }
    private(set) var availability: Availability = .unknown
    private(set) var videoSystemStatus: StreamWebSocketClient.SystemStatus?
    private(set) var isConnected = false

    private(set) var isGenerating = false
    /// Latest streamed preview frame while generating.
    private(set) var streamingFrame: UIImage?
    private(set) var streamingProgress: (index: Int, total: Int)?
    private(set) var generationStartedAt: Date?
    /// Transient error banner text; cleared on the next generate.
    var lastError: String?

    // MARK: - Playback

    /// Clip currently shown in the preview player (nil = show keyframe).
    private(set) var selectedClipID: UUID?
    /// Temp-file URL of the selected clip's MP4 for AVPlayer.
    private(set) var playbackURL: URL?

    // MARK: - Private

    private let backendURL: URL
    private let tokenProvider: @Sendable () async throws -> String
    private let modelContext: ModelContext
    /// Availability relay so the coordinator's gallery/drawing gating stays
    /// current even when the update arrives on this socket.
    private let onAvailability: (StreamWebSocketClient.SystemStatus) -> Void

    private var client: StreamWebSocketClient?
    private var eventTasks: [Task<Void, Never>] = []
    private var reconnectTask: Task<Void, Never>?
    private var screenOpen = false
    private var inFlightRequestId: String?
    /// First decoded frame of the in-flight generation → clip thumbnail.
    private var firstStreamedFrame: UIImage?
    private var playbackTempURL: URL?

    init(
        backendURL: URL,
        modelContext: ModelContext,
        tokenProvider: @escaping @Sendable () async throws -> String,
        onAvailability: @escaping (StreamWebSocketClient.SystemStatus) -> Void = { _ in }
    ) {
        self.backendURL = backendURL
        self.modelContext = modelContext
        self.tokenProvider = tokenProvider
        self.onAvailability = onAvailability
        // Restore the persisted setup (didSet observers don't run for
        // default values, so read explicitly).
        if let saved = UserDefaults.standard.string(forKey: "animatePrompt") {
            prompt = saved
        }
        let savedDuration = UserDefaults.standard.integer(forKey: "animateDurationSeconds")
        if Self.durationOptions.contains(savedDuration) {
            durationSeconds = savedDuration
        }
    }

    // MARK: - Screen lifecycle

    /// Called when the Animate screen appears. Opens the WS (which registers
    /// warm-up interest with the backend's video pool) and starts listening.
    func screenDidAppear() {
        screenOpen = true
        connectIfNeeded()
        // Default the preview to the newest clip so the screen never opens
        // onto a blank pane when history exists and no keyframe is set.
        if selectedClipID == nil, startKeyframe == nil, let latest = fetchClips().first {
            select(latest)
        }
    }

    /// Called when the Animate screen disappears. Cancels any in-flight
    /// generation and closes the socket.
    func screenDidDisappear() {
        screenOpen = false
        if isGenerating { cancelGeneration() }
        teardownConnection()
    }

    // MARK: - Generation

    var canGenerate: Bool {
        startKeyframe != nil && !isGenerating && availability == .ready
    }

    func generate() {
        guard let start = startKeyframe else { return }
        guard !isGenerating else { return }
        lastError = nil
        let requestId = "anim-\(UUID().uuidString.prefix(8).lowercased())"
        inFlightRequestId = requestId
        firstStreamedFrame = nil
        streamingFrame = nil
        streamingProgress = nil
        isGenerating = true
        generationStartedAt = Date()
        // Show the start keyframe while waiting so the preview matches what
        // is being animated (instead of an old clip).
        selectedClipID = nil
        playbackURL = nil

        struct KeyframePayload: Encodable, Sendable {
            let data: String
            let position: Double
            let strength: Double?
        }
        struct AnimateRequestMessage: Encodable, Sendable {
            var type = "animate_request"
            let requestId: String
            let prompt: String
            let numFrames: Int
            let keyframes: [KeyframePayload]
        }

        var keyframes = [KeyframePayload(
            data: Self.keyframeB64(start), position: 0, strength: nil
        )]
        if let end = endKeyframe {
            keyframes.append(KeyframePayload(
                data: Self.keyframeB64(end), position: 1, strength: nil
            ))
        }
        let message = AnimateRequestMessage(
            requestId: requestId,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            numFrames: Self.frames(forSeconds: durationSeconds),
            keyframes: keyframes
        )
        Analytics.track(.animateRequested, properties: [
            "keyframes": keyframes.count,
            "duration_s": durationSeconds,
            "prompt_len": prompt.count,
        ])
        Log.info("animate.request", attributes: [
            "event": "animate.request",
            "request_id": requestId,
            "keyframes": keyframes.count,
            "num_frames": Self.frames(forSeconds: durationSeconds),
        ])
        Task { [client] in
            try? await client?.sendConfig(message)
        }
    }

    func cancelGeneration() {
        guard let requestId = inFlightRequestId else { return }
        struct CancelMessage: Encodable, Sendable {
            var type = "animate_cancel"
            let requestId: String
        }
        Task { [client] in
            try? await client?.sendConfig(CancelMessage(requestId: requestId))
        }
        // Optimistic reset — the server's video_cancelled ack is idempotent.
        finishGeneration()
    }

    // MARK: - Clips (history)

    func fetchClips() -> [AnimationClip] {
        let descriptor = FetchDescriptor<AnimationClip>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    /// Show a saved clip in the preview player.
    func select(_ clip: AnimationClip) {
        guard let data = clip.videoData else { return }
        cleanupPlaybackTemp()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-animate-\(clip.id.uuidString).mp4")
        do {
            try data.write(to: url, options: .atomic)
            playbackTempURL = url
            playbackURL = url
            selectedClipID = clip.id
        } catch {
            Log.error("animate.playback_write_failed", attributes: [
                "event": "animate.playback_write_failed",
            ])
        }
    }

    /// "Extend": load a clip's LAST frame as the next start keyframe so the
    /// next generation continues where this clip ended — chaining one-shot
    /// clips into a longer sequence. Keeps the clip's prompt (the motion
    /// usually continues), clears the end keyframe, and inherits the clip's
    /// source drawing for the per-drawing share/replay mirror.
    func extendFromLastFrame(of clip: AnimationClip) {
        guard let data = clip.videoData else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-animate-extend-\(clip.id.uuidString).mp4")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            lastError = "Couldn't read that clip — try another."
            return
        }
        let clipPrompt = clip.prompt
        let clipSource = clip.sourceDrawingID
        Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let asset = AVURLAsset(url: url)
                let duration = try await asset.load(.duration)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                // Exact-time request at (duration - one frame): the default
                // wide tolerance can snap back to a keyframe seconds earlier,
                // which would visibly "rewind" the continuation.
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = .zero
                let target = CMTime(
                    seconds: max(0, duration.seconds - (1.0 / 24.0)),
                    preferredTimescale: 600
                )
                let cgImage = try await generator.image(at: target).image
                await MainActor.run {
                    guard let self else { return }
                    self.startKeyframe = UIImage(cgImage: cgImage)
                    self.endKeyframe = nil
                    self.prompt = clipPrompt
                    self.sourceDrawingID = clipSource
                    // Show the new start frame, not the old clip.
                    self.selectedClipID = nil
                    self.playbackURL = nil
                    Log.info("animate.extend", attributes: ["event": "animate.extend"])
                }
            } catch {
                await MainActor.run {
                    self?.lastError = "Couldn't grab the last frame — try another clip."
                }
            }
        }
    }

    /// Restore a clip's inputs into the setup panel ("remix").
    func restoreInputs(from clip: AnimationClip) {
        prompt = clip.prompt
        if let data = clip.startKeyframeData { startKeyframe = UIImage(data: data) }
        endKeyframe = clip.endKeyframeData.flatMap { UIImage(data: $0) }
        durationSeconds = Self.durationOptions.min(by: {
            abs(Double($0) - clip.durationSeconds) < abs(Double($1) - clip.durationSeconds)
        }) ?? 6
        sourceDrawingID = clip.sourceDrawingID
    }

    func deleteClip(_ clip: AnimationClip) {
        if selectedClipID == clip.id {
            selectedClipID = nil
            playbackURL = nil
            cleanupPlaybackTemp()
        }
        modelContext.delete(clip)
        try? modelContext.save()
    }

    /// Temp-file URL for sharing a clip's MP4 (named for a nice share sheet).
    func exportURL(for clip: AnimationClip) -> URL? {
        guard let data = clip.videoData else { return nil }
        let stamp = clip.createdAt.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Kiki Animation \(stamp) \(clip.id.uuidString.prefix(4)).mp4")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Connection

    private func connectIfNeeded() {
        guard client == nil else { return }
        var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false)!
        components.scheme = backendURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/animate"
        components.queryItems = [
            URLQueryItem(name: "animateId", value: String(UUID().uuidString.prefix(8)).lowercased()),
        ]
        guard let wsURL = components.url else { return }
        let tokenProvider = self.tokenProvider
        Task { [weak self] in
            do {
                let token = try await tokenProvider()
                var request = URLRequest(url: wsURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue(AppCoordinator.clientTag, forHTTPHeaderField: "X-Kiki-Client")
                let client = StreamWebSocketClient(request: request)
                try await client.connect()
                await MainActor.run {
                    guard let self, self.screenOpen else {
                        Task { await client.disconnect() }
                        return
                    }
                    self.client = client
                    self.isConnected = true
                    self.startEventLoops(client: client)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    if let rejection = error as? ServerRejectedError {
                        self.lastError = rejection.message
                        // Structured deny (e.g. free_limit_reached) — don't
                        // hammer reconnects against a deterministic refusal.
                        return
                    }
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func startEventLoops(client: StreamWebSocketClient) {
        eventTasks.forEach { $0.cancel() }
        eventTasks = []
        eventTasks.append(Task { [weak self] in
            for await event in await client.videoEvents {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.handleVideoEvent(event) }
            }
        })
        eventTasks.append(Task { [weak self] in
            for await event in await client.connectionEvents {
                guard !Task.isCancelled else { return }
                if case .disconnected = event {
                    await MainActor.run { self?.handleDisconnect() }
                }
            }
        })
    }

    private func handleDisconnect() {
        isConnected = false
        client = nil
        eventTasks.forEach { $0.cancel() }
        eventTasks = []
        if isGenerating {
            finishGeneration()
            lastError = "Connection lost — try again."
        }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard screenOpen, reconnectTask == nil else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                guard self.screenOpen, self.client == nil else { return }
                self.connectIfNeeded()
            }
        }
    }

    private func teardownConnection() {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventTasks.forEach { $0.cancel() }
        eventTasks = []
        if let client {
            Task { await client.disconnect() }
        }
        client = nil
        isConnected = false
    }

    // MARK: - Event handling

    private func handleVideoEvent(_ event: StreamWebSocketClient.VideoEvent) {
        switch event {
        case .availability(_, let video):
            availability = Availability(rawValue: video.availability) ?? .off
            videoSystemStatus = video
            onAvailability(video)

        case .started(let requestId):
            if let requestId { inFlightRequestId = requestId }
            isGenerating = true

        case .frame(let requestId, let imageData, let index, let total):
            guard requestId == nil || requestId == inFlightRequestId else { return }
            guard let frame = UIImage(data: imageData) else { return }
            if firstStreamedFrame == nil { firstStreamedFrame = frame }
            streamingFrame = frame
            if let index, let total { streamingProgress = (index, total) }

        case .complete(let requestId, let mp4, let fps, let frames):
            guard requestId == nil || requestId == inFlightRequestId else { return }
            saveCompletedClip(mp4: mp4, fps: fps, frames: frames)
            finishGeneration()

        case .cancelled(let requestId, _, let error):
            guard requestId == nil || requestId == inFlightRequestId || inFlightRequestId == nil
            else { return }
            if isGenerating {
                finishGeneration()
            }
            if let error, error != "busy" {
                lastError = Self.friendlyError(error)
                Log.info("animate.cancelled", attributes: [
                    "event": "animate.cancelled",
                    "error": error,
                ])
            }
        }
    }

    private func saveCompletedClip(mp4: Data, fps: Int?, frames: Int?) {
        let clip = AnimationClip(
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            numFrames: frames ?? Self.frames(forSeconds: durationSeconds),
            fps: fps ?? 24,
            sourceDrawingID: sourceDrawingID
        )
        clip.startKeyframeData = startKeyframe?.jpegData(compressionQuality: 0.85)
        clip.endKeyframeData = endKeyframe?.jpegData(compressionQuality: 0.85)
        clip.videoData = mp4
        clip.thumbnailData = (firstStreamedFrame ?? startKeyframe)?
            .jpegData(compressionQuality: 0.7)
        modelContext.insert(clip)
        try? modelContext.save()

        // Mirror onto the source drawing's stored animation so the existing
        // per-drawing share ("Animation (MP4)") and speed-paint replay tail
        // keep working with Animate-screen outputs.
        if let drawingID = sourceDrawingID {
            try? RecordingStore.shared.saveGeneratedVideo(mp4, for: drawingID)
        }

        select(clip)
        Analytics.track(.animateCompleted, properties: [
            "bytes": mp4.count,
            "frames": frames ?? -1,
            "wait_ms": generationStartedAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1,
        ])
        Log.info("animate.completed", attributes: [
            "event": "animate.completed",
            "bytes": mp4.count,
        ])
    }

    private func finishGeneration() {
        isGenerating = false
        inFlightRequestId = nil
        streamingFrame = nil
        streamingProgress = nil
        generationStartedAt = nil
    }

    private func cleanupPlaybackTemp() {
        if let url = playbackTempURL {
            try? FileManager.default.removeItem(at: url)
            playbackTempURL = nil
        }
    }

    // MARK: - Helpers

    /// LTX frame counts must satisfy (n-1) % 8 == 0 at 24 fps.
    static func frames(forSeconds seconds: Int) -> Int {
        switch seconds {
        case 2: return 49
        case 4: return 97
        default: return 145
        }
    }

    /// Downscale to ≤1024px and JPEG-encode for the request payload (the
    /// video model runs at 512² — full-res uploads are pure overhead).
    static func keyframeB64(_ image: UIImage) -> String {
        let maxSide: CGFloat = 1024
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height, 1))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let resized: UIImage
        if scale < 1 {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 1
            resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
            }
        } else {
            resized = image
        }
        return resized.jpegData(compressionQuality: 0.85)?.base64EncodedString() ?? ""
    }

    static func friendlyError(_ code: String) -> String {
        switch code {
        case "video_unavailable": return "Animation isn't available right now — try again in a minute."
        case "video_instance_lost": return "The animation server restarted — try again."
        case "no_image": return "Add a keyframe first."
        case "invalid_image", "invalid_keyframe": return "That image couldn't be used — try another."
        case "keyframe_too_large": return "That image is too large — try another."
        default: return "Animation failed — try again."
        }
    }
}

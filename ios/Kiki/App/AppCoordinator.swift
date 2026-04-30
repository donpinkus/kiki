import SwiftUI
import SwiftData
import os
import Sentry
import CanvasModule
import NetworkModule
import ResultModule

private let streamLog = Logger(subsystem: "com.kiki.app", category: "StreamCoordinator")

enum DrawingTool: String, CaseIterable, Hashable {
    case brush
    case eraser
    case lasso
}

enum AppScreen: Equatable {
    case signIn
    case gallery
    case drawing

    var analyticsName: String {
        switch self {
        case .signIn: return "SignIn"
        case .gallery: return "Gallery"
        case .drawing: return "Drawing"
        }
    }
}

enum DrawingLayout: String, CaseIterable {
    case splitScreen, fullscreen
}

@MainActor
@Observable
final class AppCoordinator {

    // MARK: - Navigation

    var currentScreen: AppScreen = .gallery {
        didSet {
            guard currentScreen != oldValue else { return }
            Analytics.screen(currentScreen.analyticsName)
        }
    }
    var currentDrawingId: UUID?

    // MARK: - Persistence

    private let modelContext: ModelContext
    private var isSuppressingObservation = false
    private var saveDebounceTask: Task<Void, Never>?

    // MARK: - UI State

    var currentTool: DrawingTool = .brush {
        didSet {
            if canvasViewModel.hasLassoSelection {
                if oldValue == .lasso && currentTool != .lasso {
                    // Phase A → Phase B: commit floating selection, keep clip mask
                    // visible. Brush/eraser strokes are now clipped to the lasso region.
                    canvasViewModel.transitionToClipMode()
                }
                // Switching back to lasso or between pen/eraser: clip mask persists.
                // User must explicitly clear it via "Clear Lasso" button.
            }
            // Stash the outgoing tool's size/opacity and load the incoming tool's.
            swapToolValues(from: oldValue, to: currentTool)
            applyTool()
        }
    }
    var toolSize: CGFloat = 15.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    var toolOpacity: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }

    // MARK: - Per-tool stored settings

    /// While true, toolSize / toolOpacity didSet should skip applyTool()
    /// (used when swapping values on a tool change).
    private var isSwappingToolValues = false
    private var storedToolSizes: [DrawingTool: CGFloat] = [
        .brush: 15,
        .eraser: 25,
        .lasso: 5
    ]
    private var storedToolOpacities: [DrawingTool: CGFloat] = [
        .brush: 1.0,
        .eraser: 1.0,
        .lasso: 1.0
    ]

    private func swapToolValues(from oldTool: DrawingTool, to newTool: DrawingTool) {
        guard oldTool != newTool else { return }
        storedToolSizes[oldTool] = toolSize
        storedToolOpacities[oldTool] = toolOpacity
        isSwappingToolValues = true
        toolSize = storedToolSizes[newTool] ?? toolSize
        toolOpacity = storedToolOpacities[newTool] ?? toolOpacity
        isSwappingToolValues = false
    }
    var currentColor: Color = .black {
        didSet { applyTool() }
    }
    var promptText = "" {
        didSet {
            if !isSuppressingObservation {
                scheduleSave()
                if promptText != oldValue {
                    Analytics.track(.promptChanged, properties: ["prompt_length": promptText.count])
                }
            }
            syncStreamConfig()
        }
    }
    var selectedStyle: PromptStyle = .default {
        didSet {
            if !isSuppressingObservation {
                scheduleSave()
                if selectedStyle.id != oldValue.id {
                    Analytics.track(.styleSelected, properties: ["style_id": selectedStyle.id])
                }
            }
            syncStreamConfig()
        }
    }
    var showStylePicker = false {
        didSet {
            guard showStylePicker != oldValue else { return }
            if showStylePicker {
                enterStylePreviewMode()
            } else {
                exitStylePreviewMode()
            }
        }
    }
    var showLayerPanel = false
    var resultState: ResultState = .empty
    var dividerPosition: CGFloat = 0.5
    var showFloatingPanel = false
    var canvasOnTop = false
    var generationError: String?

    /// One-time NUX tooltip for QuickShape. Set true on first successful snap;
    /// DrawingView observes this and auto-clears it after 5s. AppStorage flag
    /// in DrawingView ensures we only show it once per device, ever.
    var shouldShowQuickShapeTooltip: Bool = false

    // MARK: - Layout

    var drawingLayout: DrawingLayout = .splitScreen {
        didSet { UserDefaults.standard.set(drawingLayout.rawValue, forKey: "drawingLayout") }
    }

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    let stylePreviewController = StylePreviewController()
    private let backendURL: URL
    private let authService: AuthService

    // MARK: - Auth

    var signedInUserId: String?

    // MARK: - Stream State

    private var streamWasActiveBeforeBackground = false
    private var streamSession: StreamSession?
    /// Sentry transaction measuring user-perceived spin-up (tap → first frame).
    /// Started in `startStream`, finished on first `onImageReceived` callback.
    private var pendingStartupTransaction: (any Span)?
    /// Timestamp when the current stream startup began. Paired with first-frame
    /// arrival to emit PostHog's `stream.first_frame` with a waitMs property.
    private var streamStartupBeganAt: Date?
    /// When the user entered the current drawing. Used to compute session
    /// duration for the `drawing.closed` analytics event. Set in
    /// `openDrawing`/`newDrawing`, read + cleared in `navigateToGallery`.
    private var currentDrawingOpenedAt: Date?
    private(set) var streamReadiness: StreamSession.StreamReadiness = .disconnected

    /// Currently-playing video MP4 temp path. Tracked so we can delete it
    /// when the user resumes drawing (state leaves video) and avoid
    /// littering NSTemporaryDirectory across many idle/draw cycles.
    private var currentVideoMP4URL: URL?
    private(set) var streamFrameCount = 0

    // -- Stream parameters --

    /// Number of inference steps.
    var streamSteps: Int = 4 { didSet { syncStreamConfig() } }

    /// Fixed seed (nil = server picks a stable per-session seed).
    var streamSeed: Int? { didSet { syncStreamConfig() } }

    /// LTX-2.3 video override — square resolution (px). Session-only by design:
    /// not @AppStorage, so each app launch resets to the perf baseline (320).
    /// Step 3.5 benchmark needs deterministic baselines per launch.
    var videoResolution: Int = 320 { didSet { syncStreamConfig() } }

    /// LTX-2.3 video override — frame count. Session-only (see `videoResolution`).
    var videoFrames: Int = 49 { didSet { syncStreamConfig() } }

    /// LTX-2.3 diagnostic — when true, every video request triggers a
    /// `torch.profiler` capture on the pod (Chrome trace JSON + summary
    /// txt + meta JSON written to `/tmp/ltx-profile-*` for SCP-out).
    /// Adds ~15–25% latency to each request while on. Session-only:
    /// resets to false on each app launch so we never accidentally
    /// ship profiled performance to a real test.
    var enableProfiling: Bool = false { didSet { syncStreamConfig() } }

    /// Capture FPS for stream mode.
    var streamCaptureFPS: Double = 5 {
        didSet { streamSession?.captureInterval = 1.0 / streamCaptureFPS }
    }

    // MARK: - Private State

    private var lastSuccessfulImage: UIImage?
    private var canvasObservationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(
        modelContext: ModelContext,
        backendURL: URL = URL(string: "https://kiki-backend-production-eb81.up.railway.app")!
    ) {
        self.modelContext = modelContext
        self.backendURL = backendURL
        self.authService = AuthService(backendURL: backendURL)

        if let stored = UserDefaults.standard.string(forKey: "drawingLayout"),
           let layout = DrawingLayout(rawValue: stored) {
            self.drawingLayout = layout
        }

        // Gate on auth: if no Keychain token, show sign-in. Otherwise the
        // normal gallery/drawing flow resumes.
        let initialUserId = KeychainStore.default.get("userId")
        let initialEmail = KeychainStore.default.get("email")
        self.signedInUserId = initialUserId
        if initialUserId == nil {
            currentScreen = .signIn
        } else {
            // Re-bind analytics identity on every relaunch of an already-signed-in
            // user. `signInWithApple()` is the only other place `identify` fires,
            // but it only runs on a fresh sign-in — so without this call, returning
            // users stay bound to their anonymous device ID forever and iOS events
            // never stitch to the backend-emitted userId.
            Analytics.identify(userId: initialUserId!, email: initialEmail)

            // If no drawings exist, go directly to a new drawing
            let descriptor = FetchDescriptor<Drawing>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            let count = (try? modelContext.fetchCount(descriptor)) ?? 0
            if count == 0 {
                let drawing = Drawing()
                modelContext.insert(drawing)
                try? modelContext.save()
                currentDrawingId = drawing.id
                currentScreen = .drawing
            }
        }

        applyTool()
        startObservingCanvas()

        // Pre-warm the GPU pod as soon as the app launches with a signed-in
        // user. ~90s cold start otherwise dominates time-to-first-image and
        // makes the app look broken to App Review and first-time users.
        if signedInUserId != nil {
            startStream()
            seedResultStateForCurrentDrawing()
        }

        // Eyedropper: commit picked colors to currentColor
        canvasViewModel.onColorPicked = { [weak self] uiColor in
            self?.currentColor = Color(uiColor: uiColor)
        }
        // Supply the current brush color to the canvas ring preview
        canvasViewModel.currentBrushColorProvider = { [weak self] in
            UIColor(self?.currentColor ?? .black)
        }
        // Auto-resume after idle timeout: any stroke fires this, and if the
        // session is paused we kick a fresh provision without requiring the
        // user to navigate or tap an overlay.
        canvasViewModel.onUserActivity = { [weak self] in
            self?.handleUserActivity()
        }
        // QuickShape telemetry — forward recognizer lifecycle events to PostHog.
        canvasViewModel.onSnapEvent = { event in
            Self.trackSnapEvent(event)
        }
        // QuickShape NUX tooltip — observed by DrawingView via @Observable.
        canvasViewModel.onFirstBrushStrokeCommitted = { [weak self] in
            self?.shouldShowQuickShapeTooltip = true
        }
    }

    /// Translate a SnapEvent into a typed Analytics call. Property keys are
    /// snake_case to match the rest of our event schema.
    private static func trackSnapEvent(_ event: SnapEvent) {
        switch event {
        case .committed(let info):
            Analytics.track(.strokeSnapCommitted, properties: [
                "verdict": info.verdict,
                "confidence": info.confidence,
                "stroke_duration_sec": info.strokeDurationSec,
                "path_length": Double(info.snapshot.pathLength),
                "bbox_diagonal": Double(info.snapshot.bboxDiagonal),
                "sagitta_ratio": Double(info.snapshot.sagittaRatio),
                "signed_turn_deg": Double(info.snapshot.totalSignedTurnDeg),
                "abs_turn_deg": Double(info.snapshot.totalAbsTurnDeg),
                "line_norm_rms": Double(info.snapshot.lineNormRMS),
                "resampled_n": info.snapshot.resampledPointCount,
                "line_score": Double(info.snapshot.lineScore),
            ])
        case .abstained(let info):
            var props: [String: Any] = [
                "reason": info.reason,
                "confidence": info.confidence,
            ]
            if let s = info.snapshot {
                props["path_length"] = Double(s.pathLength)
                props["bbox_diagonal"] = Double(s.bboxDiagonal)
                props["sagitta_ratio"] = Double(s.sagittaRatio)
                props["signed_turn_deg"] = Double(s.totalSignedTurnDeg)
                props["abs_turn_deg"] = Double(s.totalAbsTurnDeg)
                props["line_norm_rms"] = Double(s.lineNormRMS)
                props["resampled_n"] = s.resampledPointCount
                props["line_score"] = Double(s.lineScore)
            }
            Analytics.track(.strokeSnapAbstained, properties: props)
        case .undoneWithin2s(let info):
            var props: [String: Any] = [
                "original_verdict": info.originalVerdict,
                "elapsed_sec": info.elapsedSec,
            ]
            if let s = info.snapshot {
                props["sagitta_ratio"] = Double(s.sagittaRatio)
                props["signed_turn_deg"] = Double(s.totalSignedTurnDeg)
                props["line_norm_rms"] = Double(s.lineNormRMS)
                props["line_score"] = Double(s.lineScore)
            }
            Analytics.track(.strokeSnapUndoneWithin2s, properties: props)
        case .previewCanceled(let info):
            Analytics.track(.strokeSnapPreviewCanceled, properties: [
                "reason": info.reason,
            ])
        }
    }

    // MARK: - Auth

    /// Exchange an Apple identity token for a backend JWT pair, then navigate
    /// to the main app. Called from SignInView.
    func signInWithApple(identityToken: String) async throws {
        let transaction = SentrySDK.startTransaction(name: "auth.signIn", operation: "auth.signIn")
        do {
            try await authService.signInWithApple(identityToken: identityToken, nonce: nil)
            transaction.finish()
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "signInWithApple", key: "op")
            }
            transaction.finish(status: .internalError)
            throw error
        }
        let userId = await authService.userId
        let email = await authService.email
        await MainActor.run {
            self.signedInUserId = userId
            if let userId {
                Analytics.identify(userId: userId, email: email)
                Analytics.track(.userSignedIn, properties: ["user_id": userId])
            }

            // After sign-in, route to gallery (or create a new drawing if none exist).
            let descriptor = FetchDescriptor<Drawing>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            let count = (try? self.modelContext.fetchCount(descriptor)) ?? 0
            if count == 0 {
                let drawing = Drawing()
                self.modelContext.insert(drawing)
                try? self.modelContext.save()
                self.currentDrawingId = drawing.id
                self.currentScreen = .drawing
            } else {
                self.currentScreen = .gallery
            }

            // Kick off pod provisioning immediately so the user isn't waiting
            // for ~90s of cold start when they tap into a drawing.
            self.startStream()
            self.seedResultStateForCurrentDrawing()
        }
    }

    func signOut() {
        Task {
            // Ask the backend to terminate the pod and delete the session row
            // BEFORE clearing the JWT. Best-effort — never throws. Without
            // this, the pod leaks for ~10 min until the idle reaper catches it.
            await authService.requestServerSignOut()
            await authService.signOut()
            await MainActor.run {
                Analytics.track(.userSignedOut)
                Analytics.reset()
                self.signedInUserId = nil
                self.currentScreen = .signIn
                self.stopStream()
            }
        }
    }

    // MARK: - Actions

    func undo() {
        if canvasViewModel.hasLassoSelection {
            canvasViewModel.cancelLassoSelection()
            return
        }
        canvasViewModel.undo()
    }

    func redo() {
        canvasViewModel.redo()
    }

    func clear() {
        canvasViewModel.clear()
    }

    func swapStreamImageToCanvas() {
        guard let image = lastSuccessfulImage else { return }
        canvasViewModel.swapLineart(image: image)
    }

    /// True when a generated frame is available to send to the canvas.
    var canSwapStreamImageToCanvas: Bool {
        lastSuccessfulImage != nil
    }

    // MARK: - Gallery / Persistence

    func newDrawing() {
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        isSuppressingObservation = true

        // Generate a stable seed for this drawing
        let seed = Int.random(in: 0...Int(UInt32.max))
        let drawing = Drawing(streamSeed: seed)
        modelContext.insert(drawing)
        try? modelContext.save()
        currentDrawingId = drawing.id
        currentDrawingOpenedAt = Date()

        // Reset all state
        promptText = ""
        selectedStyle = .default
        streamSeed = seed
        lastSuccessfulImage = nil
        showFloatingPanel = false

        canvasViewModel.setPendingState(nil)

        currentScreen = .drawing
        isSuppressingObservation = false

        Analytics.track(.drawingCreated, properties: ["drawing_id": drawing.id.uuidString])
        Analytics.track(.drawingOpened, properties: [
            "drawing_id": drawing.id.uuidString,
            "stroke_count": 0,
            "is_new": true,
        ])

        startStream()
        seedResultStateForCurrentDrawing()
    }

    func openDrawing(_ drawing: Drawing) {
        isSuppressingObservation = true

        currentDrawingId = drawing.id
        currentDrawingOpenedAt = Date()

        // Restore settings
        promptText = drawing.promptText
        selectedStyle = PromptStyle.from(id: drawing.styleId)
        streamSeed = drawing.streamSeed

        // Restore generated image
        if let imgData = drawing.generatedImageData {
            lastSuccessfulImage = UIImage(data: imgData)
        } else {
            lastSuccessfulImage = nil
        }
        showFloatingPanel = lastSuccessfulImage != nil

        // Prepare canvas state
        canvasViewModel.setPendingState(CanvasState(
            drawingData: drawing.drawingData ?? Data(),
            backgroundImageData: drawing.backgroundImageData
        ))

        currentScreen = .drawing
        isSuppressingObservation = false

        Analytics.track(.drawingOpened, properties: [
            "drawing_id": drawing.id.uuidString,
            "has_background_image": drawing.backgroundImageData != nil,
            "has_generated_image": drawing.generatedImageData != nil,
            "is_new": false,
        ])

        startStream()
        seedResultStateForCurrentDrawing()
    }

    func navigateToGallery() {
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        // Emit drawing.closed before we clear the id.
        if let drawingId = currentDrawingId, let openedAt = currentDrawingOpenedAt {
            let sessionMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            Analytics.track(.drawingClosed, properties: [
                "drawing_id": drawingId.uuidString,
                "session_duration_ms": sessionMs,
                "generation_count": streamFrameCount,
            ])
        }
        currentDrawingOpenedAt = nil

        // Delete empty drawings
        if let drawingId = currentDrawingId {
            let id = drawingId
            var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let drawing = try? modelContext.fetch(descriptor).first, drawing.isContentEmpty {
                modelContext.delete(drawing)
                try? modelContext.save()
            }
        }

        stopStream()
        currentDrawingId = nil

        // Track gallery navigation with current drawing count.
        let descriptor = FetchDescriptor<Drawing>()
        let drawingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        Analytics.track(.galleryOpened, properties: ["drawing_count": drawingCount])

        currentScreen = .gallery
    }

    func deleteDrawing(_ drawing: Drawing) {
        modelContext.delete(drawing)
        try? modelContext.save()

        let descriptor = FetchDescriptor<Drawing>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        if count == 0 {
            newDrawing()
        }
    }

    func saveCurrentDrawing() {
        guard !isSuppressingObservation else { return }
        guard let drawingId = currentDrawingId else { return }
        guard canvasViewModel.exportDrawingData() != nil else { return }

        let id = drawingId
        var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let drawing = try? modelContext.fetch(descriptor).first else { return }

        drawing.drawingData = canvasViewModel.exportDrawingData()
        drawing.backgroundImageData = canvasViewModel.exportBackgroundImageData()
        drawing.generatedImageData = lastSuccessfulImage?.jpegData(compressionQuality: 0.85)
        drawing.canvasThumbnailData = canvasViewModel.generateThumbnail()?.jpegData(compressionQuality: 0.7)
        drawing.promptText = promptText
        drawing.styleId = selectedStyle.id
        drawing.streamSeed = streamSeed

        drawing.updatedAt = Date()
        try? modelContext.save()

        Analytics.track(.drawingSaved, properties: [
            "drawing_id": drawing.id.uuidString,
            "has_background_image": drawing.backgroundImageData != nil,
            "has_generated_image": drawing.generatedImageData != nil,
            "style_id": selectedStyle.id,
        ])
    }

    private func scheduleSave() {
        guard currentDrawingId != nil else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            saveCurrentDrawing()
        }
    }

    // MARK: - Canvas Observation

    private func startObservingCanvas() {
        canvasObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in canvasViewModel.canvasChanges {
                guard !Task.isCancelled else { return }
                guard !isSuppressingObservation else { continue }
                guard !canvasViewModel.isEmpty else { continue }
                scheduleSave()
            }
        }
    }

    // MARK: - Stream

    private func startStream() {
        // Idempotent: if a session is already running (e.g. pre-warmed at app
        // launch), just push the latest config and return. The capture loop
        // will pick up the new prompt/seed before the next frame.
        if streamSession != nil {
            streamLog.info("startStream: session already running, syncing config only — readiness=\(String(describing: self.streamReadiness))")
            let crumb = Breadcrumb()
            crumb.category = "stream.lifecycle"
            crumb.message = "startStream noop (already running)"
            crumb.data = ["readiness": String(describing: streamReadiness)]
            SentrySDK.addBreadcrumb(crumb)
            syncStreamConfig()
            return
        }

        // Transaction captures user-perceived spin-up latency: from this call
        // through pod provisioning to first frame received. `StreamSession`
        // finishes it via the `onImageReceived` first-frame detection below.
        let startupTx = SentrySDK.startTransaction(name: "app.stream.startup", operation: "app.stream.startup")
        self.pendingStartupTransaction = startupTx
        self.streamStartupBeganAt = Date()

        // Per-startStream UUID — joins this attempt across iOS Sentry events
        // and backend Railway logs. One streamId may correspond to N backend
        // connIds if the StreamSession internally reconnects. Search by
        // streamId for the whole user attempt; by connId for one WS upgrade.
        let streamId = String(UUID().uuidString.prefix(8)).lowercased()
        SentrySDK.configureScope { $0.setTag(value: streamId, key: "streamId") }

        var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false)!
        components.scheme = backendURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/stream"
        components.queryItems = [URLQueryItem(name: "streamId", value: streamId)]
        guard let wsURL = components.url else {
            streamLog.error("Failed to construct WebSocket URL from \(self.backendURL.absoluteString)")
            SentrySDK.capture(message: "stream.startup: failed to construct WebSocket URL") { scope in
                scope.setLevel(.error)
                scope.setTag(value: self.backendURL.absoluteString, key: "backendURL")
            }
            startupTx.finish(status: .internalError)
            self.pendingStartupTransaction = nil
            return
        }

        streamLog.info("Starting stream to \(wsURL.absoluteString)")
        let startCrumb = Breadcrumb()
        startCrumb.category = "stream.lifecycle"
        startCrumb.message = "Starting stream"
        startCrumb.data = ["wsURL": wsURL.absoluteString]
        SentrySDK.addBreadcrumb(startCrumb)
        Analytics.track(.streamStarted, properties: [
            "drawing_id": currentDrawingId?.uuidString ?? "unknown",
        ])

        // Kick off the async flow to fetch a fresh access token, then connect.
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authService.currentAccessToken()
                var request = URLRequest(url: wsURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                await MainActor.run {
                    self.startStreamSession(request: request, backendWsURL: wsURL)
                }
            } catch {
                await MainActor.run {
                    streamLog.error("Auth token fetch failed: \(error.localizedDescription)")
                    SentrySDK.capture(error: error) { scope in
                        scope.setTag(value: "stream.authTokenFetch", key: "op")
                    }
                    startupTx.finish(status: .unauthenticated)
                    self.pendingStartupTransaction = nil
                    self.streamReadiness = .failed(message: "Please sign in again")
                    self.generationError = "Please sign in again"
                    self.signOut()
                }
            }
        }
    }

    @MainActor
    private func startStreamSession(request: URLRequest, backendWsURL: URL) {
        let session = StreamSession(
            request: request,
            canvasViewModel: canvasViewModel,
            config: buildStreamConfig()
        )
        session.captureInterval = 1.0 / streamCaptureFPS

        session.onImageReceived = { [weak self] image in
            guard let self else { return }
            self.streamFrameCount += 1
            self.lastSuccessfulImage = image
            // Resuming img2img clobbers any in-flight video state. Drop the
            // looping MP4 from disk now — otherwise NSTemporaryDirectory
            // accumulates one file per draw/idle cycle until stopStream.
            if let prior = self.currentVideoMP4URL {
                try? FileManager.default.removeItem(at: prior)
                self.currentVideoMP4URL = nil
            }
            self.resultState = .streaming(image: image, frameCount: self.streamFrameCount)
            if self.drawingLayout == .fullscreen {
                self.showFloatingPanel = true
            }

            let count = self.streamFrameCount
            if count == 1 {
                // First generated frame — user-perceived spin-up complete.
                self.pendingStartupTransaction?.finish()
                self.pendingStartupTransaction = nil
                if let startedAt = self.streamStartupBeganAt {
                    let waitMs = Int(Date().timeIntervalSince(startedAt) * 1000)
                    Analytics.track(.streamFirstFrame, properties: ["wait_ms": waitMs])
                }
                self.streamStartupBeganAt = nil
            }
        }

        session.onReadinessChanged = { [weak self] readiness in
            guard let self else { return }
            streamLog.info("Readiness changed: \(String(describing: readiness))")
            self.streamReadiness = readiness
            if case .failed(let message) = readiness {
                self.generationError = message
                // End startup transaction with failure status if we never got a frame.
                self.pendingStartupTransaction?.finish(status: .internalError)
                self.pendingStartupTransaction = nil
                let elapsedMs = self.streamStartupBeganAt.map {
                    Int(Date().timeIntervalSince($0) * 1000)
                } ?? 0
                Analytics.track(.streamFailed, properties: [
                    "message": message,
                    "elapsed_ms": elapsedMs,
                    "frames_received": self.streamFrameCount,
                    "got_first_frame": self.streamFrameCount > 0,
                ])
            }
            self.applyReadinessToResultState(readiness)
        }

        session.onVideoEvent = { [weak self] event in
            guard let self else { return }
            self.handleVideoEvent(event)
        }

        self.streamSession = session

        Task {
            await session.start()
        }
    }

    /// Public entry point for resuming a paused/idle session. Used by:
    ///   • The right-pane "Session paused" overlay (tap target)
    ///   • Stroke-triggered auto-resume (canvas onUserActivity)
    /// Tears down the existing (stopped) session and starts a fresh one. The
    /// `startStream()` early-return on `streamSession != nil` would otherwise
    /// no-op, since the session is technically present but stopped.
    func resumeStream() {
        if streamSession != nil {
            streamLog.info("Resume requested — tearing down stopped session")
            streamSession?.stop()
            streamSession = nil
        }
        startStream()
    }

    /// Called whenever the user starts a canvas stroke. If the session is
    /// idle-timed-out, this auto-resumes — no need to navigate or tap.
    fileprivate func handleUserActivity() {
        if case .idleTimeout = streamReadiness {
            streamLog.info("User activity detected during idle timeout — resuming stream")
            resumeStream()
        }
    }

    private func stopStream() {
        let hadSession = streamSession != nil
        let finalFrameCount = streamFrameCount
        streamLog.info("Stopping stream")
        // Clear streamId tag so post-stream events (e.g. an unrelated crash
        // 10 min later) aren't mis-tagged with this stream's id.
        SentrySDK.configureScope { $0.removeTag(key: "streamId") }
        streamSession?.stop()
        streamSession = nil
        streamReadiness = .disconnected
        streamFrameCount = 0
        // If we're stopping before first frame, mark the startup tx as cancelled.
        pendingStartupTransaction?.finish(status: .cancelled)
        pendingStartupTransaction = nil
        streamStartupBeganAt = nil
        // Clean up the looping MP4 temp file (if any) so we don't leave
        // junk in NSTemporaryDirectory across many sessions.
        if let url = currentVideoMP4URL {
            try? FileManager.default.removeItem(at: url)
            currentVideoMP4URL = nil
        }

        if hadSession {
            Analytics.track(.streamEnded, properties: [
                "frames_received": finalFrameCount,
                "reason": "stopped",
            ])
        }

        resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
    }

    /// Direct map from stream readiness to `resultState`. The single rule:
    /// `.ready` shows the bottom-left badge over a preview/streaming image;
    /// every other readiness state shows the corresponding overlay, with
    /// `lastSuccessfulImage` dimmed underneath when one exists.
    private func applyReadinessToResultState(_ readiness: StreamSession.StreamReadiness) {
        switch readiness {
        case .disconnected:
            resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        case .warming(let message, let startedAt):
            // `startedAt` is server-authoritative (orchestrator's session.createdAt
            // threaded through state events), so the progress bar reflects the
            // real pod-warm-cycle origin even after gallery↔drawing nav.
            resultState = .provisioning(
                message: message,
                startedAt: startedAt,
                previousImage: lastSuccessfulImage
            )
        case .ready:
            // Pod is genuinely ready; the first frame will move us to
            // `.streaming`. Show preview (or empty) until then.
            resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        case .failed(let msg):
            streamLog.error("Stream failed: \(msg)")
            resultState = .error(message: msg, previousImage: lastSuccessfulImage)
        case .idleTimeout:
            resultState = .idleTimeout(previousImage: lastSuccessfulImage)
        }
    }

    /// Seed `resultState` when entering a drawing so the result pane reflects
    /// any pre-warming already in progress, instead of momentarily flashing
    /// empty.
    private func seedResultStateForCurrentDrawing() {
        applyReadinessToResultState(streamReadiness)
    }

    /// Map a video pod event into ResultState transitions. Overall flow:
    ///   .streaming → .videoStreaming(latestFrame) → .videoLooping(mp4) → ...
    /// New img2img frames automatically clobber the video state via
    /// onImageReceived's `.streaming` set, so cancellation of an in-flight
    /// video on resume-drawing happens implicitly. The .cancelled event
    /// here covers the case where the pod aborted before any image
    /// arrived (e.g. during model warmup).
    private func handleVideoEvent(_ event: StreamWebSocketClient.VideoEvent) {
        let prev = String(describing: resultState).prefix(40)
        switch event {
        case .frame(_, let imageData, let index, let total):
            guard let frame = UIImage(data: imageData),
                  let fallback = lastSuccessfulImage else {
                streamLog.warning("[result] video_frame ignored (no fallback or decode failed)")
                return
            }
            resultState = .videoStreaming(latestFrame: frame, fallback: fallback)
            streamLog.info("[result] \(prev) → videoStreaming index=\(index ?? -1)/\(total ?? -1)")
        case .complete(_, let mp4Data, _, let frames):
            guard let fallback = lastSuccessfulImage else { return }
            // Clean up any prior MP4 we wrote — only one in flight at a time.
            if let prior = currentVideoMP4URL {
                try? FileManager.default.removeItem(at: prior)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("kiki-video-\(UUID().uuidString).mp4")
            do {
                try mp4Data.write(to: url, options: .atomic)
                currentVideoMP4URL = url
                resultState = .videoLooping(mp4URL: url, fallback: fallback)
                streamLog.info("[result] \(prev) → videoLooping bytes=\(mp4Data.count) frames=\(frames ?? -1)")
            } catch {
                streamLog.error("[result] mp4 write failed: \(error.localizedDescription)")
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "video.mp4_write", key: "op")
                }
            }
        case .cancelled(_, let atStep, let error):
            // If we're not currently in a video state, nothing to revert
            // (img2img already drove us out). Otherwise pop back to
            // .streaming on the last image.
            if resultState.isVideo, let img = lastSuccessfulImage {
                resultState = .streaming(image: img, frameCount: streamFrameCount)
            }
            if let prior = currentVideoMP4URL {
                try? FileManager.default.removeItem(at: prior)
                currentVideoMP4URL = nil
            }
            streamLog.info("[result] video_cancelled atStep=\(atStep ?? -1) err=\(error ?? "")")
        }
    }

    /// Push the current config to the stream session. The capture loop will
    /// detect the change and send it to the server before the next frame.
    private func syncStreamConfig() {
        streamSession?.config = buildStreamConfig()
    }

    // MARK: - Style Preview

    private func enterStylePreviewMode() {
        stylePreviewController.reset()

        guard let session = streamSession else {
            // No live pod; show all tiles as failed so they don't shimmer forever.
            stylePreviewController.markAllFailed(styles: PromptStyle.allStyles)
            return
        }
        guard let jpeg = session.captureFrameJPEG() else {
            stylePreviewController.markAllFailed(styles: PromptStyle.allStyles)
            return
        }

        session.enterPreviewMode()
        stylePreviewController.start(
            canvasJPEG: jpeg,
            basePrompt: promptText,
            steps: streamSteps,
            seed: streamSeed,
            styles: PromptStyle.allStyles,
            session: session
        )
    }

    private func exitStylePreviewMode() {
        stylePreviewController.cancel()
        streamSession?.exitPreviewMode()
    }

    // MARK: - App Lifecycle

    func handleScenePhaseChange(_ phase: ScenePhase) {
        let phaseName: String
        switch phase {
        case .background: phaseName = "background"
        case .active: phaseName = "active"
        case .inactive: phaseName = "inactive"
        @unknown default: phaseName = "unknown"
        }
        let crumb = Breadcrumb()
        crumb.category = "app.scenePhase"
        crumb.message = "scenePhase=\(phaseName)"
        crumb.data = [
            "phase": phaseName,
            "hasSession": streamSession != nil,
            "screen": currentScreen.analyticsName,
            "wasActiveBeforeBackground": streamWasActiveBeforeBackground,
            "readiness": String(describing: streamReadiness),
        ]
        SentrySDK.addBreadcrumb(crumb)
        streamLog.info("scenePhase=\(phaseName) hasSession=\(self.streamSession != nil) screen=\(self.currentScreen.analyticsName) wasActiveBeforeBg=\(self.streamWasActiveBeforeBackground)")

        switch phase {
        case .background:
            if streamSession != nil {
                streamWasActiveBeforeBackground = true
                stopStream()
            }
        case .active:
            if streamWasActiveBeforeBackground
                && currentScreen == .drawing
                && streamSession == nil {
                streamWasActiveBeforeBackground = false
                streamLog.info("scenePhase=active → restarting stream after background")
                startStream()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func buildStreamConfig() -> StreamConfig {
        StreamConfig(
            prompt: composedPrompt,
            steps: streamSteps,
            seed: streamSeed,
            videoWidth: videoResolution,
            videoHeight: videoResolution,
            videoFrames: videoFrames,
            enableProfiling: enableProfiling
        )
    }

    // MARK: - Private

    private var composedPrompt: String? {
        let base = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = base.isEmpty ? selectedStyle.promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
                                  : base + selectedStyle.promptSuffix
        return result.isEmpty ? nil : result
    }

    private func applyTool() {
        switch currentTool {
        case .brush:
            let config = BrushConfig(
                color: currentColor.codable,
                baseWidth: toolSize,
                opacity: toolOpacity,
                pressureGamma: 0.35,
                tiltSensitivity: 1.0
            )
            canvasViewModel.selectBrush(config)
        case .eraser:
            canvasViewModel.selectEraser(width: toolSize)
        case .lasso:
            canvasViewModel.selectLasso()
        }
    }
}

// MARK: - Color Conversion

extension Color {
    var codable: CodableColor {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CodableColor(red: r, green: g, blue: b, alpha: a)
    }
}

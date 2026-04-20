import SwiftUI
import SwiftData
import os
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
}

enum DrawingLayout: String, CaseIterable {
    case splitScreen, fullscreen
}

@MainActor
@Observable
final class AppCoordinator {

    // MARK: - Navigation

    var currentScreen: AppScreen = .gallery
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
            if !isSuppressingObservation { scheduleSave() }
            syncStreamConfig()
        }
    }
    var selectedStyle: PromptStyle = .default {
        didSet {
            if !isSuppressingObservation { scheduleSave() }
            syncStreamConfig()
        }
    }
    var showStylePicker = false
    var showLayerPanel = false
    var resultState: ResultState = .empty
    var dividerPosition: CGFloat = 0.5
    var showFloatingPanel = false
    var canvasOnTop = false
    var generationError: String?

    // MARK: - Layout

    var drawingLayout: DrawingLayout = .splitScreen {
        didSet { UserDefaults.standard.set(drawingLayout.rawValue, forKey: "drawingLayout") }
    }

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    private let backendURL: URL
    private let authService: AuthService

    // MARK: - Auth

    var signedInUserId: String?

    // MARK: - Stream State

    private var streamWasActiveBeforeBackground = false
    private var streamSession: StreamSession?
    private(set) var streamConnectionState: StreamSession.ConnectionState = .disconnected
    private(set) var streamFrameCount = 0

    // -- Stream parameters --

    /// Number of inference steps.
    var streamSteps: Int = 4 { didSet { syncStreamConfig() } }

    /// Fixed seed (nil = server picks a stable per-session seed).
    var streamSeed: Int? { didSet { syncStreamConfig() } }

    /// Capture FPS for stream mode.
    var streamCaptureFPS: Double = 2 {
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
        self.signedInUserId = initialUserId
        if initialUserId == nil {
            currentScreen = .signIn
        } else {
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
    }

    // MARK: - Auth

    /// Exchange an Apple identity token for a backend JWT pair, then navigate
    /// to the main app. Called from SignInView.
    func signInWithApple(identityToken: String) async throws {
        try await authService.signInWithApple(identityToken: identityToken, nonce: nil)
        let userId = await authService.userId
        await MainActor.run {
            self.signedInUserId = userId

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
            await authService.signOut()
            await MainActor.run {
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

        // Reset all state
        promptText = ""
        selectedStyle = .default
        streamSeed = seed
        lastSuccessfulImage = nil
        showFloatingPanel = false

        canvasViewModel.setPendingState(nil)

        currentScreen = .drawing
        isSuppressingObservation = false

        startStream()
        seedResultStateForCurrentDrawing()
    }

    func openDrawing(_ drawing: Drawing) {
        isSuppressingObservation = true

        currentDrawingId = drawing.id

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

        startStream()
        seedResultStateForCurrentDrawing()
    }

    func navigateToGallery() {
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

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
            syncStreamConfig()
            return
        }

        var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false)!
        components.scheme = backendURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/stream"
        guard let wsURL = components.url else {
            streamLog.error("Failed to construct WebSocket URL from \(self.backendURL.absoluteString)")
            return
        }

        streamLog.info("Starting stream to \(wsURL.absoluteString)")

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
                    self.streamConnectionState = .error("Please sign in again")
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
            self.resultState = .streaming(image: image, frameCount: self.streamFrameCount)
            if self.drawingLayout == .fullscreen {
                self.showFloatingPanel = true
            }

            let count = self.streamFrameCount
            if count == 1 || count % 30 == 0 {
                print("[Stream] Received frame \(count)")
            }
        }

        session.onConnectionStateChanged = { [weak self] state in
            guard let self else { return }
            streamLog.info("Connection state changed: \(String(describing: state))")
            let previousState = self.streamConnectionState
            self.streamConnectionState = state
            if case .error(let message) = state {
                self.generationError = message
            }
            self.applyStreamStateToResultState(previousState: previousState, newState: state)
        }

        self.streamSession = session

        Task {
            await session.start()
        }
    }

    private func stopStream() {
        streamLog.info("Stopping stream")
        streamSession?.stop()
        streamSession = nil
        streamConnectionState = .disconnected
        streamFrameCount = 0

        if let image = lastSuccessfulImage {
            resultState = .preview(image: image)
        } else if case .provisioning = resultState {
            resultState = .empty
        }
    }

    /// Map a stream connection state into the right `resultState`. Used to keep
    /// the result pane reflecting warm-up progress whenever the connection
    /// transitions, without overwriting an existing generated image.
    ///
    /// Subtlety: `.connected` is reported twice on a cold start — first when
    /// the WebSocket opens, again when the server sends `status=ready`. We
    /// only treat the second one as "pod ready" by checking that the previous
    /// state was `.provisioning` (i.e. we were genuinely in warm-up).
    private func applyStreamStateToResultState(
        previousState: StreamSession.ConnectionState,
        newState: StreamSession.ConnectionState
    ) {
        switch newState {
        case .connecting:
            // Don't overwrite an existing image or in-flight generation.
            guard lastSuccessfulImage == nil else {
                streamLog.info("Stream connecting — keeping existing image")
                return
            }
            if case .provisioning = resultState { return }
            if case .streaming = resultState { return }
            streamLog.info("Stream connecting — showing provisioning UI")
            resultState = .provisioning(message: "Connecting…", startedAt: Date())

        case .provisioning(let message):
            guard lastSuccessfulImage == nil else {
                streamLog.info("Stream provisioning (\(message)) — keeping existing image")
                return
            }
            if case .streaming = resultState { return }
            // Preserve `startedAt` across multiple status updates so the
            // progress bar keeps advancing instead of resetting on each message.
            if case .provisioning(_, let startedAt) = resultState {
                resultState = .provisioning(message: message, startedAt: startedAt)
            } else {
                streamLog.info("Stream provisioning — showing warm-up UI")
                resultState = .provisioning(message: message, startedAt: Date())
            }

        case .connected:
            // Two cases that look the same:
            //   1. WebSocket just opened (came from .connecting). Pod may
            //      still be cold — keep the warm-up UI; the server will send
            //      `provisioning` status messages shortly.
            //   2. Server sent `status=ready` (came from .provisioning). Pod
            //      is genuinely ready — drop the warm-up UI; the next frame
            //      will move us to .streaming.
            if case .provisioning = previousState {
                if case .provisioning = resultState {
                    streamLog.info("Stream ready (was provisioning) — clearing warm-up UI")
                    resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
                }
            }

        case .error(let msg):
            streamLog.error("Stream error: \(msg)")
            resultState = .error(message: msg, previousImage: lastSuccessfulImage)

        case .disconnected:
            if case .provisioning = resultState {
                streamLog.info("Stream disconnected during provisioning — clearing warm-up UI")
                resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
            }
        }
    }

    /// Seed `resultState` from the current image and stream connection state.
    /// Called when entering a drawing so the result pane reflects pre-warming
    /// already in progress, instead of momentarily flashing empty.
    private func seedResultStateForCurrentDrawing() {
        if let image = lastSuccessfulImage {
            resultState = .preview(image: image)
            return
        }
        // If pre-warming has been running (likely since app launch), preserve
        // the existing `startedAt` so the progress bar doesn't reset to 0%
        // when the user enters a drawing partway through warm-up.
        let preservedStart: Date? = {
            if case .provisioning(_, let startedAt) = resultState { return startedAt }
            return nil
        }()
        switch streamConnectionState {
        case .connecting:
            resultState = .provisioning(message: "Connecting…", startedAt: preservedStart ?? Date())
        case .provisioning(let message):
            resultState = .provisioning(message: message, startedAt: preservedStart ?? Date())
        case .error(let msg):
            resultState = .error(message: msg, previousImage: nil)
        case .connected, .disconnected:
            resultState = .empty
        }

    }

    /// Push the current config to the stream session. The capture loop will
    /// detect the change and send it to the server before the next frame.
    private func syncStreamConfig() {
        streamSession?.config = buildStreamConfig()
    }

    // MARK: - App Lifecycle

    func handleScenePhaseChange(_ phase: ScenePhase) {
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
            seed: streamSeed
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

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
        resultState = .empty

        canvasViewModel.setPendingState(nil)

        currentScreen = .drawing
        isSuppressingObservation = false

        startStream()
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
        resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        showFloatingPanel = lastSuccessfulImage != nil

        // Prepare canvas state
        canvasViewModel.setPendingState(CanvasState(
            drawingData: drawing.drawingData ?? Data(),
            backgroundImageData: drawing.backgroundImageData
        ))

        currentScreen = .drawing
        isSuppressingObservation = false

        startStream()
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
            self.streamConnectionState = state
            if case .error(let message) = state {
                self.generationError = message
            }
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
                pressureOpacity: 0.0,
                streamline: 0.0,
                taperIn: 8,
                taperOut: 8,
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

import SwiftUI
import SwiftData
import CanvasModule
import NetworkModule
import ResultModule

enum DrawingTool: String, CaseIterable {
    case brush
    case eraser
}

enum AppScreen: Equatable {
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
        didSet { applyTool() }
    }
    var toolSize: CGFloat = 5.0 {
        didSet { applyTool() }
    }
    var promptText = "" {
        didSet { if !isSuppressingObservation { scheduleSave() } }
    }
    var selectedStyle: PromptStyle = .default {
        didSet { if !isSuppressingObservation { scheduleSave() } }
    }
    var showStylePicker = false
    var resultState: ResultState = .empty
    var dividerPosition: CGFloat = 0.55
    var advancedParameters = AdvancedParameters() {
        didSet { if !isSuppressingObservation { scheduleSave() } }
    }
    var isSeedLocked = false {
        didSet { if !isSuppressingObservation { scheduleSave() } }
    }
    var lastGeneratedLineartImage: UIImage?
    var showingLineart = false
    var showFloatingPanel = false
    var canvasOnTop = false
    var generationError: String?
    var comparisonData: ComparisonData?
    var compareWithoutControlNet = false {
        didSet {
            if !compareWithoutControlNet {
                comparisonData = nil
                comparisonError = nil
            }
        }
    }
    var comparisonError: String?

    // MARK: - Layout

    var drawingLayout: DrawingLayout = .splitScreen {
        didSet { UserDefaults.standard.set(drawingLayout.rawValue, forKey: "drawingLayout") }
    }

    // MARK: - Generation Mode

    var triggerMode: GenerationTriggerMode = .auto {
        didSet { UserDefaults.standard.set(triggerMode.rawValue, forKey: "generationTriggerMode") }
    }

    /// True when the canvas has changed since the last generation started.
    private(set) var hasUnsavedChanges = false

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    private let pipeline: GenerationPipeline

    // MARK: - Generation State

    private let sessionId = UUID()
    private var currentRequestId: UUID?
    private var lastSuccessfulImage: UIImage?

    private(set) var isGenerating = false
    private var generationTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var canvasObservationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(
        modelContext: ModelContext,
        backendURL: URL = URL(string: "https://kiki-backend-production-eb81.up.railway.app")!
    ) {
        self.modelContext = modelContext
        let apiClient = APIClient(baseURL: backendURL)
        self.pipeline = GenerationPipeline(apiClient: apiClient)

        if let stored = UserDefaults.standard.string(forKey: "generationTriggerMode"),
           let mode = GenerationTriggerMode(rawValue: stored) {
            self.triggerMode = mode
        }
        if let stored = UserDefaults.standard.string(forKey: "drawingLayout"),
           let layout = DrawingLayout(rawValue: stored) {
            self.drawingLayout = layout
        }

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

        applyTool()
        startObservingCanvas()
    }

    // MARK: - Actions

    func undo() {
        canvasViewModel.undo()
    }

    func redo() {
        canvasViewModel.redo()
    }

    func clear() {
        canvasViewModel.clear()
        hasUnsavedChanges = false
        lastGeneratedLineartImage = nil
        showingLineart = false
    }

    func swapLineartToCanvas() {
        guard let lineartImage = lastGeneratedLineartImage else { return }
        canvasViewModel.swapLineart(image: lineartImage)
        showingLineart = false
    }

    // MARK: - Gallery / Persistence

    func newDrawing() {
        // Save current drawing before switching (if canvas is still live)
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        isSuppressingObservation = true

        let drawing = Drawing()
        modelContext.insert(drawing)
        try? modelContext.save()
        currentDrawingId = drawing.id

        // Reset all state to defaults
        promptText = ""
        selectedStyle = .default
        advancedParameters = AdvancedParameters()
        isSeedLocked = false
        lastSuccessfulImage = nil
        lastGeneratedLineartImage = nil
        showingLineart = false
        showFloatingPanel = false
        resultState = .empty
        hasUnsavedChanges = false
        comparisonData = nil
        comparisonError = nil
        compareWithoutControlNet = false

        // No pending state needed — fresh canvas
        canvasViewModel.setPendingState(nil)

        currentScreen = .drawing
        isSuppressingObservation = false
    }

    func openDrawing(_ drawing: Drawing) {
        isSuppressingObservation = true

        currentDrawingId = drawing.id

        // Restore settings
        promptText = drawing.promptText
        selectedStyle = PromptStyle.from(id: drawing.styleId)
        advancedParameters = drawing.advancedParameters
        isSeedLocked = drawing.isSeedLocked

        // Restore generated images
        if let imgData = drawing.generatedImageData {
            lastSuccessfulImage = UIImage(data: imgData)
        } else {
            lastSuccessfulImage = nil
        }
        if let lineartData = drawing.lineartImageData {
            lastGeneratedLineartImage = UIImage(data: lineartData)
        } else {
            lastGeneratedLineartImage = nil
        }
        resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        showingLineart = false
        showFloatingPanel = lastSuccessfulImage != nil

        // Reset transient state
        hasUnsavedChanges = false
        comparisonData = nil
        comparisonError = nil
        compareWithoutControlNet = false

        // Prepare canvas state — will be applied in attach() before delegate is set
        canvasViewModel.setPendingState(CanvasState(
            drawingData: drawing.drawingData ?? Data(),
            backgroundImageData: drawing.backgroundImageData
        ))

        currentScreen = .drawing
        isSuppressingObservation = false
    }

    func navigateToGallery() {
        // Save while canvas is still live
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        // Delete empty drawings to keep gallery clean
        if let drawingId = currentDrawingId {
            let id = drawingId
            var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let drawing = try? modelContext.fetch(descriptor).first, drawing.isContentEmpty {
                modelContext.delete(drawing)
                try? modelContext.save()
            }
        }

        // Cancel in-flight generation
        generationTask?.cancel()
        debounceTask?.cancel()
        isGenerating = false

        currentDrawingId = nil
        currentScreen = .gallery
    }

    func deleteDrawing(_ drawing: Drawing) {
        modelContext.delete(drawing)
        try? modelContext.save()

        // If no drawings remain, auto-create a new one
        let descriptor = FetchDescriptor<Drawing>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        if count == 0 {
            newDrawing()
        }
    }

    func saveCurrentDrawing() {
        guard !isSuppressingObservation else { return }
        guard let drawingId = currentDrawingId else { return }

        // Guard: skip save if canvas is deallocated (prevents nil overwrite)
        guard canvasViewModel.exportDrawingData() != nil else { return }

        let id = drawingId
        var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let drawing = try? modelContext.fetch(descriptor).first else { return }

        // Canvas state
        drawing.drawingData = canvasViewModel.exportDrawingData()
        drawing.backgroundImageData = canvasViewModel.exportBackgroundImageData()

        // Generated images
        drawing.generatedImageData = lastSuccessfulImage?.jpegData(compressionQuality: 0.85)
        drawing.lineartImageData = lastGeneratedLineartImage?.pngData()

        // Thumbnail
        drawing.canvasThumbnailData = canvasViewModel.generateThumbnail()?.jpegData(compressionQuality: 0.7)

        // Settings
        drawing.promptText = promptText
        drawing.styleId = selectedStyle.id
        drawing.advancedParameters = advancedParameters
        drawing.isSeedLocked = isSeedLocked

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

    /// Triggers a preview generation from the current canvas state.
    func generate() {
        // Serial queue: if already generating, mark dirty for auto-retrigger on completion.
        if isGenerating {
            hasUnsavedChanges = true
            return
        }

        let requestId = UUID()
        currentRequestId = requestId
        hasUnsavedChanges = false
        isGenerating = true
        canvasOnTop = false
        generationError = nil
        comparisonError = nil

        // Cancel any prior generation task (latest-request-wins)
        generationTask?.cancel()

        generationTask = Task {
            let input = GenerationPipeline.Input(
                sessionId: sessionId,
                requestId: requestId,
                canvasViewModel: canvasViewModel,
                prompt: composedPrompt,
                advancedParameters: advancedParameters.isDefault ? nil : advancedParameters,
                isSeedLocked: isSeedLocked,
                compareWithoutControlNet: compareWithoutControlNet
            )

            do {
                let output = try await pipeline.run(input: input) { [weak self] phase, durations in
                    guard let self, currentRequestId == requestId else { return }
                    resultState = .generating(
                        progress: GenerationProgress(currentPhase: phase, durations: durations),
                        previousImage: lastSuccessfulImage
                    )
                }

                guard !Task.isCancelled, currentRequestId == requestId else { return }

                // Empty canvas — no generation needed, restore previous state
                guard let output else {
                    resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
                    comparisonData = nil
                    comparisonError = nil
                    isGenerating = false
                    return
                }

                lastSuccessfulImage = output.image
                lastGeneratedLineartImage = output.generatedLineartImage
                showingLineart = false
                generationError = nil
                resultState = .preview(image: output.image)
                if drawingLayout == .fullscreen {
                    showFloatingPanel = true
                }

                if compareWithoutControlNet {
                    comparisonData = output.comparisonData
                    if let error = output.comparisonError {
                        comparisonError = error
                    }
                }

                if isSeedLocked, let seed = output.seed {
                    advancedParameters.seed = seed
                }

                // Persist the new generated image immediately
                saveCurrentDrawing()
            } catch is CancellationError {
                return
            } catch {
                if Task.isCancelled { return }
                guard currentRequestId == requestId else { return }
                let message = mapErrorMessage(error)
                generationError = message
                resultState = .error(
                    message: message,
                    previousImage: lastSuccessfulImage
                )
            }

            // Clear isGenerating before retrigger so generate() doesn't hit the in-flight guard
            isGenerating = false
            if hasUnsavedChanges {
                generate()
            }
        }
    }

    // MARK: - Canvas Observation

    private func startObservingCanvas() {
        canvasObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in canvasViewModel.canvasChanges {
                guard !Task.isCancelled else { return }
                guard !isSuppressingObservation else { continue }

                // Don't mark dirty for empty canvas (e.g. after clear or erasing last stroke)
                guard !canvasViewModel.isEmpty else { continue }
                hasUnsavedChanges = true

                // Persist canvas changes (debounced)
                scheduleSave()

                // In manual mode, just mark dirty — don't auto-generate
                guard triggerMode == .auto else { continue }

                // Auto mode: debounce then generate after 1.5s of no drawing
                debounceTask?.cancel()
                debounceTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard !Task.isCancelled, let self else { return }
                    if !isGenerating, !canvasViewModel.isEmpty {
                        generate()
                    }
                }
            }
        }
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
            canvasViewModel.selectBrush(width: toolSize)
        case .eraser:
            canvasViewModel.selectEraser(width: toolSize)
        }
    }

    private func mapErrorMessage(_ error: Error) -> String {
        switch error {
        case let pipelineError as PipelineError:
            return pipelineError.userMessage
        case let generationError as GenerationError:
            return generationError.userMessage
        case let urlError as URLError:
            return "Network error: \(urlError.localizedDescription) (code \(urlError.code.rawValue))"
        default:
            return "\(type(of: error)): \(error.localizedDescription)"
        }
    }
}

// MARK: - GenerationError + User Message

extension GenerationError {
    var userMessage: String {
        switch self {
        case .networkTimeout:
            return "Network timeout — server didn't respond. Is the pod running?"
        case .serverError(let statusCode, let message):
            return "Server error \(statusCode): \(message)"
        case .rateLimited(let retryAfter):
            if let retry = retryAfter {
                return "Rate limited — retry after \(Int(retry))s"
            }
            return "Rate limited — too many requests"
        case .contentFiltered(let categories):
            let cats = categories.isEmpty ? "unknown" : categories.joined(separator: ", ")
            return "Content filtered: \(cats)"
        case .invalidRequest(let message):
            return "Invalid request: \(message)"
        case .cancelled:
            return "Generation cancelled"
        case .decodingError:
            return "Failed to decode server response — unexpected JSON format"
        }
    }
}

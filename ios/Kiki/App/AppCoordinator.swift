import SwiftUI
import CanvasModule
import NetworkModule
import ResultModule

enum DrawingTool: String, CaseIterable {
    case brush
    case eraser
}

enum StylePreset: String, CaseIterable {
    case photoreal = "Photoreal"
    case anime = "Anime"
    case watercolor = "Watercolor"
    case storybook = "Storybook"
    case fantasy = "Fantasy"
    case ink = "Ink"
    case neon = "Neon"

    /// Maps to the backend's expected style preset key.
    var apiKey: String { rawValue.lowercased() }
}

@MainActor
@Observable
final class AppCoordinator {

    // MARK: - UI State

    var currentTool: DrawingTool = .brush {
        didSet { applyTool() }
    }
    var toolSize: CGFloat = 5.0 {
        didSet { applyTool() }
    }
    var promptText = ""
    var selectedStylePreset: StylePreset = .photoreal
    var resultState: ResultState = .empty
    var dividerPosition: CGFloat = 0.55
    var advancedParameters = AdvancedParameters()
    var isSeedLocked = false

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

    init(backendURL: URL = URL(string: "https://kiki-backend-production-eb81.up.railway.app")!) {
        let apiClient = APIClient(baseURL: backendURL)
        self.pipeline = GenerationPipeline(apiClient: apiClient)

        if let stored = UserDefaults.standard.string(forKey: "generationTriggerMode"),
           let mode = GenerationTriggerMode(rawValue: stored) {
            self.triggerMode = mode
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

        // Cancel any prior generation task (latest-request-wins)
        generationTask?.cancel()

        generationTask = Task {
            defer { isGenerating = false }

            let input = GenerationPipeline.Input(
                sessionId: sessionId,
                requestId: requestId,
                canvasViewModel: canvasViewModel,
                prompt: promptText.isEmpty ? nil : promptText,
                stylePreset: selectedStylePreset.apiKey,
                advancedParameters: advancedParameters.isDefault ? nil : advancedParameters,
                isSeedLocked: isSeedLocked
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

                // Empty canvas — no generation needed
                guard let output else { return }

                lastSuccessfulImage = output.image
                resultState = .preview(image: output.image)

                if isSeedLocked, let seed = output.seed {
                    advancedParameters.seed = seed
                }
            } catch is CancellationError {
                // Silently ignore cancellation
            } catch {
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: mapErrorMessage(error),
                    previousImage: lastSuccessfulImage
                )
            }

            // Auto-retrigger if canvas changed during generation
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
                hasUnsavedChanges = true

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

import SwiftUI
import os
import CanvasModule
import PreprocessorModule
import NetworkModule
import ResultModule

private let logger = Logger(subsystem: "com.kiki.app", category: "Generation")

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

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    private let preprocessor = SketchPreprocessor()
    private let apiClient: APIClient

    // MARK: - Generation State

    private let sessionId = UUID()
    private var currentRequestId: UUID?
    private var lastSuccessfulImageURL: URL?
    private var generationTask: Task<Void, Never>?
    private var isCanvasDirty = false
    private(set) var isGenerating = false
    private var debounceTask: Task<Void, Never>?
    private var canvasObservationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(backendURL: URL = URL(string: "https://kiki-backend-production-eb81.up.railway.app")!) {
        self.apiClient = APIClient(baseURL: backendURL)
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
        isCanvasDirty = false
    }

    /// Triggers a preview generation from the current canvas state.
    func generate() {
        // Cancel any in-flight generation
        generationTask?.cancel()

        let requestId = UUID()
        currentRequestId = requestId
        isCanvasDirty = false
        isGenerating = true

        generationTask = Task {
            defer { isGenerating = false }

            // 1. Capture snapshot
            guard let snapshot = canvasViewModel.captureSnapshot(),
                  !snapshot.isEmpty else {
                logger.warning("Snapshot capture failed or empty")
                return
            }
            let img = snapshot.image
            logger.debug("Snapshot captured: \(snapshot.strokeCount) strokes, size: \(img.size.width, privacy: .public)x\(img.size.height, privacy: .public)")

            // Show loading state
            resultState = .generating(previousImageURL: lastSuccessfulImageURL)

            // Convert directly to JPEG (canvas capture already includes white background)
            guard let jpegData = img.jpegData(compressionQuality: 0.85) else {
                logger.error("JPEG conversion failed")
                resultState = .error(
                    message: "Failed to process sketch",
                    previousImageURL: lastSuccessfulImageURL
                )
                return
            }
            logger.debug("JPEG: \(jpegData.count, privacy: .public) bytes")

            // Check for cancellation / staleness
            guard !Task.isCancelled, currentRequestId == requestId else {
                logger.debug("Cancelled or stale after preprocess")
                return
            }

            // 3. Send to backend
            let base64 = jpegData.base64EncodedString()
            logger.info("Sending generation request, style: \(selectedStylePreset.apiKey, privacy: .public)")
            let request = GenerateRequest(
                sessionId: sessionId,
                requestId: requestId,
                mode: .preview,
                prompt: promptText.isEmpty ? nil : promptText,
                stylePreset: selectedStylePreset.apiKey,
                adherence: 0.7,
                sketchImageBase64: base64,
                advancedParameters: advancedParameters.isDefault ? nil : advancedParameters
            )

            do {
                let response = try await apiClient.generate(request)
                logger.info("Response: status=\(String(describing: response.status), privacy: .public)")

                // Staleness check — only update if this is still the latest request
                guard !Task.isCancelled, currentRequestId == requestId else {
                    logger.debug("Cancelled or stale after response")
                    return
                }

                if response.status == .completed, let imageURL = response.imageURL {
                    lastSuccessfulImageURL = imageURL
                    resultState = .preview(imageURL: imageURL)
                    // Store returned seed when locked so user can see/reuse it
                    if isSeedLocked, let responseSeed = response.seed {
                        advancedParameters.seed = responseSeed
                    }
                } else {
                    resultState = .error(
                        message: "Generation failed",
                        previousImageURL: lastSuccessfulImageURL
                    )
                }
            } catch is CancellationError {
                logger.debug("Cancelled")
            } catch let error as GenerationError {
                logger.error("GenerationError: \(error.userMessage, privacy: .public)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: error.userMessage,
                    previousImageURL: lastSuccessfulImageURL
                )
            } catch {
                logger.error("Unexpected error: \(error.localizedDescription, privacy: .public)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: "Something went wrong",
                    previousImageURL: lastSuccessfulImageURL
                )
            }

            // Auto-retrigger if canvas changed during generation
            if isCanvasDirty, !Task.isCancelled {
                logger.debug("Canvas dirty, auto-retriggering")
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
                isCanvasDirty = true

                // Cancel previous debounce timer
                debounceTask?.cancel()

                // Start new debounce — generate after 1.5s of no drawing
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
}

// MARK: - GenerationError + User Message

extension GenerationError {
    var userMessage: String {
        switch self {
        case .networkTimeout:
            return "Connection timed out"
        case .serverError(_, let message):
            return message
        case .rateLimited:
            return "Too many requests. Try again soon."
        case .contentFiltered:
            return "Content was filtered"
        case .invalidRequest(let message):
            return message
        case .cancelled:
            return "Generation cancelled"
        case .decodingError:
            return "Unexpected server response"
        }
    }
}

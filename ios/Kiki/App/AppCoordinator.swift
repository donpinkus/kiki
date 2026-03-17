import SwiftUI
import CanvasModule
import PreprocessorModule
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
                print("[Generate] Snapshot capture failed or empty")
                return
            }
            let img = snapshot.image
            print("[Generate] Snapshot captured: \(snapshot.strokeCount) strokes, size: \(img.size), scale: \(img.scale), cgImage: \(img.cgImage != nil)")
            if let cg = img.cgImage {
                print("[Generate] CGImage: \(cg.width)x\(cg.height), bpc: \(cg.bitsPerComponent), alpha: \(cg.alphaInfo.rawValue)")
            }

            // Show loading state
            resultState = .generating(previousImageURL: lastSuccessfulImageURL)

            // Convert directly to JPEG (canvas capture already includes white background)
            guard let jpegData = img.jpegData(compressionQuality: 0.85) else {
                print("[Generate] JPEG conversion failed")
                resultState = .error(
                    message: "Failed to process sketch",
                    previousImageURL: lastSuccessfulImageURL
                )
                return
            }
            print("[Generate] JPEG: \(jpegData.count) bytes, image: \(img.size)")

            // Check for cancellation / staleness
            guard !Task.isCancelled, currentRequestId == requestId else {
                print("[Generate] Cancelled or stale after preprocess")
                return
            }

            // 3. Send to backend
            let base64 = jpegData.base64EncodedString()
            print("[Generate] Sending to backend: base64 length \(base64.count), style: \(selectedStylePreset.apiKey)")
            let request = GenerateRequest(
                sessionId: sessionId,
                requestId: requestId,
                mode: .preview,
                prompt: promptText.isEmpty ? nil : promptText,
                stylePreset: selectedStylePreset.apiKey,
                adherence: 0.7,
                sketchImageBase64: base64
            )

            do {
                let response = try await apiClient.generate(request)
                print("[Generate] Response: status=\(response.status), imageURL=\(response.imageURL?.absoluteString ?? "nil"), inputImageURL=\(response.inputImageURL?.absoluteString ?? "nil"), lineartImageURL=\(response.lineartImageURL?.absoluteString ?? "nil")")

                // Staleness check — only update if this is still the latest request
                guard !Task.isCancelled, currentRequestId == requestId else {
                    print("[Generate] Cancelled or stale after response")
                    return
                }

                if response.status == .completed, let imageURL = response.imageURL {
                    lastSuccessfulImageURL = imageURL
                    resultState = .preview(imageURL: imageURL)
                } else {
                    resultState = .error(
                        message: "Generation failed",
                        previousImageURL: lastSuccessfulImageURL
                    )
                }
            } catch is CancellationError {
                print("[Generate] Cancelled")
            } catch let error as GenerationError {
                print("[Generate] GenerationError: \(error)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: error.userMessage,
                    previousImageURL: lastSuccessfulImageURL
                )
            } catch {
                print("[Generate] Error: \(error)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: "Something went wrong",
                    previousImageURL: lastSuccessfulImageURL
                )
            }

            // Auto-retrigger if canvas changed during generation
            if isCanvasDirty, !Task.isCancelled {
                print("[Generate] Canvas dirty, auto-retriggering")
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

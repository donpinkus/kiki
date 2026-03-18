import SwiftUI
import CanvasModule
import PreprocessorModule
import NetworkModule
import ResultModule
import SchedulerModule

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
    var resultState: ResultState = .empty
    var dividerPosition: CGFloat = 0.55

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    private let preprocessor = SketchPreprocessor()
    private let apiClient: APIClient
    private let scheduler = GenerationScheduler()

    // MARK: - Generation State

    private let sessionId = UUID()
    private var lastSuccessfulImageURL: URL?
    private var generationTask: Task<Void, Never>?
    private(set) var isGenerating = false
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
        Task { await scheduler.markClean() }
    }

    /// Triggers a preview generation from the current canvas state.
    func generate() {
        // Cancel any in-flight generation
        generationTask?.cancel()
        isGenerating = true

        generationTask = Task {
            defer { isGenerating = false }

            let requestId = await scheduler.beginRequest()

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
            guard !Task.isCancelled, await scheduler.isCurrent(requestId) else {
                print("[Generate] Cancelled or stale after preprocess")
                return
            }

            // 3. Send to backend
            let base64 = jpegData.base64EncodedString()
            print("[Generate] Sending to backend: base64 length \(base64.count)")
            let request = GenerateRequest(
                sessionId: sessionId,
                requestId: requestId,
                mode: .preview,
                prompt: promptText.isEmpty ? nil : promptText,
                adherence: 0.7,
                sketchImageBase64: base64
            )

            do {
                let response = try await apiClient.generate(request)
                print("[Generate] Response: status=\(response.status), imageURL=\(response.imageURL?.absoluteString ?? "nil"), inputImageURL=\(response.inputImageURL?.absoluteString ?? "nil"), lineartImageURL=\(response.lineartImageURL?.absoluteString ?? "nil")")

                // Staleness check — only update if this is still the latest request
                guard !Task.isCancelled, await scheduler.isCurrent(requestId) else {
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
                guard !Task.isCancelled, await scheduler.isCurrent(requestId) else { return }
                resultState = .error(
                    message: error.userMessage,
                    previousImageURL: lastSuccessfulImageURL
                )
            } catch {
                print("[Generate] Error: \(error)")
                guard !Task.isCancelled, await scheduler.isCurrent(requestId) else { return }
                resultState = .error(
                    message: "Something went wrong",
                    previousImageURL: lastSuccessfulImageURL
                )
            }

            // Auto-retrigger if canvas changed during generation
            if await scheduler.completeRequest(requestId), !Task.isCancelled {
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

                await scheduler.scheduleGeneration { [weak self] in
                    guard let self, !isGenerating, !canvasViewModel.isEmpty else { return }
                    generate()
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

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
    var advancedParameters = AdvancedParameters()
    var isSeedLocked = false

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    private let preprocessor = SketchPreprocessor()
    private let apiClient: APIClient

    // MARK: - Generation State

    private let sessionId = UUID()
    private var currentRequestId: UUID?
    private var lastSuccessfulImage: UIImage?

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
        // If a request is already in-flight, mark dirty so it auto-retriggers on completion.
        // This prevents concurrent requests from piling up on the single GPU.
        if isGenerating {
            isCanvasDirty = true
            return
        }

        let requestId = UUID()
        currentRequestId = requestId
        isCanvasDirty = false
        isGenerating = true

        Task {
            defer { if isGenerating { isGenerating = false } }

            var durations: [GenerationPhase: TimeInterval] = [:]
            var phaseStart = Date()

            // Phase: preparing (snapshot + JPEG encoding)
            resultState = .generating(
                progress: GenerationProgress(currentPhase: .preparing, phaseStartedAt: phaseStart),
                previousImage: lastSuccessfulImage
            )

            // Capture snapshot
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

            // Convert directly to JPEG (canvas capture already includes white background)
            guard let jpegData = img.jpegData(compressionQuality: 0.85) else {
                print("[Generate] JPEG conversion failed")
                resultState = .error(
                    message: "Failed to process sketch",
                    previousImage: lastSuccessfulImage
                )
                return
            }
            print("[Generate] JPEG: \(jpegData.count) bytes, image: \(img.size)")

            // Check for cancellation / staleness
            guard !Task.isCancelled, currentRequestId == requestId else {
                print("[Generate] Cancelled or stale after preprocess")
                return
            }

            // Phase: uploading (full network round-trip)
            durations[.preparing] = Date().timeIntervalSince(phaseStart)
            phaseStart = Date()
            resultState = .generating(
                progress: GenerationProgress(currentPhase: .uploading, phaseStartedAt: phaseStart, durations: durations),
                previousImage: lastSuccessfulImage
            )

            // Send to backend
            let base64 = jpegData.base64EncodedString()
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

            // Log full request payload (minus base64 image data)
            if let jsonData = try? JSONEncoder().encode(request),
               var jsonObject = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                jsonObject["sketchImageBase64"] = "<\(base64.count) chars>"
                if let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: .prettyPrinted),
                   let prettyString = String(data: prettyData, encoding: .utf8) {
                    print("[Generate] Request payload:\n\(prettyString)")
                }
            }

            do {
                let response = try await apiClient.generate(request)
                print("[Generate] Response: status=\(response.status), imageURL=\(response.imageURL?.absoluteString ?? "nil"), inputImageURL=\(response.inputImageURL?.absoluteString ?? "nil"), lineartImageURL=\(response.lineartImageURL?.absoluteString ?? "nil")")
                if let workflowJSON = response.workflowJSON {
                    print("[Generate] ComfyUI workflow:\n\(workflowJSON)")
                }

                // Staleness check — only update if this is still the latest request
                guard !Task.isCancelled, currentRequestId == requestId else {
                    print("[Generate] Cancelled or stale after response")
                    return
                }

                if response.status == .completed, let imageURL = response.imageURL {
                    if isSeedLocked, let seed = response.seed {
                        advancedParameters.seed = seed
                    }

                    // Phase: downloading
                    durations[.uploading] = Date().timeIntervalSince(phaseStart)
                    phaseStart = Date()
                    resultState = .generating(
                        progress: GenerationProgress(currentPhase: .downloading, phaseStartedAt: phaseStart, durations: durations),
                        previousImage: lastSuccessfulImage
                    )

                    let (data, _) = try await URLSession.shared.data(from: imageURL)
                    guard let image = UIImage(data: data) else {
                        resultState = .error(message: "Image decode failed — \(data.count) bytes from \(imageURL.lastPathComponent)", previousImage: lastSuccessfulImage)
                        return
                    }
                    guard !Task.isCancelled, currentRequestId == requestId else { return }
                    lastSuccessfulImage = image
                    resultState = .preview(image: image)
                } else {
                    resultState = .error(
                        message: "Generation failed — status: \(response.status), imageURL: \(response.imageURL?.absoluteString ?? "nil")",
                        previousImage: lastSuccessfulImage
                    )
                }
            } catch is CancellationError {
                print("[Generate] Cancelled")
            } catch let error as GenerationError {
                print("[Generate] GenerationError: \(error)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: error.userMessage,
                    previousImage: lastSuccessfulImage
                )
            } catch let urlError as URLError {
                print("[Generate] URLError: \(urlError)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: "Network error: \(urlError.localizedDescription) (code \(urlError.code.rawValue))",
                    previousImage: lastSuccessfulImage
                )
            } catch {
                print("[Generate] Error: \(error)")
                guard !Task.isCancelled, currentRequestId == requestId else { return }
                resultState = .error(
                    message: "\(type(of: error)): \(error.localizedDescription)",
                    previousImage: lastSuccessfulImage
                )
            }

            // Auto-retrigger if canvas changed during generation.
            // Must clear isGenerating first so generate() doesn't hit the in-flight guard.
            isGenerating = false
            if isCanvasDirty {
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

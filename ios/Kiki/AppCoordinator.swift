import SwiftUI
import CanvasModule
import PreprocessorModule
import SchedulerModule
import NetworkModule
import ResultModule

/// Central coordinator that owns all module view models and manages cross-module communication.
///
/// Wires the data flow: Canvas → Preprocessor → Scheduler → Network → Result
@Observable
final class AppCoordinator {

    // MARK: - Properties

    let canvasViewModel = CanvasViewModel()
    let resultViewModel = ResultViewModel()

    private var scheduler: GenerationScheduler?
    private var canvasObserverTask: Task<Void, Never>?
    private var resultObserverTask: Task<Void, Never>?

    private let preprocessor = SketchPreprocessor()

    // MARK: - Lifecycle

    init() {}

    /// Call once from the root view's .onAppear to start the pipeline.
    func start(apiClient: APIClient) {
        guard scheduler == nil else { return }

        let scheduler = GenerationScheduler(apiClient: apiClient)
        self.scheduler = scheduler

        canvasObserverTask = Task { [weak self] in
            guard let self else { return }
            for await snapshot in canvasViewModel.canvasDidChange {
                guard !Task.isCancelled else { break }
                await self.handleCanvasChange(snapshot)
            }
        }

        resultObserverTask = Task {
            for await result in scheduler.results {
                guard !Task.isCancelled else { break }
                await MainActor.run { [weak self] in
                    self?.handleSchedulerResult(result)
                }
            }
        }
    }

    deinit {
        canvasObserverTask?.cancel()
        resultObserverTask?.cancel()
    }

    // MARK: - Private

    private func handleCanvasChange(_ snapshot: SketchSnapshot) async {
        guard !snapshot.isEmpty else { return }

        do {
            let processed = try await preprocessor.process(snapshot.image)
            await scheduler?.sketchDidChange(
                base64Image: processed.base64Image,
                prompt: nil,
                stylePreset: nil
            )
            await MainActor.run {
                resultViewModel.setGenerating()
            }
        } catch {
            await MainActor.run {
                resultViewModel.setError("Preprocessing failed")
            }
        }
    }

    @MainActor
    private func handleSchedulerResult(_ result: SchedulerResult) {
        guard result.response.status == .completed else {
            if result.response.status == .error {
                resultViewModel.setError("Generation failed")
            }
            return
        }

        guard let imageUrl = result.response.imageUrl,
              let url = URL(string: imageUrl) else {
            // Mock mode (no FAL_API_KEY) — no image URL returned
            return
        }

        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    await MainActor.run { resultViewModel.setError("Invalid image data") }
                    return
                }
                await MainActor.run {
                    switch result.mode {
                    case .preview:
                        resultViewModel.setPreviewImage(image)
                    case .refine:
                        resultViewModel.setRefinedImage(image)
                    }
                }
            } catch {
                await MainActor.run { resultViewModel.setError("Failed to load image") }
            }
        }
    }
}

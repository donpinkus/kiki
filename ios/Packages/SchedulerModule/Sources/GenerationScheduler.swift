import Foundation
import NetworkModule

/// Result emitted by the scheduler when a generation completes.
public struct SchedulerResult: Sendable {
    public let requestId: String
    public let mode: GenerationMode
    public let response: GenerateResponse
}

/// Manages debounce timers and request lifecycle for image generation.
///
/// Implemented as an actor for thread-safe state management.
/// Maintains two independent timers: preview (300ms) and refine (1200ms).
public actor GenerationScheduler {

    // MARK: - Properties

    private let apiClient: APIClient
    private let sessionId: String

    private var previewTimerTask: Task<Void, Never>?
    private var refineTimerTask: Task<Void, Never>?
    private var activePreviewTask: Task<Void, Never>?
    private var activeRefineTask: Task<Void, Never>?

    private var latestPreviewRequestId: String?
    private var latestRefineRequestId: String?

    private let previewDebounceNs: UInt64 = 300_000_000
    private let refineDebounceNs: UInt64 = 1_200_000_000

    public private(set) var state: SchedulerState = .idle

    private let resultContinuation: AsyncStream<SchedulerResult>.Continuation

    /// Stream of generation results for downstream consumers (AppCoordinator).
    public let results: AsyncStream<SchedulerResult>

    // MARK: - Lifecycle

    public init(apiClient: APIClient, sessionId: String = UUID().uuidString) {
        self.apiClient = apiClient
        self.sessionId = sessionId

        var cont: AsyncStream<SchedulerResult>.Continuation!
        results = AsyncStream { cont = $0 }
        resultContinuation = cont
    }

    deinit {
        resultContinuation.finish()
    }

    // MARK: - Public API

    /// Called when the canvas changes. Resets both debounce timers and cancels in-flight requests.
    public func sketchDidChange(base64Image: String, prompt: String?, stylePreset: String?) {
        cancelAll()
        state = .debouncing

        previewTimerTask = Task {
            try? await Task.sleep(nanoseconds: previewDebounceNs)
            guard !Task.isCancelled else { return }
            await firePreview(base64Image: base64Image, prompt: prompt, stylePreset: stylePreset)
        }

        refineTimerTask = Task {
            try? await Task.sleep(nanoseconds: refineDebounceNs)
            guard !Task.isCancelled else { return }
            await fireRefine(base64Image: base64Image, prompt: prompt, stylePreset: stylePreset)
        }
    }

    /// Cancel all in-flight and pending operations.
    public func cancelAll() {
        previewTimerTask?.cancel()
        refineTimerTask?.cancel()
        activePreviewTask?.cancel()
        activeRefineTask?.cancel()

        if let previewId = latestPreviewRequestId {
            Task { try? await apiClient.cancel(sessionId: sessionId, requestId: previewId) }
        }
        if let refineId = latestRefineRequestId {
            Task { try? await apiClient.cancel(sessionId: sessionId, requestId: refineId) }
        }

        state = .idle
    }

    /// Check if a response is still the latest for its mode.
    public func isLatest(requestId: String, mode: GenerationMode) -> Bool {
        switch mode {
        case .preview: return requestId == latestPreviewRequestId
        case .refine: return requestId == latestRefineRequestId
        }
    }

    // MARK: - Private

    private func firePreview(base64Image: String, prompt: String?, stylePreset: String?) {
        let request = GenerationRequest(
            mode: .preview,
            sketchBase64: base64Image,
            prompt: prompt,
            stylePreset: stylePreset
        )
        let requestId = request.id
        latestPreviewRequestId = requestId
        state = .generatingPreview(requestId: requestId)

        activePreviewTask = Task {
            do {
                let networkRequest = NetworkModule.GenerateRequest(
                    sessionId: sessionId,
                    requestId: requestId,
                    mode: .preview,
                    prompt: prompt,
                    stylePreset: stylePreset,
                    sketchImageBase64: base64Image
                )
                let response = try await apiClient.generate(networkRequest)
                guard !Task.isCancelled, await isLatest(requestId: requestId, mode: .preview) else { return }
                resultContinuation.yield(SchedulerResult(requestId: requestId, mode: .preview, response: response))
            } catch {
                guard !Task.isCancelled else { return }
                let errorResponse = GenerateResponse(requestId: requestId, status: .error, imageUrl: nil, seed: nil, provider: nil, latencyMs: nil)
                resultContinuation.yield(SchedulerResult(requestId: requestId, mode: .preview, response: errorResponse))
            }
        }
    }

    private func fireRefine(base64Image: String, prompt: String?, stylePreset: String?) {
        let request = GenerationRequest(
            mode: .refine,
            sketchBase64: base64Image,
            prompt: prompt,
            stylePreset: stylePreset
        )
        let requestId = request.id
        latestRefineRequestId = requestId
        state = .generatingRefine(requestId: requestId)

        activeRefineTask = Task {
            do {
                let networkRequest = NetworkModule.GenerateRequest(
                    sessionId: sessionId,
                    requestId: requestId,
                    mode: .refine,
                    prompt: prompt,
                    stylePreset: stylePreset,
                    sketchImageBase64: base64Image
                )
                let response = try await apiClient.generate(networkRequest)
                guard !Task.isCancelled, await isLatest(requestId: requestId, mode: .refine) else { return }
                resultContinuation.yield(SchedulerResult(requestId: requestId, mode: .refine, response: response))
            } catch {
                guard !Task.isCancelled else { return }
                let errorResponse = GenerateResponse(requestId: requestId, status: .error, imageUrl: nil, seed: nil, provider: nil, latencyMs: nil)
                resultContinuation.yield(SchedulerResult(requestId: requestId, mode: .refine, response: errorResponse))
            }
        }
    }
}

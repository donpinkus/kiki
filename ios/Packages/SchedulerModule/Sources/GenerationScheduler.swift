import Foundation
import NetworkModule

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
    private var activePreviewTask: Task<GenerateResponse, Error>?
    private var activeRefineTask: Task<GenerateResponse, Error>?

    private var latestPreviewRequestId: String?
    private var latestRefineRequestId: String?

    private let previewDebounceNs: UInt64 = 300_000_000
    private let refineDebounceNs: UInt64 = 1_200_000_000

    public private(set) var state: SchedulerState = .idle

    // MARK: - Lifecycle

    public init(apiClient: APIClient, sessionId: String = UUID().uuidString) {
        self.apiClient = apiClient
        self.sessionId = sessionId
    }

    // MARK: - Public API

    /// Called when the canvas changes. Resets both debounce timers and cancels in-flight requests.
    public func sketchDidChange(base64Image: String, prompt: String?, stylePreset: String?) {
        cancelAll()
        state = .debouncing

        previewTimerTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: previewDebounceNs)
            guard !Task.isCancelled else { return }
            await self.firePreview(base64Image: base64Image, prompt: prompt, stylePreset: stylePreset)
        }

        refineTimerTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: refineDebounceNs)
            guard !Task.isCancelled else { return }
            await self.fireRefine(base64Image: base64Image, prompt: prompt, stylePreset: stylePreset)
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
        latestPreviewRequestId = request.id
        state = .generatingPreview(requestId: request.id)

        activePreviewTask = Task {
            let networkRequest = NetworkModule.GenerateRequest(
                sessionId: sessionId,
                requestId: request.id,
                mode: .preview,
                prompt: prompt,
                stylePreset: stylePreset,
                sketchImageBase64: base64Image
            )
            return try await apiClient.generate(networkRequest)
        }
    }

    private func fireRefine(base64Image: String, prompt: String?, stylePreset: String?) {
        let request = GenerationRequest(
            mode: .refine,
            sketchBase64: base64Image,
            prompt: prompt,
            stylePreset: stylePreset
        )
        latestRefineRequestId = request.id
        state = .generatingRefine(requestId: request.id)

        activeRefineTask = Task {
            let networkRequest = NetworkModule.GenerateRequest(
                sessionId: sessionId,
                requestId: request.id,
                mode: .refine,
                prompt: prompt,
                stylePreset: stylePreset,
                sketchImageBase64: base64Image
            )
            return try await apiClient.generate(networkRequest)
        }
    }
}

import UIKit
import NetworkModule

/// Drives sequential generation of style-preview tiles for the picker.
/// Sends one preview request at a time through `StreamSession`, awaits its
/// result, then moves to the next style. Cancellation leaves any in-flight
/// request for `StreamSession.exitPreviewMode` to unwind.
@MainActor
@Observable
final class StylePreviewController {

    enum PreviewState {
        case loading
        case ready(UIImage)
        case failed
    }

    private(set) var previews: [String: PreviewState] = [:]

    private var runTask: Task<Void, Never>?

    /// Start a fresh run. Seeds all tiles as `.loading` immediately so the
    /// UI shows shimmer placeholders, then walks through `styles` in order.
    func start(
        canvasJPEG: Data,
        basePrompt: String,
        steps: Int,
        seed: Int?,
        styles: [PromptStyle],
        session: StreamSession
    ) {
        cancel()
        var seeded: [String: PreviewState] = [:]
        for style in styles { seeded[style.id] = .loading }
        previews = seeded

        runTask = Task { [weak self] in
            guard let self else { return }
            for style in styles {
                if Task.isCancelled { return }

                let prompt = Self.composePrompt(base: basePrompt, suffix: style.promptSuffix)
                let requestId = "preview-\(style.id)-\(UUID().uuidString)"
                let config = StreamConfig(prompt: prompt, steps: steps, seed: seed, requestId: requestId)

                do {
                    let image = try await Self.withTimeout(seconds: 20) {
                        try await session.sendPreview(jpeg: canvasJPEG, config: config)
                    }
                    if Task.isCancelled { return }
                    self.previews[style.id] = .ready(image)
                } catch {
                    if Task.isCancelled { return }
                    self.previews[style.id] = .failed
                }
            }
        }
    }

    /// Bounds each preview at 20s so an unresponsive pod (or one still
    /// running pre-correlation image that never sends `frame_meta`)
    /// doesn't leave tiles in shimmer forever.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let first = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return first
        }
    }

    /// Mark every listed style as failed. Used when a picker opens without
    /// a live stream session (e.g. stream failed to start).
    func markAllFailed(styles: [PromptStyle]) {
        cancel()
        var failed: [String: PreviewState] = [:]
        for style in styles { failed[style.id] = .failed }
        previews = failed
    }

    func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    func reset() {
        cancel()
        previews = [:]
    }

    private static func composePrompt(base: String, suffix: String) -> String? {
        let trimmedBase = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let composed = trimmedBase.isEmpty ? trimmedSuffix : trimmedBase + suffix
        return composed.isEmpty ? nil : composed
    }
}

import Foundation

public actor GenerationScheduler {
    public enum State: Sendable {
        case idle
        case debouncing
        case generating
    }

    public private(set) var state: State = .idle

    private let debounceInterval: Duration
    private var debounceTask: Task<Void, Never>?
    private var currentRequestId: UUID?
    private var canvasDirty: Bool = false

    public init(debounceInterval: Duration = .seconds(1.5)) {
        self.debounceInterval = debounceInterval
    }

    /// Starts or restarts the debounce timer. Calls `onFire` on the MainActor
    /// when the timer elapses without being cancelled by another canvas change.
    public func scheduleGeneration(
        onFire: @MainActor @Sendable @escaping () -> Void
    ) {
        canvasDirty = true
        debounceTask?.cancel()
        state = .debouncing

        debounceTask = Task {
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            await MainActor.run { onFire() }
        }
    }

    /// Cancels any previous generation, assigns a new request ID, and clears the dirty flag.
    /// Returns the new request ID for staleness tracking.
    public func beginRequest() -> UUID {
        let requestId = UUID()
        currentRequestId = requestId
        canvasDirty = false
        state = .generating
        return requestId
    }

    /// Returns `true` if the given request ID is still the current one (not stale).
    public func isCurrent(_ requestId: UUID) -> Bool {
        currentRequestId == requestId
    }

    /// Marks the current generation as complete. Returns `true` if the canvas was
    /// dirtied during the generation, signaling that the caller should re-trigger.
    public func completeRequest(_ requestId: UUID) -> Bool {
        guard currentRequestId == requestId else { return false }
        state = .idle
        let wasDirty = canvasDirty
        if wasDirty { canvasDirty = false }
        return wasDirty
    }

    /// Mark the canvas as dirty (e.g., when a stroke arrives during generation).
    public func markDirty() {
        canvasDirty = true
    }

    /// Mark the canvas as clean (e.g., after clearing the canvas).
    public func markClean() {
        canvasDirty = false
    }

    /// Cancel all pending debounce and generation work.
    public func cancelAll() {
        debounceTask?.cancel()
        debounceTask = nil
        currentRequestId = nil
        canvasDirty = false
        state = .idle
    }
}

import Foundation

/// The current state of the generation scheduler.
public enum SchedulerState: Sendable {
    case idle
    case debouncing
    case generatingPreview(requestId: String)
    case generatingRefine(requestId: String)
}

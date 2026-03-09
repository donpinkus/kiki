import Foundation

public actor GenerationScheduler {
    public enum State: Sendable {
        case idle
        case debouncing
        case generating
    }

    public private(set) var state: State = .idle

    public init() {}
}

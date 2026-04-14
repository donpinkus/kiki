import Foundation

/// Configuration message sent over WebSocket to the FLUX.2-klein server.
public struct StreamConfig: Codable, Sendable, Equatable {
    public let type: String
    public let prompt: String?
    public let steps: Int
    public let seed: Int?

    public init(
        prompt: String?,
        steps: Int = 4,
        seed: Int? = nil
    ) {
        self.type = "config"
        self.prompt = prompt
        self.steps = steps
        self.seed = seed
    }
}

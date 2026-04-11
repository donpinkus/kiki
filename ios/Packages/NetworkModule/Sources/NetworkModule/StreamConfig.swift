import Foundation

/// Configuration message sent over WebSocket to the FLUX.2-klein server.
public struct StreamConfig: Codable, Sendable {
    public let type: String
    public let prompt: String?
    public let mode: String
    public let denoise: Double?
    public let guidanceScale: Double?
    public let steps: Int
    public let seed: Int?

    public init(
        prompt: String?,
        mode: String = "reference",
        denoise: Double? = nil,
        guidanceScale: Double? = nil,
        steps: Int = 4,
        seed: Int? = nil
    ) {
        self.type = "config"
        self.prompt = prompt
        self.mode = mode
        self.denoise = denoise
        self.guidanceScale = guidanceScale
        self.steps = steps
        self.seed = seed
    }
}

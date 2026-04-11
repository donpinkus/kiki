import Foundation

/// Configuration message sent over WebSocket to the StreamDiffusion server.
public struct StreamConfig: Codable, Sendable {
    public let type: String
    public let prompt: String?
    public let tIndexList: [Int]
    public let width: Int
    public let height: Int

    public init(prompt: String?, tIndexList: [Int], width: Int = 512, height: Int = 512) {
        self.type = "config"
        self.prompt = prompt
        self.tIndexList = tIndexList
        self.width = width
        self.height = height
    }
}

/// Configuration message sent over WebSocket to the FLUX.2-klein server.
public struct FluxStreamConfig: Codable, Sendable {
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

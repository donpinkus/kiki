import Foundation

public struct GenerateRequest: Codable, Sendable {
    public let sessionId: String
    public let requestId: String
    public let mode: GenerationMode
    public let prompt: String?
    public let stylePreset: String?
    public let adherence: Double
    public let sketchImageBase64: String

    public init(
        sessionId: String,
        requestId: String,
        mode: GenerationMode,
        prompt: String? = nil,
        stylePreset: String? = nil,
        adherence: Double = 0.5,
        sketchImageBase64: String
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.mode = mode
        self.prompt = prompt
        self.stylePreset = stylePreset
        self.adherence = adherence
        self.sketchImageBase64 = sketchImageBase64
    }
}

public enum GenerationMode: String, Codable, Sendable {
    case preview
    case refine
}

public struct GenerateResponse: Codable, Sendable {
    public let requestId: String
    public let status: GenerationStatus
    public let imageUrl: String?
    public let seed: Int?
    public let provider: String?
    public let latencyMs: Int?
}

public enum GenerationStatus: String, Codable, Sendable {
    case completed
    case filtered
    case error
}

struct CancelRequest: Codable, Sendable {
    let sessionId: String
    let requestId: String
}

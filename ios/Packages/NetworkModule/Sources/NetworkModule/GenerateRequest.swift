import Foundation

public struct GenerateRequest: Codable, Sendable {
    public let sessionId: UUID
    public let requestId: UUID
    public let mode: GenerationMode
    public let prompt: String?
    public let adherence: Double
    public let sketchImageBase64: String

    public init(
        sessionId: UUID,
        requestId: UUID,
        mode: GenerationMode,
        prompt: String? = nil,
        adherence: Double = 0.7,
        sketchImageBase64: String
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.mode = mode
        self.prompt = prompt
        self.adherence = adherence
        self.sketchImageBase64 = sketchImageBase64
    }
}

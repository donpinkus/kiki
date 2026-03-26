import Foundation

public struct GenerateRequest: Codable, Sendable {
    public let sessionId: UUID
    public let requestId: UUID
    public let mode: GenerationMode
    public let prompt: String?
    public let sketchImageBase64: String
    public let advancedParameters: AdvancedParameters?
    public let compareWithoutControlNet: Bool?

    public init(
        sessionId: UUID,
        requestId: UUID,
        mode: GenerationMode,
        prompt: String? = nil,
        sketchImageBase64: String,
        advancedParameters: AdvancedParameters? = nil,
        compareWithoutControlNet: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.mode = mode
        self.prompt = prompt
        self.sketchImageBase64 = sketchImageBase64
        self.advancedParameters = advancedParameters
        self.compareWithoutControlNet = compareWithoutControlNet
    }
}

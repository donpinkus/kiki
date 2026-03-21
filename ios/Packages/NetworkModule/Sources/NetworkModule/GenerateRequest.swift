import Foundation

public struct GenerateRequest: Codable, Sendable {
    public let sessionId: UUID
    public let requestId: UUID
    public let mode: GenerationMode
    public let prompt: String?
    public let stylePreset: String
    public let adherence: Double // Deprecated: use advancedParameters.controlNetStrength
    public let sketchImageBase64: String
    public let advancedParameters: AdvancedParameters?

    public init(
        sessionId: UUID,
        requestId: UUID,
        mode: GenerationMode,
        prompt: String? = nil,
        stylePreset: String,
        adherence: Double = 0.7,
        sketchImageBase64: String,
        advancedParameters: AdvancedParameters? = nil
    ) {
        self.sessionId = sessionId
        self.requestId = requestId
        self.mode = mode
        self.prompt = prompt
        self.stylePreset = stylePreset
        self.adherence = adherence
        self.sketchImageBase64 = sketchImageBase64
        self.advancedParameters = advancedParameters
    }
}

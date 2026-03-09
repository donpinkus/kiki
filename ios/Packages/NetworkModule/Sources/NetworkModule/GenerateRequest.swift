import Foundation

public struct GenerateRequest: Sendable {
    public let requestId: UUID
    public let imageData: Data
    public let prompt: String
    public let style: String
    public let mode: GenerationMode

    public init(requestId: UUID, imageData: Data, prompt: String, style: String, mode: GenerationMode) {
        self.requestId = requestId
        self.imageData = imageData
        self.prompt = prompt
        self.style = style
        self.mode = mode
    }
}

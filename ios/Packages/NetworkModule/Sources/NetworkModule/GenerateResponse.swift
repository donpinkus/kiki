import Foundation

public struct GenerateResponse: Sendable {
    public let requestId: UUID
    public let imageURL: URL
    public let mode: GenerationMode

    public init(requestId: UUID, imageURL: URL, mode: GenerationMode) {
        self.requestId = requestId
        self.imageURL = imageURL
        self.mode = mode
    }
}

import Foundation

public struct GenerateResponse: Sendable {
    public let requestId: UUID
    public let status: ResponseStatus
    public let imageURL: URL?
    public let inputImageURL: URL?
    public let lineartImageURL: URL?
    public let seed: UInt64?
    public let provider: String?
    public let latencyMs: Int?
    public let mode: GenerationMode

    public init(
        requestId: UUID,
        status: ResponseStatus,
        imageURL: URL? = nil,
        inputImageURL: URL? = nil,
        lineartImageURL: URL? = nil,
        seed: UInt64? = nil,
        provider: String? = nil,
        latencyMs: Int? = nil,
        mode: GenerationMode
    ) {
        self.requestId = requestId
        self.status = status
        self.imageURL = imageURL
        self.inputImageURL = inputImageURL
        self.lineartImageURL = lineartImageURL
        self.seed = seed
        self.provider = provider
        self.latencyMs = latencyMs
        self.mode = mode
    }
}

// MARK: - ResponseStatus

public enum ResponseStatus: String, Sendable {
    case completed
    case filtered
    case error
}

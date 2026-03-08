import Foundation
import NetworkModule

/// A request for image generation, created by the scheduler.
public struct GenerationRequest: Sendable {
    public let id: String
    public let mode: GenerationMode
    public let sketchBase64: String
    public let prompt: String?
    public let stylePreset: String?
    public let adherence: Double
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        mode: GenerationMode,
        sketchBase64: String,
        prompt: String? = nil,
        stylePreset: String? = nil,
        adherence: Double = 0.5,
        createdAt: Date = .now
    ) {
        self.id = id
        self.mode = mode
        self.sketchBase64 = sketchBase64
        self.prompt = prompt
        self.stylePreset = stylePreset
        self.adherence = adherence
        self.createdAt = createdAt
    }
}

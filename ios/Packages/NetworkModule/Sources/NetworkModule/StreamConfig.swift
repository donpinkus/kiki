import Foundation

/// Configuration message sent over WebSocket to the StreamDiffusion server.
public struct StreamConfig: Codable, Sendable {
    public let type: String
    public let prompt: String?
    public let strength: Double
    public let width: Int
    public let height: Int

    public init(prompt: String?, strength: Double, width: Int = 512, height: Int = 512) {
        self.type = "config"
        self.prompt = prompt
        self.strength = strength
        self.width = width
        self.height = height
    }
}

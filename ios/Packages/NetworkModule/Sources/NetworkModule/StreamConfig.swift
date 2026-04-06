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

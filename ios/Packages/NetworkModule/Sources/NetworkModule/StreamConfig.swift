import Foundation

/// Configuration message sent over WebSocket to the FLUX.2-klein server.
///
/// `requestId` is optional. When set, the pod echoes it back via a
/// `frame_meta` preamble so the client can route the following binary
/// frame to the correct caller (used for style-preview correlation).
/// Normal streaming omits it to preserve the binary-only response path.
public struct StreamConfig: Codable, Sendable, Equatable {
    public let type: String
    public let prompt: String?
    public let steps: Int
    public let seed: Int?
    public let requestId: String?

    public init(
        prompt: String?,
        steps: Int = 4,
        seed: Int? = nil,
        requestId: String? = nil
    ) {
        self.type = "config"
        self.prompt = prompt
        self.steps = steps
        self.seed = seed
        self.requestId = requestId
    }
}

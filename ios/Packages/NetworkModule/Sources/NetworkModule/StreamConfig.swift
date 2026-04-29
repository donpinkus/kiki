import Foundation

/// Configuration message sent over WebSocket to the FLUX.2-klein server.
///
/// `requestId` is optional. When set, the pod echoes it back via a
/// `frame_meta` preamble so the client can route the following binary
/// frame to the correct caller (used for style-preview correlation).
/// Normal streaming omits it to preserve the binary-only response path.
///
/// `videoWidth` / `videoHeight` / `videoFrames` are per-request overrides
/// for the LTX-2.3 video pod. Always emitted; the backend stashes the last
/// config and forwards these into the `video_request` payload, which the pod
/// applies to `video_pipeline.generate(width=, height=, num_frames=)`.
/// Defaults match today's pod-side `config.LTX_*`, so unchanged clients are
/// a no-op vs. pre-Step-3.5 behavior.
public struct StreamConfig: Codable, Sendable, Equatable {
    public let type: String
    public let prompt: String?
    public let steps: Int
    public let seed: Int?
    public let requestId: String?
    public let videoWidth: Int
    public let videoHeight: Int
    public let videoFrames: Int

    public init(
        prompt: String?,
        steps: Int = 4,
        seed: Int? = nil,
        requestId: String? = nil,
        videoWidth: Int = 320,
        videoHeight: Int = 320,
        videoFrames: Int = 49
    ) {
        self.type = "config"
        self.prompt = prompt
        self.steps = steps
        self.seed = seed
        self.requestId = requestId
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrames = videoFrames
    }
}

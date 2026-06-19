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
///
/// `imageSize` / `scheduleMu` drive the live fal img2img path. They serialize
/// as the snake_case wire keys fal expects (`image_size`, `schedule_mu`) via
/// `CodingKeys`, flow through the backend untouched, and are read in
/// `falImageRelay.sendConfig`. `imageSize` is one of fal's two realtime presets
/// — `"square"` (768²) or `"square_hd"` (1024²); there is no higher preset on
/// `fal-ai/flux-2/klein/realtime`. `scheduleMu` (fal range 0.3–2.5) shifts the
/// denoise schedule: lower = more uniform denoising / tighter sketch adherence.
public struct StreamConfig: Codable, Sendable, Equatable {
    public let type: String
    public let prompt: String?
    public let steps: Int
    public let seed: Int?
    public let requestId: String?
    public let imageSize: String
    public let scheduleMu: Double
    public let videoWidth: Int
    public let videoHeight: Int
    public let videoFrames: Int
    public let videoPromptSuffix: String
    public let enableProfiling: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case prompt
        case steps
        case seed
        case requestId
        case imageSize = "image_size"
        case scheduleMu = "schedule_mu"
        case videoWidth
        case videoHeight
        case videoFrames
        case videoPromptSuffix
        case enableProfiling
    }

    public init(
        prompt: String?,
        steps: Int = 4,
        seed: Int? = nil,
        requestId: String? = nil,
        imageSize: String = "square_hd",
        scheduleMu: Double = 1.2,
        videoWidth: Int = 512,
        videoHeight: Int = 512,
        videoFrames: Int = 145,
        videoPromptSuffix: String = "",
        enableProfiling: Bool = false
    ) {
        self.type = "config"
        self.prompt = prompt
        self.steps = steps
        self.seed = seed
        self.requestId = requestId
        self.imageSize = imageSize
        self.scheduleMu = scheduleMu
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrames = videoFrames
        self.videoPromptSuffix = videoPromptSuffix
        self.enableProfiling = enableProfiling
    }
}

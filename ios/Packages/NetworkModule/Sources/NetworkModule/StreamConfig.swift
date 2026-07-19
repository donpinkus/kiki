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
    /// Sketch-adherence dial for the Lambda KV pipeline (reference-token K/V
    /// scaling): >1 follows the sketch harder, <1 frees the prompt, 1.0 =
    /// stock. Wire key `reference_scale`; ignored by the fal relay.
    public let referenceScale: Double
    /// Extra reference images (base64 JPEG, ≤512px) for the Lambda KV
    /// pipeline's multi-reference conditioning — e.g. a pinned object/
    /// character whose identity should persist across generations. Wire key
    /// `reference_images`; ignored by the fal relay. nil/empty = none.
    public let referenceImages: [String]?
    public let videoWidth: Int
    public let videoHeight: Int
    public let videoFrames: Int
    public let videoPromptSuffix: String
    /// The drawing's animation prompt (Animate modal). Backend caches it and
    /// uses it for BOTH manual and auto (3s-idle) video fires; nil = server
    /// default motion prompt.
    public let animationPrompt: String?
    public let enableProfiling: Bool

    private enum CodingKeys: String, CodingKey {
        case type
        case prompt
        case steps
        case seed
        case requestId
        case imageSize = "image_size"
        case scheduleMu = "schedule_mu"
        case referenceScale = "reference_scale"
        case referenceImages = "reference_images"
        case videoWidth
        case videoHeight
        case videoFrames
        case videoPromptSuffix
        case animationPrompt
        case enableProfiling
    }

    public init(
        prompt: String?,
        steps: Int = 4,
        seed: Int? = nil,
        requestId: String? = nil,
        imageSize: String = "square_hd",
        scheduleMu: Double = 1.2,
        referenceScale: Double = 1.0,
        referenceImages: [String]? = nil,
        videoWidth: Int = 512,
        videoHeight: Int = 512,
        videoFrames: Int = 145,
        videoPromptSuffix: String = "",
        animationPrompt: String? = nil,
        enableProfiling: Bool = false
    ) {
        self.type = "config"
        self.prompt = prompt
        self.steps = steps
        self.seed = seed
        self.requestId = requestId
        self.imageSize = imageSize
        self.scheduleMu = scheduleMu
        self.referenceScale = referenceScale
        self.referenceImages = referenceImages
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.videoFrames = videoFrames
        self.videoPromptSuffix = videoPromptSuffix
        self.animationPrompt = animationPrompt
        self.enableProfiling = enableProfiling
    }
}

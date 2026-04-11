import CoreGraphics

/// Controls which generation backend is used.
/// - `standard`: Current ComfyUI pipeline (REST request/response)
/// - `stream`: StreamDiffusion pipeline (WebSocket, real-time)
enum GenerationEngine: String, CaseIterable {
    case standard
    case stream
}

/// Controls which model/server powers stream mode.
/// - `streamDiffusion`: SD 1.5 + LCM-LoRA, ~7 FPS, 512x512
/// - `fluxKlein`: FLUX.2-klein-4B, ~2-3 FPS, 768x768
enum StreamEngine: String, CaseIterable {
    case streamDiffusion
    case fluxKlein

    var displayName: String {
        switch self {
        case .streamDiffusion: "StreamDiffusion"
        case .fluxKlein: "FLUX Klein"
        }
    }

    /// WebSocket path component for the backend relay.
    var streamPath: String {
        switch self {
        case .streamDiffusion: "/v1/stream/sd"
        case .fluxKlein: "/v1/stream/flux"
        }
    }

    /// Target capture resolution (server expects this size).
    var captureSize: CGSize {
        switch self {
        case .streamDiffusion: CGSize(width: 512, height: 512)
        case .fluxKlein: CGSize(width: 768, height: 768)
        }
    }

    /// Recommended default capture FPS.
    var defaultFPS: Double {
        switch self {
        case .streamDiffusion: 7
        case .fluxKlein: 2
        }
    }
}

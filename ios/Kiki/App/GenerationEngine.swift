/// Controls which generation backend is used.
/// - `standard`: Current ComfyUI pipeline (REST request/response)
/// - `stream`: StreamDiffusion pipeline (WebSocket, real-time)
enum GenerationEngine: String, CaseIterable {
    case standard
    case stream
}

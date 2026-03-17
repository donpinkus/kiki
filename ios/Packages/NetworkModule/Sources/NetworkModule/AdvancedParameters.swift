import Foundation

/// Parameters for fine-tuning ComfyUI generation. All fields are optional;
/// when nil the backend uses its workflow-template defaults.
public struct AdvancedParameters: Codable, Sendable, Equatable {

    /// ControlNet strength — how closely output follows the sketch (0–1, default 0.6).
    public var controlNetStrength: Double?

    /// ControlNet end percent — when to stop applying sketch guidance (0–1, default 0.5).
    public var controlNetEndPercent: Double?

    /// Classifier-free guidance scale (0–5, default 0.8). Low values typical with Lightning LoRA.
    public var cfgScale: Double?

    /// Inference steps (1–20, default 8).
    public var steps: Int?

    /// Denoise strength (0–1, default 1.0).
    public var denoise: Double?

    /// Maximum seed value — JS MAX_SAFE_INTEGER (2^53-1).
    public static let maxSeed: UInt64 = 9_007_199_254_740_991

    /// Seed for reproducibility. Nil = random each generation.
    /// Capped to `maxSeed` to avoid precision loss in JSON.
    public var seed: UInt64? {
        didSet {
            if let s = seed, s > Self.maxSeed {
                seed = Self.maxSeed
            }
        }
    }

    public init(
        controlNetStrength: Double? = nil,
        controlNetEndPercent: Double? = nil,
        cfgScale: Double? = nil,
        steps: Int? = nil,
        denoise: Double? = nil,
        seed: UInt64? = nil
    ) {
        self.controlNetStrength = controlNetStrength
        self.controlNetEndPercent = controlNetEndPercent
        self.cfgScale = cfgScale
        self.steps = steps
        self.denoise = denoise
        // didSet not called during init, so clamp explicitly
        self.seed = seed.map { min($0, Self.maxSeed) }
    }

    // Custom decoder — auto-synthesized init(from:) bypasses didSet, so clamp seed here too.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controlNetStrength = try container.decodeIfPresent(Double.self, forKey: .controlNetStrength)
        controlNetEndPercent = try container.decodeIfPresent(Double.self, forKey: .controlNetEndPercent)
        cfgScale = try container.decodeIfPresent(Double.self, forKey: .cfgScale)
        steps = try container.decodeIfPresent(Int.self, forKey: .steps)
        denoise = try container.decodeIfPresent(Double.self, forKey: .denoise)
        let rawSeed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        seed = rawSeed.map { min($0, Self.maxSeed) }
    }

    /// True when all fields are nil (no overrides).
    public var isDefault: Bool {
        controlNetStrength == nil
            && controlNetEndPercent == nil
            && cfgScale == nil
            && steps == nil
            && denoise == nil
            && seed == nil
    }

    // MARK: - Display Defaults

    public static let defaultControlNetStrength: Double = 0.6
    public static let defaultControlNetEndPercent: Double = 0.5
    public static let defaultCfgScale: Double = 0.8
    public static let defaultSteps: Int = 8
    public static let defaultDenoise: Double = 1.0
}

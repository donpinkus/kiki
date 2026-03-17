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

    /// Seed for reproducibility. Nil = random each generation.
    public var seed: UInt64?

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
        self.seed = seed
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

import Foundation

/// User-adjustable ComfyUI generation parameters.
/// All fields are optional — `nil` means "use the workflow template default".
public struct AdvancedParameters: Codable, Sendable, Equatable {

    // MARK: - Properties

    public var controlNetStrength: Double?
    public var controlNetEndPercent: Double?
    public var cfgScale: Double?
    public var steps: Int?
    public var denoise: Double?
    public var auraFlowShift: Double?
    public var loraStrength: Double?
    public var negativePrompt: String?
    public var seed: UInt64? {
        didSet { seed = seed.map { min($0, Self.maxSeed) } }
    }

    // MARK: - Defaults (must match DEFAULTS in backend/src/modules/providers/comfyui.ts)

    public static let defaultControlNetStrength = 1.0
    public static let defaultControlNetEndPercent = 1.0
    public static let defaultCfgScale = 0.7
    public static let defaultSteps = 8
    public static let defaultDenoise = 1.0
    public static let defaultAuraFlowShift = 2.5
    public static let defaultLoraStrength = 1.0

    /// JavaScript `Number.MAX_SAFE_INTEGER` — seeds above this lose precision in JSON.
    public static let maxSeed: UInt64 = 9_007_199_254_740_991

    // MARK: - Computed

    /// True when all fields are nil (no overrides — request omits this object entirely).
    public var isDefault: Bool {
        controlNetStrength == nil && controlNetEndPercent == nil &&
        cfgScale == nil && steps == nil && denoise == nil &&
        auraFlowShift == nil && loraStrength == nil &&
        negativePrompt == nil && seed == nil
    }

    // MARK: - Init

    public init(
        controlNetStrength: Double? = nil,
        controlNetEndPercent: Double? = nil,
        cfgScale: Double? = nil,
        steps: Int? = nil,
        denoise: Double? = nil,
        auraFlowShift: Double? = nil,
        loraStrength: Double? = nil,
        negativePrompt: String? = nil,
        seed: UInt64? = nil
    ) {
        self.controlNetStrength = controlNetStrength
        self.controlNetEndPercent = controlNetEndPercent
        self.cfgScale = cfgScale
        self.steps = steps
        self.denoise = denoise
        self.auraFlowShift = auraFlowShift
        self.loraStrength = loraStrength
        self.negativePrompt = negativePrompt
        self.seed = seed.map { min($0, Self.maxSeed) }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case controlNetStrength, controlNetEndPercent, cfgScale, steps,
             denoise, auraFlowShift, loraStrength, negativePrompt, seed
    }

    /// Rounds to 2 decimal places so encoded values match what the UI displays.
    private static func round2(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(controlNetStrength.map(Self.round2), forKey: .controlNetStrength)
        try container.encodeIfPresent(controlNetEndPercent.map(Self.round2), forKey: .controlNetEndPercent)
        try container.encodeIfPresent(cfgScale.map(Self.round2), forKey: .cfgScale)
        try container.encodeIfPresent(steps, forKey: .steps)
        try container.encodeIfPresent(denoise.map(Self.round2), forKey: .denoise)
        try container.encodeIfPresent(auraFlowShift.map(Self.round2), forKey: .auraFlowShift)
        try container.encodeIfPresent(loraStrength.map(Self.round2), forKey: .loraStrength)
        try container.encodeIfPresent(negativePrompt, forKey: .negativePrompt)
        try container.encodeIfPresent(seed, forKey: .seed)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        controlNetStrength = try container.decodeIfPresent(Double.self, forKey: .controlNetStrength)
        controlNetEndPercent = try container.decodeIfPresent(Double.self, forKey: .controlNetEndPercent)
        cfgScale = try container.decodeIfPresent(Double.self, forKey: .cfgScale)
        steps = try container.decodeIfPresent(Int.self, forKey: .steps)
        denoise = try container.decodeIfPresent(Double.self, forKey: .denoise)
        auraFlowShift = try container.decodeIfPresent(Double.self, forKey: .auraFlowShift)
        loraStrength = try container.decodeIfPresent(Double.self, forKey: .loraStrength)
        negativePrompt = try container.decodeIfPresent(String.self, forKey: .negativePrompt)
        let rawSeed = try container.decodeIfPresent(UInt64.self, forKey: .seed)
        seed = rawSeed.map { min($0, Self.maxSeed) }
    }
}

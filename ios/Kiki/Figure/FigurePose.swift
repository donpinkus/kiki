import CoreGraphics
import Foundation
import simd

/// Which bundled body the figure uses. Both share the same joint names (the
/// Quaternius Universal Base Characters rig, CC0 — see `Models/LICENSE_*`),
/// so a pose transfers between them unchanged.
enum FigureBody: String, Codable, CaseIterable, Identifiable {
    case male, female
    var id: String { rawValue }
    var resourceName: String { "figure_\(rawValue)" }
    var label: String { self == .male ? "Male" : "Female" }
}

/// Body proportions as multipliers on the adult rig (1 = as modelled). Applied
/// as per-bone scales in `FigureScene` (see `applyProportions`), so every pose,
/// handle and the Mirror button work unchanged on a child or a chibi.
struct FigureProportions: Codable, Equatable {
    /// Overall size relative to the adult (child ≈ 0.62) — multiplies the
    /// on-canvas height so figures of different kinds keep their relative scale.
    var stature: Double = 1
    /// Head (skull) size.
    var head: Double = 1
    /// Spine length.
    var torso: Double = 1
    /// Arm + leg length.
    var limbs: Double = 1
    /// Hands + feet size.
    var hands: Double = 1
    /// Width of torso and limbs.
    var build: Double = 1

    static let adult = FigureProportions()

    enum Slider: String, CaseIterable, Identifiable {
        case stature, head, torso, limbs, hands, build
        var id: String { rawValue }
        var label: String {
            switch self {
            case .stature: "Height"
            case .head: "Head"
            case .torso: "Torso"
            case .limbs: "Limbs"
            case .hands: "Hands & feet"
            case .build: "Build"
            }
        }
        var range: ClosedRange<Double> {
            switch self {
            case .stature: 0.35...1.3
            case .head: 0.7...2.6
            case .torso: 0.6...1.3
            case .limbs: 0.45...1.35
            case .hands: 0.7...1.6
            case .build: 0.7...1.6
            }
        }
    }

    subscript(slider: Slider) -> Double {
        get {
            switch slider {
            case .stature: stature
            case .head: head
            case .torso: torso
            case .limbs: limbs
            case .hands: hands
            case .build: build
            }
        }
        set {
            switch slider {
            case .stature: stature = newValue
            case .head: head = newValue
            case .torso: torso = newValue
            case .limbs: limbs = newValue
            case .hands: hands = newValue
            case .build: build = newValue
            }
        }
    }

    /// Named starting points (sliders remain free afterwards). Age-based
    /// presets (teen/child/toddler) were dropped 2026-09-14 — a scaled adult
    /// doesn't read as a child; stylisation presets do read as intended.
    enum Preset: String, CaseIterable, Identifiable {
        case standard, chibi, fashion, heavy, slim
        var id: String { rawValue }
        var label: String {
            self == .standard ? "Default" : rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
        var values: FigureProportions {
            switch self {
            case .standard: FigureProportions()
            case .chibi: FigureProportions(stature: 0.55, head: 2.3, torso: 0.75, limbs: 0.55, hands: 1.3, build: 1.1)
            case .fashion: FigureProportions(stature: 1.12, head: 0.9, torso: 1.05, limbs: 1.18, hands: 1.0, build: 0.85)
            case .heavy: FigureProportions(stature: 1.0, head: 1.0, torso: 1.0, limbs: 1.0, hands: 1.0, build: 1.4)
            case .slim: FigureProportions(stature: 1.0, head: 1.0, torso: 1.0, limbs: 1.02, hands: 1.0, build: 0.82)
            }
        }
    }

    /// The preset these values match exactly, if any (for the chip highlight).
    var matchingPreset: Preset? {
        Preset.allCases.first { p in
            Slider.allCases.allSatisfy { abs(p.values[$0] - self[$0]) < 0.005 }
        }
    }
}

/// Everything needed to re-create a posed figure on the canvas: which body,
/// where it sits in the 2048² document, how it's turned, and every joint the
/// user has moved (local orientation quaternions keyed by rig joint name).
/// Persisted as the reference layer's opaque payload (`LayerInfo.referenceData`).
struct FigurePose: Codable, Equatable {
    var body: FigureBody = .male
    /// Figure centre in document pixels (2048² canvas).
    var centerX: Double = 1024
    var centerY: Double = 1024
    /// On-canvas height of the (unposed) figure in document pixels.
    var heightPx: Double = 1500
    /// In-plane roll, radians, clockwise-positive on screen (UIKit rotation sense).
    var roll: Double = 0
    /// Turntable yaw + tilt pitch, radians (the 3D "orbit").
    var yaw: Double = 0
    var pitch: Double = 0
    /// Joint name → local orientation quaternion `[ix, iy, iz, r]`. Joints
    /// absent here stay at the rig's bind pose.
    var joints: [String: [Float]] = [:]
    /// Body proportions (child, chibi, …); default = the adult rig as modelled.
    var proportions: FigureProportions = .adult

    static let version = 1
    private enum CodingKeys: String, CodingKey {
        case version, body, centerX, centerY, heightPx, roll, yaw, pitch, joints, proportions
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        body = try c.decodeIfPresent(FigureBody.self, forKey: .body) ?? .male
        centerX = try c.decodeIfPresent(Double.self, forKey: .centerX) ?? 1024
        centerY = try c.decodeIfPresent(Double.self, forKey: .centerY) ?? 1024
        heightPx = try c.decodeIfPresent(Double.self, forKey: .heightPx) ?? 1500
        roll = try c.decodeIfPresent(Double.self, forKey: .roll) ?? 0
        yaw = try c.decodeIfPresent(Double.self, forKey: .yaw) ?? 0
        pitch = try c.decodeIfPresent(Double.self, forKey: .pitch) ?? 0
        joints = try c.decodeIfPresent([String: [Float]].self, forKey: .joints) ?? [:]
        proportions = try c.decodeIfPresent(FigureProportions.self, forKey: .proportions) ?? .adult
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Self.version, forKey: .version)
        try c.encode(body, forKey: .body)
        try c.encode(centerX, forKey: .centerX)
        try c.encode(centerY, forKey: .centerY)
        try c.encode(heightPx, forKey: .heightPx)
        try c.encode(roll, forKey: .roll)
        try c.encode(yaw, forKey: .yaw)
        try c.encode(pitch, forKey: .pitch)
        try c.encode(joints, forKey: .joints)
        try c.encode(proportions, forKey: .proportions)
    }

    var center: CGPoint {
        get { CGPoint(x: centerX, y: centerY) }
        set { centerX = newValue.x; centerY = newValue.y }
    }

    func orientation(of joint: String) -> simd_quatf? {
        guard let q = joints[joint], q.count == 4 else { return nil }
        return simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3])
    }

    mutating func setOrientation(_ q: simd_quatf, of joint: String) {
        joints[joint] = [q.imag.x, q.imag.y, q.imag.z, q.real]
    }

    // MARK: - Mirror

    /// The pose reflected across the figure's sagittal plane: left/right bones
    /// swap and each bind-relative delta is reflected (x, −y, −z, w) — the rig's
    /// `_l`/`_r` bone frames are exact mirror images, verified numerically
    /// 2026-09-13. Turntable yaw and on-screen roll negate so the figure's
    /// facing mirrors too; pitch, placement and body are unchanged.
    func mirrored() -> FigurePose {
        var out = self
        var joints: [String: [Float]] = [:]
        for (name, q) in self.joints where q.count == 4 {
            joints[Self.mirroredJointName(name)] = [q[0], -q[1], -q[2], q[3]]
        }
        out.joints = joints
        out.yaw = -yaw
        out.roll = -roll
        return out
    }

    static func mirroredJointName(_ name: String) -> String {
        if name.hasSuffix("_l") { return String(name.dropLast(2)) + "_r" }
        if name.hasSuffix("_r") { return String(name.dropLast(2)) + "_l" }
        return name
    }

    // MARK: - Payload

    static func decode(_ data: Data?) -> FigurePose? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(FigurePose.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

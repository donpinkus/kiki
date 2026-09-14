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

    static let version = 1
    private enum CodingKeys: String, CodingKey {
        case version, body, centerX, centerY, heightPx, roll, yaw, pitch, joints
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

    // MARK: - Payload

    static func decode(_ data: Data?) -> FigurePose? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(FigurePose.self, from: data)
    }

    func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }
}

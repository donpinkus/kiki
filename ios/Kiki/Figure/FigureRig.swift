import Foundation
import simd

/// The posable joints of the bundled rig (Quaternius Universal Base Characters:
/// UE5-mannequin joint names) and how dragging each on-screen handle moves the
/// body. All geometry is done in world space on `SCNNode.simdWorldOrientation`,
/// so nothing here depends on the rig's per-bone local axes.
///
/// Figure frame (glTF, Y-up): the body stands along +Y, faces +Z (toward the
/// camera), and its own left arm is on +X (screen-right when facing the viewer).
enum FigureRig {
    // Joint names as they appear in the GLB (GLTFKit2 keeps them verbatim).
    /// Top bone of the skeleton; every bone is a descendant.
    static let skeletonRoot = "root"
    static let pelvis = "pelvis"
    static let spineLow = "spine_01"
    static let chest = "spine_03"
    static let neck = "neck_01"
    static let head = "Head"
    static func upperArm(_ s: Side) -> String { "upperarm_\(s.rawValue)" }
    static func foreArm(_ s: Side) -> String { "lowerarm_\(s.rawValue)" }
    static func hand(_ s: Side) -> String { "hand_\(s.rawValue)" }
    static func thigh(_ s: Side) -> String { "thigh_\(s.rawValue)" }
    static func calf(_ s: Side) -> String { "calf_\(s.rawValue)" }
    static func foot(_ s: Side) -> String { "foot_\(s.rawValue)" }

    enum Side: String, CaseIterable { case left = "l", right = "r" }

    /// Joints whose local orientation is persisted in `FigurePose.joints`
    /// (everything a handle can rotate).
    static let posableJoints: [String] = [spineLow, neck]
        + Side.allCases.flatMap { [upperArm($0), foreArm($0), thigh($0), calf($0)] }

    /// What happens when a handle is dragged to a new screen-plane target.
    enum Action {
        /// Two-bone IK: `root`→`mid`→`end` chain; `end` lands on the target, the
        /// mid joint bends toward `pole` (figure-frame direction) when the chain
        /// is straight and has no bend plane of its own.
        case twoBoneIK(root: String, mid: String, end: String, pole: SIMD3<Float>)
        /// Swing `pivot` so its child `follow` points at the target; everything
        /// below follows rigidly (elbow / knee / chest / head drags).
        case swing(pivot: String, follow: String)
        /// Move the whole figure by the drag delta.
        case translate
    }

    struct Handle: Identifiable, Equatable {
        let id: String
        /// Joint whose world position anchors the handle on screen.
        let anchor: String
        /// Offset from the anchor along the anchor→`towards` direction, in
        /// metres of the unscaled model (puts the head handle on the skull, not
        /// the neck). nil → handle sits on the anchor joint.
        let towards: String?
        let offsetMetres: Float
        let action: Action

        static func == (a: Handle, b: Handle) -> Bool { a.id == b.id }
    }

    /// Elbows bend backward (−Z), knees bend forward (+Z) in the figure frame.
    private static let elbowPole = SIMD3<Float>(0, 0, -1)
    private static let kneePole = SIMD3<Float>(0, 0, 1)

    static let handles: [Handle] = {
        var h: [Handle] = [
            Handle(id: "head", anchor: head, towards: neck, offsetMetres: -0.10,
                   action: .swing(pivot: neck, follow: head)),
            Handle(id: "chest", anchor: chest, towards: nil, offsetMetres: 0,
                   action: .swing(pivot: spineLow, follow: chest)),
            Handle(id: "pelvis", anchor: pelvis, towards: nil, offsetMetres: 0,
                   action: .translate),
        ]
        for s in Side.allCases {
            h += [
                Handle(id: "hand_\(s.rawValue)", anchor: hand(s), towards: nil, offsetMetres: 0,
                       action: .twoBoneIK(root: upperArm(s), mid: foreArm(s), end: hand(s), pole: elbowPole)),
                Handle(id: "elbow_\(s.rawValue)", anchor: foreArm(s), towards: nil, offsetMetres: 0,
                       action: .swing(pivot: upperArm(s), follow: foreArm(s))),
                Handle(id: "foot_\(s.rawValue)", anchor: foot(s), towards: nil, offsetMetres: 0,
                       action: .twoBoneIK(root: thigh(s), mid: calf(s), end: foot(s), pole: kneePole)),
                Handle(id: "knee_\(s.rawValue)", anchor: calf(s), towards: nil, offsetMetres: 0,
                       action: .swing(pivot: thigh(s), follow: calf(s))),
            ]
        }
        return h
    }()

    // MARK: Proportion morphs (per-bone scales; bone axis = local +Y on this rig)

    /// Bones whose LENGTH follows the limbs slider.
    static let limbBones: [String] = Side.allCases.flatMap { [upperArm($0), foreArm($0), thigh($0), calf($0)] }
    /// Bones whose LENGTH follows the torso slider.
    static let torsoBones: [String] = [spineLow, "spine_02", chest]
    /// Bones scaled uniformly by the hands slider (their finger/toe children inherit).
    static let extremityBones: [String] = Side.allCases.flatMap { [hand($0), foot($0)] }
    /// Bones whose WIDTH (local X/Z) follows the build slider.
    static let buildBones: [String] = [pelvis] + torsoBones + limbBones
    /// Bones that get a compensating node above each child so their scale
    /// never leaks into the child's frame (everything except uniform leaves).
    static let compensatedBones: [String] = Array(Set([pelvis] + torsoBones + limbBones))

    /// The rig binds in a T-pose; a relaxed standing A-pose is the sensible
    /// starting point. World-space swings applied to the bind pose, in order.
    /// Angles about the figure's +Z (forward) axis: the left arm (on +X) drops
    /// clockwise (negative), the right arm mirrors.
    static let defaultPoseSwings: [(joint: String, axis: SIMD3<Float>, radians: Float)] = [
        (upperArm(.left), SIMD3<Float>(0, 0, 1), -1.15),
        (upperArm(.right), SIMD3<Float>(0, 0, 1), 1.15),
        (foreArm(.left), SIMD3<Float>(0, 0, 1), -0.15),
        (foreArm(.right), SIMD3<Float>(0, 0, 1), 0.15),
    ]
}

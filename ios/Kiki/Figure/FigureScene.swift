import GLTFKit2
import Metal
import SceneKit
import UIKit
import simd

/// The SceneKit side of the posable figure: loads a bundled rigged body,
/// places it in a scene whose orthographic camera maps 1 scene unit to 1
/// document pixel (2048² canvas), applies/reads `FigurePose`, solves handle
/// drags in world space, and bakes the figure to a transparent CGImage.
///
/// Scene graph:
/// ```
/// placement (doc offset · roll · scale)
///   └─ orbit (yaw · pitch, pivot = figure centre)
///        └─ model (loaded glTF root, shifted so its mid-height sits at the pivot)
/// camera (orthographic, +Z looking −Z) ── key + fill lights ride with it
/// ```
/// Doc pixel (x, y) ⇔ world (x − 1024, 1024 − y, z): projection is affine, so
/// joint hit-testing needs no SceneKit unprojection.
@MainActor
final class FigureScene {
    static let documentSide: Float = 2048

    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let placementNode = SCNNode()
    private let orbitNode = SCNNode()
    private let modelNode = SCNNode()
    private(set) var body: FigureBody
    /// Unposed model height in its own units (metres for this rig).
    private(set) var modelHeight: Float = 1.8
    private var joints: [String: SCNNode] = [:]
    private var bindOrientations: [String: simd_quatf] = [:]
    /// Bone → the compensating nodes inserted above each of its children
    /// (`installMorphRig`); they carry the inverse of the bone's morph scale.
    private var compensators: [String: [SCNNode]] = [:]
    private var stature: Float = 1

    /// Parsed GLB per body, shared across sessions. `GLTFSCNSceneSource` builds
    /// fresh SCNNodes from the asset every time, so the asset is safe to share
    /// (an `SCNNode.clone()` of a skinned hierarchy would NOT be — its skinner
    /// keeps pointing at the original bones).
    private static var assetCache: [FigureBody: GLTFAsset] = [:]

    private static func asset(for body: FigureBody) throws -> GLTFAsset {
        if let cached = assetCache[body] { return cached }
        guard let url = Bundle.main.url(forResource: body.resourceName, withExtension: "glb") else {
            throw LoadError.missingResource
        }
        let asset = try GLTFAsset(url: url, options: [:])
        assetCache[body] = asset
        return asset
    }

    enum LoadError: Error { case missingResource, noScene, noJoints }

    init(body: FigureBody) throws {
        self.body = body
        scene.background.contents = UIColor.clear

        let camera = SCNCamera()
        camera.usesOrthographicProjection = true
        camera.orthographicScale = Double(Self.documentSide / 2)
        camera.zNear = 1
        camera.zFar = 100_000
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 20_000)
        scene.rootNode.addChildNode(cameraNode)

        // Lights ride with the camera so shading stays view-relative while the
        // figure turns — the form reads the same from every angle.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.light?.color = UIColor.white
        key.eulerAngles = SCNVector3(-0.55, -0.45, 0)
        cameraNode.addChildNode(key)
        let rim = SCNNode()
        rim.light = SCNLight()
        rim.light?.type = .directional
        rim.light?.intensity = 250
        rim.eulerAngles = SCNVector3(0.35, 0.9, 0)
        cameraNode.addChildNode(rim)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        scene.rootNode.addChildNode(placementNode)
        placementNode.addChildNode(orbitNode)
        orbitNode.addChildNode(modelNode)

        try loadModel(body)
    }

    // MARK: - Model

    private func loadModel(_ body: FigureBody) throws {
        let asset = try Self.asset(for: body)
        guard let loaded = GLTFSCNSceneSource(asset: asset).defaultScene else { throw LoadError.noScene }

        for child in modelNode.childNodes { child.removeFromParentNode() }
        for child in Array(loaded.rootNode.childNodes) {
            child.removeFromParentNode()
            modelNode.addChildNode(child)
        }
        // Every skeleton bone (65 on this rig): handles drive a few, but pose
        // presets sampled from animation clips carry fingers, clavicles, feet…
        joints = [:]
        bindOrientations = [:]
        if let skeletonRoot = modelNode.childNode(withName: FigureRig.skeletonRoot, recursively: true) {
            skeletonRoot.enumerateHierarchy { node, _ in
                guard let name = node.name, !name.isEmpty else { return }
                joints[name] = node
                bindOrientations[name] = node.simdOrientation
            }
        }
        guard joints[FigureRig.pelvis] != nil, joints[FigureRig.hand(.left)] != nil else {
            throw LoadError.noJoints
        }
        installMorphRig()

        // Mannequin look: one neutral matte material everywhere; eyes/brows a
        // shade darker so the face still reads.
        modelNode.enumerateHierarchy { node, _ in
            guard let geometry = node.geometry else { return }
            let dark = (node.name ?? "").lowercased().contains("eye")
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = UIColor(white: dark ? 0.32 : 0.80, alpha: 1)
            material.roughness.contents = 0.62
            material.metalness.contents = 0.0
            material.isDoubleSided = false
            geometry.materials = Array(repeating: material, count: max(1, geometry.materials.count))
        }

        // Height from the bind-pose mesh (skinned geometry bounds = bind pose).
        let (minB, maxB) = modelNode.boundingBox
        let h = maxB.y - minB.y
        modelHeight = h > 0.1 ? Float(h) : 1.8
        // Pivot at mid-height so orbit/scale/roll happen about the figure centre.
        modelNode.position = SCNVector3(0, -(Float(minB.y) + modelHeight / 2), 0)
        self.body = body
    }

    /// Swap bodies, keeping the pose (identical joint names on both rigs).
    func setBody(_ body: FigureBody, pose: inout FigurePose) throws {
        guard body != self.body else { return }
        try loadModel(body)
        pose.body = body
        apply(pose)
    }

    // MARK: - Proportion morphs

    /// Insert one compensating node between each morphable bone and each of
    /// its children. The child's rest translation moves onto the compensator
    /// (so a length scale on the parent moves the joint), the child keeps its
    /// rotation, and the compensator carries the INVERSE scale — so
    ///   parent · S · T(p) · S⁻¹ · R_child = parent · T(S·p) · R_child
    /// is rigid: the child's frame sees no scale, limbs bend without shear,
    /// and `simdWorldOrientation` setters (IK) stay exact. The skinner reads
    /// bone world transforms, so the inserted nodes are invisible to it.
    private func installMorphRig() {
        compensators = [:]
        for name in FigureRig.compensatedBones {
            guard let bone = joints[name] else { continue }
            var comps: [SCNNode] = []
            for child in Array(bone.childNodes) {
                let comp = SCNNode()
                comp.name = "\(name)__comp__\(child.name ?? "")"
                comp.simdPosition = child.simdPosition
                child.simdPosition = .zero
                child.removeFromParentNode()
                comp.addChildNode(child)
                bone.addChildNode(comp)
                comps.append(comp)
            }
            compensators[name] = comps
        }
    }

    private func setBoneScale(_ name: String, _ s: SIMD3<Float>) {
        guard let bone = joints[name] else { return }
        bone.simdScale = s
        for comp in compensators[name] ?? [] {
            comp.simdScale = SIMD3<Float>(1 / s.x, 1 / s.y, 1 / s.z)
        }
    }

    /// Push a proportions set into the bone scales (+ stature into placement).
    func applyProportions(_ p: FigureProportions) {
        let build = Float(p.build)
        let limbs = Float(p.limbs)
        let torso = Float(p.torso)
        // Limbs thicken with build a little less than the torso does.
        let limbWidth = 1 + (build - 1) * 0.7
        setBoneScale(FigureRig.pelvis, SIMD3<Float>(build, 1, build))
        for name in FigureRig.torsoBones { setBoneScale(name, SIMD3<Float>(build, torso, build)) }
        for name in FigureRig.limbBones { setBoneScale(name, SIMD3<Float>(limbWidth, limbs, limbWidth)) }
        for name in FigureRig.extremityBones {
            joints[name]?.simdScale = SIMD3<Float>(repeating: Float(p.hands))
        }
        joints[FigureRig.head]?.simdScale = SIMD3<Float>(repeating: Float(p.head))
        stature = Float(p.stature)
    }

    // MARK: - Pose ⇄ scene

    /// Push every part of `pose` into the scene graph. Stored joint values are
    /// DELTAS from the rig's bind orientation (local = bind · delta), so a pose
    /// transfers between the male and female rigs, whose bind rotations differ
    /// by several degrees for the same joint names.
    func apply(_ pose: FigurePose) {
        applyProportions(pose.proportions)
        applyPlacement(pose)
        applyJoints(pose.joints)
    }

    /// Joint deltas only (placement untouched) — pose presets.
    func applyJoints(_ deltas: [String: [Float]]) {
        for (name, node) in joints {
            guard let bind = bindOrientations[name] else { continue }
            if let q = deltas[name], q.count == 4 {
                node.simdOrientation = simd_normalize(bind * simd_quatf(ix: q[0], iy: q[1], iz: q[2], r: q[3]))
            } else {
                node.simdOrientation = bind
            }
        }
    }

    /// Placement only (translate / pinch / roll / orbit) — cheaper than `apply`.
    func applyPlacement(_ pose: FigurePose) {
        let scale = Float(pose.heightPx) / modelHeight * stature
        placementNode.simdScale = SIMD3<Float>(repeating: scale)
        placementNode.simdPosition = SIMD3<Float>(
            Float(pose.centerX) - Self.documentSide / 2,
            Self.documentSide / 2 - Float(pose.centerY),
            0)
        // Screen-clockwise roll is a negative rotation about +Z (y-up world).
        placementNode.simdOrientation = simd_quatf(angle: -Float(pose.roll), axis: SIMD3<Float>(0, 0, 1))
        orbitNode.simdOrientation = simd_quatf(angle: Float(pose.pitch), axis: SIMD3<Float>(1, 0, 0))
            * simd_quatf(angle: Float(pose.yaw), axis: SIMD3<Float>(0, 1, 0))
    }

    /// Copy the posable joints back into `pose` as bind-relative deltas
    /// (delta = bind⁻¹ · local; see `apply`).
    /// Bones still at their bind orientation are omitted, so a pose only lists
    /// what actually moved.
    func readJoints(into pose: inout FigurePose) {
        var out: [String: [Float]] = [:]
        for (name, node) in joints {
            guard let bind = bindOrientations[name] else { continue }
            let delta = simd_normalize(bind.inverse * node.simdOrientation)
            // angle = 2·acos(|w|); skip below ~0.06°.
            guard abs(delta.real) < 0.99999985 else { continue }
            out[name] = [delta.imag.x, delta.imag.y, delta.imag.z, delta.real]
        }
        pose.joints = out
    }

    /// The rig binds in a T-pose; build the relaxed default and record it.
    func applyDefaultPose(into pose: inout FigurePose) {
        applyJoints([:])
        for swing in FigureRig.defaultPoseSwings {
            guard let node = joints[swing.joint] else { continue }
            let axisWorld = simd_normalize(orbitNode.simdConvertVector(swing.axis, to: nil))
            node.simdWorldOrientation = simd_quatf(angle: swing.radians, axis: axisWorld) * node.simdWorldOrientation
        }
        readJoints(into: &pose)
    }

    // MARK: - Geometry

    func docPoint(ofWorld p: SIMD3<Float>) -> CGPoint {
        CGPoint(x: CGFloat(p.x + Self.documentSide / 2), y: CGFloat(Self.documentSide / 2 - p.y))
    }

    func world(ofDoc p: CGPoint, z: Float) -> SIMD3<Float> {
        SIMD3<Float>(Float(p.x) - Self.documentSide / 2, Self.documentSide / 2 - Float(p.y), z)
    }

    private func worldPosition(_ joint: String) -> SIMD3<Float>? {
        joints[joint]?.simdWorldPosition
    }

    /// World-space position of a handle (anchor joint, optionally offset along
    /// the anchor→towards line by a model-metre distance scaled to the canvas).
    func handleWorldPosition(_ handle: FigureRig.Handle) -> SIMD3<Float>? {
        guard let anchor = worldPosition(handle.anchor) else { return nil }
        guard let towardsName = handle.towards, let towards = worldPosition(towardsName),
              handle.offsetMetres != 0 else { return anchor }
        let dir = towards - anchor
        let len = simd_length(dir)
        guard len > 1e-4 else { return anchor }
        return anchor + dir / len * (handle.offsetMetres * placementNode.simdScale.x)
    }

    /// Document-pixel positions of every handle, for drawing + hit-testing.
    func handleDocPositions() -> [(handle: FigureRig.Handle, point: CGPoint)] {
        FigureRig.handles.compactMap { h in
            handleWorldPosition(h).map { (h, docPoint(ofWorld: $0)) }
        }
    }

    // MARK: - Drags

    /// Move `handle` toward the document point `target` (screen-plane: the
    /// target keeps the handle's current depth). Returns false for `.translate`
    /// handles — the caller moves the placement instead.
    @discardableResult
    func drag(_ handle: FigureRig.Handle, toDoc target: CGPoint) -> Bool {
        guard let current = handleWorldPosition(handle) else { return false }
        let t = world(ofDoc: target, z: current.z)
        switch handle.action {
        case .translate:
            return false
        case let .swing(pivot, follow):
            guard let p = joints[pivot], let f = joints[follow] else { return false }
            // Swing so the handle itself (which may be offset from `follow`,
            // e.g. the head-top handle) lands on the target.
            swing(pivot: p, from: current, to: t, pivotPosition: p.simdWorldPosition, follow: f)
            return true
        case let .twoBoneIK(root, mid, end, pole):
            guard let a = joints[root], let b = joints[mid], let c = joints[end] else { return false }
            let poleWorld = simd_normalize(orbitNode.simdConvertVector(pole, to: nil))
            solveTwoBone(root: a, mid: b, end: c, target: t, pole: poleWorld)
            return true
        }
    }

    /// Rotate `pivot` (world space) so the direction pivot→`from` becomes pivot→`to`.
    private func swing(pivot: SCNNode, from: SIMD3<Float>, to: SIMD3<Float>,
                       pivotPosition: SIMD3<Float>, follow: SCNNode) {
        let u = from - pivotPosition
        let v = to - pivotPosition
        guard simd_length(u) > 1e-3, simd_length(v) > 1e-3 else { return }
        let q = simd_quatf(from: simd_normalize(u), to: simd_normalize(v))
        guard q.real.isFinite else { return }
        pivot.simdWorldOrientation = q * pivot.simdWorldOrientation
    }

    /// Analytic two-bone IK in world space. Step 1 bends the mid joint about
    /// the chain's bend-plane normal so the chain length matches the target
    /// distance; step 2 swings the root so the end lands on the target.
    private func solveTwoBone(root: SCNNode, mid: SCNNode, end: SCNNode,
                              target: SIMD3<Float>, pole: SIMD3<Float>) {
        let a = root.simdWorldPosition
        let b = mid.simdWorldPosition
        let c = end.simdWorldPosition
        let l1 = simd_length(b - a)
        let l2 = simd_length(c - b)
        guard l1 > 1e-3, l2 > 1e-3 else { return }
        let eps: Float = 1e-3
        var toTarget = target - a
        var d = simd_length(toTarget)
        guard d > 1e-4 else { return }
        let dMin = abs(l1 - l2) + eps
        let dMax = l1 + l2 - eps
        if d < dMin { toTarget *= dMin / d; d = dMin }
        if d > dMax { toTarget *= dMax / d; d = dMax }

        // Bend-plane normal: the chain's own if it has a bend, else from the pole.
        let u = a - b
        let v = c - b
        var n = simd_cross(u, v)
        if simd_length(n) < 1e-4 * l1 * l2 {
            n = simd_cross(pole, u)
            if simd_length(n) < 1e-6 { n = simd_cross(SIMD3<Float>(0, 1, 0), u) }
        }
        n = simd_normalize(n)

        let cosTarget = (l1 * l1 + l2 * l2 - d * d) / (2 * l1 * l2)
        let angleTarget = acos(max(-1, min(1, cosTarget)))
        let cosCurrent = simd_dot(u, v) / (l1 * l2)
        let angleCurrent = acos(max(-1, min(1, cosCurrent)))
        let delta = angleTarget - angleCurrent
        if abs(delta) > 1e-5 {
            mid.simdWorldOrientation = simd_quatf(angle: delta, axis: n) * mid.simdWorldOrientation
        }

        let cNew = end.simdWorldPosition
        let from = cNew - a
        guard simd_length(from) > 1e-4 else { return }
        let q = simd_quatf(from: simd_normalize(from), to: simd_normalize(toTarget))
        guard q.real.isFinite else { return }
        root.simdWorldOrientation = q * root.simdWorldOrientation
    }

    // MARK: - Bake

    private static let device = MTLCreateSystemDefaultDevice()

    /// Render the figure at `side`² with a transparent background (document
    /// resolution for the reference layer).
    func render(side: Int = Int(FigureScene.documentSide)) -> CGImage? {
        let image = offscreenRenderer.snapshot(atTime: 0, with: CGSize(width: side, height: side),
                                               antialiasingMode: .multisampling4X)
        return image.cgImage
    }

    /// One renderer per scene (construction = Metal queue + scene compile; the
    /// pose picker bakes dozens of thumbnails from one library scene).
    private lazy var offscreenRenderer: SCNRenderer = {
        let renderer = SCNRenderer(device: Self.device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer
    }()
}

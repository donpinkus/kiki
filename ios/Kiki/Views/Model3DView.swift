import GLTFKit2
import SceneKit
import SwiftUI

/// Live 3D model viewer for lifted objects (GLB via GLTFKit2 → SceneKit).
/// Interactions come from SceneKit's built-in camera controller: one-finger
/// drag orbits, pinch zooms, two-finger drag pans. `autoRotate` adds a slow
/// turntable spin so it's immediately obvious the object is now 3D — the spin
/// is on the MODEL node, so it composes with (rather than fights) the user's
/// camera gestures.
struct Model3DView: UIViewRepresentable {
    let meshData: Data?
    var autoRotate: Bool = false
    /// Fires when the scene is loaded; exposes the SCNView (e.g. for
    /// transparent snapshots in the placement sheet).
    var onReady: ((SCNView) -> Void)? = nil
    var onFail: (() -> Void)? = nil

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X

        guard let meshData else {
            DispatchQueue.main.async { onFail?() }
            return view
        }
        // GLTFAsset loads from URL; write the blob to a temp file. Left for
        // the OS to clean — textures may be lazily mapped after load.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-model-\(UUID().uuidString).glb")
        do {
            try meshData.write(to: url, options: .atomic)
        } catch {
            DispatchQueue.main.async { onFail?() }
            return view
        }
        let rotate = autoRotate
        let ready = onReady
        let fail = onFail
        GLTFAsset.load(with: url, options: [:]) { _, status, maybeAsset, _, _ in
            DispatchQueue.main.async {
                guard status == .complete, let asset = maybeAsset else {
                    fail?()
                    return
                }
                let source = GLTFSCNSceneSource(asset: asset)
                guard let scene = source.defaultScene else {
                    fail?()
                    return
                }
                scene.background.contents = UIColor.clear
                if rotate {
                    // Reparent the model under a spinner node (copy the child
                    // list first — reparenting mutates it).
                    let spinner = SCNNode()
                    for child in Array(scene.rootNode.childNodes) {
                        child.removeFromParentNode()
                        spinner.addChildNode(child)
                    }
                    scene.rootNode.addChildNode(spinner)
                    spinner.runAction(.repeatForever(
                        .rotateBy(x: 0, y: 2 * .pi, z: 0, duration: 10)
                    ))
                }
                view.scene = scene
                ready?(view)
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

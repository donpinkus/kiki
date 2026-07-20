import GLTFKit2
import SceneKit
import SwiftUI

/// 3D placement for a lifted object: the USDZ model in a SceneKit view with
/// free orbit/zoom (built-in camera controls). "Place" takes a transparent
/// snapshot from the chosen angle and drops it onto the canvas as a movable
/// paste float — every placement renders from the same canonical model, so
/// the object stays perfectly consistent across drawings and angles.
struct ObjectPlacementSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    let object: SavedObject

    @State private var scnView: SCNView?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { coordinator.placingObject = nil }
                Spacer()
                Text(object.name)
                    .font(.headline)
                Spacer()
                Button {
                    if let view = scnView {
                        coordinator.placeRenderedObject(view.snapshot())
                    }
                } label: {
                    Text("Place")
                        .font(.body.weight(.semibold))
                }
                .disabled(scnView == nil)
            }
            .padding(14)

            if loadFailed {
                ContentUnavailableView(
                    "Couldn't load the 3D model",
                    systemImage: "cube.transparent",
                    description: Text("Try lifting the object again.")
                )
            } else {
                ModelSceneView(meshData: object.meshData, onReady: { scnView = $0 }, onFail: { loadFailed = true })
                    .background(Color(.secondarySystemBackground))
            }

            Text("Drag to spin · pinch to zoom — then Place to drop this exact view onto your canvas")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }
}

/// SceneKit host. Loads the GLB via GLTFKit2 (Apple has no native GLB
/// support), clears the background so snapshots come out transparent, and
/// enables the built-in orbit/zoom camera.
private struct ModelSceneView: UIViewRepresentable {
    let meshData: Data?
    let onReady: (SCNView) -> Void
    let onFail: () -> Void

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X

        guard let meshData else {
            DispatchQueue.main.async { onFail() }
            return view
        }
        // GLTFAsset loads from URL; write the blob to a temp file. Left for
        // the OS to clean — textures may be lazily mapped after load.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiki-object-\(UUID().uuidString).glb")
        do {
            try meshData.write(to: url, options: .atomic)
        } catch {
            DispatchQueue.main.async { onFail() }
            return view
        }
        GLTFAsset.load(with: url, options: [:]) { _, status, maybeAsset, _, _ in
            DispatchQueue.main.async {
                guard status == .complete, let asset = maybeAsset else {
                    onFail()
                    return
                }
                let source = GLTFSCNSceneSource(asset: asset)
                guard let scene = source.defaultScene else {
                    onFail()
                    return
                }
                scene.background.contents = UIColor.clear
                view.scene = scene
                onReady(view)
            }
        }
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}
}

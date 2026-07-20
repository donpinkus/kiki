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
                // No auto-spin here: "Place" drops the EXACT current view, so
                // the model must hold still while the user frames it.
                Model3DView(
                    meshData: object.meshData,
                    autoRotate: false,
                    onReady: { scnView = $0 },
                    onFail: { loadFailed = true }
                )
                .background(Color(.secondarySystemBackground))
            }

            Text("Drag to spin · pinch to zoom — then Place to drop this exact view onto your canvas")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(10)
        }
    }
}

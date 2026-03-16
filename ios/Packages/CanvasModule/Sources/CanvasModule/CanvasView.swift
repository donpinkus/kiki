import SwiftUI
import PencilKit

public struct CanvasView: UIViewRepresentable {
    private let viewModel: CanvasViewModel

    public init(viewModel: CanvasViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> RotatableCanvasContainer {
        let container = RotatableCanvasContainer()
        let canvasView = container.canvasView
        viewModel.attach(canvasView, container: container)
        canvasView.delegate = context.coordinator
        container.onTransformChanged = { [weak viewModel] in
            Task { @MainActor in
                viewModel?.handleTransformChanged()
            }
        }
        return container
    }

    public func updateUIView(_ uiView: RotatableCanvasContainer, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate {
        private let viewModel: CanvasViewModel

        init(viewModel: CanvasViewModel) {
            self.viewModel = viewModel
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                viewModel.handleDrawingChanged()
            }
        }

        public func scrollViewDidZoom(_ scrollView: UIScrollView) {
            Task { @MainActor in
                viewModel.handleTransformChanged()
            }
        }
    }
}

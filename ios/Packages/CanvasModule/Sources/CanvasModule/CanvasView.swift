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
        container.onInteractionChanged = { [weak viewModel] interacting in
            Task { @MainActor in
                if interacting { viewModel?.handleInteractionBegan() }
                else { viewModel?.handleInteractionEnded() }
            }
        }
        container.onUndoRequested = { [weak viewModel] in
            Task { @MainActor in viewModel?.undo() }
        }
        container.onRedoRequested = { [weak viewModel] in
            Task { @MainActor in viewModel?.redo() }
        }
        return container
    }

    public func updateUIView(_ uiView: RotatableCanvasContainer, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let viewModel: CanvasViewModel

        init(viewModel: CanvasViewModel) {
            self.viewModel = viewModel
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                viewModel.handleDrawingChanged()
            }
        }

        public func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                viewModel.handleInteractionBegan()
            }
        }

        public func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                viewModel.handleInteractionEnded()
            }
        }
    }
}

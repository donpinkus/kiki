import SwiftUI

public struct CanvasView: UIViewRepresentable {
    private let viewModel: CanvasViewModel

    public init(viewModel: CanvasViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> RotatableCanvasContainer {
        let container = RotatableCanvasContainer()
        let canvasView = container.canvasView
        viewModel.attach(canvasView, container: container)

        // Wire canvas callbacks to view model
        canvasView.onDrawingChanged = { [weak viewModel] in
            Task { @MainActor in
                viewModel?.handleDrawingChanged()
            }
        }
        canvasView.onInteractionBegan = { [weak viewModel] in
            Task { @MainActor in
                viewModel?.handleInteractionBegan()
            }
        }
        canvasView.onInteractionEnded = { [weak viewModel] in
            Task { @MainActor in
                viewModel?.handleInteractionEnded()
            }
        }

        // Wire container callbacks
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
}

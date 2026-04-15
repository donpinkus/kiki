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

        canvasView.onLassoCompleted = { [weak viewModel] path, image, bounds, preSnapshot in
            Task { @MainActor in
                viewModel?.handleLassoCompleted(path: path, image: image, bounds: bounds, preSnapshot: preSnapshot)
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
        container.onColorPicked = { [weak viewModel] color in
            Task { @MainActor in viewModel?.handleColorPicked(color) }
        }
        container.currentBrushColorProvider = { [weak viewModel] in
            viewModel?.currentBrushColorProvider?() ?? .black
        }
        return container
    }

    public func updateUIView(_ uiView: RotatableCanvasContainer, context: Context) {}
}

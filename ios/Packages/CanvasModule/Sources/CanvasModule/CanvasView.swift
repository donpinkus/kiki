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

        canvasView.onLassoSelectionStarted = { [weak viewModel] path, bounds in
            Task { @MainActor in
                viewModel?.handleLassoSelectionStarted(path: path, bounds: bounds)
            }
        }

        // Wire container callbacks — including lasso gesture transform propagation.
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
        // Lasso gesture transforms → Metal canvas selection quad positioning.
        container.onLassoTransformChanged = { [weak canvasView] translation, scale, rotation in
            canvasView?.updateSelectionTransform(translation: translation, scale: scale, rotation: rotation)
        }
        return container
    }

    public func updateUIView(_ uiView: RotatableCanvasContainer, context: Context) {}
}

import SwiftUI

public struct CanvasView: UIViewRepresentable {
    private let viewModel: CanvasViewModel
    private let drawingSurfaceSide: CGFloat
    private let externalTransformRegionProvider: (() -> CGRect?)?
    private let onExternalTransform: ((CGPoint, CGFloat) -> Void)?

    public init(
        viewModel: CanvasViewModel,
        drawingSurfaceSide: CGFloat = 0,
        externalTransformRegionProvider: (() -> CGRect?)? = nil,
        onExternalTransform: ((CGPoint, CGFloat) -> Void)? = nil
    ) {
        self.viewModel = viewModel
        self.drawingSurfaceSide = drawingSurfaceSide
        self.externalTransformRegionProvider = externalTransformRegionProvider
        self.onExternalTransform = onExternalTransform
    }

    public func makeUIView(context: Context) -> RotatableCanvasContainer {
        let container = RotatableCanvasContainer()
        container.drawingSurfaceSide = drawingSurfaceSide
        container.externalTransformRegionProvider = externalTransformRegionProvider
        container.onExternalTransform = onExternalTransform
        let canvasView = container.canvasView
        viewModel.attach(canvasView, container: container)

        // Wire canvas callbacks to view model.
        // All callbacks fire from UIKit event handlers (main thread) so no
        // Task { @MainActor } wrapper is needed.
        canvasView.onStateChanged = { [weak viewModel] in
            viewModel?.syncState()
        }
        canvasView.onDrawingChanged = { [weak viewModel] in
            viewModel?.handleDrawingChanged()
        }
        canvasView.onInteractionBegan = { [weak viewModel] in
            viewModel?.handleInteractionBegan()
        }
        canvasView.onInteractionEnded = { [weak viewModel] in
            viewModel?.handleInteractionEnded()
        }
        canvasView.onLassoSelectionStarted = { [weak viewModel] path, bounds in
            viewModel?.handleLassoSelectionStarted(path: path, bounds: bounds)
        }
        canvasView.onSnapEvent = { [weak viewModel] event in
            viewModel?.handleSnapEvent(event)
        }

        // Wire container callbacks.
        container.onTransformChanged = { [weak viewModel] in
            viewModel?.handleTransformChanged()
        }
        container.onInteractionChanged = { [weak viewModel] interacting in
            if interacting { viewModel?.handleInteractionBegan() }
            else { viewModel?.handleInteractionEnded() }
        }
        container.onUndoRequested = { [weak viewModel] in viewModel?.undo() }
        container.onRedoRequested = { [weak viewModel] in viewModel?.redo() }
        container.onColorPicked = { [weak viewModel] color in
            viewModel?.handleColorPicked(color)
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

    public func updateUIView(_ uiView: RotatableCanvasContainer, context: Context) {
        uiView.drawingSurfaceSide = drawingSurfaceSide
        // Re-apply closures so they capture the latest geometry / coordinator
        // state on every SwiftUI update (makeUIView only runs once).
        uiView.externalTransformRegionProvider = externalTransformRegionProvider
        uiView.onExternalTransform = onExternalTransform
    }
}

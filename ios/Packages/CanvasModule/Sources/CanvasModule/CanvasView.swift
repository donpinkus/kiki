import SwiftUI

public struct CanvasView: UIViewRepresentable {
    private let viewModel: CanvasViewModel
    private let drawingSurfaceSide: CGFloat
    private let externalTransformRegionProvider: (() -> CGRect?)?
    private let onExternalTransform: ((CGPoint, CGFloat) -> Void)?
    private let onContactPointChanged: ((CGPoint?, CGFloat) -> Void)?
    /// DEV: live brush-input HUD sink + tunable engine-normalization constants.
    private let onBrushInputSample: ((BrushInputSample) -> Void)?
    private let devMaxSpeed: Double
    private let devDistancePeriod: Double
    private let devFadePeriod: Double
    /// Overlay drawing mode: when active, `overlayImage` is shown opaque, locked over
    /// the canvas, with a visual-only fresh-stroke surface above it. Both default off
    /// so split-screen/fullscreen are untouched.
    private let overlayActive: Bool
    private let overlayImage: UIImage?

    public init(
        viewModel: CanvasViewModel,
        drawingSurfaceSide: CGFloat = 0,
        overlayActive: Bool = false,
        overlayImage: UIImage? = nil,
        externalTransformRegionProvider: (() -> CGRect?)? = nil,
        onExternalTransform: ((CGPoint, CGFloat) -> Void)? = nil,
        onContactPointChanged: ((CGPoint?, CGFloat) -> Void)? = nil,
        onBrushInputSample: ((BrushInputSample) -> Void)? = nil,
        devMaxSpeed: Double = 1500,
        devDistancePeriod: Double = 600,
        devFadePeriod: Double = 64
    ) {
        self.viewModel = viewModel
        self.drawingSurfaceSide = drawingSurfaceSide
        self.overlayActive = overlayActive
        self.overlayImage = overlayImage
        self.externalTransformRegionProvider = externalTransformRegionProvider
        self.onExternalTransform = onExternalTransform
        self.onContactPointChanged = onContactPointChanged
        self.onBrushInputSample = onBrushInputSample
        self.devMaxSpeed = devMaxSpeed
        self.devDistancePeriod = devDistancePeriod
        self.devFadePeriod = devFadePeriod
    }

    public func makeUIView(context: Context) -> RotatableCanvasContainer {
        let container = RotatableCanvasContainer()
        container.drawingSurfaceSide = drawingSurfaceSide
        container.externalTransformRegionProvider = externalTransformRegionProvider
        container.onExternalTransform = onExternalTransform
        container.onContactPointChanged = onContactPointChanged
        let canvasView = container.canvasView
        viewModel.attach(canvasView, container: container)

        // DEV: brush-input HUD + tunable constants (set on the Metal view directly).
        canvasView.onBrushInputSample = onBrushInputSample
        canvasView.devMaxSpeed = devMaxSpeed
        canvasView.devDistancePeriod = devDistancePeriod
        canvasView.devFadePeriod = devFadePeriod

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
        canvasView.onStrokeCompleted = { [weak viewModel] stroke in
            viewModel?.handleStrokeCompleted(stroke)
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
        // Apply initial overlay drawing-mode state (via the view model so it survives a
        // container re-create).
        NSLog("%@", "🔬OVL CanvasView.makeUIView overlayActive=\(overlayActive) hasImage=\(overlayImage != nil)")
        viewModel.setOverlayActive(overlayActive)
        viewModel.setOverlayImage(overlayImage)
        return container
    }

    public func updateUIView(_ uiView: RotatableCanvasContainer, context: Context) {
        uiView.drawingSurfaceSide = drawingSurfaceSide
        // Re-apply closures so they capture the latest geometry / coordinator
        // state on every SwiftUI update (makeUIView only runs once).
        uiView.externalTransformRegionProvider = externalTransformRegionProvider
        uiView.onExternalTransform = onExternalTransform
        uiView.onContactPointChanged = onContactPointChanged
        // DEV: push the tunable constants every update so Brush Studio sliders take effect live.
        uiView.canvasView.onBrushInputSample = onBrushInputSample
        uiView.canvasView.devMaxSpeed = devMaxSpeed
        uiView.canvasView.devDistancePeriod = devDistancePeriod
        uiView.canvasView.devFadePeriod = devFadePeriod
        // Push overlay drawing-mode state on every update (image changes ~2 FPS while
        // streaming). Routed through the view model — idempotent setters.
        NSLog("%@", "🔬OVL CanvasView.updateUIView overlayActive=\(overlayActive) hasImage=\(overlayImage != nil)")
        viewModel.setOverlayActive(overlayActive)
        viewModel.setOverlayImage(overlayImage)
    }
}

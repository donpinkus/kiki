import SwiftUI

/// Holds the complete canvas state for save/restore across sessions.
public struct CanvasState: Sendable {
    public let drawingData: Data
    public let backgroundImageData: Data?

    public init(drawingData: Data, backgroundImageData: Data?) {
        self.drawingData = drawingData
        self.backgroundImageData = backgroundImageData
    }
}

@MainActor
@Observable
public final class CanvasViewModel {

    // MARK: - Properties

    /// Cursor divisor for approximating visual stroke size in the sidebar tooltip.
    /// With the custom engine, pressure gamma means the visual width ≈ baseWidth * 0.5 at rest,
    /// so divisor ~2.0 gives a reasonable preview.
    public static let penCursorDivisor: CGFloat = 2.0

    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isEmpty = true
    public private(set) var scale: CGFloat = 1.0
    public private(set) var rotation: CGFloat = 0
    public private(set) var translation: CGPoint = .zero

    public var isDefaultTransform: Bool {
        abs(rotation) < 0.01 && abs(scale - 1.0) < 0.01
            && abs(translation.x) < 0.01 && abs(translation.y) < 0.01
    }

    public var hasBackgroundContent: Bool { container?.backgroundImage != nil }
    public private(set) var isInteracting = false
    public private(set) var hasLassoSelection = false

    private weak var canvasView: DrawingCanvasView?
    private weak var container: RotatableCanvasContainer?
    private var pendingState: CanvasState?
    private var preLassoSnapshot: CGImage?
    private var lassoClosedPath: CGPath?

    public let canvasChanges: AsyncStream<SketchSnapshot>
    private let changesContinuation: AsyncStream<SketchSnapshot>.Continuation

    /// Called when the eyedropper long-press commits a sampled color.
    /// The AppCoordinator sets this to update its currentColor.
    public var onColorPicked: ((UIColor) -> Void)?

    /// Supplies the current brush color so the preview ring can show it as the "previous" half.
    /// The AppCoordinator sets this.
    public var currentBrushColorProvider: (() -> UIColor)?

    // MARK: - Lifecycle

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: SketchSnapshot.self)
        canvasChanges = stream
        changesContinuation = continuation
    }

    deinit {
        changesContinuation.finish()
    }

    // MARK: - Public API

    func attach(_ canvasView: DrawingCanvasView, container: RotatableCanvasContainer) {
        self.canvasView = canvasView
        self.container = container
        container.updateCursorSize(diameter: 5)

        // Apply pending state from a saved drawing (set via setPendingState before navigation).
        // This runs BEFORE callbacks are wired in makeUIView, so no handleDrawingChanged fires.
        if let state = pendingState {
            if let strokes = try? JSONDecoder().decode([Stroke].self, from: state.drawingData) {
                canvasView.loadStrokes(strokes)
            }
            if let bgData = state.backgroundImageData, let bgImage = UIImage(data: bgData) {
                container.setBackgroundImage(bgImage)
            }
            pendingState = nil
            updateState()
        }
    }

    public func selectBrush(_ config: BrushConfig) {
        canvasView?.currentTool = .brush(config)
        container?.updateCursorSize(diameter: config.baseWidth, divisor: Self.penCursorDivisor)
    }

    public func selectEraser(width: CGFloat = 5) {
        canvasView?.currentTool = .eraser(width: width)
        container?.updateCursorSize(diameter: width, divisor: Self.penCursorDivisor)
    }

    public func selectLasso() {
        canvasView?.currentTool = .lasso
        container?.updateCursorSize(diameter: 0)
    }

    // MARK: - Lasso Selection

    func handleLassoCompleted(path: CGPath, image: UIImage, bounds: CGRect, preSnapshot: CGImage?) {
        preLassoSnapshot = preSnapshot
        lassoClosedPath = path
        container?.showLassoSelection(image: image, bounds: bounds, path: path)
        hasLassoSelection = true
    }

    /// Transition from Phase A (floating selection) to Phase B (clip mask).
    /// Called when switching from lasso tool to pen/eraser.
    public func transitionToClipMode() {
        guard let container, let canvasView else { return }
        guard let result = container.commitLassoSelection() else { return }
        canvasView.compositeSelectionImage(result.image, at: result.bounds, transform: result.transform)
        if let path = lassoClosedPath {
            canvasView.lassoClipPath = path
            canvasView.setNeedsDisplay()
        }
        // hasLassoSelection stays true — clip mask is active
    }

    /// Clear the lasso entirely. Commits floating selection if active, removes clip mask.
    /// Called by the "Clear Lasso" button.
    public func clearLasso() {
        guard let container, let canvasView else { return }

        if container.hasActiveLassoSelection {
            // Phase A: commit floating selection back to canvas
            if let result = container.commitLassoSelection() {
                canvasView.compositeSelectionImage(result.image, at: result.bounds, transform: result.transform)
            }
        }

        // Push undo with pre/post snapshots
        let postSnapshot = canvasView.persistentImageSnapshot
        if let pre = preLassoSnapshot {
            canvasView.undoStack.push(.lassoMove(preMoveSnapshot: pre, postMoveSnapshot: postSnapshot))
        }

        canvasView.lassoClipPath = nil
        canvasView.setNeedsDisplay()
        preLassoSnapshot = nil
        lassoClosedPath = nil
        hasLassoSelection = false
        updateState()
        handleDrawingChanged()
    }

    /// Cancel the lasso selection, restoring the original persistent bitmap.
    public func cancelLassoSelection() {
        guard let container, let canvasView else { return }
        if container.hasActiveLassoSelection {
            container.clearLassoSelection()
        }
        if let preSnapshot = preLassoSnapshot {
            canvasView.restorePersistentImage(preSnapshot)
        }
        canvasView.lassoClipPath = nil
        canvasView.setNeedsDisplay()
        preLassoSnapshot = nil
        lassoClosedPath = nil
        hasLassoSelection = false
        updateState()
    }

    /// Clear only the clip path (not the floating selection). Used when switching back to lasso tool.
    public func clearLassoClipOnly() {
        canvasView?.lassoClipPath = nil
        canvasView?.setNeedsDisplay()
        lassoClosedPath = nil
        hasLassoSelection = false
    }

    public func undo() {
        guard let action = canvasView?.performUndo() else { return }
        // Restore background image for actions that modify it
        switch action {
        case .lineartSwap(_, _, _, let prevBackground, _):
            container?.setBackgroundImage(prevBackground)
        case .clear(_, _, _, let prevBackground):
            container?.setBackgroundImage(prevBackground)
        default:
            break
        }
        updateState()
    }

    public func redo() {
        guard let action = canvasView?.performRedo() else { return }
        // Re-apply background changes for actions that modify it
        switch action {
        case .lineartSwap(_, _, _, _, let newBackground):
            if let img = newBackground {
                container?.bakeImageIntoCanvas(img)
            }
        case .clear:
            container?.setBackgroundImage(nil)
        default:
            break
        }
        updateState()
    }

    public func clear() {
        guard let canvasView else { return }
        let prev = canvasView.clearAll()
        let prevBg = container?.backgroundImage
        canvasView.undoStack.push(.clear(
            prevStrokes: prev.strokes,
            prevPersistent: prev.persistent,
            prevBaseImage: prev.baseImage,
            prevBackground: prevBg
        ))
        container?.setBackgroundImage(nil)
        resetViewTransform()
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: 0,
            bounds: .zero
        ))
    }

    public func swapLineart(image: UIImage) {
        guard let canvasView else { return }
        let prevStrokes = canvasView.strokes
        let prev = canvasView.clearAll()
        let prevBgImage = container?.backgroundImage

        canvasView.undoStack.push(.lineartSwap(
            prevStrokes: prevStrokes,
            prevPersistent: prev.persistent,
            prevBaseImage: prev.baseImage,
            prevBackground: prevBgImage,
            newBackground: image
        ))

        container?.bakeImageIntoCanvas(image)
        updateState()
    }

    public func resetViewTransform() {
        container?.resetTransform()
        scale = 1.0
        rotation = 0
        translation = .zero
    }

    public func captureSnapshot() -> SketchSnapshot? {
        guard let canvasView else { return nil }
        guard !canvasView.isEmpty || hasBackgroundContent else { return nil }

        let outputSize = canvasView.bounds.size
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }

        let rect = CGRect(origin: .zero, size: outputSize)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let image = renderer.image { ctx in
            // Composite: white base → background image → custom canvas strokes
            UIColor.white.setFill()
            UIRectFill(rect)
            container?.backgroundImage?.draw(in: rect)
            canvasView.drawHierarchy(in: rect, afterScreenUpdates: true)

            // Include floating lasso selection in stream capture
            if let lasso = container?.lassoSelectionSnapshot() {
                let cgCtx = ctx.cgContext
                cgCtx.saveGState()
                cgCtx.concatenate(lasso.transform)
                lasso.image.draw(in: lasso.bounds)
                cgCtx.restoreGState()
            }
        }

        let strokeCount = canvasView.strokes.count
        return SketchSnapshot(
            image: image,
            strokeCount: max(strokeCount, hasBackgroundContent ? 1 : 0),
            bounds: rect
        )
    }

    // MARK: - Persistence

    /// Returns the current stroke data as JSON, or nil if the canvas is not attached.
    public func exportDrawingData() -> Data? {
        canvasView?.exportStrokeData()
    }

    /// Returns the current background image (lineart swap) as PNG data, or nil.
    public func exportBackgroundImageData() -> Data? {
        container?.backgroundImage?.pngData()
    }

    /// Sets canvas state to apply on the next `attach()` call.
    /// Used when loading a saved drawing before the CanvasView is created.
    public func setPendingState(_ state: CanvasState?) {
        pendingState = state
    }

    /// Renders a thumbnail of the current canvas at the given max dimension.
    /// Returns nil if the canvas is not attached or is empty.
    public func generateThumbnail(maxDimension: CGFloat = 256) -> UIImage? {
        guard let canvasView else { return nil }
        guard !canvasView.isEmpty || hasBackgroundContent else { return nil }

        let fullSize = canvasView.bounds.size
        guard fullSize.width > 0, fullSize.height > 0 else { return nil }

        let scale = min(maxDimension / fullSize.width, maxDimension / fullSize.height, 1.0)
        let thumbSize = CGSize(width: fullSize.width * scale, height: fullSize.height * scale)

        let renderer = UIGraphicsImageRenderer(size: thumbSize)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: thumbSize)
            UIColor.white.setFill()
            UIRectFill(rect)
            container?.backgroundImage?.draw(in: rect)
            canvasView.drawHierarchy(in: rect, afterScreenUpdates: true)
        }
    }

    // MARK: - Internal

    func handleDrawingChanged() {
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: canvasView?.strokes.count ?? 0,
            bounds: canvasView?.bounds ?? .zero
        ))
    }

    func handleTransformChanged() {
        scale = container?.scale ?? 1.0
        rotation = container?.rotation ?? 0
        translation = container?.translation ?? .zero
    }

    public func handleInteractionBegan() { isInteracting = true }
    public func handleInteractionEnded() { isInteracting = false }

    func handleColorPicked(_ color: UIColor) {
        onColorPicked?(color)
    }

    // MARK: - Private

    private func updateState() {
        guard let canvasView else { return }
        isEmpty = canvasView.isEmpty && !hasBackgroundContent
        canUndo = canvasView.undoStack.canUndo
        canRedo = canvasView.undoStack.canRedo
    }
}

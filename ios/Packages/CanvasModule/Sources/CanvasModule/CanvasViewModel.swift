import SwiftUI
import PencilKit

@MainActor
@Observable
public final class CanvasViewModel {

    // MARK: - Properties

    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isEmpty = true
    public private(set) var scale: CGFloat = 1.0
    public private(set) var rotation: CGFloat = 0

    public var isDefaultTransform: Bool {
        abs(rotation) < 0.01 && abs(scale - 1.0) < 0.01
    }

    public var hasBackgroundContent: Bool { container?.backgroundImage != nil }

    private weak var canvasView: PKCanvasView?
    private weak var container: RotatableCanvasContainer?

    public let canvasChanges: AsyncStream<SketchSnapshot>
    private let changesContinuation: AsyncStream<SketchSnapshot>.Continuation

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

    func attach(_ canvasView: PKCanvasView, container: RotatableCanvasContainer) {
        self.canvasView = canvasView
        self.container = container
        canvasView.drawingPolicy = .anyInput
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
        container.updateCursorSize(diameter: 5)
    }

    public func selectBrush(width: CGFloat = 5) {
        canvasView?.tool = PKInkingTool(.pen, color: .black, width: width)
        container?.updateCursorSize(diameter: width)
    }

    public func selectEraser(width: CGFloat = 5) {
        canvasView?.tool = PKInkingTool(.pen, color: .white, width: width)
        container?.updateCursorSize(diameter: width)
    }

    public func undo() {
        canvasView?.undoManager?.undo()
        updateState()
    }

    public func redo() {
        canvasView?.undoManager?.redo()
        updateState()
    }

    public func clear() {
        container?.setBackgroundImage(nil)
        canvasView?.drawing = PKDrawing()
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
        let prevDrawing = canvasView.drawing
        let prevBgImage = container?.backgroundImage

        canvasView.undoManager?.registerUndo(withTarget: self) { target in
            target.canvasView?.undoManager?.disableUndoRegistration()
            target.canvasView?.drawing = prevDrawing
            target.canvasView?.undoManager?.enableUndoRegistration()
            target.container?.setBackgroundImage(prevBgImage)
            target.updateState()
        }

        canvasView.undoManager?.disableUndoRegistration()
        canvasView.drawing = PKDrawing()
        canvasView.undoManager?.enableUndoRegistration()

        container?.setBackgroundImage(image)
        updateState()
    }

    public func resetViewTransform() {
        container?.resetTransform()
        scale = 1.0
        rotation = 0
    }

    public func captureSnapshot() -> SketchSnapshot? {
        guard let canvasView else { return nil }
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty || hasBackgroundContent else { return nil }

        // IMPORTANT: Use drawHierarchy to capture the live view content.
        // Do NOT use PKDrawing.image(from:scale:) — it returns a blank image
        // when the canvas is inside a transformed parent (RotatableCanvasContainer).
        let outputSize = canvasView.bounds.size
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }

        let rect = CGRect(origin: .zero, size: outputSize)
        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let image = renderer.image { _ in
            // Always composite: white base → background image → PK strokes (transparent canvas)
            UIColor.white.setFill()
            UIRectFill(rect)
            container?.backgroundImage?.draw(in: rect)
            canvasView.drawHierarchy(in: rect, afterScreenUpdates: true)
        }

        return SketchSnapshot(
            image: image,
            strokeCount: max(drawing.strokes.count, hasBackgroundContent ? 1 : 0),
            bounds: hasBackgroundContent ? rect : drawing.bounds
        )
    }

    // MARK: - Internal

    func handleDrawingChanged() {
        updateState()
        // Notify listeners that the canvas changed (lightweight — no snapshot capture).
        // Actual snapshot capture is deferred to captureSnapshot() calls from the scheduler.
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: canvasView?.drawing.strokes.count ?? 0,
            bounds: canvasView?.drawing.bounds ?? .zero
        ))
    }

    func handleTransformChanged() {
        scale = container?.scale ?? 1.0
        rotation = container?.rotation ?? 0
    }

    // MARK: - Private

    private func updateState() {
        guard let canvasView else { return }
        let drawing = canvasView.drawing
        isEmpty = drawing.strokes.isEmpty && !hasBackgroundContent
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }
}

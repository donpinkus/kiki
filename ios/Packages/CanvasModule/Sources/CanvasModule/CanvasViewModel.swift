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
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = false
    }

    public func selectBrush(width: CGFloat = 5) {
        canvasView?.tool = PKInkingTool(.pen, color: .black, width: width)
    }

    public func selectEraser(width: CGFloat = 5) {
        canvasView?.tool = PKEraserTool(.bitmap, width: width)
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
        canvasView?.drawing = PKDrawing()
        resetViewTransform()
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: 0,
            bounds: .zero
        ))
    }

    public func resetViewTransform() {
        container?.resetTransform()
        scale = 1.0
        rotation = 0
    }

    public func captureSnapshot() -> SketchSnapshot? {
        guard let canvasView else { return nil }
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { return nil }

        // Use bounds (not frame) — frame is undefined when an ancestor view has
        // a non-identity CGAffineTransform (zoom/rotation on transformView).
        // For PKCanvasView (a UIScrollView), bounds.origin == contentOffset,
        // so this also captures the correct region if scrolled.
        let captureRect = canvasView.bounds
        let outputSize = captureRect.size
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }

        let renderer = UIGraphicsImageRenderer(size: outputSize)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: outputSize))
            let drawingImage = drawing.image(from: captureRect, scale: 1.0)
            drawingImage.draw(in: CGRect(origin: .zero, size: outputSize))
        }

        return SketchSnapshot(
            image: image,
            strokeCount: drawing.strokes.count,
            bounds: drawing.bounds
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
        isEmpty = drawing.strokes.isEmpty
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }
}

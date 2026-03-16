import SwiftUI
import PencilKit

@MainActor
@Observable
public final class CanvasViewModel {

    // MARK: - Properties

    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isEmpty = true

    private weak var canvasView: PKCanvasView?

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

    func attach(_ canvasView: PKCanvasView) {
        self.canvasView = canvasView
        canvasView.drawingPolicy = .anyInput
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
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
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: 0,
            bounds: .zero
        ))
    }

    public func captureSnapshot() -> SketchSnapshot? {
        guard let canvasView else { return nil }
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty else { return nil }

        // Render the canvas view as-is (white background + strokes), rather than
        // extracting the drawing separately which loses strokes during compositing.
        let renderer = UIGraphicsImageRenderer(bounds: canvasView.bounds)
        let image = renderer.image { _ in
            canvasView.drawHierarchy(in: canvasView.bounds, afterScreenUpdates: true)
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

    // MARK: - Private

    private func updateState() {
        guard let canvasView else { return }
        let drawing = canvasView.drawing
        isEmpty = drawing.strokes.isEmpty
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }
}

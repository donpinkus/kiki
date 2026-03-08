import SwiftUI
import PencilKit

@Observable
public final class CanvasViewModel {

    // MARK: - Properties

    public private(set) var drawing = PKDrawing()
    public private(set) var canUndo = false
    public private(set) var canRedo = false

    private var undoManager: UndoManager?
    private let continuation: AsyncStream<SketchSnapshot>.Continuation

    /// Stream of canvas change events for downstream consumers.
    public let canvasDidChange: AsyncStream<SketchSnapshot>

    // MARK: - Lifecycle

    public init() {
        var cont: AsyncStream<SketchSnapshot>.Continuation!
        canvasDidChange = AsyncStream { cont = $0 }
        continuation = cont
    }

    deinit {
        continuation.finish()
    }

    // MARK: - Public API

    public func setUndoManager(_ undoManager: UndoManager?) {
        self.undoManager = undoManager
    }

    public func drawingDidChange(_ drawing: PKDrawing, canvasView: PKCanvasView) {
        self.drawing = drawing
        updateUndoState()

        let image = canvasView.drawing.image(
            from: canvasView.bounds,
            scale: UIScreen.main.scale
        )
        let snapshot = SketchSnapshot(
            image: image,
            drawing: drawing,
            strokeCount: drawing.strokes.count
        )
        continuation.yield(snapshot)
    }

    public func undo() {
        undoManager?.undo()
        updateUndoState()
    }

    public func redo() {
        undoManager?.redo()
        updateUndoState()
    }

    public func clear() {
        drawing = PKDrawing()
        updateUndoState()
    }

    // MARK: - Private

    private func updateUndoState() {
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }
}

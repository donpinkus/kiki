import SwiftUI
import PencilKit

/// Tool types available in the canvas toolbar.
public enum CanvasTool: Sendable {
    case pen
    case eraser
}

@MainActor
@Observable
public final class CanvasViewModel {

    // MARK: - Properties

    public private(set) var drawing = PKDrawing()
    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public var selectedTool: CanvasTool = .pen

    /// The PencilKit tool corresponding to the current selection.
    public var currentTool: PKTool {
        switch selectedTool {
        case .pen:
            PKInkingTool(.pen, color: .black, width: 5)
        case .eraser:
            PKEraserTool(.bitmap)
        }
    }

    private var undoManager: UndoManager?
    private let continuation: AsyncStream<SketchSnapshot>.Continuation
    private var snapshotTask: Task<Void, Never>?

    /// Stream of canvas change events for downstream consumers.
    /// Snapshots are throttled to avoid blocking the main thread during active drawing.
    public nonisolated let canvasDidChange: AsyncStream<SketchSnapshot>

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

    /// Called by the PencilKit delegate on every stroke change.
    /// Updates drawing state immediately (cheap) but defers snapshot
    /// generation to avoid blocking the main thread at 60Hz.
    public func drawingDidChange(_ drawing: PKDrawing, canvasView: PKCanvasView) {
        self.drawing = drawing
        updateUndoState()

        // Cancel any pending snapshot — only the latest drawing matters.
        snapshotTask?.cancel()
        snapshotTask = Task {
            // Yield to let PencilKit finish its rendering pass first.
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms throttle
            guard !Task.isCancelled else { return }

            let scale = canvasView.window?.screen.scale ?? 2.0
            let image = canvasView.drawing.image(
                from: canvasView.bounds,
                scale: scale
            )
            let snapshot = SketchSnapshot(
                image: image,
                strokeCount: drawing.strokes.count
            )
            continuation.yield(snapshot)
        }
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

import SwiftUI

@MainActor
@Observable
public final class CanvasViewModel {

    // MARK: - Properties

    public private(set) var canUndo = false
    public private(set) var canRedo = false
    public private(set) var isEmpty = true

    public var stabilizationAmount: CGFloat = 0.0 {
        didSet { canvasView?.stabilizationAmount = stabilizationAmount }
    }

    private weak var canvasView: DrawingCanvasView?

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

    func attach(_ canvasView: DrawingCanvasView) {
        self.canvasView = canvasView
        canvasView.currentTool = ToolConfig(lineWidth: 5, color: .black, isEraser: false)
        canvasView.stabilizationAmount = stabilizationAmount
        canvasView.onDrawingChanged = { [weak self] in
            self?.handleDrawingChanged()
        }
    }

    public func selectBrush(width: CGFloat = 5) {
        canvasView?.currentTool = ToolConfig(lineWidth: width, color: .black, isEraser: false)
    }

    public func selectEraser(width: CGFloat = 5) {
        canvasView?.currentTool = ToolConfig(lineWidth: width, color: .clear, isEraser: true)
    }

    public func undo() {
        canvasView?.undo()
        updateState()
    }

    public func redo() {
        canvasView?.redo()
        updateState()
    }

    public func clear() {
        canvasView?.clear()
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: 0,
            bounds: .zero
        ))
    }

    public func captureSnapshot() -> SketchSnapshot? {
        guard let canvasView, !canvasView.isEmpty else { return nil }

        guard let image = canvasView.captureSnapshot() else { return nil }

        return SketchSnapshot(
            image: image,
            strokeCount: 0,
            bounds: canvasView.bounds
        )
    }

    // MARK: - Private

    private func handleDrawingChanged() {
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: 0,
            bounds: canvasView?.bounds ?? .zero
        ))
    }

    private func updateState() {
        guard let canvasView else { return }
        isEmpty = canvasView.isEmpty
        canUndo = canvasView.canUndo
        canRedo = canvasView.canRedo
    }
}

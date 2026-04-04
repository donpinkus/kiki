import SwiftUI
import PencilKit

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

    /// PK's .pen ink renders strokes ~3x smaller than the specified width due to pressure modulation.
    /// Used by both the canvas cursor and the slider tooltip to approximate visual stroke size.
    public static let penCursorDivisor: CGFloat = 3.0

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

    private weak var canvasView: PKCanvasView?
    private weak var container: RotatableCanvasContainer?
    private var pendingState: CanvasState?

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

        // Apply pending state from a saved drawing (set via setPendingState before navigation).
        // This runs BEFORE the delegate is set in makeUIView, so no canvasViewDrawingDidChange fires.
        if let state = pendingState {
            if let drawing = try? PKDrawing(data: state.drawingData) {
                canvasView.drawing = drawing
            }
            if let bgData = state.backgroundImageData, let bgImage = UIImage(data: bgData) {
                container.setBackgroundImage(bgImage)
            }
            pendingState = nil
            updateState()
        }
    }

    public func selectBrush(width: CGFloat = 5) {
        canvasView?.tool = PKInkingTool(.pen, color: .black, width: width)
        container?.updateCursorSize(diameter: width, divisor: Self.penCursorDivisor)
    }

    public func selectEraser(width: CGFloat = 5) {
        canvasView?.tool = PKInkingTool(.pen, color: .white, width: width)
        container?.updateCursorSize(diameter: width, divisor: Self.penCursorDivisor)
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
        translation = .zero
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

    // MARK: - Persistence

    /// Returns the current PKDrawing as serialized data, or nil if the canvas is not attached.
    public func exportDrawingData() -> Data? {
        canvasView?.drawing.dataRepresentation()
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
        let drawing = canvasView.drawing
        guard !drawing.strokes.isEmpty || hasBackgroundContent else { return nil }

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
        translation = container?.translation ?? .zero
    }

    public func handleInteractionBegan() { isInteracting = true }
    public func handleInteractionEnded() { isInteracting = false }

    // MARK: - Private

    private func updateState() {
        guard let canvasView else { return }
        let drawing = canvasView.drawing
        isEmpty = drawing.strokes.isEmpty && !hasBackgroundContent
        canUndo = canvasView.undoManager?.canUndo ?? false
        canRedo = canvasView.undoManager?.canRedo ?? false
    }
}

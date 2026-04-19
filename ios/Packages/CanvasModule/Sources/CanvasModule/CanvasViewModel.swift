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

    // MARK: - Layer State

    public private(set) var layers: [LayerInfo] = [LayerInfo(name: "Layer 1")]
    public private(set) var activeLayerIndex: Int = 0

    private weak var canvasView: MetalCanvasView?
    private weak var container: RotatableCanvasContainer?
    private var pendingState: CanvasState?
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

    func attach(_ canvasView: MetalCanvasView, container: RotatableCanvasContainer) {
        self.canvasView = canvasView
        self.container = container
        container.updateCursorSize(diameter: 5)

        // Apply pending state from a saved drawing (set via setPendingState before navigation).
        // This runs BEFORE callbacks are wired in makeUIView, so no handleDrawingChanged fires.
        if let state = pendingState {
            if !state.drawingData.isEmpty {
                // loadDrawingData auto-detects format: PNG bitmap (current) or stroke JSON (legacy).
                canvasView.loadDrawingData(state.drawingData)
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

    func handleLassoSelectionStarted(path: CGPath, bounds: CGRect) {
        lassoClosedPath = path
        container?.showLassoSelection(bounds: bounds, path: path)
        hasLassoSelection = true
    }

    /// Transition from Phase A (floating selection) to Phase B (clip mask).
    /// Called when switching from lasso tool to pen/eraser. Commits the floating
    /// selection, sets the clip path, and shows marching ants outline.
    public func transitionToClipMode() {
        guard let container, let canvasView else { return }
        canvasView.commitSelection()
        container.commitLassoSelection()
        if let path = lassoClosedPath {
            canvasView.setClipPath(path)
        }
    }

    /// Clear the lasso entirely. Commits floating selection if active, removes clip mask.
    public func clearLasso() {
        guard let container, let canvasView else { return }
        if container.hasActiveLassoSelection {
            canvasView.commitSelection()
            container.commitLassoSelection()
        }
        canvasView.setClipPath(nil)
        lassoClosedPath = nil
        hasLassoSelection = false
        handleDrawingChanged()
    }

    /// Cancel the lasso selection, restoring the original persistent bitmap.
    public func cancelLassoSelection() {
        guard let container, let canvasView else { return }
        if container.hasActiveLassoSelection {
            container.clearLassoSelection()
        }
        canvasView.cancelSelection()
        canvasView.setClipPath(nil)
        lassoClosedPath = nil
        hasLassoSelection = false
    }

    /// Clear only the clip path (not the floating selection).
    public func clearLassoClipOnly() {
        canvasView?.setClipPath(nil)
        lassoClosedPath = nil
        hasLassoSelection = false
    }

    // MARK: - Layer Management

    public func addLayer() {
        canvasView?.addLayer()
    }

    public func selectLayer(at index: Int) {
        canvasView?.selectLayer(at: index)
    }

    public func toggleLayerVisibility(at index: Int) {
        canvasView?.toggleLayerVisibility(at: index)
    }

    public func deleteLayer(at index: Int) {
        canvasView?.deleteLayer(at: index)
    }

    public func moveLayer(from source: Int, to destination: Int) {
        canvasView?.moveLayer(from: source, to: destination)
    }

    public func undo() {
        canvasView?.performUndo()
    }

    public func redo() {
        canvasView?.performRedo()
    }

    public func clear() {
        guard let canvasView else { return }
        canvasView.clearAll()
        container?.setBackgroundImage(nil)
        resetViewTransform()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: 0,
            bounds: .zero
        ))
    }

    public func swapLineart(image: UIImage) {
        guard let canvasView else { return }
        canvasView.clearAll()
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

        // Read the canvas texture directly — no drawHierarchy, no GPU sync.
        // `.shared` storage on Apple Silicon means coherent CPU read.
        let canvasCGImage = canvasView.persistentImageSnapshot

        let rect = CGRect(origin: .zero, size: outputSize)
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // sRGB — match Metal canvas color space
        let renderer = UIGraphicsImageRenderer(size: outputSize, format: format)
        let image = renderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(rect)
            container?.backgroundImage?.draw(in: rect)
            if let cgImg = canvasCGImage {
                UIImage(cgImage: cgImg).draw(in: rect)
            }
        }

        return SketchSnapshot(
            image: image,
            strokeCount: max(canvasView.strokeCount, hasBackgroundContent ? 1 : 0),
            bounds: rect
        )
    }

    // MARK: - Persistence

    /// Returns the current layered drawing data (JSON envelope with per-layer PNGs),
    /// or nil if the canvas is not attached or empty.
    public func exportDrawingData() -> Data? {
        canvasView?.exportLayeredData()
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

        let canvasCGImage = canvasView.persistentImageSnapshot

        let scale = min(maxDimension / fullSize.width, maxDimension / fullSize.height, 1.0)
        let thumbSize = CGSize(width: fullSize.width * scale, height: fullSize.height * scale)

        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // sRGB — match Metal canvas color space
        let renderer = UIGraphicsImageRenderer(size: thumbSize, format: format)
        return renderer.image { _ in
            let rect = CGRect(origin: .zero, size: thumbSize)
            UIColor.white.setFill()
            UIRectFill(rect)
            container?.backgroundImage?.draw(in: rect)
            if let cgImg = canvasCGImage {
                UIImage(cgImage: cgImg).draw(in: rect)
            }
        }
    }

    // MARK: - Internal

    func handleDrawingChanged() {
        updateState()
        changesContinuation.yield(SketchSnapshot(
            image: UIImage(),
            strokeCount: canvasView?.strokeCount ?? 0,
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

    /// Sync @Observable properties from the canvas view. Called automatically
    /// via onStateChanged callback — CanvasViewModel methods no longer need
    /// to call this manually.
    func syncState() {
        updateState()
    }

    // MARK: - Private

    private func updateState() {
        guard let canvasView else { return }
        isEmpty = canvasView.isEmpty && !hasBackgroundContent
        canUndo = canvasView.canUndo
        canRedo = canvasView.canRedo
        layers = canvasView.layers
        activeLayerIndex = canvasView.activeLayerIndex
    }
}

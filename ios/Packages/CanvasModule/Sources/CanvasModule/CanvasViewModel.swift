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

    /// Display divisor applied to slider previews. 1.0 means the preview circle
    /// matches the actual stamp diameter (= configured baseWidth) at rest. Kept
    /// as a single named constant so the slider preview and any future cursor
    /// callers stay in sync.
    public static let penCursorDivisor: CGFloat = 1.0

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

    /// THE unified selection (documents/plans/unified-selection.md): one mask,
    /// authored by SAM taps and/or freehand loops, persistent across tool
    /// switches; consumed as the paint clip, movable via `selection.beginMove`.
    public let selection = SelectionController()
    public var hasSelection: Bool { selection.hasSelection }
    /// Monotonic content version — bumps on every committed canvas change. The
    /// selection re-encodes its SAM embedding when this moves between objects.
    public private(set) var contentVersion = 0

    // MARK: - Layer State

    public private(set) var layers: [LayerInfo] = [LayerInfo(name: "Layer 1")]
    public private(set) var activeLayerIndex: Int = 0

    private weak var canvasView: MetalCanvasView?
    private weak var container: RotatableCanvasContainer?
    private var pendingState: CanvasState?
    private var selectedTool: ToolState = .brush(.defaultPen)

    public let canvasChanges: AsyncStream<SketchSnapshot>
    private let changesContinuation: AsyncStream<SketchSnapshot>.Continuation

    /// Called when the eyedropper long-press commits a sampled color.
    /// The AppCoordinator sets this to update its currentColor.
    public var onColorPicked: ((UIColor) -> Void)?

    /// Fires once per stroke (on touch-down). The AppCoordinator uses this
    /// to auto-resume after an idle-timeout so the user can just start
    /// drawing instead of needing to tap an overlay or navigate pages.
    public var onUserActivity: (() -> Void)?

    /// Supplies the current brush color so the preview ring can show it as the "previous" half.
    /// The AppCoordinator sets this.
    public var currentBrushColorProvider: (() -> UIColor)?

    /// Telemetry callback for QuickShape lifecycle events. Set by the
    /// AppCoordinator to forward to analytics via `Analytics.track`.
    public var onSnapEvent: ((SnapEvent) -> Void)?

    /// Fires the first time per app launch that a brush stroke commits with
    /// QuickShape enabled. AppCoordinator uses this to drive the one-time
    /// NUX tooltip ("Hold to snap…").
    public var onFirstBrushStrokeCommitted: (() -> Void)?
    private var hasFiredFirstBrushStrokeThisSession: Bool = false

    /// Forwarded from `MetalCanvasView.onStrokeCompleted`: every completed brush stroke
    /// (dry + wet), already normalized to canvas pixels. Used by the dev stroke recorder
    /// (Brush Studio → "Record strokes" → BrushHarness fixture).
    public var onStrokeCompleted: ((Stroke) -> Void)?

    /// Fires on ANY canvas content mutation — stroke, eraser, undo/redo, fixture
    /// replay. Broader than `onStrokeCompleted`; the app's idle stream guard uses
    /// it as the "user is actively working" signal.
    public var onContentChanged: (() -> Void)?

    func handleStrokeCompleted(_ stroke: Stroke) {
        onStrokeCompleted?(stroke)
    }

    // MARK: - Lifecycle

    public init() {
        let (stream, continuation) = AsyncStream.makeStream(of: SketchSnapshot.self)
        canvasChanges = stream
        changesContinuation = continuation
        selection.segmenterFactory = { try SAM2Segmenter.bundled() }
    }

    deinit {
        changesContinuation.finish()
    }

    // MARK: - Public API

    func attach(_ canvasView: MetalCanvasView, container: RotatableCanvasContainer) {
        self.canvasView = canvasView
        self.container = container

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

        applySelectedToolToAttachedViews()

        // Unified-selection wiring. The tap/loop sources and the clip sink live
        // on the canvas view; AppCoordinator supplies the image provider.
        canvasView.onWandTap = { [weak self] point in
            guard let self, let canvasView = self.canvasView else { return }
            self.selection.handleTap(at: point, viewSize: canvasView.bounds.size)
        }
        canvasView.onFreehandLoopClosed = { [weak self] path in
            guard let self, let canvasView = self.canvasView else { return }
            self.selection.addFreehandPath(path, viewSize: canvasView.bounds.size)
        }
        selection.contentVersionProvider = { [weak self] in self?.contentVersion ?? 0 }
        selection.onSelectionChanged = { [weak self] path, markers in
            guard let self, let canvasView = self.canvasView else { return }
            canvasView.setClipPath(path)
            canvasView.setWandMarkers(markers)
        }
        selection.onAuthorModeChanged = { [weak self] in
            // Remap tap-capture ↔ loop-capture when the panel mode flips.
            guard let self, self.isSelectionToolActive else { return }
            self.selectSelectionTool()
        }
        selection.onBeginMove = { [weak self] path in
            guard let self, let canvasView = self.canvasView, let container = self.container,
                  let rect = canvasView.beginMoveExtraction(path: path) else { return false }
            container.showLassoSelection(bounds: rect, path: path)
            return true
        }
        selection.onCommitMove = { [weak self] in
            guard let self else { return }
            self.canvasView?.commitSelection()
            self.container?.commitLassoSelection()
            self.handleDrawingChanged() // content moved → autosave + version bump
        }
        selection.onCancelMove = { [weak self] in
            guard let self else { return }
            self.container?.clearLassoSelection()
            self.canvasView?.cancelSelection() // discard float + restore snapshot
        }

        // Re-apply overlay drawing-mode state (the container may be freshly created).
        if overlayActive {
            container.setOverlayActive(true)
            container.setOverlayImage(overlayImage)
        }
    }

    public func selectBrush(_ config: BrushConfig) {
        selectedTool = .brush(config)
        applySelectedToolToAttachedViews()
    }

    public func selectEraser(width: CGFloat = 5) {
        selectedTool = .eraser(width: width)
        applySelectedToolToAttachedViews()
    }

    /// The unified Select tool. Input capture (SAM taps vs freehand loops)
    /// follows `selection.authorMode`.
    public func selectSelectionTool() {
        selectedTool = selection.authorMode == .freehand ? .lasso : .magicWand
        applySelectedToolToAttachedViews()
    }

    /// Whether the Select tool is the active tool (either capture mode).
    public var isSelectionToolActive: Bool {
        if case .lasso = selectedTool { return true }
        if case .magicWand = selectedTool { return true }
        return false
    }

    // MARK: - Overlay Drawing Mode

    /// Whether overlay drawing mode is active (generated image locked over the canvas
    /// + visual-only fresh-stroke surface). Cached so it can be re-applied when the
    /// container is re-created (the UIViewRepresentable can re-make the view).
    private var overlayActive = false
    private var overlayImage: UIImage?

    /// Activate/deactivate overlay drawing mode. Idempotent; safe to call every
    /// SwiftUI update. Inert (and detaches the overlay layer) when `false`.
    ///
    /// MUST early-return when unchanged: this is called from `CanvasView.updateUIView`
    /// on every SwiftUI update, and `overlayActive` is an `@Observable` stored property.
    /// Writing it unconditionally mutates observed state *during* the view update, which
    /// SwiftUI resolves by re-running the update → mutate again → infinite loop (the
    /// 2026-06-22 all-layouts freeze: `updateUIView` spun forever, the canvas never laid
    /// out). The guard makes steady-state updates mutate nothing.
    public func setOverlayActive(_ active: Bool) {
        guard active != overlayActive else { return }
        overlayActive = active
        container?.setOverlayActive(active)
        container?.setOverlayImage(active ? overlayImage : nil)
    }

    /// Push the generated image to display locked over the canvas (overlay mode).
    /// Stored so it survives a container re-create; only displayed while active.
    ///
    /// Same `@Observable`-mutation-during-update hazard as `setOverlayActive` — guard on
    /// identity so re-pushing the same image (or nil→nil every update) is a true no-op.
    public func setOverlayImage(_ image: UIImage?) {
        guard image !== overlayImage else { return }
        overlayImage = image
        if overlayActive { container?.setOverlayImage(image) }
    }

    /// Wipe the visual-only overlay-stroke surface. Called on each returned generation
    /// frame (still + video). Harmless no-op when not in overlay mode.
    public func clearOverlayStrokes() {
        container?.clearOverlayStrokes()
    }

    /// Debug toggle for the Phase-4 wet-paint draw-order experiment.
    public func setWetOrderingPerStamp(_ on: Bool) {
        canvasView?.wetOrderingPerStamp = on
    }

    /// True once a live canvas view is attached (replay and other canvas ops
    /// silently no-op before that).
    public var isCanvasAttached: Bool { canvasView != nil }

    /// Dev/testing: replay a recorded stroke fixture onto the live canvas
    /// through the real engine (see `MetalCanvasView.replayStrokes`). Fires the
    /// normal drawing-changed plumbing, so autosave and stream capture behave
    /// as if the strokes were drawn by hand.
    public func replayFixture(_ fixture: BrushFixture) {
        canvasView?.replayStrokes(fixture.strokes, canvasSide: fixture.canvasSide)
    }

    // MARK: - Unified Selection

    /// Clear the whole selection (objects, markers, clip path). Undoable via
    /// the selection's own undo stack.
    public func clearSelection() {
        selection.clearAll()
    }

    /// Selection snapshot of what the user sees on the canvas square: all
    /// layers over the lineart background, on white, capped at SAM's input
    /// resolution. Overlay mode substitutes the generated image at the
    /// AppCoordinator level (see its source-image provider).
    public func selectionCanvasSnapshot() -> CGImage? {
        guard let canvasView else { return nil }
        return canvasView.opaqueImageSnapshot(
            backgroundImage: container?.backgroundImage,
            maxPixelDimension: 1024
        )?.cgImage
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Sim-only: drive a synthetic freehand rectangle through the REAL loop
    /// path (simctl can't inject the freeform drag).
    public func devSimulateLasso() {
        canvasView?.devSimulateLassoRect()
    }

    /// Sim-only: inject a selection tap at a normalized canvas position.
    public func devSimulateWandTap(u: CGFloat, v: CGFloat, positive: Bool) {
        guard let canvasView else { return }
        let size = canvasView.bounds.size
        let previousMode = selection.mode
        selection.mode = positive ? .add : .subtract
        selection.handleTap(at: CGPoint(x: u * size.width, y: v * size.height), viewSize: size)
        selection.mode = previousMode
    }

    /// Sim-only: inject a synthetic circular mask object (the sim's Core ML
    /// can't run SAM's decoder — see CanvasModule CLAUDE.md).
    public func devSimulateWandMask(u: CGFloat, v: CGFloat, radiusFraction: CGFloat) {
        guard let canvasView else { return }
        selection.devInjectCircleMask(
            centerU: u, centerV: v, radiusFraction: radiusFraction,
            viewSize: canvasView.bounds.size)
    }
    #endif

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

    /// Import an image as a new top layer, hiding existing layers ("Edit" →
    /// pull generated image onto the canvas). Returns false when the layer
    /// limit is reached. Single compound undo restores the prior stack.
    public func importImageAsNewLayer(_ image: UIImage, name: String) -> Bool {
        guard let canvasView else { return false }
        let ok = canvasView.importImageAsNewLayer(image, name: name)
        if ok { updateState() }
        return ok
    }

    // MARK: - AI Edit

    /// Whether the user has an active region selection that an AI Edit should
    /// scope to. (Unified selection: the clip path is live whenever a selection
    /// exists — no Phase-A commit step anymore. A selection mid-Move has its
    /// clip hidden, so edits fall back to full-canvas until the move commits.)
    public var hasSelectionForEdit: Bool { selection.hasSelection && !selection.isMoving }

    /// Document-space grayscale selection mask (white = selected), aligned
    /// pixel-for-pixel with `editSourceSnapshot()` at the same side.
    /// Returns nil when there is no selection.
    public func selectionMaskForEdit(side: Int) -> CGImage? {
        canvasView?.selectionMaskImage(side: side)
    }

    /// Dashed-red marker overlay for the same selection (drawn over the source
    /// snapshot so the edit model can see the target region). Same side/space
    /// as `selectionMaskForEdit`.
    public func selectionMarkerForEdit(side: Int) -> CGImage? {
        canvasView?.selectionMarkerOverlayImage(side: side)
    }

    /// Flattened "what you see" composite for the AI Edit source image: all
    /// visible layers over the background image, on white, capped at `side`.
    public func editSourceSnapshot(side: Int) -> CGImage? {
        guard let canvasView else { return nil }
        return canvasView.opaqueImageSnapshot(
            backgroundImage: container?.backgroundImage,
            maxPixelDimension: side
        )?.cgImage
    }

    /// Commit an accepted AI Edit result as a new top layer, keeping existing
    /// layers visible (region results carry transparency outside the mask).
    /// Returns false when the layer limit is reached.
    public func addEditResultLayer(_ image: UIImage, name: String) -> Bool {
        guard let canvasView else { return false }
        let ok = canvasView.addImageAsNewLayer(image, name: name)
        if ok { updateState() }
        return ok
    }

    /// Show/hide the visual-only AI Edit preview locked over the canvas.
    public func setEditPreview(_ image: UIImage?) {
        container?.setEditPreview(image)
    }

    // MARK: - Paste float

    /// True while pasted content is floating (drag/pinch to place, then
    /// `commitPaste` or `cancelPaste`).
    public private(set) var isPasting = false

    /// Flattened visible-layer composite with transparency preserved (no white
    /// backing, no background image) — the copy source, so pasted content
    /// carries only actual strokes.
    public func transparentSnapshot() -> CGImage? {
        canvasView?.persistentImageSnapshot
    }

    /// Float `image` (with alpha) over the canvas at `rectInDocPixels`
    /// (document space, 2048²), hooked into the existing selection-move
    /// gestures. Nothing touches layers until `commitPaste`.
    @discardableResult
    public func beginPaste(image: CGImage, rectInDocPixels: CGRect) -> Bool {
        guard !isPasting, let canvasView, let container else { return false }
        guard let viewRect = canvasView.beginPasteFloat(image: image, rectInDocPixels: rectInDocPixels) else {
            return false
        }
        container.showLassoSelection(bounds: viewRect, path: CGPath(rect: viewRect, transform: nil))
        isPasting = true
        return true
    }

    /// Composite the paste float onto the active layer (one undo step).
    public func commitPaste() {
        guard isPasting, let canvasView, let container else { return }
        canvasView.commitSelection()
        container.commitLassoSelection()
        isPasting = false
        handleDrawingChanged()
    }

    /// Drop the paste float without touching any layer or undo history.
    public func cancelPaste() {
        guard isPasting, let canvasView, let container else { return }
        container.clearLassoSelection()
        canvasView.discardPasteFloat()
        isPasting = false
    }

    public func resetViewTransform() {
        container?.resetTransform()
        scale = 1.0
        rotation = 0
        translation = .zero
    }

    public func captureSnapshot() -> SketchSnapshot? {
        guard let canvasView else { return nil }
        // `hasActiveStroke` lets the FIRST stroke stream while still being
        // drawn: `isEmpty` only flips once a stroke commits (strokeCount is
        // stroke-end incremented), but the in-flight stroke is already in the
        // snapshot via the scratch texture. Without it, a new user's first
        // stroke generates nothing until they lift the pencil.
        guard !canvasView.isEmpty || hasBackgroundContent || canvasView.hasActiveStroke else { return nil }

        let outputSize = canvasView.bounds.size
        guard outputSize.width > 0, outputSize.height > 0 else { return nil }

        let rect = CGRect(origin: .zero, size: outputSize)
        guard let image = canvasView.opaqueImageSnapshot(backgroundImage: container?.backgroundImage) else {
            return nil
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

    /// Renders a thumbnail of a single layer's contents. Returns nil if the
    /// canvas is not attached or the index is out of range.
    public func layerThumbnail(at index: Int, maxDimension: CGFloat = 64) -> UIImage? {
        canvasView?.layerThumbnail(at: index, maxDimension: maxDimension)
    }

    /// Renders a thumbnail of the current canvas at the given max dimension.
    /// Returns nil if the canvas is not attached or is empty.
    public func generateThumbnail(maxDimension: CGFloat = 256) -> UIImage? {
        guard let canvasView else { return nil }
        guard !canvasView.isEmpty || hasBackgroundContent else { return nil }

        let fullSize = canvasView.bounds.size
        guard fullSize.width > 0, fullSize.height > 0 else { return nil }

        let imageScale = canvasView.window?.screen.scale ?? UIScreen.main.scale
        let maxPixels = max(1, Int((maxDimension * imageScale).rounded()))
        return canvasView.opaqueImageSnapshot(
            backgroundImage: container?.backgroundImage,
            maxPixelDimension: maxPixels
        )
    }

    // MARK: - Internal

    func handleDrawingChanged() {
        contentVersion &+= 1
        onContentChanged?()
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

    public func handleInteractionBegan() {
        isInteracting = true
        onUserActivity?()
    }
    public func handleInteractionEnded() { isInteracting = false }

    func handleColorPicked(_ color: UIColor) {
        onColorPicked?(color)
    }

    /// Forward a snap event from the canvas to the AppCoordinator's analytics
    /// handler. Also fires the one-time NUX tooltip on first brush commit.
    func handleSnapEvent(_ event: SnapEvent) {
        onSnapEvent?(event)
        // Tooltip trigger: first time per session that the user successfully
        // snaps. (We could trigger on first brush stroke regardless of snap,
        // but anchoring on a successful snap teaches the gesture.)
        if case .committed = event, !hasFiredFirstBrushStrokeThisSession {
            hasFiredFirstBrushStrokeThisSession = true
            onFirstBrushStrokeCommitted?()
        }
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

    private func applySelectedToolToAttachedViews() {
        switch selectedTool {
        case .brush(let config):
            canvasView?.currentTool = .brush(config)
            container?.updateCursorSize(
                diameter: config.baseWidth,
                pressureGamma: config.pressureGamma,
                tiltSensitivity: config.tiltSensitivity
            )
        case .eraser(let width):
            canvasView?.currentTool = .eraser(width: width)
            // Eraser builds its internal BrushConfig with pressureGamma 0.7 and
            // tiltSensitivity 0 (see MetalCanvasView.swift). Mirror those defaults
            // here so the cursor tracks the actual eraser stamp diameter.
            container?.updateCursorSize(
                diameter: width,
                pressureGamma: 0.7,
                tiltSensitivity: 0.0
            )
        case .lasso:
            canvasView?.currentTool = .lasso
            container?.updateCursorSize(diameter: 0)
        case .magicWand:
            canvasView?.currentTool = .magicWand
            container?.updateCursorSize(diameter: 0)
        }
    }
}

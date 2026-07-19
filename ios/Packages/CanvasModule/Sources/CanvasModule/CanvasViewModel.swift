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
    public private(set) var hasLassoSelection = false

    /// Magic wand session (SAM tap-to-select). Its published clip path rides the
    /// same `setClipPath` machinery as the lasso; `wand.hasSelection` gates the
    /// "Clear Masks" contextual UI.
    public let wand = MagicWandController()
    public var hasWandSelection: Bool { wand.hasSelection }
    /// Monotonic content version — bumps on every committed canvas change. The
    /// wand re-encodes its SAM embedding when this moves between objects.
    public private(set) var contentVersion = 0

    // MARK: - Layer State

    public private(set) var layers: [LayerInfo] = [LayerInfo(name: "Layer 1")]
    public private(set) var activeLayerIndex: Int = 0

    private weak var canvasView: MetalCanvasView?
    private weak var container: RotatableCanvasContainer?
    private var pendingState: CanvasState?
    private var selectedTool: ToolState = .brush(.defaultPen)
    private var lassoClosedPath: CGPath?

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
        wand.segmenterFactory = { try SAM2Segmenter.bundled() }
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

        // Magic wand wiring. The tap source and selection sink both live on the
        // canvas view; the AppCoordinator supplies the image + segmenter factory.
        canvasView.onWandTap = { [weak self] point in
            self?.handleWandTap(at: point)
        }
        wand.contentVersionProvider = { [weak self] in self?.contentVersion ?? 0 }
        wand.onSelectionChanged = { [weak self] path, markers in
            guard let self, let canvasView = self.canvasView else { return }
            canvasView.setClipPath(path)
            canvasView.setWandMarkers(markers)
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

    public func selectLasso() {
        selectedTool = .lasso
        applySelectedToolToAttachedViews()
    }

    public func selectMagicWand() {
        selectedTool = .magicWand
        applySelectedToolToAttachedViews()
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

    // MARK: - Lasso Selection

    #if DEBUG && targetEnvironment(simulator)
    /// Sim-only: drive a synthetic lasso selection (host tooling can't inject
    /// the freeform drag gesture). Reuses the real extraction path.
    public func devSimulateLasso() {
        canvasView?.devSimulateLassoRect()
    }
    #endif

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

    // MARK: - Magic Wand

    private func handleWandTap(at point: CGPoint) {
        guard let canvasView else { return }
        wand.handleTap(at: point, viewSize: canvasView.bounds.size)
    }

    /// Clear the whole wand selection (masks, markers, clip path).
    public func clearWand() {
        wand.clearAll()
    }

    /// Wand-session snapshot of what the user sees on the canvas square:
    /// all layers over the lineart background, on white, capped at SAM's input
    /// resolution. Overlay mode substitutes the generated image at the
    /// AppCoordinator level (see its `wandSourceImage`).
    public func wandCanvasSnapshot() -> CGImage? {
        guard let canvasView else { return nil }
        return canvasView.opaqueImageSnapshot(
            backgroundImage: container?.backgroundImage,
            maxPixelDimension: 1024
        )?.cgImage
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Sim-only: inject a wand tap at a normalized canvas position (host tooling
    /// drives the wand deterministically; simctl taps can't hit exact canvas UVs).
    public func devSimulateWandTap(u: CGFloat, v: CGFloat, positive: Bool) {
        guard let canvasView else { return }
        let size = canvasView.bounds.size
        let previousMode = wand.mode
        wand.mode = positive ? .add : .subtract
        wand.handleTap(at: CGPoint(x: u * size.width, y: v * size.height), viewSize: size)
        wand.mode = previousMode
    }

    /// Sim-only: inject a synthetic circular wand mask (see
    /// `MagicWandController.devInjectCircleMask` for why SAM can't run in the sim).
    public func devSimulateWandMask(u: CGFloat, v: CGFloat, radiusFraction: CGFloat) {
        guard let canvasView else { return }
        wand.devInjectCircleMask(
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

    /// Whether the user has an active region selection (lasso or wand) that an
    /// AI Edit should scope to.
    public var hasSelectionForEdit: Bool { hasLassoSelection || hasWandSelection }

    /// Document-space grayscale selection mask (white = selected), aligned
    /// pixel-for-pixel with `editSourceSnapshot()` at the same side. A Phase-A
    /// floating lasso is first committed to clip mode so its path is
    /// rasterizable. Returns nil when there is no selection.
    public func selectionMaskForEdit(side: Int) -> CGImage? {
        guard let canvasView else { return nil }
        if !canvasView.hasClipSelection, hasLassoSelection {
            transitionToClipMode()
        }
        return canvasView.selectionMaskImage(side: side)
    }

    /// Dashed-red marker overlay for the same selection (drawn over the source
    /// snapshot so the edit model can see the target region). Same side/space
    /// as `selectionMaskForEdit`.
    public func selectionMarkerForEdit(side: Int) -> CGImage? {
        guard let canvasView else { return nil }
        if !canvasView.hasClipSelection, hasLassoSelection {
            transitionToClipMode()
        }
        return canvasView.selectionMarkerOverlayImage(side: side)
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

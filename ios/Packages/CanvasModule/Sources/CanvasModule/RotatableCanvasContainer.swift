import UIKit

public final class RotatableCanvasContainer: UIView, UIGestureRecognizerDelegate {

    // MARK: - Public

    public let canvasView = MetalCanvasView()
    public private(set) var rotation: CGFloat = 0
    public private(set) var scale: CGFloat = 1.0
    public private(set) var translation: CGPoint = .zero

    /// Side length of the square drawing surface (in points). The container can
    /// be wider/taller than this to host gestures over the full pane while the
    /// actual drawing area stays a centered square of this size. 0 means fill
    /// the container (legacy behavior).
    public var drawingSurfaceSide: CGFloat = 0 {
        didSet { setNeedsLayout() }
    }
    public var onTransformChanged: (() -> Void)?
    public var onInteractionChanged: ((Bool) -> Void)?
    public var onUndoRequested: (() -> Void)?
    public var onRedoRequested: (() -> Void)?
    /// Called when the eyedropper long-press commits a sampled color.
    public var onColorPicked: ((UIColor) -> Void)?
    /// Callback to supply the current brush color as the "previous" color on the ring.
    public var currentBrushColorProvider: (() -> UIColor)?

    /// Optional rect (in this container's coordinate space) of an external
    /// floating overlay (e.g. the result panel) that should receive two-finger
    /// pan/pinch instead of the canvas. When a two-finger gesture's centroid
    /// falls inside this rect, the canvas's own transform gestures stand down
    /// and the deltas are forwarded via `onExternalTransform`. Single-finger /
    /// pencil touches are never affected — they always fall through to drawing.
    /// Returns `nil` when there is no such overlay (canvas behaves normally).
    public var externalTransformRegionProvider: (() -> CGRect?)?
    /// Receives incremental two-finger transform deltas when a gesture begins
    /// over the external region. `translationDelta` is in container points;
    /// `scaleDelta` is multiplicative (1.0 = no change). Rotation is never
    /// forwarded — the external overlay does not rotate.
    public var onExternalTransform: ((_ translationDelta: CGPoint, _ scaleDelta: CGFloat) -> Void)?

    /// Reports the live single-touch drawing contact point (in this container's
    /// coordinate space = pane/screen space, unaffected by canvas zoom/pan/rotate)
    /// plus the current pressure-scaled brush diameter, every move. `paneLocation`
    /// is `nil` when there is no active single-touch contact (lift / cancel /
    /// multi-finger gesture) — the signal for the result-panel "transparency hole"
    /// to fade closed. Piggybacks on the existing touch tracker; adds no work to
    /// the Metal draw path.
    public var onContactPointChanged: ((_ paneLocation: CGPoint?, _ brushDiameter: CGFloat) -> Void)?

    // MARK: - Private

    /// Intermediate view that receives the combined scale + rotation transform.
    /// The container itself has no transform (SwiftUI manages its frame).
    private let transformView = UIView()
    private let backgroundImageView = UIImageView()
    /// Overlay drawing mode: opaque generated image, locked exactly on top of the
    /// canvas (inside `transformView`, so it inherits the canvas pan/zoom/rotate
    /// 1:1). Non-interactive — touches fall through to `canvasView` underneath, so
    /// real drawing/generation are unchanged. Hidden unless overlay mode is active.
    private let generatedImageView = UIImageView()
    /// Overlay drawing mode: visual-only fresh-stroke surface, a `CAMetalLayer` view
    /// above `generatedImageView`. The Metal canvas composites the overlay-stroke
    /// texture into this layer every tick. Non-interactive. Hidden unless active.
    private let overlayStrokeView = MetalOverlayLayerView()
    private let cursorView = CursorOverlayView()
    private let ringView = ColorPickerRingView()
    /// Vertical offset applied so the ring sits above the finger instead of being covered.
    private static let ringFingerOffset: CGFloat = 80
    /// Flattened canvas snapshot captured at eyedropper pickup and reused for every
    /// `.changed` sample, so we don't re-flatten the Metal canvas on each finger move.
    private var eyedropperSnapshot: UIImage?
    private var lassoSelectionView: LassoSelectionView?
    private var cursorBaseWidth: CGFloat = 5
    private var cursorPressureGamma: CGFloat = 0.7
    private var cursorTiltSensitivity: CGFloat = 0.0
    private static let snapThreshold: CGFloat = 0.15 // ~8.6 degrees
    private static let minScale: CGFloat = 0.5
    private static let maxScale: CGFloat = 5.0

    // Canvas transform recognizers — referenced in gestureRecognizerShouldBegin
    // so they can stand down when a two-finger gesture starts over the external
    // (result-panel) region.
    private var canvasPanGesture: UIPanGestureRecognizer!
    private var canvasPinchGesture: UIPinchGestureRecognizer!
    private var canvasRotationGesture: UIRotationGestureRecognizer!
    private var undoTapGesture: UITapGestureRecognizer!
    private var redoTapGesture: UITapGestureRecognizer!
    // Panel transform recognizers — fire only when the two-finger centroid is
    // inside the external region, forwarding deltas via `onExternalTransform`.
    private var panelPanGesture: UIPanGestureRecognizer!
    private var panelPinchGesture: UIPinchGestureRecognizer!

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - Setup

    /// Procreate-style canvas surround: dark gray backing with a slightly
    /// lighter 1pt grid. A pattern color keeps it a plain `backgroundColor`
    /// (no extra layer, doesn't ride the canvas transform — the grid stays
    /// screen-fixed behind the document, like Procreate's). Colors mirror
    /// `KikiTheme.canvasBacking` in the app target; keep in sync by eye.
    private static let canvasBackingPattern: UIColor = {
        let cell: CGFloat = 26
        let backing = UIColor(white: 0.135, alpha: 1)
        let line = UIColor(white: 0.175, alpha: 1)
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // sRGB — match canvas color convention
        format.opaque = true
        let tile = UIGraphicsImageRenderer(size: CGSize(width: cell, height: cell), format: format)
            .image { ctx in
                backing.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: cell, height: cell))
                line.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: cell, height: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: 1, height: cell))
            }
        return UIColor(patternImage: tile)
    }()

    private func setup() {
        clipsToBounds = true
        backgroundColor = Self.canvasBackingPattern

        // transformView is sized in layoutSubviews — either filling the
        // container (when drawingSurfaceSide == 0) or held as a centered
        // square of drawingSurfaceSide. We don't use autoresizing so the
        // transformView's frame isn't fought by the container's resize.
        transformView.frame = bounds
        addSubview(transformView)

        // backgroundImageView sits below canvasView — always present, white bg by default.
        // When lineart is swapped in, its image is set; when cleared, white bg shows through.
        backgroundImageView.frame = transformView.bounds
        backgroundImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundImageView.contentMode = .scaleToFill
        backgroundImageView.backgroundColor = .white
        transformView.addSubview(backgroundImageView)

        // canvasView fills transformView (always transparent — background handled by backgroundImageView)
        canvasView.frame = transformView.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        transformView.addSubview(canvasView)

        // Overlay drawing mode: opaque generated image locked over the canvas, plus a
        // visual-only fresh-stroke surface above it. Both inside transformView (so they
        // ride the canvas pan/zoom/rotate exactly) and both non-interactive (single
        // finger / pencil draws straight through to canvasView). Hidden until activated.
        generatedImageView.frame = transformView.bounds
        generatedImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        generatedImageView.contentMode = .scaleAspectFill
        generatedImageView.clipsToBounds = true
        generatedImageView.isUserInteractionEnabled = false
        generatedImageView.isHidden = true
        transformView.addSubview(generatedImageView)

        overlayStrokeView.frame = transformView.bounds
        overlayStrokeView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlayStrokeView.isUserInteractionEnabled = false
        overlayStrokeView.isHidden = true
        transformView.addSubview(overlayStrokeView)

        // Cursor overlay — renders on top of canvas, shows brush/eraser size at touch position
        cursorView.frame = CGRect(x: 0, y: 0, width: 5, height: 5)
        cursorView.isHidden = true
        transformView.addSubview(cursorView)


        // Color picker ring — sits on the container (not transformView) so it stays in screen-space
        // during canvas rotation/zoom. Hidden until the long-press fires.
        ringView.isHidden = true
        addSubview(ringView)

        let touchTracker = TouchTrackingGestureRecognizer(target: self, action: #selector(handleTouchTracking(_:)))
        touchTracker.cancelsTouchesInView = false
        touchTracker.delaysTouchesBegan = false
        touchTracker.delegate = self
        addGestureRecognizer(touchTracker)

        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        addGestureRecognizer(rotationGesture)
        canvasRotationGesture = rotationGesture

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)
        canvasPinchGesture = pinchGesture

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)
        canvasPanGesture = panGesture

        // Panel transform recognizers — same two-finger pan + pinch as the
        // canvas, but they only begin when the gesture starts over the external
        // region (see gestureRecognizerShouldBegin) and forward their deltas to
        // onExternalTransform instead of transforming the canvas. No rotation.
        let panelPinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePanelPinch(_:)))
        panelPinch.delegate = self
        addGestureRecognizer(panelPinch)
        panelPinchGesture = panelPinch

        let panelPan = UIPanGestureRecognizer(target: self, action: #selector(handlePanelPan(_:)))
        panelPan.minimumNumberOfTouches = 2
        panelPan.maximumNumberOfTouches = 2
        panelPan.delegate = self
        addGestureRecognizer(panelPan)
        panelPanGesture = panelPan

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.delegate = self
        addGestureRecognizer(undoTap)
        undoTapGesture = undoTap

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.delegate = self
        addGestureRecognizer(redoTap)
        redoTapGesture = redoTap

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        longPress.allowableMovement = 10
        longPress.cancelsTouchesInView = true // cancels in-progress stroke when picker fires
        longPress.delegate = self
        addGestureRecognizer(longPress)
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()

        let side: CGFloat
        if drawingSurfaceSide > 0 {
            side = drawingSurfaceSide
        } else {
            side = min(bounds.width, bounds.height)
        }

        // Preserve any active transform so panning/zooming isn't reset by a
        // relayout. The square is laid out centered in the container; the user
        // can pan it anywhere within the container via gestures.
        let previousTransform = transformView.transform
        transformView.transform = .identity
        transformView.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        transformView.center = CGPoint(x: bounds.midX, y: bounds.midY)
        transformView.transform = previousTransform
    }

    // MARK: - Gesture Handling

    @objc private func handleTouchTracking(_ gesture: TouchTrackingGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let location = gesture.location(in: canvasView)
            cursorView.center = location
            // When the container is larger than the drawing surface, the touch
            // can land outside canvasView's bounds — hide the cursor there so
            // we don't draw a ring over the empty margin around the canvas.
            cursorView.isHidden = !canvasView.bounds.contains(location)

            // Match BrushConfig.effectiveWidth so the cursor reflects the actual
            // stamp diameter (in view points) — pow(force, gamma) for pressure,
            // and the same tiltFactor formula (which is 1.0 unless tiltSensitivity > 0).
            let force = max(gesture.normalizedForce, 0.01)
            let pressureFactor = pow(force, cursorPressureGamma)
            let tiltFactor: CGFloat
            if cursorTiltSensitivity > 0 {
                tiltFactor = 1.0 + cursorTiltSensitivity * (1.0 - gesture.altitudeAngle / (.pi / 2)) * 2.0
            } else {
                tiltFactor = 1.0
            }
            let diameter = cursorBaseWidth * pressureFactor * tiltFactor
            cursorView.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            cursorView.setNeedsDisplay()

            // Surface the live contact point to the result-panel hole effect, in
            // container (pane/screen) space — independent of the canvas transform.
            // Single-touch only: a two-finger transform should not open a hole.
            if gesture.activeTouchCount <= 1 {
                onContactPointChanged?(gesture.location(in: self), diameter)
            } else {
                onContactPointChanged?(nil, 0)
            }
        case .ended, .cancelled:
            cursorView.isHidden = true
            onContactPointChanged?(nil, 0)
        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .began:
            onInteractionChanged?(true)

        case .changed:
            rotation += gesture.rotation
            gesture.rotation = 0
            applyTransform()
            onTransformChanged?()

        case .ended, .cancelled:
            rotation += gesture.rotation
            // Snap to nearest 90 degrees if within threshold
            let nearestQuarter = (rotation / (.pi / 2)).rounded() * (.pi / 2)
            if abs(rotation - nearestQuarter) < Self.snapThreshold {
                rotation = nearestQuarter
                UIView.animate(withDuration: 0.2) { self.applyTransform() }
            } else {
                applyTransform()
            }
            onTransformChanged?()
            onInteractionChanged?(false)

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            onInteractionChanged?(true)

        case .changed:
            scale = (scale * gesture.scale).clamped(to: Self.minScale...Self.maxScale)
            gesture.scale = 1.0
            applyTransform()
            onTransformChanged?()

        case .ended, .cancelled:
            scale = (scale * gesture.scale).clamped(to: Self.minScale...Self.maxScale)
            applyTransform()
            onTransformChanged?()
            onInteractionChanged?(false)

        default:
            break
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            onInteractionChanged?(true)

        case .changed:
            let delta = gesture.translation(in: self)
            translation.x += delta.x
            translation.y += delta.y
            gesture.setTranslation(.zero, in: self)
            applyTransform()
            onTransformChanged?()

        case .ended, .cancelled:
            let delta = gesture.translation(in: self)
            translation.x += delta.x
            translation.y += delta.y
            applyTransform()
            onTransformChanged?()
            onInteractionChanged?(false)

        default:
            break
        }
    }

    // MARK: - External (panel) two-finger transform

    @objc private func handlePanelPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .changed, .ended:
            let delta = gesture.translation(in: self)
            gesture.setTranslation(.zero, in: self)
            onExternalTransform?(delta, 1.0)
        default:
            break
        }
    }

    @objc private func handlePanelPinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed, .ended:
            let scaleDelta = gesture.scale
            gesture.scale = 1.0
            onExternalTransform?(.zero, scaleDelta)
        default:
            break
        }
    }

    @objc private func handleUndoTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { onUndoRequested?() }
    }

    @objc private func handleRedoTap(_ gesture: UITapGestureRecognizer) {
        if gesture.state == .ended { onRedoRequested?() }
    }

    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        // No eyedropper during lasso selection
        guard lassoSelectionView == nil else { return }

        switch gesture.state {
        case .began:
            // Flatten the canvas once at pickup; reused for every `.changed` sample.
            eyedropperSnapshot = canvasView.opaqueImageSnapshot(backgroundImage: backgroundImageView.image)
            let containerPoint = gesture.location(in: self)
            let ringCenter = CGPoint(x: containerPoint.x, y: containerPoint.y - Self.ringFingerOffset)
            ringView.previousColor = currentBrushColorProvider?() ?? .black
            if let sampled = sampleColorInContainer(at: ringCenter) {
                ringView.currentColor = sampled
            }
            ringView.center = ringCenter
            ringView.isHidden = false

        case .changed:
            let containerPoint = gesture.location(in: self)
            let ringCenter = CGPoint(x: containerPoint.x, y: containerPoint.y - Self.ringFingerOffset)
            if let sampled = sampleColorInContainer(at: ringCenter) {
                ringView.currentColor = sampled
            }
            ringView.center = ringCenter

        case .ended:
            let committed = ringView.currentColor
            ringView.isHidden = true
            eyedropperSnapshot = nil
            onColorPicked?(committed)

        case .cancelled, .failed:
            ringView.isHidden = true
            eyedropperSnapshot = nil

        default:
            break
        }
    }

    /// Sample the displayed pixel at a point in the container's coordinate system.
    ///
    /// The canvas is backed by a `CAMetalLayer` whose pixels live in a GPU
    /// drawable, so `CALayer.render(in:)` captures nothing from it — sampling
    /// that way only ever read the white surround. Instead we read from a
    /// flattened Metal snapshot (strokes composited over the background via the
    /// same source-over path as on-screen), captured once at pickup in
    /// `eyedropperSnapshot`. The container point is converted into the canvas
    /// view's own (untransformed) coordinate space via `convert(_:from:)`, which
    /// inverts the live zoom / rotate / pan automatically.
    private func sampleColorInContainer(at point: CGPoint) -> UIColor? {
        let canvasPoint = canvasView.convert(point, from: self)
        let canvasBounds = canvasView.bounds
        guard canvasBounds.width > 0, canvasBounds.height > 0 else { return nil }
        // Outside the canvas surface → the white surround.
        guard canvasBounds.contains(canvasPoint) else { return .white }
        guard let snapshot = eyedropperSnapshot else { return .white }
        return snapshot.pixelColor(at: canvasPoint, in: canvasBounds.size)
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Eyedropper long-press: finger only, not Apple Pencil
        if gestureRecognizer is UILongPressGestureRecognizer {
            return touch.type != .pencil
        }
        // Panel manipulation is finger-only — a pencil must always draw.
        if gestureRecognizer === panelPanGesture || gestureRecognizer === panelPinchGesture {
            return touch.type != .pencil
        }
        return true
    }

    /// True when a gesture's current centroid lies inside the external (panel)
    /// region. Used to route two-finger gestures to the panel vs. the canvas.
    private func gestureIsOverExternalRegion(_ gesture: UIGestureRecognizer) -> Bool {
        guard let region = externalTransformRegionProvider?() else { return false }
        return region.contains(gesture.location(in: self))
    }

    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let overPanel = gestureIsOverExternalRegion(gestureRecognizer)
        // Panel recognizers begin only over the panel region.
        if gestureRecognizer === panelPanGesture || gestureRecognizer === panelPinchGesture {
            return overPanel
        }
        // Canvas transform / undo-tap stand down over the panel region so they
        // don't move the canvas while the user is manipulating the panel.
        if gestureRecognizer === canvasPanGesture
            || gestureRecognizer === canvasPinchGesture
            || gestureRecognizer === canvasRotationGesture
            || gestureRecognizer === undoTapGesture
            || gestureRecognizer === redoTapGesture {
            // A floating lasso selection owns all two-finger transforms — the
            // LassoSelectionView's own pan/pinch/rotate recognizers move & scale
            // the selected pixels. The canvas underneath must NOT transform too
            // (that's the "resizing the selection resizes the canvas" bug).
            // Undo/redo taps also stand down: restoring a canvas snapshot out
            // from under the floating selection texture would corrupt state.
            if hasActiveLassoSelection { return false }
            return !overPanel
        }
        return true
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Touch tracker always coexists with everything (drawing, pinch, rotation, long-press)
        if gestureRecognizer is TouchTrackingGestureRecognizer || other is TouchTrackingGestureRecognizer {
            return true
        }
        // Allow pinch, rotation, and pan to work simultaneously
        let isTransform = { (g: UIGestureRecognizer) -> Bool in
            g is UIRotationGestureRecognizer
                || g is UIPinchGestureRecognizer
                || g is UIPanGestureRecognizer
        }
        return isTransform(gestureRecognizer) && isTransform(other)
        // Long-press is exclusive — it should not fire alongside any other gesture.
        // Multi-finger gestures naturally cancel it since they introduce additional touches.
    }

    // MARK: - Overlay Drawing Mode

    /// Toggle overlay drawing mode. When active, the opaque generated image +
    /// visual-only fresh-stroke surface are shown locked over the canvas, and the
    /// canvas's Metal renderer also composites overlay strokes into the overlay
    /// layer each tick. When inactive, both views hide and the canvas stops
    /// touching the overlay path (zero added work in split-screen/fullscreen).
    public func setOverlayActive(_ active: Bool) {
        generatedImageView.isHidden = !active
        overlayStrokeView.isHidden = !active
        // Configure the overlay metal layer's device once, then hand it to the
        // canvas so it renders into it. nil detaches it (inert).
        if active {
            overlayStrokeView.configureDevice(canvasView.metalDevice)
            canvasView.overlayStrokeLayer = overlayStrokeView.metalLayer
        } else {
            canvasView.overlayStrokeLayer = nil
        }
        // Lasso path-preview dashes live on the canvas's own layer, which the
        // opaque generated image covers in overlay mode — park them above it
        // (transformView.layer shares the canvas's coordinate space).
        canvasView.setLassoPreviewHost(active ? transformView.layer : nil)
    }

    /// Push the generated image to display locked over the canvas (overlay mode).
    /// `nil` clears it. Bound to `resultState.displayImage` upstream, which already
    /// falls back to the last successful image → "show last, never blank" for free.
    public func setOverlayImage(_ image: UIImage?) {
        generatedImageView.image = image
    }

    /// Wipe the visual-only overlay-stroke surface (called on each generation frame).
    public func clearOverlayStrokes() {
        canvasView.clearOverlayStrokes()
    }

    // MARK: - Public API

    public func setBackgroundImage(_ image: UIImage?) {
        backgroundImageView.image = image
    }

    /// Bake the image into the canvas's persistent bitmap (making it erasable)
    /// and clear the background image layer.
    public func bakeImageIntoCanvas(_ image: UIImage) {
        canvasView.bakeImage(image)
        backgroundImageView.image = nil
    }

    public var backgroundImage: UIImage? {
        backgroundImageView.image
    }

    public func updateCursorSize(diameter: CGFloat, pressureGamma: CGFloat = 0.7, tiltSensitivity: CGFloat = 0.0) {
        cursorBaseWidth = diameter
        cursorPressureGamma = pressureGamma
        cursorTiltSensitivity = tiltSensitivity
    }

    // MARK: - Lasso Selection

    /// Callback that propagates lasso gesture transforms to the Metal canvas.
    public var onLassoTransformChanged: ((_ translation: CGPoint, _ scale: CGFloat, _ rotation: CGFloat) -> Void)?

    public func showLassoSelection(bounds: CGRect, path: CGPath) {
        let selectionView = LassoSelectionView(
            selectionBounds: bounds,
            lassoPath: path
        )
        selectionView.frame = canvasView.frame
        selectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        selectionView.onTransformChanged = { [weak self] translation, scale, rotation in
            self?.onLassoTransformChanged?(translation, scale, rotation)
        }
        // Top of transformView — above the overlay-mode generated image /
        // fresh-stroke surfaces, so the marching ants stay visible in overlay
        // layout (they were invisible when inserted just above canvasView).
        // Non-overlay layouts are unaffected (those views are hidden).
        transformView.addSubview(selectionView)
        canvasView.isUserInteractionEnabled = false
        lassoSelectionView = selectionView
    }

    public func commitLassoSelection() {
        guard let selectionView = lassoSelectionView else { return }
        selectionView.removeFromSuperview()
        lassoSelectionView = nil
        canvasView.isUserInteractionEnabled = true
    }

    public func clearLassoSelection() {
        lassoSelectionView?.removeFromSuperview()
        lassoSelectionView = nil
        canvasView.isUserInteractionEnabled = true
    }

    public var hasActiveLassoSelection: Bool { lassoSelectionView != nil }

    public func resetTransform() {
        rotation = 0
        scale = 1.0
        translation = .zero
        UIView.animate(withDuration: 0.3) { self.applyTransform() }
    }

    // MARK: - Private

    private func applyTransform() {
        transformView.transform = CGAffineTransform(translationX: translation.x, y: translation.y)
            .rotated(by: rotation)
            .scaledBy(x: scale, y: scale)
    }
}

// MARK: - Comparable clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

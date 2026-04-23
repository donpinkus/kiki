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

    // MARK: - Private

    /// Intermediate view that receives the combined scale + rotation transform.
    /// The container itself has no transform (SwiftUI manages its frame).
    private let transformView = UIView()
    private let backgroundImageView = UIImageView()
    private let cursorView = CursorOverlayView()
    private let ringView = ColorPickerRingView()
    /// Vertical offset applied so the ring sits above the finger instead of being covered.
    private static let ringFingerOffset: CGFloat = 80
    private var lassoSelectionView: LassoSelectionView?
    private var cursorBaseWidth: CGFloat = 5
    private var cursorPressureGamma: CGFloat = 0.7
    private var cursorTiltSensitivity: CGFloat = 0.0
    private static let snapThreshold: CGFloat = 0.15 // ~8.6 degrees
    private static let minScale: CGFloat = 0.5
    private static let maxScale: CGFloat = 5.0

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

    private func setup() {
        clipsToBounds = true
        backgroundColor = .black

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

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        panGesture.minimumNumberOfTouches = 2
        panGesture.maximumNumberOfTouches = 2
        panGesture.delegate = self
        addGestureRecognizer(panGesture)

        let undoTap = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
        undoTap.numberOfTouchesRequired = 2
        undoTap.delegate = self
        addGestureRecognizer(undoTap)

        let redoTap = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap(_:)))
        redoTap.numberOfTouchesRequired = 3
        redoTap.delegate = self
        addGestureRecognizer(redoTap)

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
        case .ended, .cancelled:
            cursorView.isHidden = true
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
            onColorPicked?(committed)

        case .cancelled, .failed:
            ringView.isHidden = true

        default:
            break
        }
    }

    /// Sample the displayed pixel at a point in the container's coordinate system.
    /// Snapshots the transformView (which holds background + canvas at their displayed
    /// positions/transforms) and reads the pixel directly — no coordinate conversion needed.
    private func sampleColorInContainer(at point: CGPoint) -> UIColor? {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        guard point.x >= 0, point.y >= 0, point.x < size.width, point.y < size.height else {
            return .white
        }

        // Render a 1x1 snapshot of the container at the target point.
        // drawHierarchy on self captures the transformView (background + canvas)
        // exactly as displayed, including any rotation/scale transforms.
        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Translate so the target point maps to (0,0)
        ctx.translateBy(x: -point.x, y: -point.y)
        // Fill white background (canvas area outside content)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        // Render the transform view (contains background image + canvas)
        transformView.layer.render(in: ctx)

        let r = CGFloat(pixel[0]) / 255
        let g = CGFloat(pixel[1]) / 255
        let b = CGFloat(pixel[2]) / 255
        let a = CGFloat(pixel[3]) / 255
        guard a > 0 else { return UIColor(red: r, green: g, blue: b, alpha: 0) }
        return UIColor(red: r / a, green: g / a, blue: b / a, alpha: a)
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        // Eyedropper long-press: finger only, not Apple Pencil
        if gestureRecognizer is UILongPressGestureRecognizer {
            return touch.type != .pencil
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
        transformView.insertSubview(selectionView, aboveSubview: canvasView)
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

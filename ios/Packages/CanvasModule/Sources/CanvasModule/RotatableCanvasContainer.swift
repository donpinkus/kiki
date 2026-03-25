import UIKit
import PencilKit

public final class RotatableCanvasContainer: UIView, UIGestureRecognizerDelegate {

    // MARK: - Public

    public let canvasView = PKCanvasView()
    public private(set) var rotation: CGFloat = 0
    public private(set) var scale: CGFloat = 1.0
    public var onTransformChanged: (() -> Void)?

    // MARK: - Private

    /// Intermediate view that receives the combined scale + rotation transform.
    /// The container itself has no transform (SwiftUI manages its frame).
    private let transformView = UIView()
    private let backgroundImageView = UIImageView()
    private let cursorView = CursorOverlayView()
    private var cursorBaseWidth: CGFloat = 5
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

        // transformView fills container — use autoresizing so it tracks size
        // changes without Auto Layout fighting the transform.
        transformView.frame = bounds
        transformView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
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
        canvasView.isScrollEnabled = false // Zoom/rotation handled by container; prevent contentOffset drift
        transformView.addSubview(canvasView)

        // Cursor overlay — renders on top of canvas, shows brush/eraser size at touch position
        cursorView.frame = CGRect(x: 0, y: 0, width: 5, height: 5)
        cursorView.isHidden = true
        transformView.addSubview(cursorView)

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
    }

    // MARK: - Gesture Handling

    @objc private func handleTouchTracking(_ gesture: TouchTrackingGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let location = gesture.location(in: canvasView)
            cursorView.center = location
            cursorView.isHidden = false

            // Dynamically size cursor based on pressure and tilt.
            // PK's .pen ink scales width with force and reduces it at low tilt angles.
            let forceFraction = 0.15 + 0.85 * gesture.normalizedForce
            // Altitude: perpendicular (π/2) = full width, flat (0) = thinner
            let tiltFraction = 0.3 + 0.7 * (gesture.altitudeAngle / (.pi / 2))
            let diameter = cursorBaseWidth * forceFraction * tiltFraction / 3.0
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

        default:
            break
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .changed:
            scale = (scale * gesture.scale).clamped(to: Self.minScale...Self.maxScale)
            gesture.scale = 1.0
            applyTransform()
            onTransformChanged?()

        case .ended, .cancelled:
            scale = (scale * gesture.scale).clamped(to: Self.minScale...Self.maxScale)
            applyTransform()
            onTransformChanged?()

        default:
            break
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Touch tracker always coexists with everything (PK drawing, pinch, rotation)
        if gestureRecognizer is TouchTrackingGestureRecognizer || other is TouchTrackingGestureRecognizer {
            return true
        }
        // Allow pinch and rotation to work simultaneously
        let dominated = gestureRecognizer is UIRotationGestureRecognizer
            || gestureRecognizer is UIPinchGestureRecognizer
        let dominating = other is UIRotationGestureRecognizer
            || other is UIPinchGestureRecognizer
        return dominated && dominating
    }

    // MARK: - Public API

    public func setBackgroundImage(_ image: UIImage?) {
        backgroundImageView.image = image
    }

    public var backgroundImage: UIImage? {
        backgroundImageView.image
    }

    public func updateCursorSize(diameter: CGFloat) {
        cursorBaseWidth = diameter
    }

    public func resetTransform() {
        rotation = 0
        scale = 1.0
        UIView.animate(withDuration: 0.3) { self.applyTransform() }
    }

    // MARK: - Private

    private func applyTransform() {
        transformView.transform = CGAffineTransform(rotationAngle: rotation)
            .scaledBy(x: scale, y: scale)
    }
}

// MARK: - Comparable clamping

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

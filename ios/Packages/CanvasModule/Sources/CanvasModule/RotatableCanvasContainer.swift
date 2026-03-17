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

        // canvasView fills transformView
        canvasView.frame = transformView.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        transformView.addSubview(canvasView)

        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        addGestureRecognizer(rotationGesture)

        let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinchGesture.delegate = self
        addGestureRecognizer(pinchGesture)
    }

    // MARK: - Gesture Handling

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
        // Allow pinch and rotation to work simultaneously
        let dominated = gestureRecognizer is UIRotationGestureRecognizer
            || gestureRecognizer is UIPinchGestureRecognizer
        let dominating = other is UIRotationGestureRecognizer
            || other is UIPinchGestureRecognizer
        return dominated && dominating
    }

    // MARK: - Public API

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

import UIKit
import PencilKit

public final class RotatableCanvasContainer: UIView, UIGestureRecognizerDelegate {

    // MARK: - Public

    public let canvasView = PKCanvasView()
    public private(set) var rotation: CGFloat = 0
    public var onTransformChanged: (() -> Void)?

    // MARK: - Private

    private static let snapThreshold: CGFloat = 0.15 // ~8.6 degrees

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
        canvasView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvasView)
        NSLayoutConstraint.activate([
            canvasView.topAnchor.constraint(equalTo: topAnchor),
            canvasView.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvasView.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvasView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.delegate = self
        addGestureRecognizer(rotationGesture)
    }

    // MARK: - Gesture Handling

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        switch gesture.state {
        case .changed:
            rotation += gesture.rotation
            gesture.rotation = 0
            transform = CGAffineTransform(rotationAngle: rotation)
            onTransformChanged?()

        case .ended, .cancelled:
            rotation += gesture.rotation
            transform = CGAffineTransform(rotationAngle: rotation)
            // Snap to nearest 90 degrees if within threshold
            let nearestQuarter = (rotation / (.pi / 2)).rounded() * (.pi / 2)
            if abs(rotation - nearestQuarter) < Self.snapThreshold {
                rotation = nearestQuarter
                UIView.animate(withDuration: 0.2) {
                    self.transform = CGAffineTransform(rotationAngle: self.rotation)
                }
            }
            onTransformChanged?()

        default:
            break
        }
    }

    public func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer is UIRotationGestureRecognizer
    }

    // MARK: - Public API

    public func resetTransform() {
        rotation = 0
        UIView.animate(withDuration: 0.3) {
            self.transform = .identity
            self.canvasView.zoomScale = 1.0
        }
    }
}

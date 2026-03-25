import UIKit.UIGestureRecognizerSubclass

/// Passive gesture recognizer that tracks touch locations and pencil properties
/// without interfering with other gesture recognizers (PencilKit drawing, pinch, rotation).
final class TouchTrackingGestureRecognizer: UIGestureRecognizer {

    /// Normalized force (0–1) from the current touch. 0 when unavailable (e.g., finger on non-3D Touch device).
    private(set) var normalizedForce: CGFloat = 0

    /// Altitude angle of the pencil in radians (0 = flat, π/2 = perpendicular).
    private(set) var altitudeAngle: CGFloat = .pi / 2

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        updatePencilProperties(from: touches)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        updatePencilProperties(from: touches)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .cancelled
    }

    private func updatePencilProperties(from touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        altitudeAngle = touch.altitudeAngle
        if touch.maximumPossibleForce > 0 {
            normalizedForce = touch.force / touch.maximumPossibleForce
        } else {
            normalizedForce = 0.5 // Fallback for devices without pressure sensing
        }
    }
}

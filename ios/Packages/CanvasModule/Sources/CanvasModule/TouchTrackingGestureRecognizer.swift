import UIKit.UIGestureRecognizerSubclass

/// Passive gesture recognizer that tracks touch locations and pencil properties
/// without interfering with other gesture recognizers (PencilKit drawing, pinch, rotation).
final class TouchTrackingGestureRecognizer: UIGestureRecognizer {

    /// Normalized force (0–1) from the current touch. 0 when unavailable (e.g., finger on non-3D Touch device).
    private(set) var normalizedForce: CGFloat = 0

    /// Altitude angle of the pencil in radians (0 = flat, π/2 = perpendicular).
    private(set) var altitudeAngle: CGFloat = .pi / 2

    /// Number of touches currently down on this recognizer. Tracked explicitly
    /// (rather than reading the base `numberOfTouches`, whose value on a passive
    /// recognizer that doesn't call `super` is not guaranteed) so callers can
    /// reliably distinguish single-touch drawing from a multi-finger gesture.
    private(set) var activeTouchCount = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouchCount += touches.count
        updatePencilProperties(from: touches)
        state = .began
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        updatePencilProperties(from: touches)
        state = .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouchCount = max(0, activeTouchCount - touches.count)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        activeTouchCount = max(0, activeTouchCount - touches.count)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        activeTouchCount = 0
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

import UIKit

/// Floating selection overlay for the lasso tool.
/// Gesture-only — handles move/scale/rotate and displays marching ants.
/// The selection IMAGE is rendered by the Metal compositor (not a UIImageView).
final class LassoSelectionView: UIView, UIGestureRecognizerDelegate {

    // MARK: - Properties

    private let selectionBounds: CGRect
    private let lassoPath: CGPath

    private let marchingAntsBlack = CAShapeLayer()
    private let marchingAntsWhite = CAShapeLayer()

    private var selectionTranslation: CGPoint = .zero
    private var selectionScale: CGFloat = 1.0
    private var selectionRotation: CGFloat = 0

    /// Called on each gesture update with the current transform state.
    /// The Metal canvas uses these values to position the selection quad.
    var onTransformChanged: ((_ translation: CGPoint, _ scale: CGFloat, _ rotation: CGFloat) -> Void)?

    // Gesture accumulation
    private var lastPinchScale: CGFloat = 1.0

    // MARK: - Init

    init(selectionBounds: CGRect, lassoPath: CGPath) {
        self.selectionBounds = selectionBounds
        self.lassoPath = lassoPath
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true

        // Marching ants layers
        setupMarchingAnts()

        // Gestures
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotation.delegate = self
        addGestureRecognizer(rotation)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Marching Ants

    private func setupMarchingAnts() {
        let configure = { (layer: CAShapeLayer, color: UIColor, dashPhase: CGFloat) in
            layer.fillColor = nil
            layer.strokeColor = color.cgColor
            layer.lineWidth = 1.5
            layer.lineDashPattern = [6, 4]
            layer.lineDashPhase = dashPhase
            layer.path = self.lassoPath
        }

        configure(marchingAntsWhite, .white, 0)
        configure(marchingAntsBlack, .black, 5)

        layer.addSublayer(marchingAntsWhite)
        layer.addSublayer(marchingAntsBlack)

        // Animate dash phase for marching effect
        let animation = CABasicAnimation(keyPath: "lineDashPhase")
        animation.fromValue = 0
        animation.toValue = -20
        animation.duration = 0.75
        animation.repeatCount = .infinity

        marchingAntsWhite.add(animation, forKey: "marchingAnts")

        let animBlack = animation.copy() as! CABasicAnimation
        animBlack.fromValue = 5
        animBlack.toValue = -15
        marchingAntsBlack.add(animBlack, forKey: "marchingAnts")
    }

    private func updateMarchingAntsTransform() {
        let center = CGPoint(x: selectionBounds.midX, y: selectionBounds.midY)

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: center.x + selectionTranslation.x,
                           y: center.y + selectionTranslation.y)
        t = t.rotated(by: selectionRotation)
        t = t.scaledBy(x: selectionScale, y: selectionScale)
        t = t.translatedBy(x: -center.x, y: -center.y)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let transformed = lassoPath.copy(using: [t])
        marchingAntsWhite.path = transformed
        marchingAntsBlack.path = transformed
        CATransaction.commit()
    }

    // MARK: - Gesture Handling

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: self)
        selectionTranslation.x += delta.x
        selectionTranslation.y += delta.y
        gesture.setTranslation(.zero, in: self)
        applySelectionTransform()
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        switch gesture.state {
        case .began:
            lastPinchScale = 1.0
        case .changed:
            let delta = gesture.scale / lastPinchScale
            selectionScale *= delta
            lastPinchScale = gesture.scale
            applySelectionTransform()
        default:
            break
        }
    }

    @objc private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        selectionRotation += gesture.rotation
        gesture.rotation = 0
        applySelectionTransform()
    }

    private func applySelectionTransform() {
        updateMarchingAntsTransform()
        onTransformChanged?(selectionTranslation, selectionScale, selectionRotation)
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        let isPinchOrRotation = { (g: UIGestureRecognizer) -> Bool in
            g is UIPinchGestureRecognizer || g is UIRotationGestureRecognizer
        }
        return isPinchOrRotation(gestureRecognizer) && isPinchOrRotation(other)
    }

    // MARK: - Public API

    /// Returns the cumulative transform and original bounds.
    func commitTransform() -> (transform: CGAffineTransform, bounds: CGRect) {
        let center = CGPoint(x: selectionBounds.midX, y: selectionBounds.midY)

        var t = CGAffineTransform.identity
        t = t.translatedBy(x: selectionTranslation.x, y: selectionTranslation.y)
        t = t.translatedBy(x: center.x, y: center.y)
        t = t.rotated(by: selectionRotation)
        t = t.scaledBy(x: selectionScale, y: selectionScale)
        t = t.translatedBy(x: -center.x, y: -center.y)

        return (t, selectionBounds)
    }
}

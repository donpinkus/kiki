import UIKit

/// Preview ring shown during the eyedropper long-press on the canvas.
/// Top half = current sampled color, bottom half = previous color.
final class ColorPickerRingView: UIView {

    static let ringDiameter: CGFloat = 60

    var currentColor: UIColor = .white {
        didSet { setNeedsDisplay() }
    }

    var previousColor: UIColor = .black {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        bounds = CGRect(x: 0, y: 0, width: Self.ringDiameter, height: Self.ringDiameter)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        let insetRect = rect.insetBy(dx: 2, dy: 2)
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = insetRect.width / 2

        // Top half — current sampled color
        ctx.saveGState()
        currentColor.setFill()
        ctx.beginPath()
        ctx.addArc(
            center: center,
            radius: radius,
            startAngle: .pi,        // 180° (left side)
            endAngle: 0,            // 0° (right side)
            clockwise: false        // counter-clockwise in screen coords = over the top
        )
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()

        // Bottom half — previous color
        ctx.saveGState()
        previousColor.setFill()
        ctx.beginPath()
        ctx.addArc(
            center: center,
            radius: radius,
            startAngle: 0,          // 0° (right)
            endAngle: .pi,          // 180° (left)
            clockwise: false        // through the bottom
        )
        ctx.closePath()
        ctx.fillPath()
        ctx.restoreGState()

        // Outer ring outline
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.6).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: insetRect)

        // Inner white hairline separator for contrast
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.strokeEllipse(in: insetRect.insetBy(dx: 1, dy: 1))
    }
}

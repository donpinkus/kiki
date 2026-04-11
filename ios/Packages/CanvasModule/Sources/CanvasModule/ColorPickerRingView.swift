import UIKit

/// Procreate-style eyedropper ring shown during long-press on the canvas.
/// Outer ring: top half = sampled color, bottom half = previous brush color.
/// Inner circle: transparent cutout showing the canvas below, with a crosshair.
final class ColorPickerRingView: UIView {

    static let ringDiameter: CGFloat = 120
    private static let ringWidth: CGFloat = 20
    private static let crosshairSize: CGFloat = 16
    private static let crosshairThickness: CGFloat = 1.5

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

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outerRadius = (rect.width - 4) / 2  // 2pt inset for shadow room
        let innerRadius = outerRadius - Self.ringWidth

        // -- Top half of ring: sampled color --
        // UIBezierPath clockwise is screen-relative (opposite of CGContext).
        // clockwise:true from π→0 goes over the top on screen.
        ctx.saveGState()
        let topRing = UIBezierPath()
        topRing.addArc(withCenter: center, radius: outerRadius, startAngle: .pi, endAngle: 0, clockwise: true)
        topRing.addArc(withCenter: center, radius: innerRadius, startAngle: 0, endAngle: .pi, clockwise: false)
        topRing.close()
        ctx.addPath(topRing.cgPath)
        ctx.setFillColor(currentColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // -- Bottom half of ring: current brush color --
        ctx.saveGState()
        let bottomRing = UIBezierPath()
        bottomRing.addArc(withCenter: center, radius: outerRadius, startAngle: 0, endAngle: .pi, clockwise: true)
        bottomRing.addArc(withCenter: center, radius: innerRadius, startAngle: .pi, endAngle: 0, clockwise: false)
        bottomRing.close()
        ctx.addPath(bottomRing.cgPath)
        ctx.setFillColor(previousColor.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // -- Divider line between halves --
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.3).cgColor)
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: center.x - outerRadius, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x - innerRadius, y: center.y))
        ctx.strokePath()
        ctx.move(to: CGPoint(x: center.x + innerRadius, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + outerRadius, y: center.y))
        ctx.strokePath()

        // -- Outer ring border --
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokeEllipse(in: CGRect(
            x: center.x - outerRadius, y: center.y - outerRadius,
            width: outerRadius * 2, height: outerRadius * 2
        ))

        // -- Inner ring border --
        ctx.strokeEllipse(in: CGRect(
            x: center.x - innerRadius, y: center.y - innerRadius,
            width: innerRadius * 2, height: innerRadius * 2
        ))

        // -- Crosshair in center --
        let ch = Self.crosshairSize / 2
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(Self.crosshairThickness)

        // Horizontal line
        ctx.move(to: CGPoint(x: center.x - ch, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + ch, y: center.y))
        ctx.strokePath()

        // Vertical line
        ctx.move(to: CGPoint(x: center.x, y: center.y - ch))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + ch))
        ctx.strokePath()

        // White outline on crosshair for contrast
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(Self.crosshairThickness + 1.5)

        ctx.move(to: CGPoint(x: center.x - ch, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + ch, y: center.y))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: center.x, y: center.y - ch))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + ch))
        ctx.strokePath()

        // Dark crosshair on top of white outline
        ctx.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(Self.crosshairThickness)

        ctx.move(to: CGPoint(x: center.x - ch, y: center.y))
        ctx.addLine(to: CGPoint(x: center.x + ch, y: center.y))
        ctx.strokePath()

        ctx.move(to: CGPoint(x: center.x, y: center.y - ch))
        ctx.addLine(to: CGPoint(x: center.x, y: center.y + ch))
        ctx.strokePath()
    }
}

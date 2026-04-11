import SwiftUI
import UIKit

/// Procreate-style eyedropper ring: outer ring split top (sampled) / bottom
/// (current brush), transparent center with crosshair.
public struct EyedropperRing: View {
    let sampledColor: Color
    let brushColor: Color

    public static let diameter: CGFloat = 120
    public static let offset: CGFloat = 80
    private let ringWidth: CGFloat = 20

    public init(sampledColor: Color, brushColor: Color) {
        self.sampledColor = sampledColor
        self.brushColor = brushColor
    }

    public var body: some View {
        Canvas { ctx, canvasSize in
            let size = min(canvasSize.width, canvasSize.height)
            let center = size / 2
            let outerR = (size - 4) / 2
            let innerR = outerR - ringWidth

            // NOTE on arc directions: SwiftUI Path uses screen-relative clockwise
            // (Y-down). clockwise:true from 180°→0° visually goes OVER the top.

            // Top half — current brush color
            var topPath = Path()
            topPath.addArc(center: CGPoint(x: center, y: center), radius: outerR,
                           startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            topPath.addArc(center: CGPoint(x: center, y: center), radius: innerR,
                           startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
            topPath.closeSubpath()
            ctx.fill(topPath, with: .color(brushColor))

            // Bottom half — sampled color
            var bottomPath = Path()
            bottomPath.addArc(center: CGPoint(x: center, y: center), radius: outerR,
                              startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
            bottomPath.addArc(center: CGPoint(x: center, y: center), radius: innerR,
                              startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
            bottomPath.closeSubpath()
            ctx.fill(bottomPath, with: .color(sampledColor))

            // Ring borders
            let outerCircle = Path(ellipseIn: CGRect(x: center - outerR, y: center - outerR,
                                                      width: outerR * 2, height: outerR * 2))
            let innerCircle = Path(ellipseIn: CGRect(x: center - innerR, y: center - innerR,
                                                      width: innerR * 2, height: innerR * 2))
            ctx.stroke(outerCircle, with: .color(.black.opacity(0.4)), lineWidth: 1.5)
            ctx.stroke(innerCircle, with: .color(.black.opacity(0.4)), lineWidth: 1.5)

            // Crosshair
            let ch: CGFloat = 8
            var hLine = Path()
            hLine.move(to: CGPoint(x: center - ch, y: center))
            hLine.addLine(to: CGPoint(x: center + ch, y: center))
            var vLine = Path()
            vLine.move(to: CGPoint(x: center, y: center - ch))
            vLine.addLine(to: CGPoint(x: center, y: center + ch))

            ctx.stroke(hLine, with: .color(.white.opacity(0.8)), lineWidth: 3)
            ctx.stroke(vLine, with: .color(.white.opacity(0.8)), lineWidth: 3)
            ctx.stroke(hLine, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
            ctx.stroke(vLine, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
        }
        .frame(width: Self.diameter, height: Self.diameter)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .allowsHitTesting(false)
    }

    /// Sample the color of a UIImage at a point in display coordinates.
    /// Uses a known RGBA CGContext with correct Y-flip to avoid byte-order issues.
    public static func sampleColor(from image: UIImage, at point: CGPoint, in displaySize: CGSize) -> Color? {
        guard let cgImage = image.cgImage,
              cgImage.width > 0, cgImage.height > 0,
              displaySize.width > 0, displaySize.height > 0 else {
            return nil
        }

        let scaleX = CGFloat(cgImage.width) / displaySize.width
        let scaleY = CGFloat(cgImage.height) / displaySize.height
        let px = max(0, min(cgImage.width - 1, Int(point.x * scaleX)))
        let py = max(0, min(cgImage.height - 1, Int(point.y * scaleY)))

        var pixel: [UInt8] = [0, 0, 0, 0]
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixel, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        let flippedY = cgImage.height - 1 - py
        ctx.draw(cgImage, in: CGRect(x: -px, y: -flippedY, width: cgImage.width, height: cgImage.height))

        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        let a = Double(pixel[3]) / 255
        guard a > 0 else { return Color(red: r, green: g, blue: b, opacity: 0) }
        return Color(red: r / a, green: g / a, blue: b / a, opacity: a)
    }
}

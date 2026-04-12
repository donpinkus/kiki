import SwiftUI
import UIKit

/// Procreate-style disk color picker with an outer hue ring and inner
/// saturation/brightness circle.
struct DiskColorPicker: View {

    @Binding var color: Color

    @State private var hue: CGFloat = 0
    @State private var saturation: CGFloat = 1
    @State private var brightness: CGFloat = 1

    @State private var isDraggingHue = false
    @State private var isDraggingSB = false
    @State private var sbImage: UIImage?

    // MARK: - Layout Constants

    private let totalDiameter: CGFloat = 280
    private let ringWidth: CGFloat = 30
    private let innerDiameter: CGFloat = 196
    private let indicatorSize: CGFloat = 26
    private let sbImageSize: Int = 400

    // MARK: - Body

    var body: some View {
        ZStack {
            hueRing
            hueIndicator
            sbCircle
            sbIndicator
        }
        .frame(width: totalDiameter, height: totalDiameter)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    let size = CGSize(width: totalDiameter, height: totalDiameter)
                    let started = !isDraggingHue && !isDraggingSB
                    handleDrag(at: value.location, in: size, started: started)
                }
                .onEnded { _ in
                    isDraggingHue = false
                    isDraggingSB = false
                }
        )
        .onAppear {
            decompose()
            regenerateSBImage()
        }
        .onChange(of: color) { _, _ in
            guard !isDraggingHue && !isDraggingSB else { return }
            decompose()
            regenerateSBImage()
        }
        .padding(20)
    }

    // MARK: - Hue Ring

    private var hueRing: some View {
        let colors = (0...12).map { i in
            Color(hue: Double(i) / 12.0, saturation: 1, brightness: 1)
        }
        return AngularGradient(
            gradient: Gradient(colors: colors),
            center: .center
        )
        .mask(
            Circle()
                .strokeBorder(lineWidth: ringWidth)
        )
        .frame(width: totalDiameter, height: totalDiameter)
    }

    private var hueIndicator: some View {
        let ringRadius = (totalDiameter - ringWidth) / 2
        let angle = hue * 2 * .pi
        let x = cos(angle) * ringRadius
        let y = sin(angle) * ringRadius

        return Circle()
            .fill(Color(hue: hue, saturation: 1, brightness: 1))
            .frame(width: indicatorSize, height: indicatorSize)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .offset(x: x, y: y)
    }

    // MARK: - Saturation/Brightness Circle

    private var sbCircle: some View {
        Group {
            if let image = sbImage {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: innerDiameter, height: innerDiameter)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .frame(width: innerDiameter, height: innerDiameter)
            }
        }
    }

    private var sbIndicator: some View {
        let r = innerDiameter / 2
        let a = 2 * saturation - 1
        let b = 1 - 2 * brightness
        let (dx, dy) = squareToDisk(a, b)

        return Circle()
            .fill(Color(hue: hue, saturation: saturation, brightness: brightness))
            .frame(width: indicatorSize, height: indicatorSize)
            .overlay(Circle().stroke(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .offset(x: dx * r, y: dy * r)
    }

    // MARK: - Gesture Handling

    private func handleDrag(at location: CGPoint, in size: CGSize, started: Bool) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = location.x - center.x
        let dy = location.y - center.y
        let dist = sqrt(dx * dx + dy * dy)

        if started {
            let innerR = innerDiameter / 2
            if dist > innerR {
                isDraggingHue = true
            } else {
                isDraggingSB = true
            }
        }

        if isDraggingHue {
            var angle = atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            hue = angle / (2 * .pi)
            regenerateSBImage()
            commitColor()
        }

        if isDraggingSB {
            let r = innerDiameter / 2
            // Normalize to unit disk, clamp to boundary
            var nx = dx / r
            var ny = dy / r
            let nd = sqrt(nx * nx + ny * ny)
            if nd > 1 { nx /= nd; ny /= nd }
            // FG-squircle: disk → square
            let (a, b) = diskToSquare(nx, ny)
            saturation = max(0, min(1, (a + 1) / 2))
            brightness = max(0, min(1, (1 - b) / 2))
            commitColor()
        }
    }

    // MARK: - SB Image Generation

    private func regenerateSBImage() {
        sbImage = generateSBImage(hue: hue, size: sbImageSize)
    }

    private func generateSBImage(hue: CGFloat, size: Int) -> UIImage {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        let sizeF = CGFloat(size)
        let radius = sizeF / 2

        for py in 0..<size {
            for px in 0..<size {
                let offset = (py * size + px) * 4

                // Normalize to [-1, 1]
                let nx = (CGFloat(px) - radius) / radius
                let ny = (CGFloat(py) - radius) / radius

                if nx * nx + ny * ny > 1 {
                    continue // transparent (already zeroed)
                }

                // FG-squircle: disk → square
                let (a, b) = diskToSquare(nx, ny)
                let s = (a + 1) / 2
                let brt = (1 - b) / 2

                let (r, g, bl) = hsbToRGB(h: hue, s: s, b: brt)
                pixels[offset] = r
                pixels[offset + 1] = g
                pixels[offset + 2] = bl
                pixels[offset + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let cgImage = ctx.makeImage() else {
            return UIImage()
        }

        return UIImage(cgImage: cgImage)
    }

    // MARK: - Square ↔ Disk Mapping (FG-Squircle)

    /// Maps a point in [-1,1]² to the unit disk. Single smooth formula, no sectors.
    private func squareToDisk(_ a: CGFloat, _ b: CGFloat) -> (CGFloat, CGFloat) {
        (a * sqrt(max(0, 1 - b * b / 2)),
         b * sqrt(max(0, 1 - a * a / 2)))
    }

    /// Inverse FG-squircle mapping (unit disk → [-1,1]²).
    private func diskToSquare(_ x: CGFloat, _ y: CGFloat) -> (CGFloat, CGFloat) {
        if x == 0 && y == 0 { return (0, 0) }
        let p = x * x + y * y
        let q = x * x - y * y
        let s = 2 - sqrt(max(0, 4 - 4 * p + q * q))
        let a = copysign(sqrt(max(0, (s + q) / 2)), x)
        let b = copysign(sqrt(max(0, (s - q) / 2)), y)
        return (a, b)
    }

    /// Pure-math HSB → RGB conversion (avoids UIColor overhead per pixel).
    private func hsbToRGB(h: CGFloat, s: CGFloat, b: CGFloat) -> (UInt8, UInt8, UInt8) {
        let c = b * s
        let hp = h * 6
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        let m = b - c

        let r1, g1, b1: CGFloat
        switch Int(hp) % 6 {
        case 0: (r1, g1, b1) = (c, x, 0)
        case 1: (r1, g1, b1) = (x, c, 0)
        case 2: (r1, g1, b1) = (0, c, x)
        case 3: (r1, g1, b1) = (0, x, c)
        case 4: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }

        return (
            UInt8(max(0, min(255, (r1 + m) * 255))),
            UInt8(max(0, min(255, (g1 + m) * 255))),
            UInt8(max(0, min(255, (b1 + m) * 255)))
        )
    }

    // MARK: - Helpers

    private func commitColor() {
        color = Color(UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
    }

    private func decompose() {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = h
        saturation = s
        brightness = b
    }
}

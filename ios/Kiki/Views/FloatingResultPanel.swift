import SwiftUI
import ResultModule

struct FloatingResultPanel: View {
    let resultState: ResultState
    let canSwapStream: Bool
    let containerSize: CGSize
    let currentBrushColor: Color
    let onClose: () -> Void
    let onSwapStreamToCanvas: () -> Void
    let onColorPicked: ((Color) -> Void)?
    var onInteraction: (() -> Void)? = nil

    @State private var position: CGPoint = .zero
    @State private var size: CGSize?
    @State private var dragOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero

    @State private var isPickingColor = false
    @State private var pickLocation: CGPoint = .zero
    @State private var sampledColor: Color = .white

    private let minSize = CGSize(width: 200, height: 160)

    private var resolvedSize: CGSize {
        size ?? CGSize(width: containerSize.width * 0.45, height: containerSize.height * 0.55)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header — drag handle + close button
            HStack {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        onInteraction?()
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        position.x += value.translation.width
                        position.y += value.translation.height
                        dragOffset = .zero
                    }
            )

            // Image
            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // Footer
            footer
        }
        .frame(width: effectiveSize.width, height: effectiveSize.height)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .offset(x: position.x + dragOffset.width, y: position.y + dragOffset.height)
    }

    // MARK: - Image Content

    @ViewBuilder
    private var imageContent: some View {
        switch resultState {
        case .preview(let image), .streaming(let image, _):
            pickableImage(image).padding(4)

        case .generating(_, let previousImage):
            ZStack {
                if let prev = previousImage {
                    pickableImage(prev).opacity(0.5)
                }
                ProgressView()
                    .controlSize(.regular)
            }
            .padding(4)

        case .error(_, let previousImage):
            if let prev = previousImage {
                pickableImage(prev).padding(4)
            } else {
                Color(.systemGray6)
            }

        case .empty:
            Color(.systemGray6)
        }
    }

    private func pickableImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay(
                GeometryReader { proxy in
                    ZStack {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(eyedropperGesture(image: image, size: proxy.size))

                        if isPickingColor {
                            FloatingColorPickerRing(
                                currentColor: sampledColor,
                                previousColor: currentBrushColor
                            )
                            .frame(width: 120, height: 120)
                            .position(x: pickLocation.x, y: pickLocation.y - 80)
                            .allowsHitTesting(false)
                        }
                    }
                }
            )
    }

    // MARK: - Eyedropper

    private static let ringOffset: CGFloat = 80

    private func eyedropperGesture(image: UIImage, size: CGSize) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onChanged { value in
                switch value {
                case .first:
                    break
                case .second(let longPressComplete, let dragValue):
                    guard longPressComplete, let drag = dragValue else { return }
                    isPickingColor = true
                    pickLocation = drag.location
                    let samplePoint = CGPoint(x: drag.location.x, y: drag.location.y - Self.ringOffset)
                    if let color = sampleColor(from: image, at: samplePoint, in: size) {
                        sampledColor = color
                    }
                }
            }
            .onEnded { value in
                if case .second(true, _) = value, isPickingColor {
                    onColorPicked?(sampledColor)
                }
                isPickingColor = false
            }
    }

    private func sampleColor(from image: UIImage, at point: CGPoint, in displaySize: CGSize) -> Color? {
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

        ctx.draw(cgImage, in: CGRect(x: -px, y: -py, width: cgImage.width, height: cgImage.height))

        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        let a = Double(pixel[3]) / 255
        guard a > 0 else { return Color(red: r, green: g, blue: b, opacity: 0) }
        return Color(red: r / a, green: g / a, blue: b / a, opacity: a)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if canSwapStream {
                Button(action: onSwapStreamToCanvas) {
                    Text("Send to canvas")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.mini)
            }

            Spacer()

            // Resize handle
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            onInteraction?()
                            resizeOffset = value.translation
                        }
                        .onEnded { value in
                            let base = resolvedSize
                            size = CGSize(
                                width: max(minSize.width, base.width + value.translation.width),
                                height: max(minSize.height, base.height + value.translation.height)
                            )
                            resizeOffset = .zero
                        }
                )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Computed

    private var effectiveSize: CGSize {
        let maxWidth = containerSize.width * 0.8
        let maxHeight = containerSize.height * 0.8
        let base = resolvedSize
        return CGSize(
            width: min(maxWidth, max(minSize.width, base.width + resizeOffset.width)),
            height: min(maxHeight, max(minSize.height, base.height + resizeOffset.height))
        )
    }
}

// MARK: - Color Picker Ring

/// Procreate-style eyedropper ring: outer ring split top (sampled) / bottom
/// (previous), transparent center with crosshair.
private struct FloatingColorPickerRing: View {
    let currentColor: Color
    let previousColor: Color

    private let ringWidth: CGFloat = 20

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = size / 2
            let outerR = (size - 4) / 2
            let innerR = outerR - ringWidth

            Canvas { ctx, _ in
                // Top half — sampled color
                var topPath = Path()
                topPath.addArc(center: CGPoint(x: center, y: center), radius: outerR,
                               startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                topPath.addArc(center: CGPoint(x: center, y: center), radius: innerR,
                               startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                topPath.closeSubpath()
                ctx.fill(topPath, with: .color(currentColor))

                // Bottom half — previous color
                var bottomPath = Path()
                bottomPath.addArc(center: CGPoint(x: center, y: center), radius: outerR,
                                  startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
                bottomPath.addArc(center: CGPoint(x: center, y: center), radius: innerR,
                                  startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                bottomPath.closeSubpath()
                ctx.fill(bottomPath, with: .color(previousColor))

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

                // White outline then dark line
                ctx.stroke(hLine, with: .color(.white.opacity(0.8)), lineWidth: 3)
                ctx.stroke(vLine, with: .color(.white.opacity(0.8)), lineWidth: 3)
                ctx.stroke(hLine, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
                ctx.stroke(vLine, with: .color(.black.opacity(0.7)), lineWidth: 1.5)
            }
            .frame(width: size, height: size)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

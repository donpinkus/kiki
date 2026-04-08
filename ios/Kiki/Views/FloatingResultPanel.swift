import SwiftUI
import ResultModule

struct FloatingResultPanel: View {
    let resultState: ResultState
    let showingLineart: Bool
    let hasLineart: Bool
    let isGenerating: Bool
    let isStreamMode: Bool
    let canSwapStream: Bool
    let containerSize: CGSize
    let currentBrushColor: Color
    let onClose: () -> Void
    let onToggleLineart: () -> Void
    let onSwapToCanvas: () -> Void
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

            // Footer — lineart toggle + swap + resize handle
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
                            .frame(width: 60, height: 60)
                            .position(x: pickLocation.x, y: pickLocation.y - 40)
                            .allowsHitTesting(false)
                        }
                    }
                }
            )
    }

    // MARK: - Eyedropper

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
                    if let color = sampleColor(from: image, at: drag.location, in: size) {
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
              displaySize.width > 0, displaySize.height > 0,
              let data = cgImage.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return nil
        }

        let scaleX = CGFloat(cgImage.width) / displaySize.width
        let scaleY = CGFloat(cgImage.height) / displaySize.height
        let px = max(0, min(cgImage.width - 1, Int(point.x * scaleX)))
        let py = max(0, min(cgImage.height - 1, Int(point.y * scaleY)))

        let bytesPerPixel = cgImage.bitsPerPixel / 8
        guard bytesPerPixel >= 3 else { return nil }

        let index = py * cgImage.bytesPerRow + px * bytesPerPixel
        let r = Double(bytes[index]) / 255
        let g = Double(bytes[index + 1]) / 255
        let b = Double(bytes[index + 2]) / 255
        let a: Double = bytesPerPixel >= 4 ? Double(bytes[index + 3]) / 255 : 1.0
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            if !isStreamMode && hasLineart && !isGenerating {
                Button { if showingLineart { onToggleLineart() } } label: {
                    Text("Generated")
                        .font(.caption.weight(showingLineart ? .regular : .semibold))
                        .foregroundStyle(showingLineart ? .secondary : .primary)
                }
                .buttonStyle(.plain)

                Button { if !showingLineart { onToggleLineart() } } label: {
                    Text("Line art")
                        .font(.caption.weight(showingLineart ? .semibold : .regular))
                        .foregroundStyle(showingLineart ? .primary : .secondary)
                }
                .buttonStyle(.plain)

                if showingLineart {
                    Spacer()
                    Button(action: onSwapToCanvas) {
                        Text("Send to canvas")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                }
            } else if isStreamMode && canSwapStream {
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

private struct FloatingColorPickerRing: View {
    let currentColor: Color
    let previousColor: Color

    var body: some View {
        ZStack {
            Circle().fill(previousColor)
            Circle()
                .fill(currentColor)
                .mask(
                    GeometryReader { proxy in
                        Rectangle()
                            .frame(width: proxy.size.width, height: proxy.size.height / 2)
                    }
                )
            Circle()
                .strokeBorder(Color.black.opacity(0.6), lineWidth: 2)
            Circle()
                .strokeBorder(Color.white.opacity(0.8), lineWidth: 1)
                .padding(1)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

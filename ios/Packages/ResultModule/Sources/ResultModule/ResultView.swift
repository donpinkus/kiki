import SwiftUI

/// Displays the generated image result with support for loading, error, and empty states.
///
/// The view never shows a blank pane after the first successful image.
/// Errors are shown as non-blocking toasts while preserving the last image.
public struct ResultView: View {

    // MARK: - Properties

    private let state: ResultState
    private let currentBrushColor: Color
    private let onColorPicked: ((Color) -> Void)?

    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastDismissTask: Task<Void, Never>?

    @State private var isPickingColor = false
    @State private var pickLocation: CGPoint = .zero
    @State private var sampledColor: Color = .white

    // MARK: - Lifecycle

    public init(
        state: ResultState = .empty,
        currentBrushColor: Color = .black,
        onColorPicked: ((Color) -> Void)? = nil
    ) {
        self.state = state
        self.currentBrushColor = currentBrushColor
        self.onColorPicked = onColorPicked
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            switch state {
            case .empty:
                emptyView

            case .generating(let progress, let previousImage):
                generatingView(progress: progress, previousImage: previousImage)

            case .preview(let image):
                imageView(image)

            case .streaming(let image, let frameCount):
                streamingView(image, frameCount: frameCount)

            case .error(let message, let previousImage):
                errorView(message: message, previousImage: previousImage)
            }

            if showToast {
                toastOverlay
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showToast)
    }

    // MARK: - Subviews

    private var emptyView: some View {
        VStack(spacing: 16) {
            Image(systemName: "pencil.and.scribble")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("Start drawing to see your image come to life.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private func generatingView(progress: GenerationProgress, previousImage: UIImage?) -> some View {
        ZStack {
            if let image = previousImage {
                imageView(image)
            } else {
                Color(.systemGray5)
            }

            VStack {
                Spacer()
                progressPanel(progress: progress)
                    .padding(.bottom, 24)
                    .padding(.horizontal, 24)
            }
        }
    }

    private func errorView(message: String, previousImage: UIImage?) -> some View {
        ZStack {
            if let image = previousImage {
                imageView(image)
            } else {
                emptyView
            }
        }
        .overlay {
            // Invisible view with .id(message) forces .onAppear to re-fire when
            // the error message changes within the same structural view position.
            // Without this, consecutive errors (e.g. two fast failures during the
            // synchronous preparation phase) would swallow the second toast.
            Color.clear
                .id(message)
                .onAppear {
                    showToastMessage(message)
                }
        }
    }

    private func streamingView(_ image: UIImage, frameCount: Int) -> some View {
        ZStack(alignment: .topTrailing) {
            imageView(image)

            Text("LIVE \(frameCount)")
                .font(.caption2.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.red.opacity(0.85), in: Capsule())
                .padding(12)
        }
    }

    private func imageView(_ image: UIImage) -> some View {
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
                            ColorPickerRing(
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
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
            .padding(12)
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
                    // Sample at crosshair position (center of ring), not finger
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

    /// Sample a pixel using a known RGBA CGContext to avoid byte-order issues.
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

        // CGContext has Y=0 at bottom; flip so screen-coordinate py maps correctly
        let flippedY = cgImage.height - 1 - py
        ctx.draw(cgImage, in: CGRect(x: -px, y: -flippedY, width: cgImage.width, height: cgImage.height))

        let r = Double(pixel[0]) / 255
        let g = Double(pixel[1]) / 255
        let b = Double(pixel[2]) / 255
        let a = Double(pixel[3]) / 255
        guard a > 0 else { return Color(red: r, green: g, blue: b, opacity: 0) }
        return Color(red: r / a, green: g / a, blue: b / a, opacity: a)
    }

    // MARK: - Progress Panel

    private func progressPanel(progress: GenerationProgress) -> some View {
        TimelineView(.periodic(from: progress.phaseStartedAt, by: 1.0)) { context in
            let elapsed = context.date.timeIntervalSince(progress.phaseStartedAt)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(GenerationPhase.allCases) { phase in
                    phaseRow(
                        phase: phase,
                        progress: progress,
                        elapsed: elapsed
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func phaseRow(
        phase: GenerationPhase,
        progress: GenerationProgress,
        elapsed: TimeInterval
    ) -> some View {
        HStack(spacing: 8) {
            if let duration = progress.durations[phase] {
                // Completed
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption2)
                Text(phase.label)
                    .foregroundStyle(.white.opacity(0.7))
                Spacer()
                Text(formatDuration(duration))
                    .foregroundStyle(.white.opacity(0.5))
            } else if phase == progress.currentPhase {
                // Active
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
                Text(phase.label)
                    .foregroundStyle(.white)
                Spacer()
                Text(formatDuration(elapsed))
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                // Pending
                Image(systemName: "circle")
                    .foregroundStyle(.white.opacity(0.3))
                    .font(.caption2)
                Text(phase.label)
                    .foregroundStyle(.white.opacity(0.3))
                Spacer()
            }
        }
        .font(.caption)
        .fontDesign(.monospaced)
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 { return "< 1s" }
        return "\(Int(duration))s"
    }

    // MARK: - Toast

    private var toastOverlay: some View {
        VStack {
            Spacer()

            HStack {
                Text(toastMessage)
                    .font(.caption)
                    .fontDesign(.monospaced)
                    .foregroundStyle(.white)

                Image(systemName: "xmark")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .onTapGesture {
                dismissToast()
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Private

    private func showToastMessage(_ message: String) {
        toastDismissTask?.cancel()
        toastMessage = message
        withAnimation {
            showToast = true
        }
        toastDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            dismissToast()
        }
    }

    private func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation {
            showToast = false
        }
    }
}

// MARK: - Color Picker Ring

/// Procreate-style eyedropper ring: outer ring split top (sampled) / bottom
/// (previous), transparent center with crosshair.
private struct ColorPickerRing: View {
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
                var topPath = Path()
                topPath.addArc(center: CGPoint(x: center, y: center), radius: outerR,
                               startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
                topPath.addArc(center: CGPoint(x: center, y: center), radius: innerR,
                               startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                topPath.closeSubpath()
                ctx.fill(topPath, with: .color(currentColor))

                var bottomPath = Path()
                bottomPath.addArc(center: CGPoint(x: center, y: center), radius: outerR,
                                  startAngle: .degrees(0), endAngle: .degrees(180), clockwise: true)
                bottomPath.addArc(center: CGPoint(x: center, y: center), radius: innerR,
                                  startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
                bottomPath.closeSubpath()
                ctx.fill(bottomPath, with: .color(previousColor))

                let outerCircle = Path(ellipseIn: CGRect(x: center - outerR, y: center - outerR,
                                                          width: outerR * 2, height: outerR * 2))
                let innerCircle = Path(ellipseIn: CGRect(x: center - innerR, y: center - innerR,
                                                          width: innerR * 2, height: innerR * 2))
                ctx.stroke(outerCircle, with: .color(.black.opacity(0.4)), lineWidth: 1.5)
                ctx.stroke(innerCircle, with: .color(.black.opacity(0.4)), lineWidth: 1.5)

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
            .frame(width: size, height: size)
        }
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
    }
}

// MARK: - Preview

#Preview("Empty") {
    ResultView(state: .empty)
}

#Preview("Generating – Preparing") {
    ResultView(state: .generating(
        progress: GenerationProgress(currentPhase: .preparing),
        previousImage: nil
    ))
}

#Preview("Generating – Uploading") {
    ResultView(state: .generating(
        progress: GenerationProgress(
            currentPhase: .uploading,
            durations: [.preparing: 0.08]
        ),
        previousImage: nil
    ))
}

#Preview("Generating – Downloading") {
    ResultView(state: .generating(
        progress: GenerationProgress(
            currentPhase: .downloading,
            durations: [.preparing: 0.05, .uploading: 11.3]
        ),
        previousImage: nil
    ))
}

#Preview("Error") {
    ResultView(state: .error(
        message: "Server error 200: Generation timed out after 120s",
        previousImage: nil
    ))
}

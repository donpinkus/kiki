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
    private let onResumeTapped: (() -> Void)?

    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastDismissTask: Task<Void, Never>?

    @State private var isPickingColor = false
    @State private var pickLocation: CGPoint = .zero
    @State private var sampledColor: Color = .white
    @State private var holdTimer: Task<Void, Never>?
    @State private var dragStart: CGPoint = .zero

    // MARK: - Lifecycle

    public init(
        state: ResultState = .empty,
        currentBrushColor: Color = .black,
        onColorPicked: ((Color) -> Void)? = nil,
        onResumeTapped: (() -> Void)? = nil
    ) {
        self.state = state
        self.currentBrushColor = currentBrushColor
        self.onColorPicked = onColorPicked
        self.onResumeTapped = onResumeTapped
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            switch state {
            case .empty:
                emptyView

            case .provisioning(let message, let startedAt):
                provisioningView(message: message, startedAt: startedAt)

            case .generating(let progress, let previousImage):
                generatingView(progress: progress, previousImage: previousImage)

            case .preview(let image):
                imageView(image)

            case .streaming(let image, let frameCount):
                streamingView(image, frameCount: frameCount)

            case .error(let message, let previousImage):
                errorView(message: message, previousImage: previousImage)

            case .idleTimeout(let message, let previousImage):
                idleTimeoutView(message: message, previousImage: previousImage)

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

    // MARK: - Provisioning

    private func provisioningView(message: String, startedAt: Date) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            // Asymptotic curve approaching 95% — starts fast, slows down.
            // t=15s ≈ 39%, t=30s ≈ 63%, t=60s ≈ 87%, t=90s ≈ 95%.
            let elapsed = max(0, context.date.timeIntervalSince(startedAt))
            let progress = min(0.95, 1.0 - exp(-elapsed / 30.0))

            VStack(spacing: 28) {
                Spacer(minLength: 0)

                Image(systemName: "wand.and.stars")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(provisioningGradient)
                    .symbolEffect(.pulse, options: .repeating)

                VStack(spacing: 8) {
                    Text("Warming up the AI")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text("First-time setup takes about 90 seconds")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    provisioningProgressBar(progress: progress)
                        .frame(height: 8)
                        .frame(maxWidth: 320)

                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 320, minHeight: 28, alignment: .top)
                        .animation(.easeInOut(duration: 0.2), value: message)
                }

                Label {
                    Text("Keep sketching — your drawing will appear here as soon as the AI is ready.")
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: "pencil.and.scribble")
                        .foregroundStyle(.tint)
                }
                .padding(16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 32)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 32)
        }
    }

    // MARK: - Idle Timeout

    private func idleTimeoutView(message _: String, previousImage: UIImage?) -> some View {
        Button(action: { onResumeTapped?() }) {
            ZStack {
                // Last generated image stays visible underneath as a reminder
                // that the user's work hasn't gone anywhere.
                if let image = previousImage {
                    imageView(image)
                }
                // Semi-opaque dim on top — mostly covers the image so the
                // paused state reads clearly, but the image is still faintly
                // visible behind it.
                Color.black.opacity(0.55)
                    .ignoresSafeArea()

                VStack(spacing: 20) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.system(size: 48, weight: .light))
                        .foregroundStyle(idleGradient)

                    Text("Session Paused - Draw to Resume")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(idleGradient)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var idleGradient: LinearGradient {
        LinearGradient(
            colors: [.teal, .purple],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var provisioningGradient: LinearGradient {
        LinearGradient(
            colors: [.purple, .pink, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func provisioningProgressBar(progress: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 4)
                    .fill(
                        LinearGradient(
                            colors: [.purple, .pink, .orange],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(8, geo.size.width * progress))
                    .animation(.easeOut(duration: 0.6), value: progress)
            }
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
        imageView(image)
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
                            EyedropperRing(sampledColor: sampledColor, brushColor: currentBrushColor)
                                .position(x: pickLocation.x, y: pickLocation.y - EyedropperRing.offset)
                        }
                    }
                }
            )
            .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
    }

    // MARK: - Eyedropper

    /// Uses a plain DragGesture with a hold timer instead of
    /// LongPressGesture.sequenced(before: DragGesture), which has
    /// a ~1s delay due to system gesture gate disambiguation.
    private func eyedropperGesture(image: UIImage, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { drag in
                if !isPickingColor {
                    // First touch or still waiting — start/continue hold timer
                    if holdTimer == nil {
                        dragStart = drag.location
                        holdTimer = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(300))
                            guard !Task.isCancelled else { return }
                            isPickingColor = true
                            updateSample(at: dragStart, image: image, size: size)
                        }
                    }
                    // Cancel if finger moved too far before activation
                    let dx = drag.location.x - dragStart.x
                    let dy = drag.location.y - dragStart.y
                    if dx * dx + dy * dy > 100 { // 10pt radius
                        holdTimer?.cancel()
                        holdTimer = nil
                    }
                } else {
                    // Already active — track finger
                    updateSample(at: drag.location, image: image, size: size)
                }
            }
            .onEnded { _ in
                holdTimer?.cancel()
                holdTimer = nil
                if isPickingColor {
                    onColorPicked?(sampledColor)
                    isPickingColor = false
                }
            }
    }

    private func updateSample(at location: CGPoint, image: UIImage, size: CGSize) {
        pickLocation = location
        let samplePoint = CGPoint(x: location.x, y: location.y - EyedropperRing.offset)
        if let color = EyedropperRing.sampleColor(from: image, at: samplePoint, in: size) {
            sampledColor = color
        }
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

// MARK: - Preview

#Preview("Empty") {
    ResultView(state: .empty)
}

#Preview("Provisioning – Just started") {
    ResultView(state: .provisioning(
        message: "Reserving GPU…",
        startedAt: Date()
    ))
}

#Preview("Provisioning – Mid warm-up") {
    ResultView(state: .provisioning(
        message: "Loading model weights — this is the longest step",
        startedAt: Date().addingTimeInterval(-30)
    ))
}

#Preview("Provisioning – Almost ready") {
    ResultView(state: .provisioning(
        message: "Final initialization…",
        startedAt: Date().addingTimeInterval(-75)
    ))
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

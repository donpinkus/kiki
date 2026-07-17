import AVFoundation
import AVKit
import OSLog
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
    private let isUserDrawing: Bool

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
        isUserDrawing: Bool = false
    ) {
        self.state = state
        self.currentBrushColor = currentBrushColor
        self.onColorPicked = onColorPicked
        self.isUserDrawing = isUserDrawing
    }

    // MARK: - Body

    public var body: some View {
        ZStack {
            Color(.systemGray6)
                .ignoresSafeArea()

            switch state {
            case .empty:
                emptyView

            case .provisioning(let message, let previousImage):
                provisioningView(message: message, previousImage: previousImage)
                    .accessibilityElement(children: .combine)

            case .preview(let image):
                imageView(image)

            case .streaming(let image, let frameCount):
                streamingView(image, frameCount: frameCount)

            case .error(let message, let previousImage):
                errorView(message: message, previousImage: previousImage)

            case .videoStreaming(let latestFrame, _):
                imageView(latestFrame)

            case .videoLooping(let mp4URL, let fallback):
                LoopingVideoView(url: mp4URL, fallback: fallback)
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)

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

    private func provisioningView(message: String, previousImage: UIImage?) -> some View {
        ZStack {
            if let previousImage {
                // Dimmed last result stays visible so the user keeps a
                // sense of continuity with their drawing while we reconnect.
                imageView(previousImage)
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .animation(.easeInOut(duration: 0.25), value: previousImage)
            } else {
                // Rainbow particles that respond to canvas drawing — gives
                // the user something to play with while we connect.
                ParticleField(isEmitting: isUserDrawing)
            }

            provisioningContent(message: message, hasBackground: previousImage != nil)
        }
    }

    private func provisioningContent(message: String, hasBackground: Bool) -> some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)

            Image(systemName: "wand.and.stars")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(provisioningGradient)
                .symbolEffect(.pulse, options: .repeating)

            VStack(spacing: 8) {
                Text("Getting ready to draw")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(hasBackground ? AnyShapeStyle(provisioningGradient) : AnyShapeStyle(HierarchicalShapeStyle.primary))
                    .modifier(LayeredShadow(enabled: hasBackground))

                // Honest about the fal pool's two modes: warm connects land in
                // a second or two; a cold pool can take a couple of minutes.
                Text("Usually just a moment — occasionally a couple of minutes")
                    .font(.subheadline)
                    .foregroundStyle(hasBackground ? AnyShapeStyle(Color.white.opacity(0.85)) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            }

            Text(message)
                .font(.caption)
                .foregroundStyle(hasBackground ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320, minHeight: 28, alignment: .top)
                .animation(.easeInOut(duration: 0.2), value: message)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
    }

    /// Title legibility on a dimmed image background — tight crisp shadow
    /// for edge definition + softer diffuse halo for separation from the
    /// underlying image (the pattern Apple uses for titles atop photo/video
    /// backgrounds).
    private struct LayeredShadow: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            } else {
                content
            }
        }
    }

    private var provisioningGradient: LinearGradient {
        LinearGradient(
            colors: [.purple, .pink, .orange],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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

#Preview("Provisioning") {
    ResultView(state: .provisioning(
        message: "Connecting…",
        previousImage: nil
    ))
}

#Preview("Provisioning – With previous image") {
    ResultView(state: .provisioning(
        message: "Connecting…",
        previousImage: UIImage(systemName: "photo.fill")?.withTintColor(.systemTeal, renderingMode: .alwaysOriginal)
    ))
}

#Preview("Error") {
    ResultView(state: .error(
        message: "Server error 200: Generation timed out after 120s",
        previousImage: nil
    ))
}

// MARK: - LoopingVideoView

/// AVPlayerLooper-backed seamless MP4 loop for `.videoLooping`.
///
/// Renders into a CALayer via AVPlayerLayer (no AVPlayerViewController
/// chrome). Looping is via AVPlayerLooper against an AVQueuePlayer so the
/// transition between iterations is seamless — AVPlayer's `.seekToZero`
/// approach has a visible blink on H.264.
///
/// `fallback` is shown if the player item enters `.failed` (file gone,
/// decode error). Constraint #2: never clear the right pane.
private struct LoopingVideoView: UIViewRepresentable {
    let url: URL
    let fallback: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.fallbackImage = fallback
        attach(view: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ view: PlayerContainerView, context: Context) {
        view.fallbackImage = fallback
        // If the URL changed, rebuild the player. Same URL → keep looping.
        if context.coordinator.currentURL != url {
            attach(view: view, coordinator: context.coordinator)
        }
    }

    static func dismantleUIView(_ view: PlayerContainerView, coordinator: Coordinator) {
        coordinator.player?.pause()
        coordinator.looper = nil
        coordinator.player = nil
        coordinator.currentURL = nil
    }

    private func attach(view: PlayerContainerView, coordinator: Coordinator) {
        configureAudioSession()
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = false
        player.volume = 1.0
        coordinator.looper = AVPlayerLooper(player: player, templateItem: item)
        coordinator.player = player
        coordinator.currentURL = url
        view.attach(player: player)
        player.play()
    }

    private func configureAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            videoLog.warning("LoopingVideoView audio session setup failed: \(error.localizedDescription)")
        }
    }

    final class Coordinator {
        var player: AVQueuePlayer?
        var looper: AVPlayerLooper?
        var currentURL: URL?
    }
}

/// UIView host for AVPlayerLayer. Falls back to a static image if the
/// player item fails — covers KVO `.failed` (decode/asset load fails before
/// playback) plus `failedToPlayToEndTime` and `playbackStalled` (failures
/// after the item enters `.readyToPlay`, which the status KVO alone misses).
private final class PlayerContainerView: UIView {
    private var playerLayer: AVPlayerLayer?
    private let fallbackImageView = UIImageView()
    private var failureObserver: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []

    var fallbackImage: UIImage? {
        didSet { fallbackImageView.image = fallbackImage }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        fallbackImageView.contentMode = .scaleAspectFit
        fallbackImageView.frame = bounds
        fallbackImageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fallbackImageView.isHidden = true
        addSubview(fallbackImageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    deinit {
        removeNotificationObservers()
    }

    func attach(player: AVPlayer) {
        playerLayer?.removeFromSuperlayer()
        removeNotificationObservers()

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.frame = bounds
        self.layer.addSublayer(layer)
        playerLayer = layer

        guard let item = player.currentItem else { return }

        // KVO: catches the `.failed` transition (asset load / initial decode).
        failureObserver = item.observe(\.status, options: [.new]) { [weak self, weak layer] item, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if item.status == .failed {
                    self.showFallback(layer: layer, reason: "status=failed err=\(item.error?.localizedDescription ?? "nil")")
                } else {
                    self.fallbackImageView.isHidden = true
                    layer?.isHidden = false
                }
            }
        }

        // Notifications: catch failures that happen *after* `.readyToPlay`,
        // which KVO on `.status` doesn't observe.
        let center = NotificationCenter.default
        notificationObservers.append(center.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self, weak layer] note in
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            self?.showFallback(layer: layer, reason: "failedToPlayToEndTime err=\(err?.localizedDescription ?? "nil")")
        })
        notificationObservers.append(center.addObserver(
            forName: AVPlayerItem.playbackStalledNotification,
            object: item,
            queue: .main
        ) { [weak self, weak layer] _ in
            self?.showFallback(layer: layer, reason: "playbackStalled")
        })
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer?.frame = bounds
    }

    private func showFallback(layer: AVPlayerLayer?, reason: String) {
        videoLog.warning("LoopingVideoView falling back: \(reason)")
        fallbackImageView.isHidden = false
        layer?.isHidden = true
    }

    private func removeNotificationObservers() {
        let center = NotificationCenter.default
        for token in notificationObservers { center.removeObserver(token) }
        notificationObservers.removeAll()
    }
}

private let videoLog = Logger(subsystem: "com.kiki.result", category: "video")

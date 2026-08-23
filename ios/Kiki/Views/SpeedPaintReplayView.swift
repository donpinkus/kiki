import AVKit
import Sentry
import SwiftUI

/// The speed-paint replay share PAGE (AppScreen.replay, entered from the
/// drawing's Share menu): previews the replay in an autoplaying, looping
/// player and lets the user pick a layout (side-by-side / stacked) and speed
/// before sharing. A full screen rather than a modal so the preview gets all
/// the real estate — and fullScreenCover was never an option: video layers
/// inside this app's fullScreenCover never composite on iPadOS 26 hardware
/// (even AVPlayerViewController shows nothing), while plain screens (this,
/// Animate) and sheets display fine.
///
/// The preview plays the stitched composition directly — no encode pass — so
/// it appears near-instantly and re-composes live when layout or speed
/// changes. The MP4 is only encoded when a share action is tapped, which is
/// also when the watermark is burned (`AVVideoCompositionCoreAnimationTool`
/// is export-only); the preview shows the watermark as a SwiftUI overlay
/// instead.
struct SpeedPaintReplayView: View {
    @Environment(AppCoordinator.self) private var coordinator

    /// Speed options, in display order — `fit12` leads because it's the
    /// default: it sizes content + the 3s final hold to 12s total, so the
    /// export never splits into multiple videos when shared to Instagram /
    /// TikTok.
    private enum SpeedChoice: String, CaseIterable, Identifiable {
        case fit12, x1, x2, x5, x10

        var id: String { rawValue }

        var label: String {
            switch self {
            case .fit12: return "12s"
            case .x1: return "1x"
            case .x2: return "2x"
            case .x5: return "5x"
            case .x10: return "10x"
            }
        }

        var composerSpeed: ReplaySpeed {
            switch self {
            case .fit12: return .fitTotal(seconds: 12)
            case .x1: return .multiplier(1)
            case .x2: return .multiplier(2)
            case .x5: return .multiplier(5)
            case .x10: return .multiplier(10)
            }
        }
    }

    @State private var layout: ReplayLayout = .vertical
    @State private var speed: SpeedChoice = .fit12
    @State private var watermark = true
    /// The flush/consolidate pass runs once per modal open, inside the first
    /// rebuild (behind the spinner) — never again while previews may be
    /// reading segment files.
    @State private var hasFlushed = false
    @State private var isComposing = false
    @State private var hasPreview = false
    @State private var isExporting = false
    @State private var exportedURL: URL?
    @State private var exportedKey: String?
    /// In-flight eager export (started as soon as settings settle, so a share
    /// tap usually finds the MP4 finished or mostly finished).
    @State private var exportTask: Task<URL?, Never>?
    @State private var exportTaskKey: String?
    @State private var shareItem: ReplayShareItem?
    @State private var statusMessage: String?

    @State private var player = AVPlayer()
    @State private var loopObserver: NSObjectProtocol?

    var body: some View {
        VStack(spacing: 16) {
            topBar
                .padding(.horizontal, 20)
                .padding(.top, 12)

            VStack(spacing: 16) {
                // The preview owns all the vertical space the controls below
                // don't need — the whole point of the dedicated page.
                preview

                HStack(spacing: 20) {
                    Picker("Layout", selection: $layout) {
                        ForEach(ReplayLayout.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 280)

                    Picker("Speed", selection: $speed) {
                        ForEach(SpeedChoice.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 340)

                    Toggle(isOn: $watermark) {
                        Label("“Drawn with Kiki” watermark", systemImage: "sparkles")
                    }
                    .fixedSize()
                }

                HStack(spacing: 12) {
                    Button {
                        shareToInstagram()
                    } label: {
                        Label("Share to Instagram", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        saveToPhotos()
                    } label: {
                        Label("Save to Photos", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        share()
                    } label: {
                        Label("Share…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .frame(maxWidth: 760)
                .disabled(!hasPreview || isComposing || isExporting)
                .overlay {
                    if isExporting {
                        ProgressView("Preparing video…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding([.horizontal, .bottom], 20)
        }
        .background(Color(.systemGroupedBackground))
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        .alert(
            "Speed paint replay",
            isPresented: Binding(get: { statusMessage != nil }, set: { if !$0 { statusMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(statusMessage ?? "")
        }
        .task(id: previewKey) { await rebuildPreview() }
        .task(id: exportKey) {
            // Eagerly encode for the current settings so the share tap is
            // instant (or nearly). The 600ms settle absorbs rapid control
            // flips; .task(id:) cancels the debounce on each change, and
            // startEagerExport cancels any stale in-flight encode.
            // MUST wait for the first-open flush/consolidation to finish —
            // consolidation deletes segment files, and an export building
            // concurrently reads them mid-delete (seen on device: -11800 on
            // a segment being consolidated).
            try? await Task.sleep(for: .milliseconds(600))
            while !hasFlushed, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard !Task.isCancelled else { return }
            startEagerExport()
        }
        .onDisappear {
            player.pause()
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            exportTask?.cancel()
        }
    }

    // MARK: - Top bar (matches AnimateView's)

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                coordinator.closeReplay()
            } label: {
                Label("Back", systemImage: "chevron.left")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            Spacer()

            Text("Speed paint replay")
                .font(.title3.weight(.semibold))

            Spacer()

            // Balances the Back button so the title stays centered.
            Label("Back", systemImage: "chevron.left")
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .hidden()
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
            // NO clipShape / opacity on the player view: on iPadOS 26
            // hardware, a masked AVPlayerLayer is suspected of compositing
            // to nothing (frames delivered, geometry correct, screen gray).
            // Corner rounding can come back later via layer.cornerRadius.
            PlayerLayerView(player: player)
            if isComposing {
                ProgressView().controlSize(.large)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Preview-only stand-in for the burned watermark (which only
            // exists in exported files). Extra trailing inset in the story
            // layout mirrors the export's clearance for Instagram's corner UI.
            if watermark && hasPreview {
                watermarkBadge
                    .padding(.top, 10)
                    .padding(.trailing, layout == .vertical ? 34 : 12)
            }
        }
        .aspectRatio(layout.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var watermarkBadge: some View {
        HStack(spacing: 5) {
            (Text("Drawn with ")
                .foregroundColor(Color(red: 0.15, green: 0.17, blue: 0.24))
                + Text("Kiki")
                .foregroundColor(Color(hue: 0.75, saturation: 0.85, brightness: 0.92)))
                .font(.system(size: 13, weight: .bold, design: .rounded))
            if let icon = UIImage(named: "kiki_mark") {
                Image(uiImage: icon)
                    .resizable()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .shadow(color: .white, radius: 2, y: 1)
        .opacity(0.9)
    }

    // MARK: - Preview composition (instant, no encode)

    private var previewKey: String { "\(layout.rawValue)-\(speed.rawValue)" }

    private func rebuildPreview() async {
        isComposing = true
        defer { isComposing = false }
        if !hasFlushed {
            await coordinator.flushRecording(consolidate: true)
            hasFlushed = true
        }
        guard let built = await coordinator.buildReplayComposition(layout: layout, speed: speed.composerSpeed) else {
            // Only alert if we never managed to compose anything — a re-compose
            // failure (layout/speed change) keeps showing the previous video.
            if !hasPreview {
                statusMessage = "Couldn't build the replay — no recorded footage was found for this drawing."
            }
            return
        }
        let item = AVPlayerItem(asset: built.composition)
        item.videoComposition = built.videoComposition
        // Fresh player per item: reusing one AVPlayer across item swaps is
        // the one factor common to every black-preview incarnation (both the
        // old VideoPlayer file path and the composition path), and stale-
        // player reuse with videoCompositions is a known wedge. External
        // playback off so frames can't silently route to another screen.
        player.pause()
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.allowsExternalPlayback = false
        newPlayer.actionAtItemEnd = .none
        player = newPlayer
        installLoopObserver()
        player.play()
        hasPreview = true
        watchItemStatus(item)
    }

    /// Surface player-item load failures instead of a silent black player —
    /// a composition that builds fine can still fail to PLAY (decoder
    /// limits, strict videoComposition validation on device, unreadable
    /// source files). The error is shown, logged, and shipped to Sentry.
    private func watchItemStatus(_ item: AVPlayerItem) {
        Task { @MainActor in
            for _ in 0..<50 where item.status == .unknown {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard item === player.currentItem else { return }  // superseded
            switch item.status {
            case .failed:
                let detail = item.error.map(String.init(describing:)) ?? "unknown"
                statusMessage = "Preview failed to load: \(item.error?.localizedDescription ?? "unknown error")"
                Analytics.track(.replayPreviewFailed, properties: ["status": "failed", "error": detail])
                Log.error("replay.preview_item_failed", attributes: [
                    "event": "replay.preview_item_failed",
                    "error": detail,
                ])
                SentrySDK.capture(message: "replay.preview_item_failed") { scope in
                    scope.setExtra(value: detail, key: "error")
                }
            case .unknown:
                Analytics.track(.replayPreviewFailed, properties: ["status": "stuck"])
                Log.error("replay.preview_item_stuck", attributes: [
                    "event": "replay.preview_item_stuck",
                ])
                SentrySDK.capture(message: "replay.preview_item_stuck")
            default:
                break
            }
        }
    }

    /// (Re)install the end-of-item loop. Called after each player swap so the
    /// closure's `player` read (through @State storage) matches the live one.
    private func installLoopObserver() {
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        loopObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { note in
            // object: nil because the item is replaced on every recompose;
            // filter here so other players' end events don't seek our replay.
            guard let item = note.object as? AVPlayerItem, item === player.currentItem else { return }
            player.seek(to: .zero)
            player.play()
        }
    }

    // MARK: - Sharing (export on demand — this is where the encode happens)

    private var exportKey: String { "\(layout.rawValue)-\(speed.rawValue)-\(watermark)" }

    /// Kick off (or keep) a background encode for the current settings.
    /// Cancels a stale in-flight encode first — `export` supports real
    /// cancellation, so abandoned settings don't burn the encoder.
    private func startEagerExport() {
        let key = exportKey
        if exportedKey == key, exportedURL != nil { return }   // already cached
        if exportTaskKey == key, exportTask != nil { return }  // already encoding
        exportTask?.cancel()
        exportTaskKey = key
        exportTask = Task { @MainActor in
            let url = await coordinator.composeReplay(layout: layout, speed: speed.composerSpeed, watermark: watermark)
            if let url, !Task.isCancelled {
                exportedURL = url
                exportedKey = key
            } else if !Task.isCancelled, exportTaskKey == key {
                // Failed (not superseded) — clear so a share tap retries fresh.
                exportTaskKey = nil
                exportTask = nil
            }
            return url
        }
    }

    /// Run `action` with an exported MP4 for the current settings: cached →
    /// instant; eager encode in flight → await it; otherwise encode now. The
    /// encode is the slow part (seconds for long recordings), so it never
    /// happens for the preview.
    private func withExportedReplay(target: String, _ action: @escaping @MainActor (URL) -> Void) {
        track(target: target)
        Task { @MainActor in
            let key = exportKey
            if let exportedURL, exportedKey == key {
                action(exportedURL)
                return
            }
            isExporting = true
            defer { isExporting = false }
            let url: URL?
            if exportTaskKey == key, let task = exportTask {
                url = await task.value
            } else {
                exportTask?.cancel()
                url = await coordinator.composeReplay(layout: layout, speed: speed.composerSpeed, watermark: watermark)
            }
            guard let url else {
                statusMessage = "Couldn't export the replay — try again."
                return
            }
            exportedURL = url
            exportedKey = key
            action(url)
        }
    }

    private func shareToInstagram() {
        withExportedReplay(target: "instagram_stories") { url in
            InstagramStories.share(videoURL: url) { success in
                if !success {
                    statusMessage = "Couldn't open Instagram — make sure the app is installed."
                }
            }
        }
    }

    private func saveToPhotos() {
        withExportedReplay(target: "photos") { url in
            Task {
                let saved = await PhotoLibrarySaver.saveVideo(url)
                statusMessage = saved
                    ? "Saved to Photos."
                    : "Couldn't save — check photo access in Settings."
            }
        }
    }

    private func share() {
        withExportedReplay(target: "share_sheet") { url in
            shareItem = ReplayShareItem(url: url)
        }
    }

    private func track(target: String) {
        Analytics.track(.videoShared, properties: [
            "format": "mp4",
            "layout": layout.rawValue,
            "speed": speed.label,
            "target": target,
        ])
    }
}

/// Identifiable wrapper so `.sheet(item:)` re-presents on URL change.
private struct ReplayShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Bare `AVPlayerLayer` preview. SwiftUI's `VideoPlayer` rendered black in
/// this modal even with the item at `.readyToPlay` (telemetry: item status
/// "ready" + black screen, while the export of the same composition played
/// fine elsewhere). The plain layer displays the same player correctly, and
/// the autoplay loop needs no playback controls anyway.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}

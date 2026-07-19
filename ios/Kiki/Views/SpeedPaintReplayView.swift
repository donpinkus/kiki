import AVKit
import Sentry
import SwiftUI

/// Modal that previews the speed-paint replay in an autoplaying, looping player
/// and lets the user pick a layout (side-by-side / stacked) and speed
/// (1x / 2x / 5x / fit-to-12s) before sharing. The preview plays the stitched
/// composition directly — no encode pass — so it appears near-instantly and
/// re-composes live when layout or speed changes. The MP4 is only encoded when
/// a share action is tapped, which is also when the watermark is burned
/// (`AVVideoCompositionCoreAnimationTool` is export-only); the preview shows
/// the watermark as a SwiftUI overlay instead.
struct SpeedPaintReplayView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    /// Speed options. `fit12` sizes content + the 3s final hold to 12s total,
    /// so the export never splits into multiple videos when shared to
    /// Instagram / TikTok.
    private enum SpeedChoice: String, CaseIterable, Identifiable {
        case x1, x2, x5, fit12

        var id: String { rawValue }

        var label: String {
            switch self {
            case .x1: return "1x"
            case .x2: return "2x"
            case .x5: return "5x"
            case .fit12: return "12s"
            }
        }

        var composerSpeed: ReplaySpeed {
            switch self {
            case .x1: return .multiplier(1)
            case .x2: return .multiplier(2)
            case .x5: return .multiplier(5)
            case .fit12: return .fitTotal(seconds: 12)
            }
        }
    }

    @State private var layout: ReplayLayout = .vertical
    @State private var speed: SpeedChoice = .fit12
    /// End the replay with the drawing's generated animation instead of the
    /// 3s freeze frame (only offered when an animation exists).
    @State private var animationTail = true
    @State private var watermark = true
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
    /// Mirrors AVPlayerLayer.isReadyForDisplay (via KVO in PlayerLayerView) —
    /// the definitive "is the screen actually getting frames" signal.
    @State private var layerReadyForDisplay = false
    /// On-screen playback probe (temporary debug — black-preview hunt).
    /// Rendered over the preview so diagnosis needs no log channel at all.
    @State private var probeText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                preview

                Picker("Layout", selection: $layout) {
                    ForEach(ReplayLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Speed", selection: $speed) {
                    ForEach(SpeedChoice.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Toggle(isOn: $watermark) {
                    Label("“Drawn with Kiki” watermark", systemImage: "sparkles")
                }

                if coordinator.generatedAnimationURL != nil {
                    Toggle(isOn: $animationTail) {
                        Label("End with the animation", systemImage: "film")
                    }
                }

                VStack(spacing: 12) {
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
                .disabled(!hasPreview || isComposing || isExporting)
                .overlay {
                    if isExporting {
                        ProgressView("Preparing video…")
                            .padding()
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .padding()
            .navigationTitle("Speed paint replay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
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
        }
        .task(id: previewKey) { await rebuildPreview() }
        .task(id: exportKey) {
            // Eagerly encode for the current settings so the share tap is
            // instant (or nearly). The 600ms settle absorbs rapid control
            // flips; .task(id:) cancels the debounce on each change, and
            // startEagerExport cancels any stale in-flight encode.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            startEagerExport()
        }
        .onDisappear {
            player.pause()
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
            exportTask?.cancel()
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.secondarySystemBackground))
            PlayerLayerView(player: player, onReadyForDisplay: { ready in
                guard ready != layerReadyForDisplay else { return }
                layerReadyForDisplay = ready
                Analytics.track(.replayPreviewFailed, properties: [
                    "status": "layer_display",
                    "ready_for_display": ready,
                ])
            })
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .opacity(isComposing ? 0.4 : 1)
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
        .overlay(alignment: .bottomLeading) {
            if !probeText.isEmpty {
                Text(probeText)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 6))
                    .padding(8)
            }
        }
        .aspectRatio(layout.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            while !Task.isCancelled {
                updateProbeText()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// status: unk/rdy/fail · r: rate · t: current/duration · sz: presentation
    /// size · disp: layer has frames · tc: paused0/waiting1/playing2 · err.
    private func updateProbeText() {
        guard let item = player.currentItem else {
            probeText = "no item"
            return
        }
        let statusName = ["unk", "rdy", "fail"][item.status.rawValue]
        let time = String(format: "%.2f", item.currentTime().seconds)
        let duration = String(format: "%.1f", item.duration.seconds)
        let rate = String(format: "%.2f", player.rate)
        let size = "\(Int(item.presentationSize.width))x\(Int(item.presentationSize.height))"
        let err = item.error != nil ? " ERR:\(item.error!.localizedDescription)" : ""
        probeText = "it=\(statusName) r=\(rate) t=\(time)/\(duration) sz=\(size) disp=\(layerReadyForDisplay ? "Y" : "N") tc=\(player.timeControlStatus.rawValue)\(err)"
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
        guard let built = await coordinator.buildReplayComposition(layout: layout, speed: speed.composerSpeed, animationTail: animationTail) else {
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
                Analytics.track(.replayPreviewFailed, properties: ["status": "ready"])
                Log.info("replay.preview_item_ready", attributes: [
                    "event": "replay.preview_item_ready",
                ])
                // Deep probe 2s in: the item said ready but the screen may
                // still be empty — capture everything that distinguishes
                // "playing but not displayed" from "not playing at all".
                try? await Task.sleep(for: .seconds(2))
                guard item === player.currentItem else { return }
                let t1 = item.currentTime().seconds
                try? await Task.sleep(for: .milliseconds(600))
                guard item === player.currentItem else { return }
                let probe: [String: Any] = [
                    "status": "probe",
                    "rate": player.rate,
                    "time_control": player.timeControlStatus.rawValue,
                    "waiting_reason": player.reasonForWaitingToPlay?.rawValue ?? "none",
                    "time_before_s": t1,
                    "time_after_s": item.currentTime().seconds,
                    "presentation_w": Double(item.presentationSize.width),
                    "presentation_h": Double(item.presentationSize.height),
                    "external_playback": player.isExternalPlaybackActive,
                    "layer_ready_for_display": layerReadyForDisplay,
                    "error_log_events": item.errorLog()?.events.count ?? 0,
                ]
                Analytics.track(.replayPreviewFailed, properties: probe)
                Log.info("replay.preview_probe", attributes: probe.merging(["event": "replay.preview_probe"]) { a, _ in a })
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
            let url = await coordinator.composeReplay(layout: layout, speed: speed.composerSpeed, watermark: watermark, animationTail: animationTail)
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
                url = await coordinator.composeReplay(layout: layout, speed: speed.composerSpeed, watermark: watermark, animationTail: animationTail)
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
    var onReadyForDisplay: ((Bool) -> Void)?

    final class LayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
        var observation: NSKeyValueObservation?
        var onReady: ((Bool) -> Void)?
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        view.onReady = onReadyForDisplay
        view.observation = view.playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak view] layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async { view?.onReady?(ready) }
        }
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
        view.onReady = onReadyForDisplay
    }
}

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
        .onAppear { startLooping() }
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
            VideoPlayer(player: player)
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
        player.replaceCurrentItem(with: item)
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
                Log.error("replay.preview_item_failed", attributes: [
                    "event": "replay.preview_item_failed",
                    "error": detail,
                ])
                SentrySDK.capture(message: "replay.preview_item_failed") { scope in
                    scope.setExtra(value: detail, key: "error")
                }
            case .unknown:
                Log.error("replay.preview_item_stuck", attributes: [
                    "event": "replay.preview_item_stuck",
                ])
                SentrySDK.capture(message: "replay.preview_item_stuck")
            default:
                Log.info("replay.preview_item_ready", attributes: [
                    "event": "replay.preview_item_ready",
                ])
            }
        }
    }

    private func startLooping() {
        player.actionAtItemEnd = .none
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

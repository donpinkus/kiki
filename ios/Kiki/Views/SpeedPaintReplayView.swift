import AVKit
import SwiftUI

/// Modal that previews the speed-paint replay in an autoplaying, looping player
/// and lets the user pick a layout (side-by-side / stacked) and playback speed
/// (1x / 2x / 5x) before sharing. The preview re-composes whenever the layout or
/// speed changes.
struct SpeedPaintReplayView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var layout: ReplayLayout = .vertical
    @State private var speed: Double = 2
    @State private var watermark = true
    @State private var composedURL: URL?
    @State private var isComposing = false
    @State private var shareItem: ReplayShareItem?
    @State private var statusMessage: String?

    @State private var player = AVPlayer()
    @State private var loopObserver: NSObjectProtocol?

    private let speeds: [Double] = [1, 2, 5]

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                preview

                Picker("Layout", selection: $layout) {
                    ForEach(ReplayLayout.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)

                Picker("Speed", selection: $speed) {
                    ForEach(speeds, id: \.self) { Text("\(Int($0))x").tag($0) }
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
                .disabled(composedURL == nil || isComposing)
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
        .task(id: composeKey) { await recompose() }
        .onAppear { startLooping() }
        .onDisappear {
            player.pause()
            if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
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
        .aspectRatio(layout.aspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var composeKey: String { "\(layout.rawValue)-\(Int(speed))-\(watermark)" }

    private func recompose() async {
        isComposing = true
        defer { isComposing = false }
        guard let url = await coordinator.composeReplay(layout: layout, speed: speed, watermark: watermark) else {
            // Only alert if we never managed to compose anything — a re-compose
            // failure (layout/speed change) keeps showing the previous video.
            if composedURL == nil {
                statusMessage = "Couldn't build the replay — no recorded footage was found for this drawing."
            }
            return
        }
        composedURL = url
        // A freshly replaced item starts at zero; just play.
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
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

    private func shareToInstagram() {
        guard let url = composedURL else { return }
        track(target: "instagram_stories")
        InstagramStories.share(videoURL: url) { success in
            if !success {
                statusMessage = "Couldn't open Instagram — make sure the app is installed."
            }
        }
    }

    private func saveToPhotos() {
        guard let url = composedURL else { return }
        Task {
            let saved = await PhotoLibrarySaver.saveVideo(url)
            track(target: "photos")
            statusMessage = saved
                ? "Saved to Photos."
                : "Couldn't save — check photo access in Settings."
        }
    }

    private func share() {
        guard let url = composedURL else { return }
        track(target: "share_sheet")
        shareItem = ReplayShareItem(url: url)
    }

    private func track(target: String) {
        Analytics.track(.videoShared, properties: [
            "format": "mp4",
            "layout": layout.rawValue,
            "speed": Int(speed),
            "target": target,
        ])
    }
}

/// Identifiable wrapper so `.sheet(item:)` re-presents on URL change.
private struct ReplayShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

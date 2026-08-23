import SwiftUI
import NetworkModule
import CanvasModule
import ExportModule

struct DrawingTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showSettings = false
    @State private var showColorPicker = false
    @State private var shareItem: ShareItem?

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            // MARK: Left — Settings, Gallery
            Button {
                showSettings = true
            } label: {
                chromeIcon("gearshape")
            }
            .tint(KikiTheme.icon)
            .popover(isPresented: $showSettings) {
                SettingsPanel()
                    .frame(width: 400, height: 600)
            }

            Button {
                coordinator.navigateToGallery()
            } label: {
                Text("Gallery")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KikiTheme.icon)
            }
            .tint(KikiTheme.icon)

            // Share — exports the current generated result. The native iOS
            // share sheet (presented below) provides Save to Files + the app
            // carousel. The "Share image" section makes "Share video" an
            // additive sibling later.
            Menu {
                Section("Share image") {
                    ForEach(ExportFormat.imageFormats) { format in
                        Button(format.displayName) {
                            if let url = coordinator.makeShareFile(format) {
                                shareItem = ShareItem(url: url)
                            }
                        }
                    }
                    if let animationURL = coordinator.generatedAnimationURL {
                        Button("Animation (MP4)") {
                            shareItem = ShareItem(url: animationURL)
                        }
                    }
                    // Cut the active selection as a transparent-PNG sticker.
                    if coordinator.canShareSticker {
                        Button {
                            if let url = coordinator.makeStickerFile() {
                                shareItem = ShareItem(url: url)
                            }
                        } label: {
                            Label("Sticker (PNG)", systemImage: "scissors")
                        }
                    }
                }
                if coordinator.canShareVideo {
                    Section("Share video") {
                        // TEMP A/B (gray-preview hunt round 2): both
                        // presentations of the same replay view, so device
                        // behavior can be compared live.
                        Button("Speed paint replay (page)") {
                            coordinator.openReplayFromDrawing()
                        }
                        Button("Speed paint replay (modal)") {
                            coordinator.showReplayModal = true
                        }
                    }
                }
            } label: {
                Text("Share")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KikiTheme.icon)
            }
            .tint(KikiTheme.icon)
            .disabled(!(coordinator.canShare || coordinator.canShareVideo || coordinator.canShareSticker))

            UsageMeterView()

            KikiAIStatusBadge()

            Spacer()

            // MARK: Center — Style, Prompt
            if coordinator.drawingLayout != .splitScreen {
                Button {
                    coordinator.showStylePicker = true
                } label: {
                    Text(coordinator.selectedStyle.name)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                TextField("Describe what you want…", text: $coordinator.promptText)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .foregroundStyle(KikiTheme.icon)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(KikiTheme.buttonCircle, in: Capsule())
                    .frame(minWidth: 120, maxWidth: 400)
            }

            Spacer()

            // MARK: Right — Pen, Eraser, Lasso, Reset Transform, Layers
            toolButton(icon: "pencil.tip", tool: .brush)
            toolButton(icon: "eraser", tool: .eraser)
            // Lasso publishes its on-screen frame so DrawingView can float the
            // "Clear Lasso" button directly beneath it (clearly associated).
            // The unified Select tool (SAM taps + freehand loops). Publishes
            // its frame so DrawingView can hang the selection panel beneath it.
            toolButton(icon: "wand.and.stars", tool: .select)
                .anchorPreference(key: SelectButtonAnchorKey.self, value: .bounds) { $0 }

            // Object library: reusable cutouts saved from selections; tap a
            // tile to drop it into this drawing as a movable float.
            Button {
                coordinator.objectsDrawerBadge = 0
                coordinator.showObjectsDrawer.toggle()
            } label: {
                chromeIcon("shippingbox")
                    .overlay(alignment: .topTrailing) {
                        // Background 3D lifts that finished since last open.
                        if coordinator.objectsDrawerBadge > 0 {
                            Text("\(coordinator.objectsDrawerBadge)")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Color.red, in: Capsule())
                                .offset(x: 8, y: -6)
                        }
                    }
            }
            .popover(isPresented: $coordinator.showObjectsDrawer) {
                ObjectsDrawer()
                    .frame(width: 360, height: 420)
            }

            // AI Edit (inpaint): edits the active selection if one exists,
            // else the whole drawing. Highlighted while a preview is live.
            Button {
                coordinator.showAIEditSheet = true
            } label: {
                chromeIcon(
                    "sparkles",
                    color: coordinator.aiEditPhase != .idle ? Color.accentColor : KikiTheme.icon
                )
            }

            Button {
                coordinator.showLayerPanel.toggle()
            } label: {
                chromeIcon("square.on.square")
            }
            .popover(isPresented: $coordinator.showLayerPanel) {
                // LayerPanelView sizes itself: grows with the layer count,
                // caps near screen height (then its ScrollView scrolls).
                LayerPanelView()
            }

            colorSwatch
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(KikiTheme.barBackground)
        // Procreate-style chrome is always dark; forcing dark resolves
        // .primary/.secondary in bar content AND presented popovers to light-
        // on-dark, matching the reference's dark panels.
        .environment(\.colorScheme, .dark)
        .sheet(item: $shareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
        // TEMP A/B (gray-preview hunt round 2). A .sheet, NOT
        // .fullScreenCover: video layers never composite inside this app's
        // fullScreenCover on iPadOS 26 hardware.
        .sheet(isPresented: $coordinator.showReplayModal) {
            SpeedPaintReplayView(presentation: .modal)
                .environment(coordinator)
        }
    }

    // MARK: - Color swatch

    private var colorSwatch: some View {
        @Bindable var coordinator = coordinator
        let isDark = coordinator.currentColor.isDark

        return Button {
            showColorPicker.toggle()
        } label: {
            Circle()
                .fill(coordinator.currentColor)
                .frame(width: 28, height: 28)
                .overlay {
                    if isDark {
                        // Thin black inner ring (fake inner shadow) — stroke inset
                        // so half the line sits inside the fill, blurred for softness.
                        Circle()
                            .inset(by: 1)
                            .stroke(Color.black.opacity(0.5), lineWidth: 1.25)
                            .blur(radius: 0.75)
                            .mask(Circle())
                        // White outer outline for contrast against bar background.
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 1.5)
                    } else {
                        Circle()
                            .strokeBorder(Color.primary.opacity(0.3), lineWidth: 1.5)
                    }
                }
        }
        .popover(isPresented: $showColorPicker) {
            DiskColorPicker(color: $coordinator.currentColor)
        }
        // Simulator dev automation: the UI bridge can't tap the swatch, so it
        // raises this coordinator flag instead (mirrors devShowStatusDetails).
        .onChange(of: coordinator.devShowColorPicker) { _, requested in
            if requested {
                showColorPicker = true
                coordinator.devShowColorPicker = false
            }
        }
        .frame(width: 36, height: 36)
    }

    // MARK: - Helpers

    /// Procreate-style chrome button: gray icon in a dark circle.
    private func chromeIcon(_ icon: String, color: Color = KikiTheme.icon) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(color)
            .frame(width: KikiTheme.buttonDiameter, height: KikiTheme.buttonDiameter)
            .background(Circle().fill(KikiTheme.buttonCircle))
    }

    private func toolButton(icon: String, tool: DrawingTool) -> some View {
        Button {
            coordinator.currentTool = tool
        } label: {
            chromeIcon(icon, color: coordinator.currentTool == tool ? Color.accentColor : KikiTheme.icon)
        }
    }

}

/// Identifiable wrapper so `.sheet(item:)` re-presents when the exported file
/// changes (e.g. user picks a different format).
private struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// Reports the Select tool button's on-screen bounds up the view tree so
/// `DrawingView` can anchor the selection panel beneath it.
struct SelectButtonAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

private extension Color {
    // Perceived-luminance check (Rec. 601 weights). Used to decide whether a
    // color swatch needs a high-contrast (white + inner-dark) border.
    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.55
    }
}

// MARK: - Kiki's AI status badge

/// Ambient H100 status: a dot + "Kiki's AI" label. Green = ready (sketch
/// magic available), pink = warming up, red = provisioning error, gray =
/// off/unknown. Tapping opens a popover with the honest details (elapsed
/// warm-up time + ETA, or the provisioning error) and a wake-up action.
/// Post-launch this may go away if a warm pool makes readiness permanent.
struct KikiAIStatusBadge: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showDetails = false

    /// Softer than .pink, which reads as red against the dark chrome.
    static let warmPink = Color(red: 1.0, green: 0.71, blue: 0.82)

    private var dotColor: Color {
        if coordinator.isStreamIdlePaused { return .gray }
        // The WS push reaches every user; the polled state (test accounts
        // only — the REST endpoint 403s otherwise) refines it when present.
        if let pushed = coordinator.imageAvailability, coordinator.lambdaPoolState == nil {
            switch pushed {
            case .ready: return .green
            case .warming: return Self.warmPink
            case .off: return Self.warmPink // asleep — same soft state as "none"
            }
        }
        switch coordinator.lambdaPoolState?.status {
        case "ready": return .green
        case "launching", "booting", "none": return Self.warmPink
        case "error": return .red
        default: return .gray
        }
    }

    private var label: String {
        if coordinator.isStreamIdlePaused { return "Kiki's AI · resting" }
        switch coordinator.lambdaPoolState?.status {
        case "ready": return "Kiki's AI"
        case "launching", "booting": return "Kiki's AI · warming up"
        case "none": return "Kiki's AI · asleep"
        case "error": return "Kiki's AI · error"
        default: return "Kiki's AI"
        }
    }

    /// Second dot: the VIDEO system. Hidden entirely while the feature flag
    /// is off (availability == .off) so the badge is unchanged for
    /// image-only operation.
    private var videoDotColor: Color? {
        if coordinator.isStreamIdlePaused { return nil }
        switch coordinator.videoAvailability {
        case .off: return nil
        case .warming: return Self.warmPink
        case .ready: return .green
        }
    }

    var body: some View {
        Button {
            showDetails = true
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 7, height: 7)
                if let videoDot = videoDotColor {
                    Circle()
                        .fill(videoDot)
                        .frame(width: 7, height: 7)
                        .overlay(
                            // Tiny ▶ glyph differentiates the video dot at a glance.
                            Image(systemName: "play.fill")
                                .font(.system(size: 4))
                                .foregroundStyle(.black.opacity(0.55))
                        )
                }
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(KikiTheme.icon)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(KikiTheme.buttonCircle, in: Capsule())
        }
        .popover(isPresented: $showDetails) {
            KikiAIStatusDetails()
                .frame(width: 300)
                .padding()
        }
        // Simulator dev automation: the DevAutomation UI bridge can't tap the
        // badge, so it raises this coordinator flag instead.
        .onChange(of: coordinator.devShowStatusDetails) { _, requested in
            if requested {
                showDetails = true
                coordinator.devShowStatusDetails = false
            }
        }
    }
}

private struct KikiAIStatusDetails: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        // 1s tick so elapsed counts and progress bars advance live while
        // the popover is open. The tick's date is passed INTO the stage rows
        // — without a changing input, SwiftUI skips re-rendering the child
        // and the countdown freezes at its first value (shipped bug,
        // caught 2026-07-19).
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 10) {
                // ── IMAGE system ─────────────────────────────────────────
                Text("Kiki's image AI")
                    .font(.headline)
                if coordinator.isStreamIdlePaused {
                    Text("Resting — no activity for a while, so the connection is paused. Draw anything to wake it back up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                SystemStageView(
                    status: coordinator.imageSystemStatus,
                    now: context.date,
                    readyText: "Ready — sketch magic is available.",
                    offText: "Asleep — powered down after 30 quiet minutes."
                )
                // Test-account extras from the detailed REST poll (the push
                // is intentionally minimal for everyone else).
                if coordinator.lambdaPoolState?.status == "error" {
                    if let err = coordinator.lambdaPoolState?.lastError {
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Try again") { coordinator.ensureLambdaPool() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if coordinator.imageSystemStatus?.availability == "off",
                          coordinator.lambdaPoolState != nil {
                    Button("Wake up") { coordinator.ensureLambdaPool() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                Text("Powers the Edit button — turning generated images back into editable sketches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // ── VIDEO system (hidden entirely when the feature is off) ─
                if coordinator.videoAvailability != .off {
                    Divider()
                    Text("Kiki's video AI")
                        .font(.headline)
                    SystemStageView(
                        status: coordinator.videoSystemStatus,
                        now: context.date,
                        readyText: "Ready — animations are available.",
                        offText: "Asleep."
                    )
                    Text("Powers the Animate page — tap Animate on a drawing or in the gallery.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }
}

/// One H100 system's stage line: green check when ready; while warming, the
/// stage decides the surface — capacity search is UNPREDICTABLE (minutes to
/// hours, so: indeterminate spinner + elapsed, never an ETA), while booting
/// is consistent (measured p50 ~4-5.5 min, so: a determinate progress bar,
/// capped at 95% until the backend actually reports ready).
private struct SystemStageView: View {
    let status: StreamWebSocketClient.SystemStatus?
    /// The TimelineView tick. MUST flow in as an input: it's what makes
    /// SwiftUI re-render this row each second — computing Date() internally
    /// leaves the inputs unchanged between ticks, so SwiftUI skips the child
    /// and every countdown freezes.
    let now: Date
    let readyText: String
    let offText: String

    var body: some View {
        switch status?.availability {
        case "ready":
            Label(readyText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case "warming":
            warmingBody
        case "off":
            Label(offText, systemImage: "moon.zzz")
                .foregroundStyle(KikiAIStatusBadge.warmPink)
        default:
            Text("Status unknown — start drawing to wake Kiki's AI.")
                .foregroundStyle(.secondary)
        }
    }

    private var elapsedSeconds: Int? {
        status?.stageStartedAtMs.map { max(0, Int(now.timeIntervalSince1970 - $0 / 1000)) }
    }

    @ViewBuilder
    private var warmingBody: some View {
        switch status?.stage {
        case "searching":
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding a GPU…\(elapsedSeconds.map { " \($0)s" } ?? "")")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case "booting":
            VStack(alignment: .leading, spacing: 4) {
                let estimate = max(status?.bootEstimateSeconds ?? 300, 1)
                let elapsed = elapsedSeconds ?? 0
                ProgressView(value: min(0.95, Double(elapsed) / Double(estimate)))
                    .tint(KikiAIStatusBadge.warmPink)
                HStack {
                    Label("Warming up", systemImage: "flame")
                        .foregroundStyle(KikiAIStatusBadge.warmPink)
                    Spacer()
                    if elapsed < estimate {
                        Text("~\(estimate - elapsed)s left")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("almost there…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        default: // 'waking': interest registered, GPU search starts momentarily
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waking up — about to start looking for a GPU…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}


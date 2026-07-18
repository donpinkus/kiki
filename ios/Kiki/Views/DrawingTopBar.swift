import SwiftUI
import CanvasModule
import ExportModule

struct DrawingTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showSettings = false
    @State private var showColorPicker = false
    @State private var shareItem: ShareItem?
    @State private var showReplay = false

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
                }
                if coordinator.canShareVideo {
                    Section("Share video") {
                        Button("Speed paint replay") {
                            Task { @MainActor in
                                await coordinator.flushRecording()
                                showReplay = true
                            }
                        }
                    }
                }
            } label: {
                Text("Share")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(KikiTheme.icon)
            }
            .tint(KikiTheme.icon)
            .disabled(!(coordinator.canShare || coordinator.canShareVideo))

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
            toolButton(icon: "lasso", tool: .lasso)

            if coordinator.canvasViewModel.hasLassoSelection {
                Button {
                    coordinator.canvasViewModel.clearLasso()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
            }

            Button {
                coordinator.showLayerPanel.toggle()
            } label: {
                chromeIcon("square.on.square")
            }
            .popover(isPresented: $coordinator.showLayerPanel) {
                LayerPanelView()
                    .frame(width: 260, height: 400)
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
        .fullScreenCover(isPresented: $showReplay) {
            SpeedPaintReplayView()
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
        switch coordinator.lambdaPoolState?.status {
        case "ready": return .green
        case "launching", "booting", "none": return Self.warmPink
        case "error": return .red
        default: return .gray
        }
    }

    private var label: String {
        switch coordinator.lambdaPoolState?.status {
        case "ready": return "Kiki's AI"
        case "launching", "booting": return "Kiki's AI · warming up"
        case "none": return "Kiki's AI · asleep"
        case "error": return "Kiki's AI · error"
        default: return "Kiki's AI"
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
    }
}

private struct KikiAIStatusDetails: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        // 1s tick so "elapsed" counts up live while the popover is open.
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(alignment: .leading, spacing: 10) {
                Text("Kiki's AI")
                    .font(.headline)

                switch coordinator.lambdaPoolState?.status {
                case "ready":
                    Label("Ready — sketch magic is available.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case "launching":
                    Label("Finding a GPU…", systemImage: "hourglass")
                        .foregroundStyle(KikiAIStatusBadge.warmPink)
                    warmingDetail
                case "booting":
                    Label("Warming up…", systemImage: "flame")
                        .foregroundStyle(KikiAIStatusBadge.warmPink)
                    warmingDetail
                case "none":
                    Label("Asleep — powered down after 30 quiet minutes.", systemImage: "moon.zzz")
                        .foregroundStyle(KikiAIStatusBadge.warmPink)
                    Button("Wake up") { coordinator.ensureLambdaPool() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                case "error":
                    Label("Error fetching Kiki's AI", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    if let err = coordinator.lambdaPoolState?.lastError {
                        Text(err)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Button("Try again") { coordinator.ensureLambdaPool() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                default:
                    Text("Status unknown — Kiki's AI may be asleep.")
                        .foregroundStyle(.secondary)
                    Button("Wake up") { coordinator.ensureLambdaPool() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                Text("Powers the Edit button — turning generated images back into editable sketches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline)
        }
    }

    @ViewBuilder
    private var warmingDetail: some View {
        let elapsed: Int? = coordinator.lambdaPoolState?.launchedAtMs.map {
            max(0, Int(Date().timeIntervalSince1970 - $0 / 1000))
        }
        HStack(spacing: 12) {
            if let elapsed {
                Text("\(elapsed)s elapsed")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let eta = coordinator.lambdaPoolState?.etaSeconds {
                Text("~\(eta)s remaining")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }
}

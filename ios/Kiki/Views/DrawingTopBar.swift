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

            if !coordinator.canvasViewModel.isDefaultTransform {
                actionButton(
                    icon: "arrow.counterclockwise",
                    action: coordinator.canvasViewModel.resetViewTransform,
                    disabled: false
                )
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

    private func actionButton(icon: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button {
            action()
        } label: {
            chromeIcon(icon, color: disabled ? KikiTheme.iconDim : KikiTheme.icon)
        }
        .disabled(disabled)
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

import SwiftUI
import CanvasModule

struct DrawingTopBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showSettings = false
    @State private var showColorPicker = false

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(spacing: 12) {
            // MARK: Left — Settings, Gallery
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
            }
            .tint(Color.primary)
            .popover(isPresented: $showSettings) {
                SettingsPanel()
                    .frame(width: 400, height: 600)
            }

            Button {
                coordinator.navigateToGallery()
            } label: {
                Text("Gallery")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.primary)
            }
            .tint(Color.primary)

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
                Image(systemName: "square.on.square")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
            }
            .popover(isPresented: $coordinator.showLayerPanel) {
                LayerPanelView()
                    .frame(width: 260, height: 400)
            }

            colorSwatch
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
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

    private func toolButton(icon: String, tool: DrawingTool) -> some View {
        Button {
            coordinator.currentTool = tool
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(coordinator.currentTool == tool ? Color.accentColor : .primary)
                .frame(width: 36, height: 36)
        }
    }

    private func actionButton(icon: String, action: @escaping () -> Void, disabled: Bool) -> some View {
        Button {
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(disabled ? .tertiary : .primary)
                .frame(width: 36, height: 36)
        }
        .disabled(disabled)
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

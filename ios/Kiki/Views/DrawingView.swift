import SwiftUI
import SwiftData
import CanvasModule
import ResultModule

struct DrawingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var quickShapeTooltipDismissTask: Task<Void, Never>?
    /// Persistent flag — once the user has seen the QuickShape tooltip on
    /// any device session, never show it again on this device.
    @AppStorage("quickShape.tooltip.shown") private var hasSeenQuickShapeTooltip: Bool = false

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 0) {
            DrawingTopBar()

            if let error = coordinator.generationError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                    Text(error)
                        .font(.subheadline)
                        .lineLimit(2)
                    Spacer()
                    if coordinator.isOutOfDrawingTime {
                        Button("Subscribe") {
                            coordinator.showPaywall = true
                        }
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.borderedProminent)
                        .tint(.white)
                        .foregroundStyle(.red)
                    }
                    Button {
                        coordinator.generationError = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.red.opacity(0.85))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            GeometryReader { geometry in
                // The gesture container fills the full drawing pane so pan/zoom/
                // rotate aren't clipped by the drawing surface's square footprint.
                // The drawing surface itself stays a centered `canvasSide` square
                // inside the container (see RotatableCanvasContainer).
                let canvasPaneWidth = coordinator.drawingLayout == .splitScreen
                    ? geometry.size.width * coordinator.dividerPosition
                    : geometry.size.width
                // Largest square that fits the available pane (full width in
                // fullscreen, the left half in split screen) and the height
                // below the top toolbar — so the canvas fills the space instead
                // of sitting as a small centered square.
                let canvasSide = min(canvasPaneWidth, geometry.size.height)

                ZStack(alignment: .topLeading) {
                    CanvasView(
                        viewModel: coordinator.canvasViewModel,
                        drawingSurfaceSide: canvasSide,
                        externalTransformRegionProvider: { [weak coordinator] in
                            // Two-finger gestures over the floating panel's rect
                            // move/scale it instead of the canvas. nil = no panel
                            // (split screen, or no image yet) → canvas behaves normally.
                            guard let coordinator,
                                  coordinator.drawingLayout == .fullscreen,
                                  let image = coordinator.resultState.displayImage else { return nil }
                            return PanelLayout.rect(
                                for: image,
                                in: geometry.size,
                                offset: coordinator.panelOffset,
                                scale: coordinator.panelScale
                            )
                        },
                        onExternalTransform: { [weak coordinator] translationDelta, scaleDelta in
                            coordinator?.applyPanelTransform(
                                translationDelta: translationDelta,
                                scaleDelta: scaleDelta
                            )
                        },
                        onContactPointChanged: { [weak coordinator] paneContact, diameter in
                            // Drives the result-panel transparency hole. Immediate
                            // while drawing; animated fade-closed on lift (nil).
                            guard let coordinator else { return }
                            if let paneContact {
                                coordinator.updatePanelHole(
                                    paneContact: paneContact,
                                    diameter: diameter,
                                    paneSize: geometry.size
                                )
                            } else {
                                withAnimation(.easeOut(duration: 0.2)) {
                                    coordinator.panelHole.isActive = false
                                }
                            }
                        }
                    )
                        .frame(width: canvasPaneWidth, height: geometry.size.height)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: coordinator.drawingLayout == .splitScreen ? .trailing : .center
                        )
                        .ignoresSafeArea(.keyboard)
                        .zIndex(0)

                    CanvasSidebar()
                        .frame(maxHeight: .infinity, alignment: .leading)
                        .zIndex(3)

                    if coordinator.canvasViewModel.hasLassoSelection {
                        let topMargin = (geometry.size.height - canvasSide) / 2
                        Button {
                            coordinator.canvasViewModel.clearLasso()
                        } label: {
                            Label("Clear Lasso", systemImage: "xmark.circle.fill")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.secondary)
                        .controlSize(.small)
                        .frame(width: canvasSide, height: max(topMargin, 0), alignment: .center)
                        .frame(
                            maxWidth: .infinity,
                            alignment: coordinator.drawingLayout == .splitScreen ? .trailing : .center
                        )
                        .zIndex(10)
                    }

                    // QuickShape NUX tooltip — appears once per device, on the
                    // user's first successful snap. Auto-dismisses after 5s
                    // or on tap. AppStorage flag suppresses subsequent showings.
                    if coordinator.shouldShowQuickShapeTooltip && !hasSeenQuickShapeTooltip {
                        quickShapeTooltip
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 24)
                            .zIndex(11)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                            .onAppear {
                                quickShapeTooltipDismissTask?.cancel()
                                quickShapeTooltipDismissTask = Task {
                                    try? await Task.sleep(for: .seconds(5))
                                    guard !Task.isCancelled else { return }
                                    dismissQuickShapeTooltip()
                                }
                            }
                            .onTapGesture {
                                quickShapeTooltipDismissTask?.cancel()
                                dismissQuickShapeTooltip()
                            }
                    }

                    if coordinator.drawingLayout == .splitScreen {
                        splitScreenResultPane(geometry: geometry)
                            .zIndex(2)
                    } else if let image = coordinator.resultState.displayImage {
                        // Fullscreen: image-only floating preview, sized to the
                        // image's aspect ratio. Visual-only (allowsHitTesting
                        // false) — a single finger / pencil draws straight through
                        // it onto the canvas; two fingers over it move/scale it
                        // (handled by the canvas container, which drives
                        // panelOffset/panelScale). No buttons, no glass chrome.
                        FloatingResultPanel(
                            image: image,
                            baseSize: PanelLayout.baseSize(for: image, in: geometry.size)
                        )
                        .scaleEffect(coordinator.panelScale)
                        .offset(coordinator.panelOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(PanelLayout.edgeInset)
                        .allowsHitTesting(false)
                        .zIndex(2)
                    }
                }
                .background(Color(.systemGray6))
            }
            // Fill the bottom home-indicator safe-area inset so the (black) Metal
            // canvas reaches the physical bottom edge like it already does on the
            // top/left/right edges. Without this, the systemGray6 background bleeds
            // into the bottom inset while the canvas content stops above it, leaving
            // a ~24pt gray bar. Touch→texture mapping is unaffected: it's computed
            // from the centered canvas square's own bounds, not the pane height.
            .ignoresSafeArea(edges: .bottom)
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.generationError != nil)
        .animation(.easeOut(duration: 0.25), value: coordinator.shouldShowQuickShapeTooltip)
        .ignoresSafeArea(.keyboard)
        .onAppear { KeyboardDismissal.installIfNeeded() }
        .task { coordinator.refreshUsage() }
        .fullScreenCover(isPresented: $coordinator.showStylePicker) {
            StylePickerView()
                .environment(coordinator)
        }
        .fullScreenCover(isPresented: $coordinator.showPaywall) {
            PaywallView()
                .environment(coordinator)
        }
    }

    // MARK: - QuickShape Tooltip

    private var quickShapeTooltip: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.tap.fill")
                .font(.subheadline)
            Text("Hold at the end of a stroke to snap it to a shape")
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.85), in: Capsule())
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    private func dismissQuickShapeTooltip() {
        hasSeenQuickShapeTooltip = true
        withAnimation(.easeOut(duration: 0.25)) {
            coordinator.shouldShowQuickShapeTooltip = false
        }
    }

    // MARK: - Split Screen Result Pane

    private func splitScreenResultPane(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ResultView(
                state: coordinator.resultState,
                currentBrushColor: coordinator.currentColor,
                onColorPicked: { coordinator.currentColor = $0 },
                onResumeTapped: { coordinator.resumeStream() },
                isUserDrawing: coordinator.canvasViewModel.isInteracting
            )
            .overlay(alignment: .top) {
                PromptTitleBar()
            }
            .overlay(alignment: .bottomTrailing) {
                if coordinator.canSwapStreamImageToCanvas {
                    streamSwapBar
                        .padding(12)
                }
            }

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)

            Color.clear
                .frame(width: geometry.size.width * coordinator.dividerPosition)
                .contentShape(Rectangle())
                .allowsHitTesting(false)
        }
    }

    // MARK: - Private

    private var streamSwapBar: some View {
        Button {
            coordinator.swapStreamImageToCanvas()
        } label: {
            Label("Send to Canvas", systemImage: "arrow.right")
                .font(.caption)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
    }
}

private struct PromptTitleBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    // Fixed content height — both the style tile and the prompt input stay
    // this tall regardless of text length. Long prompts scroll inside the
    // TextEditor rather than growing the bar.
    private static let contentHeight: CGFloat = 92
    private static let cornerRadius: CGFloat = 10

    var body: some View {
        @Bindable var coordinator = coordinator

        HStack(alignment: .center, spacing: 8) {
            styleButton
            promptInput
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
    }

    // Glass-like specular stroke — brighter top, accent-tinted bottom edge.
    // Fakes the light-catching edge of Apple's Liquid Glass.
    private static let glassStroke = LinearGradient(
        colors: [
            .white.opacity(0.35),
            .white.opacity(0.05),
            Color.accentColor.opacity(0.35)
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    private var styleButton: some View {
        Button {
            coordinator.showStylePicker = true
        } label: {
            VStack(spacing: 4) {
                Text("STYLE")
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(coordinator.selectedStyle.name)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.75)
                    .lineLimit(2)
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 6)
            .frame(width: Self.contentHeight, height: Self.contentHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Self.cornerRadius)
                    .stroke(Self.glassStroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }

    // Multi-line text input. `lineLimit(4, reservesSpace: true)` reserves
    // ~4 lines of height so the bar stays at a fixed initial size; extra
    // text scrolls internally once the limit is reached. Leading pencil
    // icon is the primary affordance — signals "type here."
    private var promptInput: some View {
        @Bindable var coordinator = coordinator
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "pencil.line")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
            TextField(
                "Describe your image…",
                text: $coordinator.promptText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.subheadline)
            .lineLimit(4, reservesSpace: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: Self.contentHeight)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .stroke(Self.glassStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 4)
    }
}

#Preview {
    DrawingView()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
}

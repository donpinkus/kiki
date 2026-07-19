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
                        overlayActive: coordinator.drawingLayout == .overlay,
                        overlayImage: coordinator.drawingLayout == .overlay
                            ? coordinator.resultState.displayImage
                            : nil,
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
                        },
                        onBrushInputSample: { [weak coordinator] sample in
                            coordinator?.liveBrushInput = sample
                        },
                        devMaxSpeed: coordinator.devMaxSpeed,
                        devDistancePeriod: coordinator.devDistancePeriod,
                        devFadePeriod: coordinator.devFadePeriod
                    )
                        .frame(width: canvasPaneWidth, height: geometry.size.height)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: coordinator.drawingLayout == .splitScreen ? .trailing : .center
                        )
                        .ignoresSafeArea(.keyboard)
                        .zIndex(0)

                    // DEV: live brush-input HUD (top-right), visual-only.
                    if coordinator.showInputHUD {
                        BrushInputHUD(sample: coordinator.liveBrushInput, note: coordinator.activeTestNote)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(.top, 16).padding(.trailing, 16)
                            .allowsHitTesting(false)
                            .zIndex(5)
                    }

                    CanvasSidebar()
                        .frame(maxHeight: .infinity, alignment: .leading)
                        .zIndex(3)

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
                    } else if coordinator.drawingLayout == .fullscreen,
                              let image = coordinator.resultState.displayImage {
                        // Overlay mode renders the generated image INSIDE the canvas
                        // container (locked to the canvas transform), so this branch is
                        // fullscreen-only. Overlay → render nothing here.
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

                        // Edit button rides the floating panel's geometry as a
                        // hit-testable sibling (the panel itself deliberately
                        // has allowsHitTesting(false) so strokes pass through).
                        ZStack(alignment: .bottomTrailing) {
                            Color.clear
                            resultActionButtons.padding(4)
                        }
                        .frame(
                            width: PanelLayout.baseSize(for: image, in: geometry.size).width,
                            height: PanelLayout.baseSize(for: image, in: geometry.size).height
                        )
                        .scaleEffect(coordinator.panelScale)
                        .offset(coordinator.panelOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(PanelLayout.edgeInset)
                        .zIndex(3)
                    }

                    // Overlay layout renders the generated image inside the
                    // canvas container; anchor the Edit button to the canvas
                    // pane's bottom-right instead.
                    if coordinator.drawingLayout == .overlay,
                       coordinator.resultState.displayImage != nil {
                        ZStack(alignment: .bottomTrailing) {
                            Color.clear
                            resultActionButtons.padding(4)
                        }
                        .frame(width: canvasSide, height: canvasSide)
                        .zIndex(3)
                    }

                    // AI Edit: while a preview is showing, swallow canvas
                    // touches (the opaque preview covers the canvas, so
                    // strokes would land invisibly underneath) and float the
                    // Accept / Retry / Discard bar.
                    if coordinator.aiEditPhase == .preview {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in })
                            .frame(width: canvasPaneWidth, height: geometry.size.height)
                            .zIndex(8)
                        aiEditPreviewBar
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 28)
                            .zIndex(12)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // Paste float: placement bar (drag/pinch handled by the
                    // float's own gestures; this bar commits or cancels).
                    if coordinator.canvasViewModel.isPasting {
                        HStack(spacing: 10) {
                            Text("Drag to place · pinch to scale")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button(role: .destructive) {
                                coordinator.canvasViewModel.cancelPaste()
                            } label: {
                                Label("Cancel", systemImage: "xmark")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.bordered)
                            Button {
                                coordinator.canvasViewModel.commitPaste()
                            } label: {
                                Label("Place", systemImage: "checkmark")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 6)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(10)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 28)
                        .zIndex(12)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }

                    // AI Edit: in-flight indicator (~3-5 s on a warm pool).
                    if coordinator.aiEditPhase == .generating {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("AI editing…")
                                .font(.callout.weight(.medium))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 12)
                        .transition(.opacity)
                        .zIndex(10)
                    }

                    // Transient toast ("Kiki's magic AI is still warming up…").
                    if let banner = coordinator.transientBanner {
                        Text(banner)
                            .font(.callout.weight(.medium))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 12)
                            .transition(.opacity)
                            .zIndex(10)
                    }
                }
                .animation(.easeInOut(duration: 0.35), value: coordinator.transientBanner)
                .background(KikiTheme.canvasBacking)
            }
            // Fill the bottom home-indicator safe-area inset so the (black) Metal
            // canvas reaches the physical bottom edge like it already does on the
            // top/left/right edges. Without this, the systemGray6 background bleeds
            // into the bottom inset while the canvas content stops above it, leaving
            // a ~24pt gray bar. Touch→texture mapping is unaffected: it's computed
            // from the centered canvas square's own bounds, not the pane height.
            .ignoresSafeArea(edges: .bottom)
        }
        // Selection panel, anchored beneath the Select tool button. While the
        // Select tool is active: author mode (Auto/Freehand), Add/Remove,
        // auto-mode params, selection-wide Expand, Move, Clear Selection. With
        // another tool active but a selection still clipping drawing, it
        // collapses to just "Clear Selection".
        .overlayPreferenceValue(SelectButtonAnchorKey.self) { selectAnchor in
            GeometryReader { proxy in
                if let selectAnchor, coordinator.aiEditPhase != .preview {
                    let selectRect = proxy[selectAnchor]
                    let selection = coordinator.canvasViewModel.selection
                    if coordinator.currentTool == .select || selection.hasSelection || selection.isMoving {
                        // Top-anchored (offset, not .position) so the panel can
                        // grow/shrink rows without re-centering math.
                        ZStack(alignment: .topLeading) {
                            Color.clear
                            selectionPanel
                                .frame(width: selectionPanelWidth)
                                .offset(
                                    x: min(selectRect.midX - selectionPanelWidth / 2,
                                           proxy.size.width - selectionPanelWidth - 8),
                                    y: selectRect.maxY + 8
                                )
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: coordinator.aiEditPhase)
        .animation(.easeInOut(duration: 0.3), value: coordinator.generationError != nil)
        .animation(.easeOut(duration: 0.25), value: coordinator.shouldShowQuickShapeTooltip)
        .ignoresSafeArea(.keyboard)
        .onAppear {
            KeyboardDismissal.installIfNeeded()
            // Track H100 availability while drawing so the Edit button's
            // enabled state stays honest without user interaction.
            coordinator.startLambdaStatusPolling()
        }
        .onDisappear { coordinator.stopLambdaStatusPolling() }
        .task { coordinator.refreshUsage() }
        .sheet(isPresented: $coordinator.showAIEditSheet) {
            AIEditSheet()
                .environment(coordinator)
        }
        .fullScreenCover(isPresented: $coordinator.showStylePicker) {
            StylePickerView()
                .environment(coordinator)
        }
        // THE brush-editing surface (replaced the gear popover + docked dev panel, 2026-07-17).
        .fullScreenCover(isPresented: $coordinator.showBrushStudio) {
            BrushStudioPage()
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

    // MARK: - Selection Panel

    private var selectionPanelWidth: CGFloat { 224 }

    /// Contextual selection UI beneath the Select tool button.
    /// - Select tool active, not moving: author mode (Auto/Freehand),
    ///   Add/Remove, auto-mode params, selection-wide Expand, Move, Clear.
    /// - Moving: just "Done" (+ hint) — the float owns the gestures.
    /// - Another tool active with a live selection: just "Clear Selection".
    private var selectionPanel: some View {
        let selection = coordinator.canvasViewModel.selection
        return VStack(spacing: 8) {
            if selection.isMoving {
                Text("Drag to move · pinch to scale · two-finger twist to rotate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    selection.commitMove()
                } label: {
                    Label("Done Moving", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                }
                .buttonStyle(.borderedProminent)
            } else if coordinator.currentTool == .select {
                @Bindable var selectionBinding = selection

                // Two authors, one selection: SAM taps or freehand loops.
                Picker("Author", selection: $selectionBinding.authorMode) {
                    Label("Auto", systemImage: "wand.and.stars")
                        .tag(SelectionController.AuthorMode.auto)
                    Label("Freehand", systemImage: "lasso")
                        .tag(SelectionController.AuthorMode.freehand)
                }
                .pickerStyle(.segmented)

                Picker("Point mode", selection: $selectionBinding.mode) {
                    Label("Add", systemImage: "plus.circle.fill")
                        .tag(SelectionController.PointMode.add)
                    Label("Remove", systemImage: "minus.circle.fill")
                        .tag(SelectionController.PointMode.subtract)
                }
                .pickerStyle(.segmented)

                if selection.authorMode == .auto {
                    // SAM's 3 candidate masks — the "tolerance" analog.
                    Picker("Selection size", selection: $selectionBinding.granularity) {
                        Text("Small").tag(SelectionController.Granularity.small)
                        Text("Auto").tag(SelectionController.Granularity.auto)
                        Text("Large").tag(SelectionController.Granularity.large)
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $selectionBinding.contiguous) {
                        Text("Contiguous")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }

                // Selection-wide grow/shrink (freehand regions included).
                HStack(spacing: 6) {
                    Text("Expand")
                        .font(.caption)
                    Slider(
                        value: Binding(
                            get: { Double(selectionBinding.expansion) },
                            set: { selectionBinding.expansion = Int($0.rounded()) }
                        ),
                        in: -20...20, step: 1
                    )
                    Text("\(selection.expansion)")
                        .font(.caption.monospacedDigit())
                        .frame(width: 26, alignment: .trailing)
                }

                if selection.isBusy {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(selection.isEncoding ? "Analyzing image…" : "Selecting…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if !selection.hasSelection && selection.currentPointCount == 0 {
                    Text(selection.authorMode == .auto
                         ? "Tap an object to select it"
                         : "Draw a loop to select a region")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = selection.lastError {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }

                if selection.hasSelection {
                    HStack(spacing: 8) {
                        Button {
                            selection.beginMove()
                        } label: {
                            Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                        .buttonStyle(.bordered)

                        // Copy the selection's content (strokes only, alpha
                        // outside) to the app clipboard + system pasteboard.
                        // Paste lives in the left sidebar.
                        Button {
                            coordinator.copySelection()
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 36)
                        }
                        .buttonStyle(.bordered)
                    }

                    // Persist the cutout to the object library (toolbar
                    // shippingbox) for reuse across drawings.
                    Button {
                        coordinator.saveSelectionToObjects()
                    } label: {
                        Label("Save Object", systemImage: "shippingbox")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                    }
                    .buttonStyle(.bordered)
                }
            }

            if !selection.isMoving, selection.hasSelection || selection.currentPointCount > 0 {
                clearSelectionButton
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
        .animation(.easeInOut(duration: 0.15), value: selection.isBusy)
        .animation(.easeInOut(duration: 0.15), value: selection.isMoving)
    }

    private var clearSelectionButton: some View {
        Button {
            coordinator.canvasViewModel.clearSelection()
        } label: {
            Label("Clear Selection", systemImage: "xmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
        }
        .buttonStyle(.borderedProminent)
        .tint(.secondary)
        .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    // MARK: - AI Edit preview bar

    /// Floating Accept / Retry / Discard controls while an AI Edit preview is
    /// locked over the canvas. Nothing touches the layer stack until Accept.
    private var aiEditPreviewBar: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                coordinator.discardAIEdit()
            } label: {
                Label("Discard", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)

            Button {
                coordinator.showAIEditSheet = true
            } label: {
                Label("Prompt", systemImage: "pencil")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)

            Button {
                coordinator.retryAIEdit()
            } label: {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.bordered)

            Button {
                coordinator.acceptAIEdit()
            } label: {
                Label("Accept", systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
    }

    // MARK: - Split Screen Result Pane

    private func splitScreenResultPane(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ResultView(
                state: coordinator.resultState,
                currentBrushColor: coordinator.currentColor,
                onColorPicked: { coordinator.currentColor = $0 },
                isUserDrawing: coordinator.canvasViewModel.isInteracting
            )
            .overlay(alignment: .top) {
                PromptTitleBar()
            }
            .overlay(alignment: .bottomTrailing) {
                VStack(alignment: .trailing, spacing: 8) {
                    if coordinator.canSwapStreamImageToCanvas {
                        streamSwapBar
                    }
                    if coordinator.resultState.displayImage != nil {
                        resultActionButtons
                    }
                }
                .padding(4)
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

    /// Animate + Edit, bottom-right of the generated image. Animate is
    /// hidden entirely while the video feature flag is off
    /// (videoAvailability == .off — the backend's availability push).
    private var resultActionButtons: some View {
        HStack(spacing: 6) {
            if coordinator.videoAvailability != .off {
                animateButton
            }
            editButton
        }
    }

    /// "Animate" → open the Animate screen with this drawing's result
    /// pre-loaded as the start keyframe.
    private var animateButton: some View {
        Button {
            coordinator.openAnimateFromDrawing()
        } label: {
            Label("Animate", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        }
    }

    /// "Edit" → sketchify the generated image onto the canvas as a new layer.
    /// Ready: menu with the two import modes. Warming: dimmed button whose tap
    /// explains ("warming up") via the transient banner. In-flight: spinner.
    @ViewBuilder
    private var editButton: some View {
        if coordinator.sketchifyInProgress {
            ProgressView()
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial, in: Capsule())
        } else if coordinator.lambdaPoolReady {
            Menu {
                Button {
                    coordinator.sketchifyToCanvas(mode: .lines)
                } label: {
                    Label("Lines", systemImage: "pencil.and.outline")
                }
                Button {
                    coordinator.sketchifyToCanvas(mode: .linesColors)
                } label: {
                    Label("Lines + color", systemImage: "paintpalette")
                }
            } label: {
                editButtonLabel(enabled: true)
            }
        } else {
            Button {
                coordinator.showLambdaWarmingBanner()
            } label: {
                editButtonLabel(enabled: false)
            }
        }
    }

    private func editButtonLabel(enabled: Bool) -> some View {
        Text("Edit")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .opacity(enabled ? 1 : 0.5)
    }

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

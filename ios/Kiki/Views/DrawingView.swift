import SwiftUI
import SwiftData
import CanvasModule
import ResultModule

struct DrawingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var panelReturnTask: Task<Void, Never>?
    @State private var errorDismissTask: Task<Void, Never>?

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
                .onAppear {
                    errorDismissTask?.cancel()
                    errorDismissTask = Task {
                        try? await Task.sleep(for: .seconds(8))
                        guard !Task.isCancelled else { return }
                        coordinator.generationError = nil
                    }
                }
            }

            GeometryReader { geometry in
                let canvasSide = min(
                    geometry.size.width * coordinator.dividerPosition,
                    geometry.size.height
                )
                // The gesture container fills the full drawing pane so pan/zoom/
                // rotate aren't clipped by the drawing surface's square footprint.
                // The drawing surface itself stays a centered `canvasSide` square
                // inside the container (see RotatableCanvasContainer).
                let canvasPaneWidth = coordinator.drawingLayout == .splitScreen
                    ? geometry.size.width * coordinator.dividerPosition
                    : geometry.size.width

                ZStack(alignment: .topLeading) {
                    CanvasView(viewModel: coordinator.canvasViewModel, drawingSurfaceSide: canvasSide)
                        .frame(width: canvasPaneWidth, height: geometry.size.height)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: coordinator.drawingLayout == .splitScreen ? .trailing : .center
                        )
                        .ignoresSafeArea(.keyboard)
                        .zIndex(coordinator.canvasOnTop ? 2 : 0)

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

                    if coordinator.drawingLayout == .splitScreen {
                        splitScreenResultPane(geometry: geometry)
                            .zIndex(2)
                    } else if coordinator.showFloatingPanel {
                        FloatingResultPanel(
                            resultState: coordinator.resultState,
                            canSwapStream: coordinator.canSwapStreamImageToCanvas,
                            containerSize: geometry.size,
                            currentBrushColor: coordinator.currentColor,
                            onClose: { coordinator.showFloatingPanel = false },
                            onSwapStreamToCanvas: { coordinator.swapStreamImageToCanvas() },
                            onColorPicked: { coordinator.currentColor = $0 },
                            onInteraction: {
                                panelReturnTask?.cancel()
                                coordinator.canvasOnTop = false
                            }
                        )
                        .overlay(alignment: .bottomLeading) {
                            connectionStatusIndicator
                                .padding(8)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(16)
                        .zIndex(coordinator.canvasOnTop ? 0 : 2)
                        .opacity(coordinator.canvasOnTop ? 0 : 1)
                    }
                }
                .background(Color(.systemGray6))
                .onChange(of: coordinator.canvasViewModel.isInteracting) { _, interacting in
                    guard coordinator.drawingLayout == .fullscreen else { return }
                    if interacting {
                        panelReturnTask?.cancel()
                        coordinator.canvasOnTop = true
                    } else {
                        panelReturnTask?.cancel()
                        panelReturnTask = Task {
                            try? await Task.sleep(for: .milliseconds(500))
                            guard !Task.isCancelled else { return }
                            withAnimation(.easeIn(duration: 0.25)) {
                                coordinator.canvasOnTop = false
                            }
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: coordinator.generationError != nil)
        .ignoresSafeArea(.keyboard)
        .onAppear { KeyboardDismissal.installIfNeeded() }
        .fullScreenCover(isPresented: $coordinator.showStylePicker) {
            StylePickerView()
                .environment(coordinator)
        }
    }

    // MARK: - Split Screen Result Pane

    private func splitScreenResultPane(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ResultView(
                state: coordinator.resultState,
                currentBrushColor: coordinator.currentColor,
                onColorPicked: { coordinator.currentColor = $0 },
                onResumeTapped: { coordinator.resumeStream() }
            )
            .overlay(alignment: .top) {
                PromptTitleBar()
            }
            .overlay(alignment: .bottomLeading) {
                connectionStatusIndicator
                    .padding(12)
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

    private var connectionStatusIndicator: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(streamStatusColor)
                .frame(width: 7, height: 7)
            Text(streamStatusLabel)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var streamStatusColor: Color {
        switch coordinator.streamReadiness {
        case .ready: return .green
        case .warming: return .orange
        case .disconnected: return .gray
        case .failed: return .red
        case .idleTimeout: return .blue
        }
    }

    private var streamStatusLabel: String {
        switch coordinator.streamReadiness {
        case .ready: return "Streaming · frame \(coordinator.streamFrameCount)"
        case .warming(let message, _): return message
        case .disconnected: return "Disconnected"
        case .failed: return "Error"
        case .idleTimeout: return "Paused"
        }
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

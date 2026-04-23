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
                        .padding(.leading, 12)
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
                onColorPicked: { coordinator.currentColor = $0 }
            )
            .overlay(alignment: .top) {
                PromptTitleBar()
                    .padding(.top, 8)
                    .padding(.horizontal, 24)
            }
            .overlay(alignment: .bottom) {
                if coordinator.canSwapStreamImageToCanvas {
                    streamSwapBar
                        .padding(.bottom, 16)
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
            Label("Send to Canvas", systemImage: "arrow.left.arrow.right")
                .font(.caption)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

private struct PromptTitleBar: View {
    @Environment(AppCoordinator.self) private var coordinator
    @FocusState private var isFocused: Bool

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 10) {
            Button {
                coordinator.showStylePicker = true
            } label: {
                Text(coordinator.selectedStyle.name.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.4)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(Color.accentColor)
            }

            TextField("Describe your image…", text: $coordinator.promptText)
                .textFieldStyle(.plain)
                .font(.title3.weight(.medium))
                .multilineTextAlignment(.center)
                .focused($isFocused)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isFocused ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(height: isFocused ? 1.5 : 1)
                        .animation(.easeInOut(duration: 0.15), value: isFocused)
                }
                .frame(maxWidth: 520)
        }
    }
}

#Preview {
    DrawingView()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
}

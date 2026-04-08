import SwiftUI
import SwiftData
import CanvasModule
import ResultModule

struct DrawingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showDebugModal = false
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
                // Square canvas — side length is the smaller of half-width and full-height,
                // so the canvas fits perfectly in either half of the split-screen layout.
                // Stays the same size in fullscreen for consistency.
                let canvasSide = min(
                    geometry.size.width * coordinator.dividerPosition,
                    geometry.size.height
                )

                ZStack(alignment: .topLeading) {
                    // Canvas — square, trailing-aligned in split-screen, centered in fullscreen.
                    CanvasView(viewModel: coordinator.canvasViewModel)
                        .frame(width: canvasSide, height: canvasSide)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: .infinity,
                            alignment: coordinator.drawingLayout == .splitScreen ? .trailing : .center
                        )
                        .ignoresSafeArea(.keyboard)
                        .zIndex(coordinator.canvasOnTop ? 2 : 0)

                    // Canvas sidebar — always on top of both canvas and panel
                    CanvasSidebar()
                        .padding(.leading, 12)
                        .frame(maxHeight: .infinity, alignment: .leading)
                        .zIndex(3)

                    // Layout-specific result display
                    if coordinator.drawingLayout == .splitScreen {
                        splitScreenResultPane(geometry: geometry)
                            .zIndex(2)
                    } else if coordinator.showFloatingPanel {
                        FloatingResultPanel(
                            resultState: effectiveResultState,
                            showingLineart: coordinator.showingLineart,
                            hasLineart: coordinator.lastGeneratedLineartImage != nil,
                            isGenerating: coordinator.isGenerating,
                            isStreamMode: coordinator.generationEngine == .stream,
                            canSwapStream: coordinator.canSwapStreamImageToCanvas,
                            containerSize: geometry.size,
                            onClose: { coordinator.showFloatingPanel = false },
                            onToggleLineart: { coordinator.showingLineart.toggle() },
                            onSwapToCanvas: { coordinator.swapLineartToCanvas() },
                            onSwapStreamToCanvas: { coordinator.swapStreamImageToCanvas() },
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
        .fullScreenCover(isPresented: $showDebugModal) {
            if let data = coordinator.comparisonData {
                DebugComparisonModal(data: data)
            }
        }
        .fullScreenCover(isPresented: $coordinator.showStylePicker) {
            StylePickerView()
                .environment(coordinator)
        }
        .alert(
            "Comparison Failed",
            isPresented: Binding(
                get: { coordinator.comparisonError != nil },
                set: { if !$0 { coordinator.comparisonError = nil } }
            )
        ) {
            Button("OK") { coordinator.comparisonError = nil }
        } message: {
            Text(coordinator.comparisonError ?? "")
        }
    }

    // MARK: - Split Screen Result Pane

    private func splitScreenResultPane(geometry: GeometryProxy) -> some View {
        HStack(spacing: 0) {
            ResultView(state: effectiveResultState)
                .overlay(alignment: .topTrailing) {
                    if coordinator.compareWithoutControlNet || coordinator.comparisonData != nil {
                        Button { if coordinator.comparisonData != nil { showDebugModal = true } } label: {
                            Image(systemName: "square.grid.2x2")
                                .font(.system(size: 14))
                                .foregroundStyle(.white)
                                .padding(8)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .disabled(coordinator.comparisonData == nil)
                        .opacity(coordinator.comparisonData != nil ? 1 : 0.4)
                        .padding(12)
                    }
                }
                .overlay(alignment: .bottom) {
                    if coordinator.generationEngine == .standard
                        && coordinator.lastGeneratedLineartImage != nil
                        && !coordinator.isGenerating {
                        lineartToggleBar
                            .padding(.bottom, 16)
                    } else if coordinator.canSwapStreamImageToCanvas {
                        streamSwapBar
                            .padding(.bottom, 16)
                    }
                }

            Rectangle()
                .fill(Color(.separator))
                .frame(width: 1)

            // Transparent spacer over the canvas area (on the right)
            Color.clear
                .frame(width: geometry.size.width * coordinator.dividerPosition)
                .contentShape(Rectangle())
                .allowsHitTesting(false)
        }
    }

    // MARK: - Private

    private var effectiveResultState: ResultState {
        if coordinator.showingLineart,
           let lineart = coordinator.lastGeneratedLineartImage,
           case .preview = coordinator.resultState {
            return .preview(image: lineart)
        }
        return coordinator.resultState
    }

    private var lineartToggleBar: some View {
        @Bindable var coordinator = coordinator
        return HStack(spacing: 12) {
            Picker("View", selection: $coordinator.showingLineart) {
                Text("Generated").tag(false)
                Text("Lineart").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            if coordinator.showingLineart {
                Button {
                    coordinator.swapLineartToCanvas()
                } label: {
                    Label("Swap to Canvas", systemImage: "arrow.left.arrow.right")
                        .font(.caption)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }

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

#Preview {
    DrawingView()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
}

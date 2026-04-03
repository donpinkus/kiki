import SwiftUI
import SwiftData
import CanvasModule
import ResultModule

struct DrawingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showDebugModal = false

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(spacing: 0) {
            DrawingTopBar()

            GeometryReader { geometry in
                HStack(spacing: 0) {
                    CanvasView(viewModel: coordinator.canvasViewModel)
                        .frame(width: geometry.size.width * coordinator.dividerPosition)
                        .ignoresSafeArea(.keyboard)
                        .overlay(alignment: .leading) {
                            CanvasSidebar()
                                .padding(.leading, 12)
                        }

                    Rectangle()
                        .fill(Color(.separator))
                        .frame(width: 1)

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
                            if coordinator.lastGeneratedLineartImage != nil && !coordinator.isGenerating {
                                lineartToggleBar
                                    .padding(.bottom, 16)
                            }
                        }
                }
            }
        }
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
}

#Preview {
    DrawingView()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
}

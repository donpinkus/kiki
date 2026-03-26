import SwiftUI
import SwiftData
import CanvasModule
import ResultModule

struct DrawingView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showDebugModal = false

    var body: some View {
        @Bindable var coordinator = coordinator

        GeometryReader { geometry in
            HStack(spacing: 0) {
                CanvasView(viewModel: coordinator.canvasViewModel)
                    .frame(width: geometry.size.width * coordinator.dividerPosition)
                    .ignoresSafeArea(.keyboard)

                Rectangle()
                    .fill(Color(.separator))
                    .frame(width: 1)

                VStack(spacing: 0) {
                    if coordinator.lastGeneratedLineartImage != nil && !coordinator.isGenerating {
                        lineartToggleBar
                    }

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

                    promptBar(promptText: $coordinator.promptText)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            FloatingToolbar()
                .padding(16)
        }
        .overlay(alignment: .topLeading) {
            Button {
                coordinator.navigateToGallery()
            } label: {
                Label("Gallery", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(16)
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

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func promptBar(promptText: Binding<String>) -> some View {
        HStack(spacing: 12) {
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

            TextField("Describe what you want…", text: promptText)
                .textFieldStyle(.plain)
                .font(.subheadline)

            Button {
                coordinator.generate()
            } label: {
                Image(systemName: "apple.intelligence")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(
                        coordinator.canvasViewModel.isEmpty || coordinator.isGenerating
                            ? Color.accentColor.opacity(0.4)
                            : Color.accentColor,
                        in: Circle()
                    )
                    .overlay(alignment: .topTrailing) {
                        if coordinator.hasUnsavedChanges && !coordinator.isGenerating {
                            Circle()
                                .fill(.orange)
                                .frame(width: 8, height: 8)
                        }
                    }
            }
            .disabled(coordinator.canvasViewModel.isEmpty || coordinator.isGenerating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

#Preview {
    DrawingView()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
}

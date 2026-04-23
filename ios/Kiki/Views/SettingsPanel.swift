import SwiftUI
import SwiftData

struct SettingsPanel: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                displaySection
                streamParametersSection
                captureSection

                Section {
                    Button("Reset All to Defaults", role: .destructive) {
                        coordinator.streamSteps = 4
                        coordinator.streamSeed = nil
                        coordinator.streamCaptureFPS = 2
                        coordinator.drawingLayout = .splitScreen
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var displaySection: some View {
        @Bindable var coordinator = coordinator

        return Section("Display") {
            Picker("Layout", selection: $coordinator.drawingLayout) {
                Text("Split").tag(DrawingLayout.splitScreen)
                Text("Fullscreen").tag(DrawingLayout.fullscreen)
            }
            .pickerStyle(.segmented)
        }
    }

    private var streamParametersSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Parameters") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Steps")
                        .font(.subheadline)
                    Spacer()
                    Text("\(coordinator.streamSteps)")
                        .font(.subheadline.monospacedDigit())
                }
                Slider(
                    value: Binding(
                        get: { Double(coordinator.streamSteps) },
                        set: { coordinator.streamSteps = Int($0) }
                    ),
                    in: 1...8,
                    step: 1
                )
            }

            HStack {
                Text("Seed")
                    .font(.subheadline)
                TextField(
                    "Random",
                    text: Binding(
                        get: { coordinator.streamSeed.map { String($0) } ?? "" },
                        set: { text in
                            if text.isEmpty {
                                coordinator.streamSeed = nil
                            } else if let value = Int(text) {
                                coordinator.streamSeed = value
                            }
                        }
                    )
                )
                .font(.subheadline.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
                .frame(maxWidth: 120)
            }
        }
    }

    private var captureSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Capture") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Capture FPS")
                        .font(.subheadline)
                    Spacer()
                    Text("\(Int(coordinator.streamCaptureFPS))")
                        .font(.subheadline.monospacedDigit())
                }
                Slider(value: $coordinator.streamCaptureFPS, in: 1...10, step: 1)
            }
        }
    }
}

#Preview {
    SettingsPanel()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
        .frame(width: 400, height: 600)
}

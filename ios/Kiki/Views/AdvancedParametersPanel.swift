import SwiftUI
import SwiftData

struct AdvancedParametersPanel: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                streamModeSection
                streamParametersSection
                captureSection

                Section {
                    Button("Reset All to Defaults", role: .destructive) {
                        coordinator.streamMode = "reference"
                        coordinator.streamDenoise = 0.6
                        coordinator.streamGuidanceScale = 4.0
                        coordinator.streamSteps = 4
                        coordinator.streamSeed = nil
                        coordinator.streamCaptureFPS = 2
                    }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var streamModeSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Mode") {
            Picker("Mode", selection: $coordinator.streamMode) {
                Text("Reference").tag("reference")
                Text("Denoise").tag("denoise")
            }
            .pickerStyle(.segmented)
        }
    }

    private var streamParametersSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Parameters") {
            if coordinator.streamMode == "reference" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Guidance Scale")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f", coordinator.streamGuidanceScale))
                            .font(.subheadline.monospacedDigit())
                    }
                    Slider(value: $coordinator.streamGuidanceScale, in: 1...10, step: 0.5)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Denoise Strength")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", coordinator.streamDenoise))
                            .font(.subheadline.monospacedDigit())
                    }
                    Slider(value: $coordinator.streamDenoise, in: 0.1...1.0, step: 0.05)
                    Text("Lower = more sketch fidelity, higher = more model freedom.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

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
    AdvancedParametersPanel()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
        .frame(width: 400, height: 600)
}

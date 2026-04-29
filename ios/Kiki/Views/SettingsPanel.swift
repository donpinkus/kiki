import SwiftUI
import SwiftData

struct SettingsPanel: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                displaySection
                videoSection
                streamParametersSection
                captureSection
                diagnosticsSection

                Section {
                    Button("Reset All to Defaults", role: .destructive) {
                        coordinator.streamSteps = 4
                        coordinator.streamSeed = nil
                        coordinator.streamCaptureFPS = 2
                        coordinator.drawingLayout = .splitScreen
                        coordinator.videoResolution = 320
                        coordinator.videoFrames = 49
                        coordinator.enableProfiling = false
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // LTX-2.3 frame counts must satisfy (n-1) % 8 == 0; FPS is fixed at 24
    // pod-side (config.LTX_FPS), so duration = (n-1) / 24 + ~0 (we display
    // the simpler frames/24 since 49→2.0s reads cleanly).
    private static let frameOptions: [Int] = [49, 81, 113, 145]
    private static let resolutionOptions: [Int] = [320, 384, 448, 512]

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

    private var videoSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Video") {
            Picker("Resolution", selection: $coordinator.videoResolution) {
                ForEach(Self.resolutionOptions, id: \.self) { px in
                    Text("\(px) × \(px)").tag(px)
                }
            }

            Picker("Frames", selection: $coordinator.videoFrames) {
                ForEach(Self.frameOptions, id: \.self) { n in
                    let seconds = Double(n) / 24.0
                    Text(String(format: "%d frames (%.1fs)", n, seconds)).tag(n)
                }
            }
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

    private var diagnosticsSection: some View {
        @Bindable var coordinator = coordinator

        return Section {
            Toggle("Profile next runs", isOn: $coordinator.enableProfiling)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Adds ~15–25% latency. Writes a Perfetto trace to /tmp on the pod (fetch via SCP).")
        }
    }
}

#Preview {
    SettingsPanel()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
        .frame(width: 400, height: 600)
}

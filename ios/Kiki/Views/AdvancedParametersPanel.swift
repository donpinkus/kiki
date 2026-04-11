import SwiftUI
import SwiftData
import NetworkModule

struct AdvancedParametersPanel: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                if coordinator.generationEngine == .stream {
                    streamParametersSection
                } else {
                    generationModeSection
                    controlNetSection
                    samplerSection
                    modelSection
                    negativePromptSection
                    seedSection

                    Section("Debug") {
                        Toggle("Compare without ControlNet", isOn: $coordinator.compareWithoutControlNet)
                    }
                }

                Section {
                    Button("Reset All to Defaults", role: .destructive) {
                        coordinator.advancedParameters = AdvancedParameters()
                        coordinator.isSeedLocked = false
                        coordinator.compareWithoutControlNet = false
                        // SD defaults
                        coordinator.streamTIndexListText = "20,30"
                        // FLUX defaults
                        coordinator.fluxMode = "reference"
                        coordinator.fluxDenoiseStrength = 0.6
                        coordinator.fluxGuidanceScale = 4.0
                        coordinator.fluxSteps = 4
                        coordinator.fluxSeed = nil
                        // Capture FPS
                        coordinator.streamCaptureFPS = coordinator.streamEngine.defaultFPS
                    }
                }
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Stream Sections

    private var streamParametersSection: some View {
        @Bindable var coordinator = coordinator

        return Group {
            Section("Stream Engine") {
                Picker("Engine", selection: $coordinator.streamEngine) {
                    ForEach(StreamEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
            }

            if coordinator.streamEngine == .streamDiffusion {
                sdStreamSection
            } else {
                fluxStreamSection
            }

            Section("Capture") {
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

    private var sdStreamSection: some View {
        @Bindable var coordinator = coordinator

        return Section("StreamDiffusion") {
            VStack(alignment: .leading, spacing: 4) {
                Text("t_index_list")
                    .font(.subheadline)
                Text("Lower = more creative, higher = more faithful to input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("e.g. 15,25", text: $coordinator.streamTIndexListText)
                    .font(.subheadline.monospacedDigit())
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
            }
        }
    }

    private var fluxStreamSection: some View {
        @Bindable var coordinator = coordinator

        return Section("FLUX Klein") {
            Picker("Mode", selection: $coordinator.fluxMode) {
                Text("Reference").tag("reference")
                Text("Denoise").tag("denoise")
            }
            .pickerStyle(.segmented)

            if coordinator.fluxMode == "reference" {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Guidance Scale")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.1f", coordinator.fluxGuidanceScale))
                            .font(.subheadline.monospacedDigit())
                    }
                    Slider(value: $coordinator.fluxGuidanceScale, in: 1...10, step: 0.5)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Denoise Strength")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", coordinator.fluxDenoiseStrength))
                            .font(.subheadline.monospacedDigit())
                    }
                    Slider(value: $coordinator.fluxDenoiseStrength, in: 0.1...1.0, step: 0.05)
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
                    Text("\(coordinator.fluxSteps)")
                        .font(.subheadline.monospacedDigit())
                }
                Slider(
                    value: Binding(
                        get: { Double(coordinator.fluxSteps) },
                        set: { coordinator.fluxSteps = Int($0) }
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
                        get: { coordinator.fluxSeed.map { String($0) } ?? "" },
                        set: { text in
                            if text.isEmpty {
                                coordinator.fluxSeed = nil
                            } else if let value = Int(text) {
                                coordinator.fluxSeed = value
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

    // MARK: - Standard Sections

    private var generationModeSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Generation Mode") {
            Picker("Trigger", selection: $coordinator.triggerMode) {
                Text("Auto").tag(GenerationTriggerMode.auto)
                Text("Manual").tag(GenerationTriggerMode.manual)
            }
            .pickerStyle(.segmented)
        }
    }

    private var controlNetSection: some View {
        Section("ControlNet") {
            parameterSlider(
                label: "Strength",
                value: optionalBinding(
                    \.controlNetStrength,
                    default: AdvancedParameters.defaultControlNetStrength
                ),
                range: 0...1,
                defaultValue: AdvancedParameters.defaultControlNetStrength
            )
            parameterSlider(
                label: "End %",
                value: optionalBinding(
                    \.controlNetEndPercent,
                    default: AdvancedParameters.defaultControlNetEndPercent
                ),
                range: 0...1,
                defaultValue: AdvancedParameters.defaultControlNetEndPercent
            )
        }
    }

    private var samplerSection: some View {
        Section("Sampler") {
            parameterSlider(
                label: "CFG",
                value: optionalBinding(
                    \.cfgScale,
                    default: AdvancedParameters.defaultCfgScale
                ),
                range: 0...5,
                defaultValue: AdvancedParameters.defaultCfgScale
            )
            parameterSlider(
                label: "Steps",
                value: optionalIntBinding(
                    \.steps,
                    default: AdvancedParameters.defaultSteps
                ),
                range: 1...20,
                step: 1,
                defaultValue: Double(AdvancedParameters.defaultSteps),
                formatAsInt: true
            )
            parameterSlider(
                label: "Denoise",
                value: optionalBinding(
                    \.denoise,
                    default: AdvancedParameters.defaultDenoise
                ),
                range: 0...1,
                defaultValue: AdvancedParameters.defaultDenoise
            )
        }
    }

    private var modelSection: some View {
        Section("Model") {
            parameterSlider(
                label: "AuraFlow Shift",
                value: optionalBinding(
                    \.auraFlowShift,
                    default: AdvancedParameters.defaultAuraFlowShift
                ),
                range: 0...5,
                defaultValue: AdvancedParameters.defaultAuraFlowShift
            )
            parameterSlider(
                label: "LoRA Strength",
                value: optionalBinding(
                    \.loraStrength,
                    default: AdvancedParameters.defaultLoraStrength
                ),
                range: 0...2,
                defaultValue: AdvancedParameters.defaultLoraStrength
            )
        }
    }

    private var negativePromptSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Negative Prompt") {
            HStack {
                TextField(
                    "Default (backend)",
                    text: Binding(
                        get: { coordinator.advancedParameters.negativePrompt ?? "" },
                        set: { coordinator.advancedParameters.negativePrompt = $0.isEmpty ? nil : $0 }
                    )
                )
                .font(.subheadline)

                if coordinator.advancedParameters.negativePrompt != nil {
                    Button {
                        coordinator.advancedParameters.negativePrompt = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var seedSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Seed") {
            HStack {
                TextField(
                    "Random",
                    text: Binding(
                        get: {
                            coordinator.advancedParameters.seed.map { String($0) } ?? ""
                        },
                        set: { text in
                            if text.isEmpty {
                                coordinator.advancedParameters.seed = nil
                            } else if let value = UInt64(text) {
                                coordinator.advancedParameters.seed = min(value, AdvancedParameters.maxSeed)
                            }
                        }
                    )
                )
                .font(.subheadline.monospacedDigit())
                .keyboardType(.numberPad)

                Button {
                    coordinator.isSeedLocked.toggle()
                    if !coordinator.isSeedLocked {
                        coordinator.advancedParameters.seed = nil
                    }
                } label: {
                    Image(systemName: coordinator.isSeedLocked ? "lock.fill" : "lock.open")
                        .foregroundStyle(coordinator.isSeedLocked ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func parameterSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double? = nil,
        defaultValue: Double,
        formatAsInt: Bool = false
    ) -> some View {
        let isModified = abs(value.wrappedValue - defaultValue) > 0.005 * (range.upperBound - range.lowerBound)

        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.subheadline)
                Spacer()
                Text(formatAsInt ? "\(Int(value.wrappedValue))" : String(format: "%.2f", value.wrappedValue))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(isModified ? .primary : .secondary)
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
        }
    }

    /// Creates a binding to an optional Double property on `advancedParameters`.
    /// When the value is within 0.5% of the default, stores `nil` instead.
    private func optionalBinding(
        _ keyPath: WritableKeyPath<AdvancedParameters, Double?>,
        default defaultValue: Double,
        tolerance: Double = 0.005
    ) -> Binding<Double> {
        Binding(
            get: {
                coordinator.advancedParameters[keyPath: keyPath] ?? defaultValue
            },
            set: { newValue in
                let normalized = abs(newValue - defaultValue) / max(abs(defaultValue), 1.0)
                coordinator.advancedParameters[keyPath: keyPath] = normalized < tolerance ? nil : newValue
            }
        )
    }

    /// Creates a binding to an optional Int property, converting through Double for Slider.
    private func optionalIntBinding(
        _ keyPath: WritableKeyPath<AdvancedParameters, Int?>,
        default defaultValue: Int
    ) -> Binding<Double> {
        Binding(
            get: {
                Double(coordinator.advancedParameters[keyPath: keyPath] ?? defaultValue)
            },
            set: { newValue in
                let intValue = Int(newValue.rounded())
                coordinator.advancedParameters[keyPath: keyPath] = intValue == defaultValue ? nil : intValue
            }
        )
    }
}

#Preview {
    AdvancedParametersPanel()
        .environment(AppCoordinator(modelContext: try! ModelContainer(for: Drawing.self).mainContext))
        .frame(width: 400, height: 600)
}

import SwiftUI
import NetworkModule

struct AdvancedParametersPanel: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        NavigationStack {
            Form {
                controlNetSection
                samplerSection
                seedSection
                resetSection
            }
            .navigationTitle("Advanced")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Sections

    private var controlNetSection: some View {
        @Bindable var coordinator = coordinator

        return Section("ControlNet") {
            parameterSlider(
                label: "Strength",
                value: optionalBinding(
                    get: { coordinator.advancedParameters.controlNetStrength },
                    set: { coordinator.advancedParameters.controlNetStrength = $0 },
                    default: AdvancedParameters.defaultControlNetStrength
                ),
                range: 0...1,
                defaultValue: AdvancedParameters.defaultControlNetStrength
            )

            parameterSlider(
                label: "End %",
                value: optionalBinding(
                    get: { coordinator.advancedParameters.controlNetEndPercent },
                    set: { coordinator.advancedParameters.controlNetEndPercent = $0 },
                    default: AdvancedParameters.defaultControlNetEndPercent
                ),
                range: 0...1,
                defaultValue: AdvancedParameters.defaultControlNetEndPercent
            )
        }
    }

    private var samplerSection: some View {
        @Bindable var coordinator = coordinator

        return Section("Sampler") {
            parameterSlider(
                label: "CFG",
                value: optionalBinding(
                    get: { coordinator.advancedParameters.cfgScale },
                    set: { coordinator.advancedParameters.cfgScale = $0 },
                    default: AdvancedParameters.defaultCfgScale
                ),
                range: 0...5,
                defaultValue: AdvancedParameters.defaultCfgScale
            )

            stepsRow

            parameterSlider(
                label: "Denoise",
                value: optionalBinding(
                    get: { coordinator.advancedParameters.denoise },
                    set: { coordinator.advancedParameters.denoise = $0 },
                    default: AdvancedParameters.defaultDenoise
                ),
                range: 0...1,
                defaultValue: AdvancedParameters.defaultDenoise
            )
        }
    }

    private var stepsRow: some View {
        @Bindable var coordinator = coordinator
        let stepsValue = Binding<Double>(
            get: { Double(coordinator.advancedParameters.steps ?? AdvancedParameters.defaultSteps) },
            set: {
                let intVal = Int($0.rounded())
                coordinator.advancedParameters.steps = intVal == AdvancedParameters.defaultSteps ? nil : intVal
            }
        )

        return HStack {
            Text("Steps")
            Spacer()
            Text("\(Int(stepsValue.wrappedValue))")
                .foregroundStyle(coordinator.advancedParameters.steps != nil ? .primary : .secondary)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
            Slider(value: stepsValue, in: 1...20, step: 1)
                .frame(width: 180)
        }
    }

    private var seedSection: some View {
        @Bindable var coordinator = coordinator
        let seedText = Binding<String>(
            get: {
                if let seed = coordinator.advancedParameters.seed {
                    return String(seed)
                }
                return ""
            },
            set: { newValue in
                coordinator.advancedParameters.seed = UInt64(newValue)
            }
        )

        return Section("Seed") {
            HStack {
                TextField("Random", text: seedText)
                    .keyboardType(.numberPad)
                    .monospacedDigit()

                Button {
                    coordinator.isSeedLocked.toggle()
                    if !coordinator.isSeedLocked {
                        coordinator.advancedParameters.seed = nil
                    }
                } label: {
                    Image(systemName: coordinator.isSeedLocked ? "lock.fill" : "lock.open")
                        .foregroundStyle(coordinator.isSeedLocked ? Color.accentColor : .secondary)
                }
            }
        }
    }

    private var resetSection: some View {
        Section {
            Button("Reset All to Defaults") {
                coordinator.advancedParameters = AdvancedParameters()
                coordinator.isSeedLocked = false
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Helpers

    /// Creates a binding that stores nil when the value matches the default,
    /// preventing parameters from appearing "dirty" when unchanged.
    private func optionalBinding(
        get: @escaping () -> Double?,
        set: @escaping (Double?) -> Void,
        default defaultValue: Double,
        tolerance: Double = 0.005
    ) -> Binding<Double> {
        Binding(
            get: { get() ?? defaultValue },
            set: { newValue in
                set(abs(newValue - defaultValue) < tolerance ? nil : newValue)
            }
        )
    }

    private func parameterSlider(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        defaultValue: Double
    ) -> some View {
        let isModified = abs(value.wrappedValue - defaultValue) >= 0.005
        return HStack {
            Text(label)
            Spacer()
            Text(String(format: "%.2f", value.wrappedValue))
                .foregroundStyle(isModified ? .primary : .secondary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
            Slider(value: value, in: range)
                .frame(width: 180)
        }
    }
}

#Preview {
    AdvancedParametersPanel()
        .environment(AppCoordinator())
}

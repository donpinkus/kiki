import SwiftUI
import CanvasModule

// MARK: - Brush Studio (dev panel)
//
// A live tuning surface for the Krita-grade brush dynamics (BrushDynamics.swift). Lets you
// author/tune a brush on device: pick sensors, shape each parameter's response curve, set
// combine mode + strength/min/max, jitter color, toggle smudge — applied to the active brush
// in real time via AppCoordinator.toolDynamics. Dev-only; per `feedback_ipad_dev_toggles` real
// tuning belongs in a dev panel, not the shipping brush UI.
//
// Edits flow: this view mutates a local `BrushDynamics`, and `.onChange` pushes it to
// `coordinator.toolDynamics` (→ `applyTool()` rebuilds + selects the brush live). An inert
// dynamics pushes `nil` so the default pen is restored exactly.

struct BrushStudioView: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss
    @State private var dyn: BrushDynamics

    init(initial: BrushDynamics?) {
        _dyn = State(initialValue: initial ?? BrushDynamics())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            presetButton("Default Pen") { coordinator.resetBrushDynamics(); dyn = BrushDynamics() }
                            ForEach(BrushPresetCatalog.all) { preset in
                                presetButton(preset.name) {
                                    coordinator.applyBrushPreset(preset)
                                    dyn = preset.dynamics
                                }
                            }
                        }
                    }
                }

                curveSection("Size", option: $dyn.size, fold: .sizeLike, defaultSensor: .pressure)
                curveSection("Flow", option: $dyn.flow, fold: .sizeLike, defaultSensor: .pressure)
                curveSection("Rotation", option: $dyn.rotation, fold: .rotationLike, defaultSensor: .drawingAngle)
                curveSection("Scatter", option: $dyn.scatter, fold: .sizeLike, defaultSensor: .pressure)

                ColorJitterSection(jitter: $dyn.colorJitter)

                Section("Smudge") {
                    Toggle("Smudge mode (push canvas color, no new ink)",
                           isOn: Binding(get: { coordinator.toolWetSmudge },
                                         set: { coordinator.toolWetSmudge = $0 }))
                    Text("Tune Mix (wetStrength) + Smear (wetPickup) in the brush settings popover.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Brush Studio (dev)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: dyn) { _, new in
                coordinator.toolDynamics = new.isInert ? nil : new
            }
        }
    }

    private func presetButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private func curveSection(_ title: String, option: Binding<CurveOption?>,
                              fold: BrushFold, defaultSensor: BrushSensor) -> some View {
        Section(title) {
            Toggle("Enabled", isOn: Binding(
                get: { option.wrappedValue != nil },
                set: { on in
                    option.wrappedValue = on
                        ? CurveOption(sensors: [SensorChannel(sensor: defaultSensor)], fold: fold)
                        : nil
                }))
            if option.wrappedValue != nil {
                CurveOptionEditor(option: Binding(
                    get: { option.wrappedValue ?? CurveOption(sensors: [], fold: fold) },
                    set: { option.wrappedValue = $0 }))
            }
        }
    }
}

// MARK: - One parameter's editor

private struct CurveOptionEditor: View {
    @Binding var option: CurveOption

    private let allSensors: [BrushSensor] = BrushSensor.allCases

    // True when the option carries per-sensor curves (e.g. Speed Pencil) that the single
    // shared-curve editor below can't represent.
    private var hasPerSensorCurves: Bool {
        !option.useSameCurve && option.sensors.contains { !$0.curve.isIdentity }
    }

    var body: some View {
        // Sensors
        VStack(alignment: .leading, spacing: 4) {
            Text("Sensors").font(.caption).foregroundStyle(.secondary)
            FlowChips(items: allSensors.map { ($0.rawValue, isOn(for: $0)) }) { idx in
                toggleSensor(allSensors[idx])
            }
            if option.sensors.isEmpty {
                Text("No sensors → constant value (Size loses pressure response).")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }
        // Combine mode (only meaningful with >1 scaling sensor)
        Picker("Combine", selection: Binding(
            get: { option.combineMode },
            set: { option.combineMode = $0 })) {
            Text("×").tag(CombineMode.multiply)
            Text("+").tag(CombineMode.add)
            Text("max").tag(CombineMode.max)
            Text("min").tag(CombineMode.min)
            Text("diff").tag(CombineMode.difference)
        }.pickerStyle(.segmented)

        // Response curve. M2: when the option has per-sensor curves, seed the editor from the
        // first real one (not the identity commonCurve, which would misrepresent it), and warn
        // that editing collapses to ONE shared curve across all sensors.
        VStack(alignment: .leading, spacing: 4) {
            Text("Response curve").font(.caption).foregroundStyle(.secondary)
            if hasPerSensorCurves {
                Text("⚠︎ This preset uses per-sensor curves. Editing applies one shared curve to all sensors.")
                    .font(.caption2).foregroundStyle(.orange)
            }
            ResponseCurveEditor(curve: Binding(
                get: {
                    if hasPerSensorCurves, let first = option.sensors.first(where: { !$0.curve.isIdentity }) {
                        return first.curve
                    }
                    return option.commonCurve
                },
                set: { option.commonCurve = $0; option.useSameCurve = true }))
        }

        sliderRow("Strength", value: $option.strength, range: 0...2)
        // Clamp so min ≤ max (otherwise min silently acts as a hard ceiling — review m3).
        sliderRow("Min", value: Binding(
            get: { option.minValue },
            set: { option.minValue = Swift.min($0, option.maxValue) }), range: 0...1)
        sliderRow("Max", value: Binding(
            get: { option.maxValue },
            set: { option.maxValue = Swift.max($0, option.minValue) }), range: 0...2)
    }

    private func isOn(for s: BrushSensor) -> Bool { option.sensors.contains { $0.sensor == s } }
    private func toggleSensor(_ s: BrushSensor) {
        if let i = option.sensors.firstIndex(where: { $0.sensor == s }) {
            option.sensors.remove(at: i)
        } else {
            option.sensors.append(SensorChannel(sensor: s))
        }
    }

    private func sliderRow(_ label: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(label).frame(width: 64, alignment: .leading).font(.caption)
            Slider(value: value, in: range)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospaced()).frame(width: 44)
        }
    }
}

// MARK: - Color jitter

private struct ColorJitterSection: View {
    @Binding var jitter: ColorJitter?
    var body: some View {
        Section("Color jitter (per stroke)") {
            Toggle("Enabled", isOn: Binding(
                get: { jitter != nil },
                set: { jitter = $0 ? ColorJitter(hue: 0.05, saturation: 0.15, brightness: 0.1) : nil }))
            if jitter != nil {
                let j = Binding(get: { jitter ?? ColorJitter() }, set: { jitter = $0 })
                slider("Hue", j.hue); slider("Saturation", j.saturation); slider("Brightness", j.brightness)
            }
        }
    }
    private func slider(_ label: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(label).frame(width: 84, alignment: .leading).font(.caption)
            Slider(value: value, in: 0...1)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption.monospaced()).frame(width: 44)
        }
    }
}

// MARK: - Draggable response-curve editor (5 fixed-x control points, y-draggable)

private struct ResponseCurveEditor: View {
    @Binding var curve: ResponseCurve
    private static let xs: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
    @State private var ys: [Double]
    @State private var dragging = false

    init(curve: Binding<ResponseCurve>) {
        _curve = curve
        // Sample the incoming curve at the fixed x positions to seed the editable points.
        _ys = State(initialValue: ResponseCurveEditor.xs.map { curve.wrappedValue.value($0) })
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack {
                // grid + curve
                Path { p in
                    p.move(to: .zero); p.addRect(CGRect(x: 0, y: 0, width: w, height: h))
                }.stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                Path { p in
                    let n = 48
                    for i in 0...n {
                        let x = Double(i) / Double(n)
                        let y = curve.value(x)
                        let pt = CGPoint(x: x * w, y: (1 - y) * h)
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }.stroke(Color.accentColor, lineWidth: 2)
                // control points
                ForEach(Array(Self.xs.enumerated()), id: \.offset) { i, x in
                    Circle().fill(Color.accentColor)
                        .frame(width: 12, height: 12)
                        .position(x: x * w, y: (1 - ys[i]) * h)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                dragging = true
                let nx = max(0, min(1, g.location.x / w))
                let ny = max(0, min(1, 1 - g.location.y / h))
                // snap to the nearest control point in x, set its y
                var best = 0; var bestD = Double.greatestFiniteMagnitude
                for (i, x) in Self.xs.enumerated() {
                    let d = abs(x - nx); if d < bestD { bestD = d; best = i }
                }
                ys[best] = ny
                curve = ResponseCurve(points: zip(Self.xs, ys).map { ResponseCurve.Point($0, $1) })
            }.onEnded { _ in dragging = false })
        }
        .frame(height: 140)
        // Re-seed the draggable points when the bound curve changes externally (e.g. a preset
        // is loaded while this editor is open) — but NOT from our own drag writes (guarded by
        // `dragging`), which would otherwise round-trip through the LUT and drift. Fixes the
        // "load preset → drag → curve clobbered with stale points" desync (review M1).
        .onChange(of: curve) { _, new in
            if !dragging { ys = Self.xs.map { new.value($0) } }
        }
    }
}

// MARK: - Simple wrapping chip row

private struct FlowChips: View {
    let items: [(String, Bool)]
    let onTap: (Int) -> Void
    var body: some View {
        // Lazy 3-column grid keeps it simple + scroll-free in a Form row.
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button(item.0) { onTap(i) }
                    .font(.caption2)
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .frame(maxWidth: .infinity)
                    .background(item.1 ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .buttonStyle(.plain)
            }
        }
    }
}

import SwiftUI
import CanvasModule

// MARK: - Brush Studio shared components
//
// The dynamics curve editors + live input HUD. The old docked dev-panel `BrushStudioView`
// that lived here was folded into the full-page `BrushStudioPage` (2026-07-17); this file
// keeps the reusable pieces: `CurveOptionEditor` (sensors + response curve + strength),
// `ColorJitterSection`, `FlowChips`, and the on-canvas `BrushInputHUD`.

// MARK: - Live input HUD (dev)

/// On-canvas readout of the live brush inputs + resulting multipliers, for tuning the engine.
struct BrushInputHUD: View {
    let sample: BrushInputSample?
    let note: String?
    var body: some View {
        let s = sample ?? BrushInputSample()
        VStack(alignment: .leading, spacing: 2) {
            if let note { Text(note).font(.caption2).foregroundStyle(.yellow).frame(maxWidth: 220, alignment: .leading) }
            row("pressure", String(format: "%.2f", s.pressure))
            row("speed", String(format: "%.0f px/s", s.speedRaw))
            row("  →norm", String(format: "%.2f", s.speedNorm))
            row("tilt", String(format: "%.2f", s.tiltElevation))
            row("azimuth", String(format: "%.2f", s.azimuth))
            row("angle", String(format: "%.2f", s.drawingAngle))
            row("size×", String(format: "%.2f", s.sizeMul))
            row("flow×", String(format: "%.2f", s.flowMul))
            row("dab", "\(s.dabIndex)")
        }
        .padding(8)
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .font(.caption2.monospaced())
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 6) {
            Text(k).frame(width: 64, alignment: .leading).foregroundStyle(.white.opacity(0.7))
            Text(v)
        }
    }
}

// MARK: - One parameter's editor

struct CurveOptionEditor: View {
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
                set: { option.commonCurve = $0; option.useSameCurve = true }),
                sensor: option.sensors.first?.sensor)
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

struct ColorJitterSection: View {
    let title: String
    @Binding var jitter: ColorJitter?
    var defaults = ColorJitter(hue: 0.05, saturation: 0.15, brightness: 0.1)
    var body: some View {
        // Header toggle + rows (plain stack — the Studio page is not a Form).
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { jitter != nil },
                set: { jitter = $0 ? defaults : nil })) {
                Text(title).font(.headline)
            }
            if jitter != nil {
                let j = Binding(get: { jitter ?? ColorJitter() }, set: { jitter = $0 })
                slider("Hue", j.hue); slider("Saturation", j.saturation); slider("Brightness", j.brightness)
            }
        }
        .padding(.top, 8)
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
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var curve: ResponseCurve
    let sensor: BrushSensor?
    private static let xs: [Double] = [0, 0.25, 0.5, 0.75, 1.0]
    @State private var ys: [Double]
    @State private var dragging = false

    init(curve: Binding<ResponseCurve>, sensor: BrushSensor?) {
        _curve = curve
        self.sensor = sensor
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
                // LIVE input marker: where the current sensor value lands on the curve (moves as
                // you draw). Reading liveBrushInput scopes the ~20 Hz re-render to this editor only.
                if let sensor, let sx = coordinator.liveBrushInput?.value(for: sensor) {
                    let sy = curve.value(sx)
                    Path { p in
                        p.move(to: CGPoint(x: sx * w, y: h)); p.addLine(to: CGPoint(x: sx * w, y: (1 - sy) * h))
                    }.stroke(Color.red.opacity(0.6), lineWidth: 1)
                    Circle().fill(Color.red).frame(width: 11, height: 11)
                        .position(x: sx * w, y: (1 - sy) * h)
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

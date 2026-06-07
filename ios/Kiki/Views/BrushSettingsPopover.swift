import SwiftUI
import CanvasModule

/// Secondary brush controls, shown in a popover from the sidebar gear button.
/// Vertically stacked labeled sliders. The native `.popover` dismisses on a tap
/// outside (pen or finger). See pro-brush-roadmap Phases 0–2.
struct BrushSettingsPopover: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(alignment: .leading, spacing: 18) {
            sliderRow("Opacity", value: $coordinator.toolOpacity, range: 0.05...1.0)
            sliderRow("Flow", value: $coordinator.toolFlow, range: 0.05...1.0)
            sliderRow("Stabilize", value: $coordinator.toolStreamline, range: 0.0...1.0)
            sliderRow("Hardness", value: $coordinator.toolHardness, range: 0.0...1.0)
            sliderRow("Spacing", value: $coordinator.toolSpacing, range: 0.02...1.0)
            sliderRow("Taper", value: $coordinator.toolTaper, range: 0.0...1.0)

            Divider()
            Toggle(isOn: $coordinator.toolWetEnabled) {
                Text("Wet paint").font(.subheadline.weight(.medium))
                + Text("  (experimental)").font(.caption).foregroundColor(.secondary)
            }
            if coordinator.toolWetEnabled {
                Toggle(isOn: $coordinator.wetOrderingPerStamp) {
                    Text("Per-stamp draw").font(.caption)
                    + Text("  (debug: draw-order A/B)").font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func sliderRow(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}

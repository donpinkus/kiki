import SwiftUI
import CanvasModule

/// Secondary brush controls, shown in a popover from the sidebar gear button.
/// Vertically stacked labeled sliders, each with a "?" that opens a help popover.
/// The native `.popover` dismisses on a tap outside (pen or finger). See pro-brush-roadmap.
struct BrushSettingsPopover: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        VStack(alignment: .leading, spacing: 18) {
            BrushShapePicker(selection: $coordinator.toolShapeID)

            BrushSliderRow("Opacity", value: $coordinator.toolOpacity, range: 0.05...1.0, help: Self.help["Opacity"]!)
            BrushSliderRow("Flow", value: $coordinator.toolFlow, range: 0.05...1.0, help: Self.help["Flow"]!)
            BrushSliderRow("Stabilize", value: $coordinator.toolStreamline, range: 0.0...1.0, help: Self.help["Stabilize"]!)
            BrushSliderRow("Hardness", value: $coordinator.toolHardness, range: 0.0...1.0, help: Self.help["Hardness"]!)
            BrushSliderRow("Spacing", value: $coordinator.toolSpacing, range: 0.02...1.0, help: Self.help["Spacing"]!)
            BrushSliderRow("Taper", value: $coordinator.toolTaper, range: 0.0...1.0, help: Self.help["Taper"]!)

            Divider()
            Toggle(isOn: $coordinator.toolWetEnabled) {
                Text("Wet paint").font(.subheadline.weight(.medium))
                + Text("  (experimental)").font(.caption).foregroundColor(.secondary)
            }
            if coordinator.toolWetEnabled {
                BrushSliderRow("Mix", value: $coordinator.toolWetStrength, range: 0.05...1.0, help: Self.help["Mix"]!)
                BrushSliderRow("Smear", value: $coordinator.toolWetPickup, range: 0.0...1.0, help: Self.help["Smear"]!)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    // One-sentence summary + what 0% and 100% mean, per control.
    static let help: [String: BrushHelp] = [
        "Opacity": BrushHelp(summary: "How opaque the finished stroke is.",
            low: "Invisible.",
            high: "Fully opaque; overlapping passes within one stroke stay even (no darkening)."),
        "Flow": BrushHelp(summary: "How much paint each dab lays down as you draw.",
            low: "Almost nothing per dab — builds up very gradually.",
            high: "Full paint per dab."),
        "Stabilize": BrushHelp(summary: "Smooths shaky lines by letting the drawn line lag behind the pencil.",
            low: "Follows your hand exactly — every wobble shows.",
            high: "Very smooth and confident, but the line trails behind the pencil."),
        "Hardness": BrushHelp(summary: "How crisp or soft the brush edge is.",
            low: "Soft, feathered airbrush edge.",
            high: "Crisp, sharp edge."),
        "Spacing": BrushHelp(summary: "How far apart the stamped dabs are along the stroke.",
            low: "Dense — a smooth, continuous line.",
            high: "Far apart — you see individual dabs."),
        "Taper": BrushHelp(summary: "Thins the stroke toward its start and end.",
            low: "Uniform width from end to end.",
            high: "Tapers to a point at both ends."),
        "Mix": BrushHelp(summary: "How strongly each dab deposits its color onto the canvas.",
            low: "Barely tints — color builds up slowly.",
            high: "Covers in a single pass."),
        "Smear": BrushHelp(summary: "How much the brush picks up and carries the colors it crosses.",
            low: "No pickup — always lays your color, no blending trail.",
            high: "Soaks up and drags color along the stroke (smudgy, blends).")
    ]
}

/// Brush-tip shape selector (pro-brush Phase 3). A grid of labeled chips; "Round" is the
/// procedural soft circle (`toolShapeID == nil`), the rest bind grayscale stamp textures.
private struct BrushShapePicker: View {
    /// nil == round (procedural).
    @Binding var selection: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    private func isSelected(_ shape: BrushShapeDescriptor) -> Bool {
        (selection ?? BrushShapeCatalog.roundID) == shape.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Shape").font(.subheadline.weight(.medium))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(BrushShapeCatalog.all) { shape in
                    let selected = isSelected(shape)
                    Button {
                        selection = shape.id == BrushShapeCatalog.roundID ? nil : shape.id
                    } label: {
                        Text(shape.displayName)
                            .font(.caption)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(selected ? Color.accentColor.opacity(0.18) : Color.gray.opacity(0.12))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 1.5)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Help text for a brush control: a one-line summary plus the 0% / 100% extremes.
struct BrushHelp {
    let summary: String
    let low: String     // what 0% means
    let high: String    // what 100% means
}

/// A labeled slider with a value readout and a "?" button that opens a help popover.
private struct BrushSliderRow: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let help: BrushHelp
    @State private var showHelp = false

    init(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, help: BrushHelp) {
        self.title = title
        self._value = value
        self.range = range
        self.help = help
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(title).font(.subheadline.weight(.medium))
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHelp) {
                    helpContent.presentationCompactAdaptation(.popover)
                }
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }

    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(help.summary).font(.subheadline)
            VStack(alignment: .leading, spacing: 6) {
                helpRow("0%", help.low)
                helpRow("100%", help.high)
            }
        }
        .padding(16)
        .frame(width: 270)
    }

    private func helpRow(_ label: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            Text(text).font(.caption)
        }
    }
}

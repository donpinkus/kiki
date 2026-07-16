import SwiftUI
import CanvasModule

/// Secondary brush controls, shown in a popover from the sidebar gear button.
/// Vertically stacked labeled sliders, each with a "?" that opens a help popover.
/// The native `.popover` dismisses on a tap outside (pen or finger). See pro-brush-roadmap.
struct BrushSettingsPopover: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        // Controls the wet path doesn't consume (it's a procedural round tip with its own
        // deposit model — no shape texture, no per-dab flow, no taper). Gray them out while
        // Wet paint is on rather than letting them silently do nothing.
        let wet = coordinator.toolWetEnabled

        VStack(alignment: .leading, spacing: 18) {
            PresetPicker()
            Divider()
            Group {
                BrushShapePicker(selection: $coordinator.toolShapeID)
                if coordinator.toolShapeID != nil {
                    BrushSliderRow("Tip lightness", value: $coordinator.toolTipLightness, range: 0.0...1.0, help: Self.help["Tip lightness"]!)
                }
                GrainPicker(selection: $coordinator.toolGrainID)
                if coordinator.toolGrainID != nil {
                    BrushSliderRow("Grain depth", value: $coordinator.toolGrainDepth, range: 0.0...1.0, help: Self.help["Grain depth"]!)
                    BrushSliderRow("Grain scale", value: $coordinator.toolGrainScale, range: 0.5...3.0, help: Self.help["Grain scale"]!,
                                   format: { String(format: "%.1f\u{00D7}", $0) })
                }
            }
            .disabled(wet)
            .opacity(wet ? 0.35 : 1)

            BrushSliderRow("Opacity", value: $coordinator.toolOpacity, range: 0.05...1.0, help: Self.help["Opacity"]!)
            Group {
                BrushSliderRow("Flow", value: $coordinator.toolFlow, range: 0.05...1.0, help: Self.help["Flow"]!)
            }
            .disabled(wet)
            .opacity(wet ? 0.35 : 1)
            BrushSliderRow("Stabilize", value: $coordinator.toolStreamline, range: 0.0...1.0, help: Self.help["Stabilize"]!)
            BrushSliderRow("Smoothing", value: $coordinator.toolStabilization, range: 0.0...1.0, help: Self.help["Smoothing"]!)
            BrushSliderRow("Hardness", value: $coordinator.toolHardness, range: 0.0...1.0, help: Self.help["Hardness"]!)
            BrushSliderRow("Aspect", value: $coordinator.toolAspect, range: 0.1...1.0, help: Self.help["Aspect"]!)
            BrushSliderRow("Spacing", value: $coordinator.toolSpacing, range: 0.02...1.0, help: Self.help["Spacing"]!)
            Group {
                BrushSliderRow("Count", value: $coordinator.toolStampCount, range: 1...8, help: Self.help["Count"]!,
                               format: { "\(Int($0.rounded()))" })
                if coordinator.toolStampCount.rounded() > 1 {
                    BrushSliderRow("Count jitter", value: $coordinator.toolStampCountJitter, range: 0.0...1.0, help: Self.help["Count jitter"]!)
                }
                if coordinator.toolShapeID != nil {
                    BrushSliderRow("Rotation", value: $coordinator.toolRotationFollow, range: -1.0...1.0, help: Self.help["Rotation"]!,
                                   format: { String(format: "%+.0f%%", $0 * 100) })
                    HStack(spacing: 20) {
                        Toggle("Flip X", isOn: $coordinator.toolFlipX)
                        Toggle("Flip Y", isOn: $coordinator.toolFlipY)
                    }
                    .font(.subheadline.weight(.medium))
                }
            }
            .disabled(wet)
            .opacity(wet ? 0.35 : 1)
            Group {
                BrushSliderRow("Taper", value: $coordinator.toolTaper, range: 0.0...1.0, help: Self.help["Taper"]!)
                BrushSliderRow("Fall off", value: $coordinator.toolFallOff, range: 0.0...1.0, help: Self.help["Fall off"]!)
            }
            .disabled(wet)
            .opacity(wet ? 0.35 : 1)

            Divider()
            Toggle(isOn: $coordinator.toolWetEnabled) {
                Text("Wet paint").font(.subheadline.weight(.medium))
                + Text("  (experimental)").font(.caption).foregroundColor(.secondary)
            }
            if coordinator.toolWetEnabled {
                Text("Wet paint uses a round tip — Shape, Flow, Taper and Brush Studio dynamics don't apply. Opacity scales the deposit.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                BrushSliderRow("Mix", value: $coordinator.toolWetStrength, range: 0.05...1.0, help: Self.help["Mix"]!)
                BrushSliderRow("Smear", value: $coordinator.toolWetPickup, range: 0.0...1.0, help: Self.help["Smear"]!)
            }

            Divider()
            Button {
                // Close this popover, then open the Studio sheet (owned by the sidebar) so it
                // presents reliably instead of being cancelled by the popover dismissing.
                coordinator.showBrushSettings = false
                coordinator.showBrushStudio = true
            } label: {
                Label("Brush Studio (dev)", systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.medium))
            }
            if coordinator.toolDynamics != nil {
                Text(wet ? "Dynamics active (ignored while Wet paint is on)" : "Dynamics active")
                    .font(.caption).foregroundColor(.secondary)
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
        "Smoothing": BrushHelp(summary: "Averages the path over the distance drawn for clean, steady curves.",
            low: "No averaging — the path is exactly what Stabilize produces.",
            high: "Very clean curvature; tremors vanish. The stroke still ends where the pencil lifts."),
        "Hardness": BrushHelp(summary: "How crisp or soft the brush edge is.",
            low: "Soft, feathered airbrush edge.",
            high: "Crisp, sharp edge."),
        "Tip lightness": BrushHelp(summary: "Lets the tip's texture lighten and darken the ink (embossed, dimensional strokes).",
            low: "Flat ink — the tip texture only shapes coverage.",
            high: "Full value mapping — dark tip areas darken, light areas lighten; mid-gray = your color."),
        "Grain depth": BrushHelp(summary: "How strongly the paper tooth shows through the stroke.",
            low: "No texture — solid paint.",
            high: "Heavy dry-media break-up; press harder (more flow) to fill the tooth."),
        "Aspect": BrushHelp(summary: "How flat the brush tip is — a calligraphy/chisel nib at low values.",
            low: "A thin flat blade (pair with Rotation dynamics in Brush Studio to steer the nib).",
            high: "Fully round tip."),
        "Spacing": BrushHelp(summary: "How far apart the stamped dabs are along the stroke.",
            low: "Dense — a smooth, continuous line.",
            high: "Far apart — you see individual dabs."),
        "Fall off": BrushHelp(summary: "The stroke's paint gradually runs out as you draw.",
            low: "Never runs out.",
            high: "Fades to nothing within a short distance — like a drying marker."),
        "Grain scale": BrushHelp(summary: "How coarse the paper-grain features are.",
            low: "Fine tooth.",
            high: "Coarse, chunky tooth."),
        "Count": BrushHelp(summary: "How many stamps land at each spacing point (pairs with Scatter in Brush Studio for spray/cluster texture).",
            low: "One stamp per point — the normal stroke.",
            high: "Eight stamps per point, each with its own scatter."),
        "Count jitter": BrushHelp(summary: "Randomly varies the per-point stamp count, so density breathes along the stroke.",
            low: "Always the full Count.",
            high: "Anywhere from one stamp up to the full Count, at random."),
        "Rotation": BrushHelp(summary: "How the tip turns with your stroke direction.",
            low: "−100%: turns opposite to the stroke (mirrored calligraphy).",
            high: "+100%: follows the stroke; 0% holds the tip upright."),
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

/// Curated preset picker (preset-library v1): one-tap full brush recipes. Keeps the
/// user's color/size; every secondary knob below reflects the applied preset.
private struct PresetPicker: View {
    @Environment(AppCoordinator.self) private var coordinator

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Presets").font(.subheadline.weight(.medium))
            LazyVGrid(columns: columns, spacing: 8) {
                chip(nil, "None")
                ForEach(CuratedPresetCatalog.all) { preset in
                    chip(preset.id, preset.displayName)
                }
            }
        }
    }

    private func chip(_ id: String?, _ label: String) -> some View {
        let selected = coordinator.activeCuratedPresetID == id
        return Button {
            if let id, let preset = CuratedPresetCatalog.preset(for: id) {
                coordinator.applyCuratedPreset(preset)
            } else {
                coordinator.clearCuratedPreset()
            }
        } label: {
            Text(label)
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

/// Grain texture selector (P8). "None" = no grain; the rest are the procedural
/// document-space grains from `GrainCatalog`.
private struct GrainPicker: View {
    @Binding var selection: String?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Grain").font(.subheadline.weight(.medium))
            LazyVGrid(columns: columns, spacing: 8) {
                chip(nil, "None")
                ForEach(GrainCatalog.all) { grain in
                    chip(grain.id, grain.displayName)
                }
            }
        }
    }

    private func chip(_ id: String?, _ label: String) -> some View {
        let selected = selection == id
        return Button {
            selection = id
        } label: {
            Text(label)
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
    /// Value readout override (default: percent).
    let format: (CGFloat) -> String
    @State private var showHelp = false

    init(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, help: BrushHelp,
         format: @escaping (CGFloat) -> String = { "\(Int(($0 * 100).rounded()))%" }) {
        self.title = title
        self._value = value
        self.range = range
        self.help = help
        self.format = format
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
                Text(format(value))
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

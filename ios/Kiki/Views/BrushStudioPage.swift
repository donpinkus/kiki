import SwiftUI
import PhotosUI
import CanvasModule

// MARK: - Brush Studio (full page, Procreate-style)
//
// THE brush-editing surface: dark three-pane layout matching Procreate's Brush Studio —
// left rail (sections, blue pill selection), middle controls column, and a large
// interactive DRAWING PAD on the right (live brush; strokes re-render as knobs change).
//
// TAXONOMY (2026-07-17): tabs, group headings, and attribute names mirror Procreate's
// Brush Studio verbatim (documents/research/krita-brush/14-procreate-brush-studio-
// inventory.md) so gaps in our engine are VISIBLE, not hidden: every Procreate
// attribute appears either as a bound control, a "via curves" pointer (capability
// exists in the sensor-curve engine), or a grayed N/A gap row. Kiki-only knobs live
// in "Kiki extensions" groups at the bottom of each tab.

struct BrushStudioPage: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var section: StudioSection = .strokePath
    @State private var showSaveDialog = false
    @State private var saveName = ""
    @State private var padClearToken = 0
    @State private var snapshot: AppCoordinator.BrushStudioSnapshot?
    /// Local mirror of coordinator.toolDynamics (nil ⇄ inert), edited by several
    /// sections. Synced both ways below; Equatable guards break the write cycle.
    @State private var dyn = BrushDynamics()

    var body: some View {
        HStack(spacing: 0) {
            rail
            controls
            padPane
        }
        .background(StudioTheme.page.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear {
            snapshot = coordinator.takeBrushSnapshot()
            dyn = coordinator.toolDynamics ?? BrushDynamics()
        }
        .onChange(of: dyn) { _, new in
            coordinator.toolDynamics = new.isInert ? nil : new
        }
        .onChange(of: coordinator.toolDynamics) { _, new in
            let resolved = new ?? BrushDynamics()
            if resolved != dyn { dyn = resolved }
        }
        .alert("Save as brush", isPresented: $showSaveDialog) {
            TextField("Brush name", text: $saveName)
            Button("Save") {
                coordinator.saveCurrentBrush(named: saveName)
                saveName = ""
            }
            Button("Cancel", role: .cancel) { saveName = "" }
        } message: {
            Text("Saves every setting as a named brush. Color and size stay yours when you apply it later.")
        }
    }

    // MARK: Left rail

    private var rail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Brush Studio")
                .font(.title.weight(.bold))
                .padding(.horizontal, 26)
                .padding(.top, 28)
                .padding(.bottom, 18)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(StudioSection.allCases) { s in
                        Button {
                            section = s
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: s.icon)
                                    .font(.system(size: 17))
                                    .frame(width: 26)
                                Text(s.rawValue)
                                    .font(.body.weight(section == s ? .semibold : .regular))
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(section == s ? StudioTheme.accent : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(section == s ? .white : StudioTheme.railIdle)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 272)
        .background(StudioTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .padding(12)
    }

    // MARK: Middle controls column

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(section.heading)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white.opacity(0.85))
                switch section {
                case .brushes: BrushesSection()
                case .strokePath: StrokePathSection(dyn: $dyn)
                case .stabilization: StabilizationSection()
                case .taper: TaperSection()
                case .shape: ShapeSection(dyn: $dyn)
                case .grain: GrainSection()
                case .rendering: RenderingSection()
                case .wetMix: WetMixSection()
                case .colorDynamics: ColorDynamicsSection(dyn: $dyn)
                case .dynamics: DynamicsSection(dyn: $dyn)
                case .applePencil: ApplePencilSection()
                case .properties: PropertiesSection()
                case .about: AboutSection(onReset: {
                    if let snapshot { coordinator.restoreBrushSnapshot(snapshot) }
                })
                case .developer: DeveloperSection(dyn: $dyn)
                }
            }
            .padding(.horizontal, 30)
            .padding(.top, 34)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 440)
        .id(section)   // reset scroll position when switching sections
    }

    // MARK: Right drawing pad

    private var padPane: some View {
        ZStack(alignment: .top) {
            // The engine's display + touch mapping assume a SQUARE view (canvasScale is a
            // single documentSide/width scalar; the compositor fills the drawable with the
            // square document). A pane-shaped view stretches the display and skews touch→
            // texture mapping vertically (strokes landed below the pencil, 2026-07-17
            // device report). So: size the canvas as a square covering the pane's larger
            // edge, pin it top-leading, and clip — the pad is a window onto a square canvas.
            GeometryReader { geo in
                let side = max(geo.size.width, geo.size.height)
                BrushTryPadView(
                    brush: coordinator.currentBrushConfig(),
                    clearToken: padClearToken,
                    onBrushInputSample: { coordinator.liveBrushInput = $0 },
                    devMaxSpeed: coordinator.devMaxSpeed,
                    devDistancePeriod: coordinator.devDistancePeriod,
                    devFadePeriod: coordinator.devFadePeriod
                )
                .frame(width: side, height: side)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 22))

            HStack(spacing: 10) {
                padChipLabel {
                    HStack(spacing: 8) {
                        Image(systemName: "scribble.variable")
                        Text("Drawing Pad").font(.subheadline.weight(.semibold))
                    }
                }
                Button { padClearToken += 1 } label: {
                    padChipLabel { Text("Clear").font(.subheadline.weight(.medium)) }
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    saveName = defaultSaveName
                    showSaveDialog = true
                } label: {
                    padChipLabel { Text("Save as brush").font(.subheadline.weight(.medium)) }
                }
                .buttonStyle(.plain)
                Button {
                    if let snapshot { coordinator.restoreBrushSnapshot(snapshot) }
                    coordinator.showBrushStudio = false
                } label: {
                    padChipLabel { Text("Cancel").font(.subheadline.weight(.medium)) }
                }
                .buttonStyle(.plain)
                Button {
                    coordinator.showBrushStudio = false
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(StudioTheme.accent)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
        }
        .padding(.vertical, 12)
        .padding(.trailing, 12)
    }

    private var defaultSaveName: String {
        if let id = coordinator.activeCustomBrushID,
           let saved = coordinator.customBrushLibrary.brush(for: id) {
            return saved.name
        }
        if let id = coordinator.activeCuratedPresetID,
           let preset = CuratedPresetCatalog.preset(for: id) {
            return preset.displayName
        }
        return ""
    }

    private func padChipLabel(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(StudioTheme.padChip)
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
    }
}

// MARK: - Theme + sections

enum StudioTheme {
    static let page = Color(red: 0.082, green: 0.082, blue: 0.090)
    static let card = Color(red: 0.129, green: 0.129, blue: 0.141)
    static let chip = Color.white.opacity(0.08)
    static let padChip = Color(red: 0.16, green: 0.16, blue: 0.175)
    static let accent = Color(red: 0.23, green: 0.51, blue: 0.96)
    static let railIdle = Color.white.opacity(0.62)
}

/// Procreate's Brush Studio attribute list (their order), plus Kiki's Brushes (library)
/// on top and Developer at the bottom. Materials (3D-only) and Preview (replaced by the
/// live drawing pad) are intentionally absent.
enum StudioSection: String, CaseIterable, Identifiable {
    case brushes = "Brushes"
    case strokePath = "Stroke Path"
    case stabilization = "Stabilization"
    case taper = "Taper"
    case shape = "Shape"
    case grain = "Grain"
    case rendering = "Rendering"
    case wetMix = "Wet Mix"
    case colorDynamics = "Color Dynamics"
    case dynamics = "Dynamics"
    case applePencil = "Apple Pencil"
    case properties = "Properties"
    case about = "About this brush"
    case developer = "Developer"

    var id: String { rawValue }

    var heading: String {
        switch self {
        case .strokePath: return "Stroke properties"
        default: return rawValue
        }
    }

    var icon: String {
        switch self {
        case .brushes: return "paintbrush.pointed"
        case .strokePath: return "scribble"
        case .stabilization: return "scribble.variable"
        case .taper: return "pencil.tip"
        case .shape: return "seal"
        case .grain: return "circle.grid.3x3"
        case .rendering: return "drop.halffull"
        case .wetMix: return "drop"
        case .colorDynamics: return "paintpalette"
        case .dynamics: return "gauge.with.needle"
        case .applePencil: return "pencil"
        case .properties: return "list.bullet"
        case .about: return "info.circle"
        case .developer: return "wrench.and.screwdriver"
        }
    }
}

// MARK: - Brushes (saved + curated presets)

private struct BrushesSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var renamingBrush: SavedBrush?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 118), spacing: 8)]

    var body: some View {
        if !coordinator.customBrushLibrary.brushes.isEmpty {
            StudioGroup("My brushes") {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(coordinator.customBrushLibrary.brushes) { saved in
                        StudioChip(label: saved.name,
                                   selected: coordinator.activeCustomBrushID == saved.id) {
                            coordinator.applySavedBrush(saved)
                        }
                        .contextMenu {
                            Button("Rename…") {
                                renameText = saved.name
                                renamingBrush = saved
                            }
                            Button("Overwrite with current settings") {
                                coordinator.customBrushLibrary.update(
                                    saved.id, config: coordinator.currentBrushConfig())
                            }
                            Button("Delete", role: .destructive) {
                                coordinator.customBrushLibrary.delete(saved.id)
                                if coordinator.activeCustomBrushID == saved.id {
                                    coordinator.activeCustomBrushID = nil
                                }
                            }
                        }
                    }
                }
                StudioFootnote("Tap to apply. Touch and hold to rename, overwrite, or delete.")
            }
        }
        StudioGroup("Presets") {
            LazyVGrid(columns: columns, spacing: 8) {
                StudioChip(label: "None",
                           selected: coordinator.activeCuratedPresetID == nil
                                     && coordinator.activeCustomBrushID == nil) {
                    coordinator.clearCuratedPreset()
                }
                ForEach(CuratedPresetCatalog.all) { preset in
                    StudioChip(label: preset.displayName,
                               selected: coordinator.activeCuratedPresetID == preset.id) {
                        coordinator.applyCuratedPreset(preset)
                    }
                }
            }
            StudioFootnote("Presets keep your color and size. \u{201C}None\u{201D} resets every knob to the plain pen.")
        }
        .alert("Rename brush", isPresented: Binding(
            get: { renamingBrush != nil },
            set: { if !$0 { renamingBrush = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let brush = renamingBrush {
                    coordinator.customBrushLibrary.rename(brush.id, to: renameText)
                }
                renamingBrush = nil
            }
            Button("Cancel", role: .cancel) { renamingBrush = nil }
        }
    }
}

// MARK: - Stroke Path

private struct StrokePathSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var dyn: BrushDynamics

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        BrushSliderRow("Spacing", value: $coordinator.toolSpacing, range: 0.02...1.0, help: BrushHelpCatalog.help["Spacing"]!)
        Group {
            BrushSliderRow("Spacing Jitter", value: $coordinator.toolSpacingJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Spacing Jitter"]!)
            CurveAmountSlider(title: "Jitter Lateral", option: $dyn.scatterLateral,
                              defaultSensors: [], help: BrushHelpCatalog.help["Jitter Lateral"]!)
            CurveAmountSlider(title: "Jitter Linear", option: $dyn.scatterLinear,
                              defaultSensors: [], help: BrushHelpCatalog.help["Jitter Linear"]!)
            BrushSliderRow("Fall Off", value: $coordinator.toolFallOff, range: 0.0...1.0, help: BrushHelpCatalog.help["Fall Off"]!)
        }
        .disabled(wet).opacity(wet ? 0.35 : 1)
        StudioFootnote("Jitter amounts can also be pressure-driven: Dynamics tab → Scatter ⊥ / Scatter ∥ curves.")
        if wet { WetGateFootnote() }
    }
}

// MARK: - Stabilization

private struct StabilizationSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        StudioGroup("StreamLine") {
            BrushSliderRow("Amount", value: $coordinator.toolStreamline, range: 0.0...1.0, help: BrushHelpCatalog.help["StreamLine Amount"]!)
            BrushSliderRow("Pressure", value: $coordinator.toolPressureSmoothing, range: 0.0...1.0, help: BrushHelpCatalog.help["StreamLine Pressure"]!)
        }
        StudioGroup("Stabilization") {
            BrushSliderRow("Amount", value: $coordinator.toolStabilization, range: 0.0...1.0, help: BrushHelpCatalog.help["Stabilization Amount"]!)
        }
        StudioGroup("Motion Filtering") {
            GapRow("Amount", note: "Wobble-extremity filtering without averaging — not in Kiki's engine (our Stabilization is a distance-Gaussian).")
            GapRow("Expression", note: "Counteracts over-smoothing — depends on Motion Filtering.")
        }
    }
}

// MARK: - Taper

private struct TaperSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        StudioGroup("Pressure Taper") {
            Group {
                BrushSliderRow("Start", value: $coordinator.toolTaperStart, range: 0.0...1.0, help: BrushHelpCatalog.help["Taper Start"]!)
                BrushSliderRow("End", value: $coordinator.toolTaperEnd, range: 0.0...1.0, help: BrushHelpCatalog.help["Taper End"]!)
                BrushSliderRow("Opacity", value: $coordinator.toolTaperOpacity, range: 0.0...1.0, help: BrushHelpCatalog.help["Taper Opacity"]!)
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
            GapRow("Link Tip Sizes", note: "Both taper ends share one tip size.")
            GapRow("Size", note: "Severity of the thick→thin transition — Kiki's taper profile is fixed.")
            GapRow("Pressure", note: "Toggle taper responding to pencil pressure.")
            GapRow("Tip", note: "Fine vs chunky taper tip.")
            GapRow("Tip Animation", note: "Animates the tip while drawing.")
        }
        StudioGroup("Touch Taper") {
            GapRow("Touch Taper", note: "Separate taper for finger strokes — Kiki applies one taper to all input.")
        }
        StudioGroup("Properties") {
            GapRow("Classic Taper", note: "Legacy Procreate taper behavior.")
        }
        if wet { WetGateFootnote() }
    }
}

// MARK: - Shape

private struct ShapeSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var dyn: BrushDynamics

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        StudioGroup("Shape Source") {
            Group {
                BrushShapePicker(selection: $coordinator.toolShapeID)
                UserAssetPicker(kind: .shape, selection: $coordinator.toolShapeID)
                StudioFootnote("Imported tips read luminance as coverage (white = paint). They stamp upright by default — steer with Rotation, Azimuth, or Scatter.")
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
        }
        StudioGroup("Behavior") {
            Group {
                if coordinator.toolShapeID != nil {
                    BrushSliderRow("Rotation", value: $coordinator.toolRotationFollow, range: -1.0...1.0, help: BrushHelpCatalog.help["Rotation"]!,
                                   format: { String(format: "%+.0f%%", $0 * 100) })
                }
                Toggle(isOn: Binding(
                    get: { dyn.rotation?.sensors.contains { $0.sensor == .tiltDirection } ?? false },
                    set: { on in
                        dyn.rotation = on
                            ? CurveOption(sensors: [SensorChannel(sensor: .tiltDirection)], fold: .rotationLike)
                            : nil
                    })) {
                    Text("Azimuth").font(.subheadline.weight(.medium))
                }
                StudioFootnote("Azimuth: the pencil's tilt direction orients the tip (overrides stroke-direction rotation).")
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
            GapRow("Azimuth and barrel roll", note: "Pencil Pro barrel-roll input isn't read yet.")
        }
        StudioGroup("Properties") {
            Group {
                BrushSliderRow("Scatter", value: $coordinator.toolRotationJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Scatter"]!)
                Toggle("Randomized", isOn: $coordinator.toolRandomizedRotation)
                    .font(.subheadline.weight(.medium))
                StudioFootnote("Randomized: one random tip rotation per stroke (Scatter above is per stamp).")
                BrushSliderRow("Count", value: $coordinator.toolStampCount, range: 1...8, help: BrushHelpCatalog.help["Count"]!,
                               format: { "\(Int($0.rounded()))" })
                if coordinator.toolStampCount.rounded() > 1 {
                    BrushSliderRow("Count Jitter", value: $coordinator.toolStampCountJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Count Jitter"]!)
                }
                if coordinator.toolShapeID != nil {
                    HStack(spacing: 24) {
                        Toggle("Flip X", isOn: $coordinator.toolFlipX)
                        Toggle("Flip Y", isOn: $coordinator.toolFlipY)
                    }
                    .font(.subheadline.weight(.medium))
                }
                BrushSliderRow("Roundness", value: $coordinator.toolAspect, range: 0.1...1.0, help: BrushHelpCatalog.help["Roundness"]!)
                BrushSliderRow("Pressure Roundness", value: Binding(
                    get: { 1 - CGFloat(dyn.ratio?.minValue ?? 1) },
                    set: { v in
                        dyn.ratio = v <= 0.005 ? nil
                            : CurveOption(sensors: [SensorChannel(sensor: .pressure)], minValue: Double(1 - v))
                    }), range: 0.0...1.0, help: BrushHelpCatalog.help["Pressure Roundness"]!)
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
            GapRow("Tilt Roundness", note: "Tilt-driven squash — configurable via Dynamics → Roundness curve + TiltElevation sensor.")
            GapRow("Roundness Jitter (vert/horiz)", note: "Random per-stamp squash.")
        }
        StudioGroup("Filtering") {
            GapRow("No / Classic / Improved Filtering", note: "Tip-texture resampling modes — Kiki uses mipmapped sampling only.")
        }
        StudioGroup("Kiki extensions") {
            BrushSliderRow("Hardness", value: $coordinator.toolHardness, range: 0.0...1.0, help: BrushHelpCatalog.help["Hardness"]!)
            BrushSliderRow("Angle", value: $coordinator.toolTipAngle, range: 0...(.pi), help: BrushHelpCatalog.help["Angle"]!,
                           format: { "\(Int(($0 * 180 / .pi).rounded()))\u{00B0}" })
            if coordinator.toolShapeID != nil {
                Group {
                    BrushSliderRow("Tip lightness", value: $coordinator.toolTipLightness, range: 0.0...1.0, help: BrushHelpCatalog.help["Tip lightness"]!)
                }
                .disabled(wet).opacity(wet ? 0.35 : 1)
            }
        }
        if wet { WetGateFootnote() }
    }
}

// MARK: - Grain

private struct GrainSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        StudioGroup("Grain Source") {
            Group {
                GrainPicker(selection: $coordinator.toolGrainID)
                UserAssetPicker(kind: .grain, selection: $coordinator.toolGrainID)
                StudioFootnote("Imported grains tile at their native pixel size (Scale multiplies). Screenshots of Procreate grains work — the engine reads them grayscale.")
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
        }
        if coordinator.toolGrainID != nil {
            StudioGroup("Behavior") {
                Group {
                    HStack(spacing: 8) {
                        StudioChip(label: "Moving", selected: coordinator.toolGrainMoving) {
                            coordinator.toolGrainMoving = true
                        }
                        StudioChip(label: "Texturized", selected: !coordinator.toolGrainMoving) {
                            coordinator.toolGrainMoving = false
                        }
                    }
                    StudioFootnote(coordinator.toolGrainMoving
                         ? "Moving: the grain rides with the stroke — sized and centered per stroke."
                         : "Texturized: the grain is anchored to the canvas at a fixed size — overlapping strokes reveal one consistent pattern.")
                    if coordinator.toolGrainMoving {
                        BrushSliderRow("Movement", value: $coordinator.toolGrainMovement, range: 0.0...1.0, help: BrushHelpCatalog.help["Grain Movement"]!,
                                       format: { $0 > 0.97 ? "Rolling" : ($0 < 0.03 ? "Smear" : "\(Int(($0 * 100).rounded()))%") })
                        BrushSliderRow("Zoom", value: $coordinator.toolGrainZoom, range: 0.0...1.0, help: BrushHelpCatalog.help["Grain Zoom"]!,
                                       format: { $0 < 0.03 ? "Follow size" : ($0 > 0.97 ? "Cropped" : "\(Int(($0 * 100).rounded()))%") })
                    }
                }
                .disabled(wet).opacity(wet ? 0.35 : 1)
            }
            StudioGroup("Settings") {
                Group {
                    BrushSliderRow("Scale", value: $coordinator.toolGrainScale, range: 0.5...3.0, help: BrushHelpCatalog.help["Grain Scale"]!,
                                   format: { String(format: "%.1f\u{00D7}", $0) })
                    BrushSliderRow("Depth", value: $coordinator.toolGrainDepth, range: 0.0...1.0, help: BrushHelpCatalog.help["Grain Depth"]!)
                    BrushSliderRow("Depth Jitter", value: $coordinator.toolGrainDepthJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Grain Depth Jitter"]!)
                }
                .disabled(wet).opacity(wet ? 0.35 : 1)
                GapRow("Rotation", note: "Grain rotation vs stroke direction.")
                GapRow("Depth Minimum", note: "Floor for pressure-driven depth (curve Min in Dynamics → Grain).")
                GapRow("Offset Jitter", note: "Random grain offset per stamp.")
                GapRow("Blend Mode", note: "Grain blend mode — Kiki grain is multiplicative carve only.")
                GapRow("Brightness / Contrast", note: "Grain texture pre-adjustment.")
            }
        }
        if wet { WetGateFootnote() }
    }
}

// MARK: - Rendering

private struct RenderingSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    private static let modes: [(String, Bool)] = [
        ("Light Glaze", true),          // ≈ Kiki's flow/opacity split ("Glaze")
        ("Uniformed Glaze", false),
        ("Intense Glaze", false),
        ("Heavy Glaze", false),
        ("Uniform Blending", false),
        ("Intense Blending", false),
    ]

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        StudioGroup("Rendering Mode") {
            VStack(spacing: 6) {
                ForEach(Self.modes, id: \.0) { mode in
                    HStack {
                        Text(mode.0).font(.body.weight(.medium))
                            .foregroundStyle(mode.1 ? .white : .white.opacity(0.3))
                        Spacer()
                        if mode.1 {
                            Image(systemName: "checkmark").font(.subheadline.weight(.bold))
                                .foregroundStyle(StudioTheme.accent)
                        } else {
                            Text("N/A").font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.3))
                        }
                    }
                    .padding(.vertical, 8).padding(.horizontal, 14)
                    .background(mode.1 ? StudioTheme.chip : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            StudioFootnote("Kiki has one rendering mode ≈ Light Glaze (per-dab Flow builds up inside the stroke; Opacity caps the whole stroke). The heavier glazes and the two wet Blending modes are engine gaps — Kiki's wet engine is toggled in Wet Mix instead.")
        }
        StudioGroup("Blending") {
            Group {
                BrushSliderRow("Flow", value: $coordinator.toolFlow, range: 0.05...1.0, help: BrushHelpCatalog.help["Flow"]!)
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
            GapRow("Wet Edges", note: "Pigment bleeding into the paper at stroke edges (roadmap spike exists).")
            GapRow("Burnt Edges", note: "Color-burn where strokes overlap (+ blend-mode choice).")
            GapRow("Blend Mode", note: "Whole-stroke blend mode (multiply, screen, …) — Kiki strokes are source-over only.")
            GapRow("Luminance Blending", note: "Luminance-weighted stroke blending.")
            GapRow("Alpha Threshold", note: "Hard-clips low-alpha stroke fringes.")
        }
        StudioGroup("Kiki extensions") {
            BrushSliderRow("Opacity", value: $coordinator.toolOpacity, range: 0.05...1.0, help: BrushHelpCatalog.help["Opacity"]!)
        }
        if wet { WetGateFootnote() }
    }
}

// MARK: - Wet Mix

private struct WetMixSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        Toggle(isOn: $coordinator.toolWetEnabled) {
            Text("Wet paint").font(.subheadline.weight(.medium))
            + Text("  (experimental)").font(.caption).foregroundColor(.secondary)
        }
        StudioFootnote("Procreate enables wet paint via the Blending rendering modes; Kiki uses this toggle. Wet paint uses a round tip — Shape, Flow, Taper and Dynamics don't apply; Opacity scales the deposit.")
        if coordinator.toolWetEnabled {
            GapRow("Dilution", note: "Water-transparency — deliberately folded into Attack + Opacity in Kiki's KM engine (decision 2026-07-16).")
            BrushSliderRow("Charge", value: $coordinator.toolWetCharge, range: 0.05...1.0, help: BrushHelpCatalog.help["Charge"]!)
            BrushSliderRow("Attack", value: $coordinator.toolWetStrength, range: 0.05...1.0, help: BrushHelpCatalog.help["Attack"]!)
            BrushSliderRow("Pull", value: $coordinator.toolWetPickup, range: 0.0...1.0, help: BrushHelpCatalog.help["Pull"]!)
            GapRow("Grade", note: "Chunkiness/contrast of the wet brush texture.")
            BrushSliderRow("Blur", value: $coordinator.toolWetBlur, range: 0.0...1.0, help: BrushHelpCatalog.help["Blur"]!)
            GapRow("Blur Jitter", note: "Random per-stamp blur.")
            BrushSliderRow("Wetness Jitter", value: $coordinator.toolWetJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Wetness Jitter"]!)
            StudioGroup("Kiki extensions") {
                BrushSliderRow("Refill", value: $coordinator.toolWetRefill, range: 0.0...1.0, help: BrushHelpCatalog.help["Refill"]!)
            }
        }
        StudioGroup("Smudge") {
            Toggle("Smudge mode (push canvas color, no new ink)",
                   isOn: $coordinator.toolWetSmudge)
                .font(.subheadline.weight(.medium))
            StudioFootnote("Smudge uses the wet engine: Attack and Pull above set its strength and pickup.")
        }
    }
}

// MARK: - Color Dynamics

private struct ColorDynamicsSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var dyn: BrushDynamics

    var body: some View {
        StudioGroup("Secondary color (Kiki)") {
            ColorPicker("Ink 2", selection: Binding(
                get: { coordinator.toolSecondaryColor ?? .yellow },
                set: { coordinator.toolSecondaryColor = $0 }), supportsOpacity: false)
                .font(.subheadline.weight(.medium))
            Toggle("Enabled", isOn: Binding(
                get: { coordinator.toolSecondaryColor != nil },
                set: { coordinator.toolSecondaryColor = $0 ? .yellow : nil }))
                .font(.subheadline.weight(.medium))
            StudioFootnote("Procreate picks the secondary color in the color companion; Kiki sets it here. The blends below drive how much of it shows.")
        }
        ColorJitterSection(title: "Stamp Color Jitter", jitter: $dyn.dabColorJitter,
                           defaults: ColorJitter(hue: 0.01, saturation: 0.08, brightness: 0.08))
        GapRow("Stamp Color Jitter → Secondary Color", note: "Random per-stamp secondary blend — approximate via Dynamics → Secondary blend + Fuzzy (dab) sensor.")
        ColorJitterSection(title: "Stroke Color Jitter", jitter: $dyn.colorJitter)
        GapRow("Stroke Color Jitter → Secondary Color", note: "Per-stroke random secondary blend.")
        StudioGroup("Color Pressure") {
            CurveAmountSlider(title: "Secondary Color", option: $dyn.secondary,
                              defaultSensors: [.pressure], help: BrushHelpCatalog.help["Color Pressure Secondary"]!)
            GapRow("Hue", note: "Pressure shifts hue.")
            GapRow("Saturation", note: "Pressure shifts saturation.")
            GapRow("Brightness", note: "Pressure shifts brightness — approximate via Dynamics → Darkness curve.")
        }
        StudioGroup("Color Tilt") {
            GapRow("Hue / Saturation / Lightness / Secondary", note: "Tilt-driven color — no tilt→color mapping in Kiki yet (tilt sensors exist; color targets don't).")
        }
        StudioFootnote("Brightness ≈ Procreate's Lightness (symmetric); Darkness is the one-sided darken jitter.")
    }
}

// MARK: - Dynamics (Procreate: speed + jitter; Kiki: the full sensor-curve engine)

private struct DynamicsSection: View {
    @Binding var dyn: BrushDynamics

    var body: some View {
        StudioGroup("Speed") {
            CurvePointerRow("Size", note: "Dynamics engine below: enable the Size curve and add the Speed sensor (fast = thin by inverting the curve).")
            CurvePointerRow("Opacity", note: "Flow curve + Speed sensor.")
            CurvePointerRow("Spacing", note: "Spacing curve + Speed sensor.")
        }
        StudioGroup("Jitter") {
            CurvePointerRow("Size", note: "Size curve + Fuzzy (dab) sensor.")
            CurvePointerRow("Opacity", note: "Flow curve + Fuzzy (dab) sensor.")
        }
        StudioGroup("Kiki sensor-curve engine") {
            StudioFootnote("Superset of Procreate's Dynamics: any sensor (pressure, tilt, speed, distance, fade, fuzzy…) drives any parameter through an editable response curve. Draw in the pad — the red marker rides the live curve.")
            CurveToggleSection(title: "Size", option: $dyn.size, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Flow", option: $dyn.flow, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Rotation", option: $dyn.rotation, fold: .rotationLike, defaultSensor: .drawingAngle)
            CurveToggleSection(title: "Scatter", option: $dyn.scatter, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Scatter \u{22A5} (across)", option: $dyn.scatterLateral, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Scatter \u{2225} (along)", option: $dyn.scatterLinear, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Roundness", option: $dyn.ratio, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Spacing", option: $dyn.spacing, fold: .sizeLike, defaultSensor: .speed)
            CurveToggleSection(title: "Darkness", option: $dyn.darkness, fold: .sizeLike, defaultSensor: .pressure)
            CurveToggleSection(title: "Grain (moving)", option: $dyn.grain, fold: .sizeLike, defaultSensor: .pressure)
        }
    }
}

// MARK: - Apple Pencil

private struct ApplePencilSection: View {
    var body: some View {
        StudioGroup("Pressure") {
            GapRow("Pressure graph", note: "Dedicated pressure response graph — Kiki's equivalent is the per-parameter curve editors (Dynamics tab).")
            CurvePointerRow("Size", note: "Size curve + Pressure sensor.")
            CurvePointerRow("Opacity", note: "Flow curve + Pressure sensor.")
            CurvePointerRow("Flow", note: "Flow curve + Pressure sensor.")
            GapRow("Bleed", note: "Pressure-driven edge bleed.")
        }
        StudioGroup("Tilt") {
            GapRow("Tilt graph / trigger angle", note: "Angle threshold where tilt kicks in.")
            CurvePointerRow("Size", note: "Size curve + TiltElevation sensor.")
            CurvePointerRow("Opacity", note: "Flow curve + TiltElevation sensor.")
            GapRow("Gradation", note: "Shading softness on an angle.")
            GapRow("Bleed", note: "Tilt-driven edge bleed.")
            GapRow("Size Compression", note: "Compresses tilt size range.")
        }
        StudioGroup("Barrel Roll (Pencil Pro)") {
            GapRow("Size / Opacity / Bleed / Relative to stroke", note: "Barrel-roll input isn't read yet (UIKit rollAngle, iOS 17.5+).")
        }
        StudioGroup("Cursor & Hover") {
            GapRow("Cursor Outline / Hover preview", note: "Pencil hover UI — not applicable to Kiki yet.")
        }
    }
}

// MARK: - Properties

private struct PropertiesSection: View {
    var body: some View {
        StudioGroup("Brush Behavior") {
            GapRow("Use Stamp Preview", note: "Library thumbnail as a stamp — Kiki's library shows names (thumbnails planned).")
            GapRow("Orient to Screen", note: "Rotates the brush with the canvas.")
            GapRow("Preview Size", note: "Library preview scale.")
            CurvePointerRow("Smudge Pull", note: "Wet Mix tab: Smudge mode + Pull set the smudge strength.")
        }
        StudioGroup("Brush Limits") {
            GapRow("Maximum / Minimum Size", note: "Per-brush bounds for the sidebar size slider — Kiki's slider range is global.")
            GapRow("Maximum / Minimum Opacity", note: "Per-brush bounds for the opacity slider.")
        }
    }
}

// MARK: - About this brush

private struct AboutSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    let onReset: () -> Void

    var body: some View {
        StudioGroup("This brush") {
            HStack {
                Text(label).font(.title3.weight(.semibold))
                Spacer()
            }
            if let id = coordinator.activeCustomBrushID,
               let saved = coordinator.customBrushLibrary.brush(for: id) {
                Text("Saved \(saved.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.white.opacity(0.5))
            }
        }
        StudioGroup("Reset") {
            Button("Reset to opened state") { onReset() }
                .buttonStyle(.bordered)
            StudioFootnote("Restores every knob to how it was when you opened the Studio (same as Cancel, without closing). Procreate's reset points aren't implemented — Save as brush is the Kiki equivalent.")
        }
    }

    private var label: String {
        if let id = coordinator.activeCustomBrushID,
           let saved = coordinator.customBrushLibrary.brush(for: id) {
            return saved.name
        }
        if let id = coordinator.activeCuratedPresetID,
           let preset = CuratedPresetCatalog.preset(for: id) {
            return preset.displayName
        }
        return "Custom brush"
    }
}

/// One-line explanation shown at the bottom of sections whose controls are wet-gated.
private struct WetGateFootnote: View {
    var body: some View {
        StudioFootnote("Dimmed controls don't apply while Wet paint is on (it uses a round procedural tip with its own deposit model).")
    }
}

// MARK: - Developer (test brushes, engine knobs, stroke recorder)

private struct DeveloperSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var dyn: BrushDynamics
    @State private var recordingShareItem: RecordingShareItem?
    @State private var uploadNote = ""
    @State private var uploadState: FixtureUploadState = .idle
    @State private var uploadError: String = ""

    var body: some View {
        @Bindable var coordinator = coordinator

        StudioGroup("Control-isolation test brushes") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button("Default Pen") {
                        coordinator.resetBrushDynamics()
                        dyn = BrushDynamics()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    ForEach(BrushPresetCatalog.all) { preset in
                        Button(preset.name) {
                            coordinator.applyBrushPreset(preset)
                            dyn = preset.dynamics
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if let note = coordinator.activeTestNote {
                Text(note).font(.caption).foregroundStyle(StudioTheme.accent)
            }
        }

        StudioGroup("Engine") {
            Toggle("Live input HUD", isOn: $coordinator.showInputHUD)
                .font(.subheadline.weight(.medium))
            devSlider("Max speed", value: $coordinator.devMaxSpeed, range: 500...30000, fmt: "%.0f")
            devSlider("Distance period", value: $coordinator.devDistancePeriod, range: 100...4000, fmt: "%.0f")
            devSlider("Fade period", value: $coordinator.devFadePeriod, range: 8...512, fmt: "%.0f")
        }

        StudioGroup("Stroke recorder (BrushHarness fixtures)") {
            Toggle("Record strokes", isOn: $coordinator.isRecordingStrokes)
                .font(.subheadline.weight(.medium))
            StudioFootnote("Recording captures strokes drawn on the CANVAS (not this pad) — close the Studio, draw, then come back to upload.")
            TextField("Note (what's wrong / what to look at)", text: $uploadNote)
                .font(.caption)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text("\(coordinator.recordedStrokes.count) stroke\(coordinator.recordedStrokes.count == 1 ? "" : "s") recorded")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                // .borderless kept: one-tap-fires-every-button hazard (2026-07-15/16).
                Button("Clear") {
                    coordinator.recordedStrokes.removeAll()
                    uploadState = .idle
                }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(coordinator.recordedStrokes.isEmpty)
                Button("Share…") {
                    if let url = coordinator.exportRecordedStrokesURL() {
                        recordingShareItem = RecordingShareItem(url: url)
                    }
                }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(coordinator.recordedStrokes.isEmpty)
                Button(uploadState == .uploading ? "Uploading…" : "Upload") {
                    uploadState = .uploading
                    let note = uploadNote
                    Task {
                        let err = await coordinator.uploadRecordedFixture(note: note.isEmpty ? nil : note)
                        uploadError = err ?? ""
                        uploadState = err == nil ? .done : .failed
                    }
                }
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
                    .disabled(coordinator.recordedStrokes.isEmpty || uploadState == .uploading)
            }
            switch uploadState {
            case .idle, .uploading:
                EmptyView()
            case .done:
                Text("Uploaded ✓ — strokes + canvas snapshot are in Insights (fetch-fixtures.sh)")
                    .font(.caption2).foregroundStyle(.green)
            case .failed:
                Text("Upload failed: \(uploadError). The recording is saved — Share… still works.")
                    .font(.caption2).foregroundStyle(.red)
            }
            if coordinator.recordedStrokes.isEmpty, let last = coordinator.lastRecordingURL {
                Button("Share last recording…") {
                    recordingShareItem = RecordingShareItem(url: last)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            StudioFootnote("Upload sends the stroke data (for exact replay) + a PNG of the canvas to Kiki Insights — a one-tap brush bug report. Share… is the offline AirDrop fallback.")
        }
        .sheet(item: $recordingShareItem) { item in
            ShareSheet(activityItems: [item.url])
        }
    }

    private func devSlider(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, fmt: String) -> some View {
        HStack {
            Text(label).font(.caption).frame(width: 110, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: fmt, value.wrappedValue)).font(.caption.monospaced()).frame(width: 60)
        }
    }
}

/// Identifiable URL wrapper for `.sheet(item:)` (same pattern as ReplayShareItem).
private struct RecordingShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

private enum FixtureUploadState { case idle, uploading, done, failed }

// MARK: - Shared building blocks

/// A titled sub-group inside a section column (replaces Form's Section on the dark page).
struct StudioGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.45))
                .kerning(0.6)
            content
        }
        .padding(.top, 8)
    }
}

/// Small secondary explanatory text.
struct StudioFootnote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2).foregroundStyle(.white.opacity(0.45))
    }
}

/// A Procreate attribute Kiki doesn't support yet — a VISIBLE gap (the point of the
/// Procreate-taxonomy exercise). Grayed, with an "N/A" chip and a why/where note.
struct GapRow: View {
    let title: String
    var note: String?

    init(_ title: String, note: String? = nil) {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.35))
                Spacer()
                Text("N/A")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Capsule())
                    .foregroundStyle(.white.opacity(0.3))
            }
            if let note {
                Text(note).font(.caption2).foregroundStyle(.white.opacity(0.3))
            }
        }
    }
}

/// A Procreate attribute whose CAPABILITY exists in Kiki, but through the sensor-curve
/// engine rather than a dedicated slider.
struct CurvePointerRow: View {
    let title: String
    let note: String

    init(_ title: String, note: String) {
        self.title = title
        self.note = note
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("via curves")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(StudioTheme.accent.opacity(0.18))
                    .clipShape(Capsule())
                    .foregroundStyle(StudioTheme.accent)
            }
            Text(note).font(.caption2).foregroundStyle(.white.opacity(0.4))
        }
    }
}

/// Procreate-style plain amount slider over a dynamics CurveOption: the slider IS the
/// option's strength — created (with the given default sensors) on first move, cleared
/// at zero. The full curve editor (Dynamics tab) remains the power surface; this keeps
/// the two views consistent because both edit the same option.
struct CurveAmountSlider: View {
    let title: String
    @Binding var option: CurveOption?
    let defaultSensors: [BrushSensor]
    let help: BrushHelp

    var body: some View {
        BrushSliderRow(title, value: Binding(
            get: { CGFloat(option?.strength ?? 0) },
            set: { v in
                if v <= 0.005 {
                    option = nil
                } else if var existing = option {
                    existing.strength = Double(v)
                    option = existing
                } else {
                    option = CurveOption(sensors: defaultSensors.map { SensorChannel(sensor: $0) },
                                         fold: .sizeLike, strength: Double(v))
                }
            }), range: 0...1, help: help)
    }
}

/// A titled dynamics parameter group: header row with enable toggle + full curve editor.
struct CurveToggleSection: View {
    let title: String
    @Binding var option: CurveOption?
    let fold: BrushFold
    let defaultSensor: BrushSensor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { option != nil },
                set: { on in
                    option = on
                        ? CurveOption(sensors: [SensorChannel(sensor: defaultSensor)], fold: fold)
                        : nil
                })) {
                Text(title).font(.headline)
            }
            if option != nil {
                CurveOptionEditor(option: Binding(
                    get: { option ?? CurveOption(sensors: [], fold: fold) },
                    set: { option = $0 }))
            }
        }
        .padding(.top, 8)
    }
}

/// Selectable labeled chip (presets, saved brushes, shapes, grains).
struct StudioChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? StudioTheme.accent : StudioTheme.chip)
                .clipShape(RoundedRectangle(cornerRadius: 9))
                .foregroundStyle(selected ? .white : .white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

/// Brush-tip shape selector. "Round" is the procedural soft circle (`selection == nil`),
/// the rest bind grayscale stamp textures.
struct BrushShapePicker: View {
    /// nil == round (procedural).
    @Binding var selection: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(BrushShapeCatalog.all) { shape in
                StudioChip(label: shape.displayName,
                           selected: (selection ?? BrushShapeCatalog.roundID) == shape.id) {
                    selection = shape.id == BrushShapeCatalog.roundID ? nil : shape.id
                }
            }
        }
    }
}

/// Grain texture selector. "None" = no grain; the rest are the procedural
/// document-space grains from `GrainCatalog`.
struct GrainPicker: View {
    @Binding var selection: String?

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            StudioChip(label: "None", selected: selection == nil) { selection = nil }
            ForEach(GrainCatalog.all) { grain in
                StudioChip(label: grain.displayName, selected: selection == grain.id) {
                    selection = grain.id
                }
            }
        }
    }
}

/// User-imported tips/grains: thumbnail chips + Photos/Paste import + rename/delete.
/// Selection binds straight to toolShapeID / toolGrainID — the engine resolves the
/// asset id lazily from disk, so import is just "write PNG, set id".
struct UserAssetPicker: View {
    let kind: BrushAsset.Kind
    @Binding var selection: String?
    @Environment(AppCoordinator.self) private var coordinator
    @State private var photoItem: PhotosPickerItem?
    @State private var renamingAsset: BrushAsset?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        let items = kind == .shape ? coordinator.brushAssets.shapes : coordinator.brushAssets.grains
        if !items.isEmpty {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(items) { asset in
                    assetChip(asset)
                        .contextMenu {
                            Button("Rename…") {
                                renameText = asset.name
                                renamingAsset = asset
                            }
                            Button("Delete", role: .destructive) {
                                if selection == asset.id { selection = nil }
                                coordinator.brushAssets.delete(asset.id)
                            }
                        }
                }
            }
        }
        HStack(spacing: 8) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Import", systemImage: "photo")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            Button {
                if let image = UIPasteboard.general.image {
                    if let asset = coordinator.brushAssets.importImage(image, kind: kind) {
                        selection = asset.id
                    }
                }
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data),
                   let asset = coordinator.brushAssets.importImage(image, kind: kind) {
                    selection = asset.id
                }
                photoItem = nil
            }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingAsset != nil },
            set: { if !$0 { renamingAsset = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                if let asset = renamingAsset {
                    coordinator.brushAssets.rename(asset.id, to: renameText)
                }
                renamingAsset = nil
            }
            Button("Cancel", role: .cancel) { renamingAsset = nil }
        }
    }

    private func assetChip(_ asset: BrushAsset) -> some View {
        let selected = selection == asset.id
        return Button {
            selection = asset.id
        } label: {
            HStack(spacing: 8) {
                if let image = coordinator.brushAssets.image(for: asset) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Text(asset.name)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(selected ? StudioTheme.accent : StudioTheme.chip)
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .foregroundStyle(selected ? .white : .white.opacity(0.85))
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

/// Procreate-style slider row: label + "?" help left, value chip right, slider below.
/// The chip reads "None" at a zero percent value (matches Procreate's off state).
struct BrushSliderRow: View {
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.body.weight(.medium))
                Button { showHelp = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.35))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showHelp) {
                    helpContent.presentationCompactAdaptation(.popover)
                }
                Spacer()
                Text(chipText)
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(StudioTheme.chip)
                    .clipShape(Capsule())
            }
            Slider(value: $value, in: range)
                .tint(.white.opacity(0.85))
        }
    }

    private var chipText: String {
        let text = format(value)
        return text == "0%" ? "None" : text
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

// MARK: - Help copy

enum BrushHelpCatalog {
    // One-sentence summary + what 0% and 100% mean, per control.
    static let help: [String: BrushHelp] = [
        "Opacity": BrushHelp(summary: "How opaque the finished stroke is.",
            low: "Invisible.",
            high: "Fully opaque; overlapping passes within one stroke stay even (no darkening)."),
        "Flow": BrushHelp(summary: "How much paint each dab lays down as you draw.",
            low: "Almost nothing per dab — builds up very gradually.",
            high: "Full paint per dab."),
        "StreamLine Amount": BrushHelp(summary: "Smooths shaky lines by letting the drawn line lag behind the pencil.",
            low: "Follows your hand exactly — every wobble shows.",
            high: "Very smooth and confident, but the line trails behind the pencil."),
        "StreamLine Pressure": BrushHelp(summary: "Low-pass on pencil pressure only — evens out width pulsing without touching the path.",
            low: "Raw pressure — every micro-variation shows in the width.",
            high: "Very even width; deliberate pressure changes respond gradually."),
        "Stabilization Amount": BrushHelp(summary: "Averages the path over the distance drawn for clean, steady curves.",
            low: "No averaging — the path is exactly what StreamLine produces.",
            high: "Very clean curvature; tremors vanish. The stroke still ends where the pencil lifts."),
        "Hardness": BrushHelp(summary: "How crisp or soft the brush edge is.",
            low: "Soft, feathered airbrush edge.",
            high: "Crisp, sharp edge."),
        "Tip lightness": BrushHelp(summary: "Lets the tip's texture lighten and darken the ink (embossed, dimensional strokes).",
            low: "Flat ink — the tip texture only shapes coverage.",
            high: "Full value mapping — dark tip areas darken, light areas lighten; mid-gray = your color."),
        "Grain Movement": BrushHelp(summary: "How the moving grain travels with the stroke.",
            low: "Smear — the texture drags and stretches into streaks along the stroke (crayon/lead).",
            high: "Rolling — the texture rolls under the brush undistorted (patterns stay true)."),
        "Grain Zoom": BrushHelp(summary: "Whether the moving grain scales with the brush.",
            low: "Follow size — grain features grow and shrink with brush size.",
            high: "Cropped — grain stays at its own fixed size regardless of brush size."),
        "Grain Depth Jitter": BrushHelp(summary: "Randomly varies the grain strength per stamp — patchy, organic tooth.",
            low: "Even grain along the stroke.",
            high: "Some stamps carve the full Depth, others barely any."),
        "Grain Depth": BrushHelp(summary: "How strongly the paper tooth shows through the stroke.",
            low: "No texture — solid paint.",
            high: "Heavy dry-media break-up; press harder (more flow) to fill the tooth."),
        "Angle": BrushHelp(summary: "The tip's fixed base angle — a calligraphy nib when Roundness is low.",
            low: "0°: the flat axis lies horizontal.",
            high: "180°: rotated through a half turn (90° = vertical)."),
        "Roundness": BrushHelp(summary: "Squashes the tip — a calligraphy/chisel nib at low values.",
            low: "A thin flat blade (pair with Rotation or Azimuth to steer the nib).",
            high: "Fully round tip."),
        "Pressure Roundness": BrushHelp(summary: "Pressure squashes the tip: light touch = flattened, full pressure = the Roundness above.",
            low: "No pressure response.",
            high: "Light strokes flatten to a blade."),
        "Spacing": BrushHelp(summary: "How far apart the stamped dabs are along the stroke.",
            low: "Dense — a smooth, continuous line.",
            high: "Far apart — you see individual dabs."),
        "Spacing Jitter": BrushHelp(summary: "Randomly varies the gap between dabs, so the stroke's rhythm breathes.",
            low: "Even gaps.",
            high: "Gaps vary widely — spray-like, irregular deposits."),
        "Jitter Lateral": BrushHelp(summary: "Shifts stamps randomly PERPENDICULAR to the stroke — width-wise spray.",
            low: "Stamps stay on the path.",
            high: "Stamps scatter far to the sides of the path."),
        "Jitter Linear": BrushHelp(summary: "Shifts stamps randomly ALONG the stroke direction.",
            low: "Stamps stay evenly spaced.",
            high: "Stamps bunch and gap along the path."),
        "Fall Off": BrushHelp(summary: "The stroke's paint gradually runs out as you draw.",
            low: "Never runs out.",
            high: "Fades to nothing within a short distance — like a drying marker."),
        "Grain Scale": BrushHelp(summary: "How coarse the paper-grain features are.",
            low: "Fine tooth.",
            high: "Coarse, chunky tooth."),
        "Count": BrushHelp(summary: "How many stamps land at each spacing point (pairs with the Jitter sliders for spray/cluster texture).",
            low: "One stamp per point — the normal stroke.",
            high: "Eight stamps per point, each with its own scatter."),
        "Count Jitter": BrushHelp(summary: "Randomly varies the per-point stamp count, so density breathes along the stroke.",
            low: "Always the full Count.",
            high: "Anywhere from one stamp up to the full Count, at random."),
        "Rotation": BrushHelp(summary: "How the tip turns with your stroke direction.",
            low: "−100%: turns opposite to the stroke (mirrored calligraphy).",
            high: "+100%: follows the stroke; 0% holds the tip upright."),
        "Scatter": BrushHelp(summary: "Random spin per stamp (rotation randomization — Procreate's Shape Scatter).",
            low: "Every stamp keeps the tip's orientation.",
            high: "Every stamp lands at a fully random angle — no repeating art."),
        "Taper Start": BrushHelp(summary: "Thins the stroke toward its START.",
            low: "Full width from the first touch.",
            high: "Long thin lead-in."),
        "Taper End": BrushHelp(summary: "Thins the stroke toward its END.",
            low: "Full width to the lift.",
            high: "Long thin tail-out."),
        "Taper Opacity": BrushHelp(summary: "Also fades the ink toward the tapered tips, not just the width.",
            low: "Tips thin but stay full-strength (classic hard taper).",
            high: "Tips fade out to nothing (soft, airy entries and exits)."),
        "Attack": BrushHelp(summary: "How strongly each wet dab deposits its color onto the canvas (Procreate: how much paint sticks).",
            low: "Barely tints — color builds up slowly.",
            high: "Covers in a single pass."),
        "Pull": BrushHelp(summary: "How much the brush picks up and drags the colors it crosses (mixing).",
            low: "No pickup — always lays your color, no blending trail.",
            high: "Soaks up and drags color along the stroke (smudgy, blends)."),
        "Charge": BrushHelp(summary: "How much paint is loaded on the brush — it runs out as you stroke.",
            low: "A dab's worth: the stroke dries to a faint tint within a short distance.",
            high: "Bottomless — deposits at full strength forever."),
        "Refill": BrushHelp(summary: "How fast the brush re-loads its own color after picking up paint it crossed.",
            low: "Never — picked-up color rides along until you cross something else.",
            high: "Instantly — the brush always lays pure ink, no matter what it crosses."),
        "Wetness Jitter": BrushHelp(summary: "Randomly varies how much paint each dab deposits — organic patchiness.",
            low: "Even deposit along the stroke.",
            high: "Some dabs land soaked, others nearly dry."),
        "Blur": BrushHelp(summary: "Softens the smudge — dragged edges melt instead of staying crisp (Smudge mode only).",
            low: "Crisp smudge — edges keep their definition as they drag.",
            high: "Soft melt — the smudge averages what it crosses and feathers its rim."),
        "Color Pressure Secondary": BrushHelp(summary: "Pressure blends toward the secondary color (Ink 2).",
            low: "Always the primary color.",
            high: "Full pressure = fully Ink 2 (two-tone nib).")
    ]
}

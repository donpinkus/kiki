import SwiftUI
import CanvasModule

// MARK: - Brush Studio (full page, Procreate-style)
//
// THE brush-editing surface: dark three-pane layout matching Procreate's Brush Studio —
// left rail (sections, blue pill selection), middle controls column, and a large
// interactive DRAWING PAD on the right (a bare MetalCanvasView holding the live brush,
// so you try every knob change immediately; scribbles persist across tweaks and are
// never saved). Cancel reverts to the on-open snapshot; ✓ keeps the edits. All controls
// bind the same AppCoordinator tool state the canvas uses — you are always editing the
// brush you're holding, and "Save as brush" snapshots it into the library.

struct BrushStudioPage: View {
    @Environment(AppCoordinator.self) private var coordinator
    @State private var section: StudioSection = .strokePath
    @State private var showSaveDialog = false
    @State private var saveName = ""
    @State private var padClearToken = 0
    @State private var snapshot: AppCoordinator.BrushStudioSnapshot?
    /// Local mirror of coordinator.toolDynamics (nil ⇄ inert), edited by the Dynamics +
    /// Color sections. Synced both ways below; Equatable guards break the write cycle.
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
                            .padding(.vertical, 11)
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
                case .strokePath: StrokePathSection()
                case .stabilization: StabilizationSection()
                case .taper: TaperSection()
                case .shape: ShapeSection()
                case .grain: GrainSection()
                case .rendering: RenderingSection()
                case .wet: WetSection()
                case .color: ColorSection(dyn: $dyn)
                case .dynamics: DynamicsSection(dyn: $dyn)
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
                padChip {
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

    /// A non-interactive dark floating chip (label style shared with the buttons).
    private func padChip(@ViewBuilder _ content: () -> some View) -> some View {
        padChipLabel(content)
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

enum StudioSection: String, CaseIterable, Identifiable {
    case brushes = "Brushes"
    case strokePath = "Stroke path"
    case stabilization = "Stabilization"
    case taper = "Taper"
    case shape = "Shape"
    case grain = "Grain"
    case rendering = "Rendering"
    case wet = "Wet paint"
    case color = "Color dynamics"
    case dynamics = "Dynamics"
    case developer = "Developer"

    var id: String { rawValue }

    /// Column heading (Procreate uses e.g. "Stroke properties" for Stroke path).
    var heading: String {
        switch self {
        case .brushes: return "Brushes"
        case .strokePath: return "Stroke properties"
        case .stabilization: return "Stabilization"
        case .taper: return "Taper"
        case .shape: return "Shape"
        case .grain: return "Grain"
        case .rendering: return "Rendering"
        case .wet: return "Wet paint"
        case .color: return "Color dynamics"
        case .dynamics: return "Pencil dynamics"
        case .developer: return "Developer"
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
        case .wet: return "drop"
        case .color: return "paintpalette"
        case .dynamics: return "gauge.with.needle"
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

// MARK: - Stroke path

private struct StrokePathSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        BrushSliderRow("Spacing", value: $coordinator.toolSpacing, range: 0.02...1.0, help: BrushHelpCatalog.help["Spacing"]!)
        Group {
            BrushSliderRow("Spacing jitter", value: $coordinator.toolSpacingJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Spacing jitter"]!)
            BrushSliderRow("Fall off", value: $coordinator.toolFallOff, range: 0.0...1.0, help: BrushHelpCatalog.help["Fall off"]!)
            BrushSliderRow("Count", value: $coordinator.toolStampCount, range: 1...8, help: BrushHelpCatalog.help["Count"]!,
                           format: { "\(Int($0.rounded()))" })
            if coordinator.toolStampCount.rounded() > 1 {
                BrushSliderRow("Count jitter", value: $coordinator.toolStampCountJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Count jitter"]!)
            }
        }
        .disabled(wet).opacity(wet ? 0.35 : 1)
        if wet { WetGateFootnote() }
    }
}

// MARK: - Stabilization

private struct StabilizationSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        BrushSliderRow("Stabilize", value: $coordinator.toolStreamline, range: 0.0...1.0, help: BrushHelpCatalog.help["Stabilize"]!)
        BrushSliderRow("Smoothing", value: $coordinator.toolStabilization, range: 0.0...1.0, help: BrushHelpCatalog.help["Smoothing"]!)
        BrushSliderRow("Pressure smoothing", value: $coordinator.toolPressureSmoothing, range: 0.0...1.0, help: BrushHelpCatalog.help["Pressure smoothing"]!)
    }
}

// MARK: - Taper

private struct TaperSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        Group {
            BrushSliderRow("Taper", value: $coordinator.toolTaper, range: 0.0...1.0, help: BrushHelpCatalog.help["Taper"]!)
            if coordinator.toolTaper > 0.005 {
                BrushSliderRow("Taper opacity", value: $coordinator.toolTaperOpacity, range: 0.0...1.0, help: BrushHelpCatalog.help["Taper opacity"]!)
            }
        }
        .disabled(wet).opacity(wet ? 0.35 : 1)
        if wet { WetGateFootnote() }
    }
}

// MARK: - Shape

private struct ShapeSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        StudioGroup("Tip") {
            Group {
                BrushShapePicker(selection: $coordinator.toolShapeID)
                if coordinator.toolShapeID != nil {
                    BrushSliderRow("Tip lightness", value: $coordinator.toolTipLightness, range: 0.0...1.0, help: BrushHelpCatalog.help["Tip lightness"]!)
                }
            }
            .disabled(wet).opacity(wet ? 0.35 : 1)
        }
        StudioGroup("Geometry") {
            BrushSliderRow("Hardness", value: $coordinator.toolHardness, range: 0.0...1.0, help: BrushHelpCatalog.help["Hardness"]!)
            BrushSliderRow("Aspect", value: $coordinator.toolAspect, range: 0.1...1.0, help: BrushHelpCatalog.help["Aspect"]!)
            BrushSliderRow("Angle", value: $coordinator.toolTipAngle, range: 0...(.pi), help: BrushHelpCatalog.help["Angle"]!,
                           format: { "\(Int(($0 * 180 / .pi).rounded()))\u{00B0}" })
            if coordinator.toolShapeID != nil {
                Group {
                    BrushSliderRow("Rotation", value: $coordinator.toolRotationFollow, range: -1.0...1.0, help: BrushHelpCatalog.help["Rotation"]!,
                                   format: { String(format: "%+.0f%%", $0 * 100) })
                    HStack(spacing: 24) {
                        Toggle("Flip X", isOn: $coordinator.toolFlipX)
                        Toggle("Flip Y", isOn: $coordinator.toolFlipY)
                    }
                    .font(.subheadline.weight(.medium))
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

        Group {
            GrainPicker(selection: $coordinator.toolGrainID)
            if coordinator.toolGrainID != nil {
                BrushSliderRow("Grain depth", value: $coordinator.toolGrainDepth, range: 0.0...1.0, help: BrushHelpCatalog.help["Grain depth"]!)
                BrushSliderRow("Grain scale", value: $coordinator.toolGrainScale, range: 0.5...3.0, help: BrushHelpCatalog.help["Grain scale"]!,
                               format: { String(format: "%.1f\u{00D7}", $0) })
                Toggle(isOn: $coordinator.toolGrainMoving) {
                    Text("Moving grain").font(.subheadline.weight(.medium))
                }
                StudioFootnote(coordinator.toolGrainMoving
                     ? "Tooth rides with the stroke — streaky crayon/lead."
                     : "Tooth stays on the paper — overlapping strokes share it.")
            }
        }
        .disabled(wet).opacity(wet ? 0.35 : 1)
        if wet { WetGateFootnote() }
    }
}

// MARK: - Rendering

private struct RenderingSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator
        let wet = coordinator.toolWetEnabled

        BrushSliderRow("Opacity", value: $coordinator.toolOpacity, range: 0.05...1.0, help: BrushHelpCatalog.help["Opacity"]!)
        Group {
            BrushSliderRow("Flow", value: $coordinator.toolFlow, range: 0.05...1.0, help: BrushHelpCatalog.help["Flow"]!)
        }
        .disabled(wet).opacity(wet ? 0.35 : 1)
        if wet { WetGateFootnote() }
    }
}

// MARK: - Wet paint

private struct WetSection: View {
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var coordinator = coordinator

        Toggle(isOn: $coordinator.toolWetEnabled) {
            Text("Wet paint").font(.subheadline.weight(.medium))
            + Text("  (experimental)").font(.caption).foregroundColor(.secondary)
        }
        if coordinator.toolWetEnabled {
            StudioFootnote("Wet paint uses a round tip — Shape, Flow, Taper and Dynamics don't apply. Opacity scales the deposit.")
            BrushSliderRow("Mix", value: $coordinator.toolWetStrength, range: 0.05...1.0, help: BrushHelpCatalog.help["Mix"]!)
            BrushSliderRow("Smear", value: $coordinator.toolWetPickup, range: 0.0...1.0, help: BrushHelpCatalog.help["Smear"]!)
            BrushSliderRow("Charge", value: $coordinator.toolWetCharge, range: 0.05...1.0, help: BrushHelpCatalog.help["Charge"]!)
            BrushSliderRow("Refill", value: $coordinator.toolWetRefill, range: 0.0...1.0, help: BrushHelpCatalog.help["Refill"]!)
            BrushSliderRow("Wet jitter", value: $coordinator.toolWetJitter, range: 0.0...1.0, help: BrushHelpCatalog.help["Wet jitter"]!)
            BrushSliderRow("Blur", value: $coordinator.toolWetBlur, range: 0.0...1.0, help: BrushHelpCatalog.help["Blur"]!)
        }
        StudioGroup("Smudge") {
            Toggle("Smudge mode (push canvas color, no new ink)",
                   isOn: $coordinator.toolWetSmudge)
                .font(.subheadline.weight(.medium))
            StudioFootnote("Smudge uses the wet engine: Mix and Smear above set its strength and pickup.")
        }
    }
}

/// One-line explanation shown at the bottom of sections whose controls are wet-gated.
private struct WetGateFootnote: View {
    var body: some View {
        StudioFootnote("Dimmed controls don't apply while Wet paint is on (it uses a round procedural tip with its own deposit model).")
    }
}

// MARK: - Color dynamics

private struct ColorSection: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Binding var dyn: BrushDynamics

    var body: some View {
        StudioGroup("Secondary color") {
            ColorPicker("Ink 2", selection: Binding(
                get: { coordinator.toolSecondaryColor ?? .yellow },
                set: { coordinator.toolSecondaryColor = $0 }), supportsOpacity: false)
                .font(.subheadline.weight(.medium))
            Toggle("Enabled", isOn: Binding(
                get: { coordinator.toolSecondaryColor != nil },
                set: { coordinator.toolSecondaryColor = $0 ? .yellow : nil }))
                .font(.subheadline.weight(.medium))
            StudioFootnote("Blend is driven by the Secondary blend curve — pressure for a two-tone nib, Distance for a gradient, Fuzzy for speckle.")
        }
        CurveToggleSection(title: "Secondary blend", option: $dyn.secondary, fold: .sizeLike, defaultSensor: .pressure)
        ColorJitterSection(title: "Color jitter (per stroke)", jitter: $dyn.colorJitter)
        ColorJitterSection(title: "Color jitter (per dab)", jitter: $dyn.dabColorJitter,
                           defaults: ColorJitter(hue: 0.01, saturation: 0.08, brightness: 0.08))
    }
}

// MARK: - Dynamics (sensor → curve machine)

private struct DynamicsSection: View {
    @Binding var dyn: BrushDynamics

    var body: some View {
        StudioFootnote("Each parameter maps live pencil sensors (pressure, tilt, speed…) through a response curve. Draw in the pad — the red marker rides the curve.")
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
                // .borderless is LOAD-BEARING inside Forms; kept here for the same
                // one-tap-fires-every-button hazard (2026-07-15/16 device reports).
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
        "Stabilize": BrushHelp(summary: "Smooths shaky lines by letting the drawn line lag behind the pencil.",
            low: "Follows your hand exactly — every wobble shows.",
            high: "Very smooth and confident, but the line trails behind the pencil."),
        "Smoothing": BrushHelp(summary: "Averages the path over the distance drawn for clean, steady curves.",
            low: "No averaging — the path is exactly what Stabilize produces.",
            high: "Very clean curvature; tremors vanish. The stroke still ends where the pencil lifts."),
        "Pressure smoothing": BrushHelp(summary: "Low-pass on pencil pressure only — evens out width pulsing without touching the path.",
            low: "Raw pressure — every micro-variation shows in the width.",
            high: "Very even width; deliberate pressure changes respond gradually."),
        "Hardness": BrushHelp(summary: "How crisp or soft the brush edge is.",
            low: "Soft, feathered airbrush edge.",
            high: "Crisp, sharp edge."),
        "Tip lightness": BrushHelp(summary: "Lets the tip's texture lighten and darken the ink (embossed, dimensional strokes).",
            low: "Flat ink — the tip texture only shapes coverage.",
            high: "Full value mapping — dark tip areas darken, light areas lighten; mid-gray = your color."),
        "Grain depth": BrushHelp(summary: "How strongly the paper tooth shows through the stroke.",
            low: "No texture — solid paint.",
            high: "Heavy dry-media break-up; press harder (more flow) to fill the tooth."),
        "Angle": BrushHelp(summary: "The tip's fixed base angle — a calligraphy nib when Aspect is low.",
            low: "0°: the flat axis lies horizontal.",
            high: "180°: rotated through a half turn (90° = vertical)."),
        "Aspect": BrushHelp(summary: "How flat the brush tip is — a calligraphy/chisel nib at low values.",
            low: "A thin flat blade (pair with Rotation dynamics to steer the nib).",
            high: "Fully round tip."),
        "Spacing": BrushHelp(summary: "How far apart the stamped dabs are along the stroke.",
            low: "Dense — a smooth, continuous line.",
            high: "Far apart — you see individual dabs."),
        "Spacing jitter": BrushHelp(summary: "Randomly varies the gap between dabs, so the stroke's rhythm breathes.",
            low: "Even gaps.",
            high: "Gaps vary widely — spray-like, irregular deposits."),
        "Fall off": BrushHelp(summary: "The stroke's paint gradually runs out as you draw.",
            low: "Never runs out.",
            high: "Fades to nothing within a short distance — like a drying marker."),
        "Grain scale": BrushHelp(summary: "How coarse the paper-grain features are.",
            low: "Fine tooth.",
            high: "Coarse, chunky tooth."),
        "Count": BrushHelp(summary: "How many stamps land at each spacing point (pairs with Scatter dynamics for spray/cluster texture).",
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
        "Taper opacity": BrushHelp(summary: "Also fades the ink toward the tapered tips, not just the width.",
            low: "Tips thin but stay full-strength (classic hard taper).",
            high: "Tips fade out to nothing (soft, airy entries and exits)."),
        "Mix": BrushHelp(summary: "How strongly each dab deposits its color onto the canvas.",
            low: "Barely tints — color builds up slowly.",
            high: "Covers in a single pass."),
        "Smear": BrushHelp(summary: "How much the brush picks up and carries the colors it crosses.",
            low: "No pickup — always lays your color, no blending trail.",
            high: "Soaks up and drags color along the stroke (smudgy, blends)."),
        "Charge": BrushHelp(summary: "How much paint is loaded on the brush — it runs out as you stroke.",
            low: "A dab's worth: the stroke dries to a faint tint within a short distance.",
            high: "Bottomless — deposits at full strength forever."),
        "Refill": BrushHelp(summary: "How fast the brush re-loads its own color after picking up paint it crossed.",
            low: "Never — picked-up color rides along until you cross something else.",
            high: "Instantly — the brush always lays pure ink, no matter what it crosses."),
        "Wet jitter": BrushHelp(summary: "Randomly varies how much paint each dab deposits — organic patchiness.",
            low: "Even deposit along the stroke.",
            high: "Some dabs land soaked, others nearly dry."),
        "Blur": BrushHelp(summary: "Softens the smudge — dragged edges melt instead of staying crisp (Smudge mode only).",
            low: "Crisp smudge — edges keep their definition as they drag.",
            high: "Soft melt — the smudge averages what it crosses and feathers its rim.")
    ]
}

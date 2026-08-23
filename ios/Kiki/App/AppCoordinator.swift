import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import SwiftData
import os
import Sentry
import CanvasModule
import ExportModule
import NetworkModule
import ResultModule

private let streamLog = Logger(subsystem: "com.kiki.app", category: "StreamCoordinator")

enum DrawingTool: String, CaseIterable, Hashable {
    case brush
    case eraser
    /// The unified Select tool — SAM taps or freehand loops, per
    /// `SelectionController.authorMode` (documents/plans/unified-selection.md).
    case select
}

enum AppScreen: Equatable {
    case signIn
    case gallery
    case drawing
    case animate
    /// Speed-paint replay share page (from a drawing's Share menu). A full
    /// screen, NOT a modal: the preview wants all the real estate, and
    /// fullScreenCover kills video compositing on iPadOS 26 hardware.
    case replay

    var analyticsName: String {
        switch self {
        case .signIn: return "SignIn"
        case .gallery: return "Gallery"
        case .drawing: return "Drawing"
        case .animate: return "Animate"
        case .replay: return "Replay"
        }
    }
}

enum DrawingLayout: String, CaseIterable {
    /// Result pane on the left half; canvas on the right half.
    case splitScreen
    /// Canvas fills the pane; the generated image floats as a draggable panel.
    case fullscreen
    /// Generated image overlaid opaque, locked exactly on top of the canvas
    /// (pan/zoom/rotate together); fresh strokes flash on a visual-only surface
    /// above it and clear on every returned generation frame.
    case overlay
}

@MainActor
@Observable
final class AppCoordinator {

    // MARK: - Navigation

    var currentScreen: AppScreen = .gallery
    var currentDrawingId: UUID?

    // MARK: - Persistence

    private let modelContext: ModelContext
    private var isSuppressingObservation = false
    private var saveDebounceTask: Task<Void, Never>?

    // MARK: - UI State

    var currentTool: DrawingTool = .brush {
        didSet {
            // Leaving Select commits any floating Move + freezes the open
            // object. The selection itself PERSISTS across all tool switches
            // (unified-selection.md) — only "Clear Selection" removes it.
            if oldValue == .select, currentTool != .select {
                canvasViewModel.selection.toolDeactivated()
            }
            // Stash the outgoing tool's size/opacity and load the incoming tool's.
            swapToolValues(from: oldValue, to: currentTool)
            applyTool()
        }
    }
    var toolSize: CGFloat = 15.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    var toolOpacity: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Per-stamp deposit rate ("Flow"). Separate from opacity: flow controls
    /// within-stroke build-up, opacity caps the whole stroke. See pro-brush-roadmap Phase 0.
    var toolFlow: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// StreamLine stabilization ("Stabilize"). 0 = no smoothing; higher = steadier,
    /// more confident lines (the drawn point lags the pencil). See pro-brush-roadmap Phase 1.
    var toolStreamline: CGFloat = 0.35 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Edge hardness ("Hardness"). 0 = soft/feathered; 1 = crisp. See pro-brush-roadmap Phase 2.
    var toolHardness: CGFloat = 0.5 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Stamp spacing as a fraction of width ("Spacing"). Lower = smoother. See Phase 2.
    var toolSpacing: CGFloat = 0.3 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Per-end stroke taper ("Taper" start/end, Procreate Pressure Taper). 0 = none.
    /// The legacy symmetric BrushConfig.taper folds into these on apply (max per end).
    var toolTaperStart: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    var toolTaperEnd: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Random per-dab tip spin ("Scatter", Procreate Shape). 0 = none, 1 = fully random.
    var toolRotationJitter: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// One random tip rotation per stroke ("Randomized", Procreate Shape).
    var toolRandomizedRotation: Bool = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Random per-stamp grain strength ("Depth Jitter", Procreate Grain).
    var toolGrainDepthJitter: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Moving-grain "Movement" (smear 0 ↔ Rolling 1).
    var toolGrainMovement: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Moving-grain "Zoom" (Follow size 0 ↔ Cropped 1).
    var toolGrainZoom: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Moving-grain "Rotation" (±100% ≙ ±180° vs stroke direction).
    var toolGrainRotation: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Moving-grain "Depth Minimum" (floor for modulated depth).
    var toolGrainDepthMinimum: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Moving-grain "Offset Jitter" (random tile offset per stroke).
    var toolGrainOffsetJitter: Bool = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Grain "Brightness" pre-adjust (both modes).
    var toolGrainBrightness: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Grain "Contrast" pre-adjust (both modes).
    var toolGrainContrast: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Gaussian arc-length smoothing ("Smoothing", P3). 0 = off; higher = steadier
    /// curvature with more trailing lag (catch-up-on-lift covers the tail).
    var toolStabilization: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Tip lightness ("Tip lightness", P4a): shaped tip luma → ink value mapping.
    var toolTipLightness: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Spacing jitter (batch 2; no slider yet — written by presets, read by applyTool).
    var toolSpacingJitter: CGFloat = 0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Pressure smoothing (P3; no slider — written by presets, read by applyTool).
    var toolPressureSmoothing: CGFloat = 0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// The last-applied curated preset id (chip highlight in the popover). Purely
    /// informational — manual knob tweaks after applying don't clear it (v1).
    var activeCuratedPresetID: String?
    /// Taper opacity fade ("Taper opacity", richer taper): fades alpha at tapered tips.
    var toolTaperOpacity: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Wet Refill ("Refill"): pull the carried load back toward the ink over distance.
    var toolWetRefill: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Secondary ink ("Ink 2", P6): per-dab blend target; nil = single ink.
    var toolSecondaryColor: Color? = nil {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Wet Blur ("Blur", smudge softness): neighborhood pickup + soft rim.
    var toolWetBlur: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Wetness Jitter ("Wet jitter"): per-dab random deposit patchiness.
    var toolWetJitter: CGFloat = 0.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Wet Charge ("Charge", P7): finite paint reservoir; 1 = bottomless.
    var toolWetCharge: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Static tip angle ("Angle", radians): the nib's base orientation (calligraphy).
    var toolTipAngle: CGFloat = 0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Fall Off ("Fall off"): paint runs out over drawn distance.
    var toolFallOff: CGFloat = 0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Grain mode ("Moving grain"): tooth rides with the stroke instead of the paper.
    var toolGrainMoving: Bool = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Grain scale ("Grain scale", 0.5–3×): coarseness multiplier on the grain tile.
    var toolGrainScale: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Stamps per spacing point ("Count", 1–8; CGFloat for the slider, rounded at build).
    var toolStampCount: CGFloat = 1 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Count jitter [0,1] ("Count jitter").
    var toolStampCountJitter: CGFloat = 0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Signed follow-stroke rotation ("Rotation", −1…1). 1 = legacy full follow.
    var toolRotationFollow: CGFloat = 1 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Tip art mirror ("Flip X/Y").
    var toolFlipX: Bool = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    var toolFlipY: Bool = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Grain texture id ("Grain", P8). nil = none.
    var toolGrainID: String? = nil {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Grain depth ("Depth", P8): how aggressively the paper tooth carves the dab.
    var toolGrainDepth: CGFloat = 0.5 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Tip aspect ratio ("Aspect", P4b anisotropy). 1 = round; lower flattens the tip
    /// into a chisel/calligraphy nib (combine with a Rotation dynamics option or a
    /// stroke-oriented shape to steer the nib angle).
    var toolAspect: CGFloat = 1.0 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }

    /// Wet-paint mode (pro-brush Phase 4, experimental). Brush only.
    var toolWetEnabled = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Wet "Mix": per-stamp deposit strength toward the carried load color.
    var toolWetStrength: CGFloat = 0.4 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Wet "Smear": how much the brush picks up and carries the canvas color it crosses.
    var toolWetPickup: CGFloat = 0.25 {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Selected brush-tip shape id (see `BrushShapeCatalog`). nil / "round" = the
    /// procedural soft circle; other ids bind a grayscale stamp texture (Phase 3).
    var toolShapeID: String? = nil {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Krita-grade brush dynamics (sensor→curve→combine→remap). nil = no dynamics (legacy pen).
    /// Edited live by the Brush Studio dev panel; applied to the active brush on change.
    var toolDynamics: BrushDynamics? = nil {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }
    /// Smudge mode (with wet path): seed the carried load from the canvas instead of the ink.
    var toolWetSmudge = false {
        didSet {
            guard !isSwappingToolValues else { return }
            applyTool()
        }
    }

    /// Whether the full-page Brush Studio is shown (fullScreenCover from DrawingView).
    /// The single brush-editing surface — the old settings popover + docked dev panel
    /// were folded into it (2026-07-17).
    var showBrushStudio = false
    /// The last-applied saved custom brush id (chip highlight in the Studio). Purely
    /// informational, like activeCuratedPresetID.
    var activeCustomBrushID: UUID?
    /// On-device named custom brushes ("Save as brush" in the Brush Studio).
    let customBrushLibrary = CustomBrushLibrary()
    /// User-imported brush tips + grains (Studio → Shape/Grain Source → Import). Its
    /// init points the engine (`BrushAssetStore.directory`) at the on-disk store.
    let brushAssets = BrushAssetLibrary()

    // MARK: - DEV brush-tuning harness (input HUD + engine knobs + active test note)

    /// Latest live brush-input sample (from MetalCanvasView), shown in the on-canvas HUD.
    var liveBrushInput: BrushInputSample?
    /// Whether the live input HUD is shown on the canvas.
    var showInputHUD = false
    /// Tunable engine-normalization constants (pushed into the canvas via DrawingView's CanvasView
    /// on each @Observable update; dialed via Brush Studio sliders).
    var devMaxSpeed: Double = 1500
    var devDistancePeriod: Double = 600
    var devFadePeriod: Double = 64
    /// The active test brush's instruction note (shown in Brush Studio).
    var activeTestNote: String?

    /// DEV stroke recorder (Brush Studio → "Record strokes"): while on, every completed
    /// brush stroke (dry + wet, canvas-pixel-normalized by MetalCanvasView) is appended
    /// here, exportable as a BrushHarness fixture JSON via the share sheet. See
    /// `ios/Packages/CanvasModule/BrushHarness/README.md`.
    var isRecordingStrokes = false
    var recordedStrokes: [Stroke] = []

    /// Write the recording as a BrushFixture JSON to a temp file for sharing
    /// (AirDrop/Files → replay with `brushharness --fixtures <file>`).
    func exportRecordedStrokesURL() -> URL? {
        guard let data = recordedFixtureJSON() else { return nil }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("brush-strokes-\(stamp).json")
        do { try data.write(to: url) } catch { return nil }
        return url
    }

    private func recordedFixtureJSON() -> Data? {
        guard !recordedStrokes.isEmpty else { return nil }
        let fixture = BrushFixture(name: nil, canvasSide: 2048, strokes: recordedStrokes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(fixture)
    }

    /// One-tap fixture upload to Kiki Insights: the stroke JSON (for BrushHarness
    /// replay) plus a PNG snapshot of the current canvas (so a verbal description
    /// has a picture to point at — the "brush bug report" button). Returns success
    /// for UI confirmation. Fetched Mac-side via `BrushHarness/fetch-fixtures.sh`.
    /// The last recording written to disk (auto-saved on every Upload attempt BEFORE any
    /// network I/O, so a failed/interrupted upload can never lose the strokes — Share…
    /// works from this file even if the in-memory recording is gone).
    var lastRecordingURL: URL?

    /// Returns nil on success, else a human-readable failure reason for the Studio UI.
    func uploadRecordedFixture(note: String?) async -> String? {
        guard let json = recordedFixtureJSON() else { return "no strokes recorded" }
        // Persist FIRST — losing a recording to a failed upload is unacceptable.
        if let url = exportRecordedStrokesURL() { lastRecordingURL = url }
        let snapshot = canvasViewModel.generateThumbnail(maxDimension: 1024)?.pngData()
        return await InsightsSink.shared.uploadFixture(
            name: nil, note: note, strokeCount: recordedStrokes.count,
            fixtureJSON: json, snapshotPNG: snapshot)
    }

    // MARK: - Per-tool stored settings

    /// While true, toolSize / toolOpacity / toolFlow / toolStreamline didSet should skip
    /// applyTool() (used when swapping values on a tool change).
    private var isSwappingToolValues = false
    private var storedToolSizes: [DrawingTool: CGFloat] = [
        .brush: 15,
        .eraser: 25,
        .select: 5
    ]
    private var storedToolOpacities: [DrawingTool: CGFloat] = [
        .brush: 1.0,
        .eraser: 1.0,
        .select: 1.0
    ]
    private var storedToolFlows: [DrawingTool: CGFloat] = [
        .brush: 1.0,
        .eraser: 1.0,
        .select: 1.0
    ]
    private var storedToolStreamlines: [DrawingTool: CGFloat] = [
        .brush: 0.35,
        .eraser: 0.0,
        .select: 0.0
    ]
    private var storedToolHardnesses: [DrawingTool: CGFloat] = [
        .brush: 0.5,
        .eraser: 1.0,
        .select: 1.0
    ]
    private var storedToolSpacings: [DrawingTool: CGFloat] = [
        .brush: 0.3,
        .eraser: 0.3,
        .select: 0.3
    ]
    /// Per-tool brush shape. Absent = procedural round; only the brush meaningfully uses it.
    private var storedToolShapes: [DrawingTool: String] = [:]

    private func swapToolValues(from oldTool: DrawingTool, to newTool: DrawingTool) {
        guard oldTool != newTool else { return }
        storedToolSizes[oldTool] = toolSize
        storedToolOpacities[oldTool] = toolOpacity
        storedToolFlows[oldTool] = toolFlow
        storedToolStreamlines[oldTool] = toolStreamline
        storedToolHardnesses[oldTool] = toolHardness
        storedToolSpacings[oldTool] = toolSpacing
        storedToolShapes[oldTool] = toolShapeID  // nil clears the entry
        isSwappingToolValues = true
        toolSize = storedToolSizes[newTool] ?? toolSize
        toolOpacity = storedToolOpacities[newTool] ?? toolOpacity
        toolFlow = storedToolFlows[newTool] ?? toolFlow
        toolStreamline = storedToolStreamlines[newTool] ?? toolStreamline
        toolHardness = storedToolHardnesses[newTool] ?? toolHardness
        toolSpacing = storedToolSpacings[newTool] ?? toolSpacing
        toolShapeID = storedToolShapes[newTool]
        isSwappingToolValues = false
    }
    /// Initial brush color is a friendly aqua blue, not black: it makes the
    /// color wheel obviously "already a color" so new users realize switching
    /// colors is a thing (product call 2026-07-16).
    var currentColor: Color = Color(red: 0.15, green: 0.69, blue: 0.78) {
        didSet { applyTool() }
    }
    var promptText = "" {
        didSet {
            noteInteraction()
            if !isSuppressingObservation {
                scheduleSave()
                if promptText != oldValue {
                    Analytics.track(.promptChanged, properties: ["prompt_length": promptText.count])
                }
            }
            syncStreamConfig()
        }
    }
    var selectedStyle: PromptStyle = .default {
        didSet {
            noteInteraction()
            if !isSuppressingObservation {
                scheduleSave()
                if selectedStyle.id != oldValue.id {
                    Analytics.track(.styleSelected, properties: ["style_id": selectedStyle.id])
                }
            }
            syncStreamConfig()
        }
    }
    var showStylePicker = false {
        didSet {
            guard showStylePicker != oldValue else { return }
            if showStylePicker {
                enterStylePreviewMode()
            } else {
                exitStylePreviewMode()
            }
        }
    }
    var showLayerPanel = false
    var resultState: ResultState = .empty

    /// Availability of the video H100 system, pushed by the backend
    /// (`system_availability` on the stream AND animate sockets): .off =
    /// feature flag disabled (hide ALL animation UX), .warming = enabled but
    /// the video instance is booting, .ready = a video H100 is serving.
    /// Persisted across launches so the gallery's Animate entry isn't blind
    /// before the first socket opens.
    enum VideoAvailability: String {
        case off
        case warming
        case ready
    }
    var videoAvailability: VideoAvailability =
        VideoAvailability(rawValue: UserDefaults.standard.string(forKey: "lastVideoAvailability") ?? "") ?? .off {
        didSet {
            UserDefaults.standard.set(videoAvailability.rawValue, forKey: "lastVideoAvailability")
        }
    }

    /// IMAGE system availability from the same push. Unlike the detailed
    /// lambdaPoolState (test-account-gated REST poll), this reaches EVERY
    /// user — the badge prefers it when present. nil until the first push.
    var imageAvailability: VideoAvailability?

    /// Full pushed status per system (stage + boot-progress timing) — drives
    /// the badge popover's independent image/video sections for ALL users.
    var imageSystemStatus: StreamWebSocketClient.SystemStatus?
    var videoSystemStatus: StreamWebSocketClient.SystemStatus?

    /// The Animate screen's controller. Created lazily on first entry and
    /// kept for the app's lifetime so prompt/keyframes/history selection
    /// survive leaving and re-entering the screen.
    var animate: AnimateController?
    /// Where the Animate screen's Back button returns to.
    private var animateReturnScreen: AppScreen = .gallery

    /// The drawing's animation prompt (motion description for the video
    /// model). Persisted per drawing; prefills the Animate screen when
    /// entering from this drawing.
    var animationPromptText = "" {
        didSet {
            noteInteraction()
            if !isSuppressingObservation {
                scheduleSave()
            }
        }
    }

    /// "simulator:<model>" or "device:<model>" + app version — sent as
    /// X-Kiki-Client on the stream WS handshake.
    static let clientTag: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        var sysinfo = utsname()
        uname(&sysinfo)
        let model = withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(validatingCString: $0) ?? "unknown" }
        }
        #if targetEnvironment(simulator)
        return "simulator:\(model) kiki/\(version)"
        #else
        return "device:\(model) kiki/\(version)"
        #endif
    }()

    /// Mirrors the backend's DEFAULT_ANIMATION_PROMPT (videoSession.ts) —
    /// shown as the modal's placeholder so users see what runs if they
    /// leave it empty.
    static let defaultAnimationPrompt =
        "gentle cinematic motion: the scene subtly comes alive with natural movement, " +
        "soft ambient animation, camera slowly drifting closer"
    var dividerPosition: CGFloat = 0.5
    /// Message for the red error banner in `DrawingView`. Set on stream/auth
    /// failures; cleared automatically when the condition resolves (successful
    /// sign-in, stream reaching `.ready`, subscription activation) or manually
    /// via the banner's ✕. The `didSet` is the single chokepoint that reports
    /// "user saw an error banner" to analytics — don't add per-site tracking.
    var generationError: String? {
        didSet {
            guard let generationError, generationError != oldValue else { return }
            Analytics.track(.errorBannerShown, properties: [
                "message": generationError,
                "surface": "drawing_banner",
            ])
        }
    }

    /// Fullscreen result-panel transform. `panelOffset` is the panel's
    /// translation from its default top-trailing position (in pane points);
    /// `panelScale` scales the image uniformly about its center. Driven by the
    /// two-finger pan/pinch the canvas container forwards when a gesture starts
    /// over the panel (see DrawingView ↔ CanvasView wiring).
    var panelOffset: CGSize = .zero
    var panelScale: CGFloat = 1.0
    private static let minPanelScale: CGFloat = 0.4
    private static let maxPanelScale: CGFloat = 3.0

    /// Apply an incremental two-finger transform to the floating panel.
    /// `translationDelta` is in pane points; `scaleDelta` is multiplicative.
    func applyPanelTransform(translationDelta: CGPoint, scaleDelta: CGFloat) {
        panelOffset.width += translationDelta.x
        panelOffset.height += translationDelta.y
        panelScale = min(max(panelScale * scaleDelta, Self.minPanelScale), Self.maxPanelScale)
    }

    /// The "transparency hole" punched into the fullscreen result panel around
    /// the pencil while drawing. Center/radius are in the panel's UNSCALED base
    /// coordinate space (the `.scaleEffect` is applied on top in SwiftUI). Only a
    /// small leaf view reads this, so 120 Hz updates don't re-render DrawingView.
    var panelHole = PanelHole()

    /// Map a live pane-space contact point + brush diameter into the panel's
    /// base coordinate space and open the hole. No-op (and closes the hole) when
    /// the panel isn't shown.
    func updatePanelHole(paneContact: CGPoint, diameter: CGFloat, paneSize: CGSize) {
        guard drawingLayout == .fullscreen, let image = resultState.displayImage else {
            panelHole.isActive = false
            return
        }
        let rect = PanelLayout.rect(for: image, in: paneSize, offset: panelOffset, scale: panelScale)
        let safeScale = max(panelScale, 0.01)
        panelHole.center = CGPoint(
            x: (paneContact.x - rect.minX) / safeScale,
            y: (paneContact.y - rect.minY) / safeScale
        )
        // Base halo (140pt) + brush radius. Large so a wide area around the
        // pencil is cleared; the feather is set small in the mask so most of
        // this radius is fully transparent rather than a long falloff.
        panelHole.radius = (140 + diameter / 2) / safeScale
        panelHole.isActive = true
    }

    /// One-time NUX tooltip for QuickShape. Set true on first successful snap;
    /// DrawingView observes this and auto-clears it after 5s. AppStorage flag
    /// in DrawingView ensures we only show it once per device, ever.
    var shouldShowQuickShapeTooltip: Bool = false

    // MARK: - Layout

    var drawingLayout: DrawingLayout = .overlay {
        didSet {
            UserDefaults.standard.set(drawingLayout.rawValue, forKey: "drawingLayout")
            // Clear any in-flight panel hole so it can't linger across a layout
            // switch (the panel only exists in fullscreen).
            panelHole = PanelHole()
        }
    }

    // MARK: - Modules

    let canvasViewModel = CanvasViewModel()
    let stylePreviewController = StylePreviewController()
    private let backendURL: URL
    private let authService: AuthService

    // MARK: - Subscription / paywall

    /// StoreKit 2 subscription state + purchase flow (see SubscriptionManager).
    let subscriptionManager: SubscriptionManager
    /// Drives the paywall `fullScreenCover`. Set true on `free_limit_reached`
    /// (or a manual upgrade tap); cleared on dismiss / successful purchase.
    var showPaywall = false
    /// True once the backend reported the monthly free-tier cap was hit. Keeps a
    /// "Subscribe" affordance in the error banner after the paywall is dismissed.
    var isOutOfDrawingTime = false

    // -- Free-tier usage meter --
    /// Current monthly fal spend / cap (USD). nil until first loaded. Updated
    /// live over the WS while drawing (`onUsageUpdate`) and via `refreshUsage()`
    /// (`GET /v1/usage`) on screen appear + after a stream stops.
    var usageSpendUsd: Double?
    var usageCapUsd: Double?
    /// True for test accounts + active subscribers (no cap) → meter hidden.
    var usageExempt = false

    /// Show the meter only once loaded, for a non-exempt signed-in user with a
    /// real cap.
    var showUsageBar: Bool {
        signedInUserId != nil && !usageExempt && usageSpendUsd != nil && (usageCapUsd ?? 0) > 0
    }

    /// Spend as a 0…1 fraction of the cap, for the bar fill.
    var usageFraction: Double {
        guard let spend = usageSpendUsd, let cap = usageCapUsd, cap > 0 else { return 0 }
        return min(max(spend / cap, 0), 1)
    }

    /// Fetch current usage from the backend (best-effort). Call on screen appear
    /// and after a stream stops; the live WS push covers mid-drawing.
    func refreshUsage() {
        guard signedInUserId != nil else { return }
        Task { @MainActor [authService] in
            if let usage = try? await authService.fetchUsage() {
                self.usageSpendUsd = usage.spendUsd
                self.usageCapUsd = usage.capUsd
                self.usageExempt = usage.exempt
            }
        }
    }

    // MARK: - Auth

    var signedInUserId: String?

    // MARK: - Stream State

    private var streamWasActiveBeforeBackground = false
    private var streamSession: StreamSession?
    /// Sentry transaction measuring user-perceived spin-up (tap → first frame).
    /// Started in `startStream`, finished on first `onImageReceived` callback.
    private var pendingStartupTransaction: (any Span)?
    /// Timestamp when the current stream startup began. Paired with first-frame
    /// arrival to emit `stream.first_frame` with a waitMs property.
    private var streamStartupBeganAt: Date?
    /// When the user entered the current drawing. Used to compute session
    /// duration for the `drawing.closed` analytics event. Set in
    /// `openDrawing`/`newDrawing`, read + cleared in `navigateToGallery`.
    private var currentDrawingOpenedAt: Date?

    /// Wall-clock when the app last entered the foreground. Brackets an app-level
    /// session: `app.foregrounded` on entry, `app.backgrounded` (with duration)
    /// on exit. Powers the Insights login/session timeline.
    private var appForegroundedAt: Date?

    private(set) var streamReadiness: StreamSession.StreamReadiness = .disconnected

    // ── Idle stream guard ────────────────────────────────────────────────
    // An open drawing with no interaction reconnects forever (the proxy
    // drops idle sockets ~75s; each reconnect sends a frame) — an abandoned
    // client (simulator, iPad on a couch) can pin a warm GPU indefinitely
    // (10h simulator incident, 2026-07-19). After idlePauseSeconds without a
    // stroke/prompt/style/animate interaction the stream DELIBERATELY stops
    // (no auto-reconnect) and the badge reads "resting"; the next
    // interaction resumes it within ~1s. Drawing itself never depends on
    // the stream, so a resting canvas stays fully usable.
    // Dev seam: `-KikiIdlePauseSeconds 45` launch arg shortens the window so
    // the pause/resume cycle is testable without a 10-minute wait.
    private static let idlePauseSeconds: TimeInterval = {
        let override = UserDefaults.standard.double(forKey: "KikiIdlePauseSeconds")
        return override > 0 ? override : 10 * 60
    }()
    private(set) var isStreamIdlePaused = false
    private var lastInteractionAt = Date()
    private var idleGuardTask: Task<Void, Never>?

    /// Record a generation-relevant interaction; wakes a resting stream.
    func noteInteraction() {
        lastInteractionAt = Date()
        if isStreamIdlePaused {
            isStreamIdlePaused = false
            streamLog.info("[idle-guard] interaction — resuming stream")
            Log.info("stream.idle_resume", attributes: ["event": "stream.idle_resume"])
            startStream()
        }
    }

    private func startIdleGuard() {
        idleGuardTask?.cancel()
        lastInteractionAt = Date()
        idleGuardTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled else { return }
                if self.streamSession != nil,
                   !self.isStreamIdlePaused,
                   Date().timeIntervalSince(self.lastInteractionAt) > Self.idlePauseSeconds {
                    self.pauseStreamForIdle()
                }
            }
        }
    }

    private func pauseStreamForIdle() {
        guard streamSession != nil else { return }
        streamLog.info("[idle-guard] no interaction for \(Int(Self.idlePauseSeconds))s — resting stream")
        Log.info("stream.idle_pause", attributes: [
            "event": "stream.idle_pause",
            "idle_seconds": Int(Date().timeIntervalSince(lastInteractionAt)),
        ])
        streamSession?.stop()
        streamSession = nil
        // Keep the recording footage captured so far (same policy as
        // resumeStream's teardown).
        stopRecordingCheckpoints()
        if let recorder, let drawingId = currentDrawingId {
            finalizeRecording(recorder, drawingId: drawingId)
        }
        recorder = nil
        isStreamIdlePaused = true
    }

    private(set) var streamFrameCount = 0
    /// Strokes completed during the CURRENT canvas session (reset on every
    /// drawing open). Shipped as `strokes_added` on `drawing.closed` — powers
    /// the Insights drawing-experience waterfall's "first stroke made" stage.
    private var sessionStrokeCount = 0

    // -- Stream parameters --

    /// Number of inference steps.
    var streamSteps: Int = 4 { didSet { syncStreamConfig() } }

    /// Fixed seed (nil = server picks a stable per-session seed).
    var streamSeed: Int? { didSet { syncStreamConfig() } }

    /// Live fal img2img output resolution (px, square). Only fal's two realtime
    /// presets exist — 768 (`square`) and 1024 (`square_hd`); there is no higher
    /// option on `fal-ai/flux-2/klein/realtime`. Drives both the `image_size`
    /// config key and the canvas capture size (StreamSession matches the input
    /// JPEG to the output). Default 1024.
    var streamResolution: Int = 1024 { didSet { syncStreamConfig() } }

    /// Live fal `schedule_mu` — denoise-schedule time shift (fal range 0.3–2.5).
    /// Lower = more uniform denoising / tighter adherence to the sketch; fal's
    /// own default is 2.3 (looser/more restyling). Default 1.2 (more adherence).
    var streamScheduleMu: Double = 1.2 { didSet { syncStreamConfig() } }

    /// Sketch-adherence dial (Lambda KV pipeline: reference-token K/V scaling).
    /// >1 follows the sketch harder, <1 frees the prompt; 1.0 = stock. Only
    /// honored on the lambda path — the fal relay ignores the key, so pin
    /// imageProvider=lambda when tuning.
    var streamReferenceScale: Double = 1.0 { didSet { syncStreamConfig() } }

    /// Which backend image path serves this device's stream: "auto" (what
    /// real users get — H100 pool when assignable, else fal; the backend
    /// decides and can downgrade mid-session), "fal" (pin hosted realtime) or
    /// "lambda" (pin our FLUX pipeline on a Lambda Cloud H100 — the adherence
    /// A/B). Sent as `?imageProvider=` on the stream WS; the backend honors
    /// the fal/lambda pins for TEST ACCOUNTS only and ignores "auto" (which
    /// therefore falls through to the server-side IMAGE_PROVIDER). Unlike the
    /// config-push params above this is a WS query param, so changing it
    /// reconnects the stream. Persisted.
    var imageProvider: String = UserDefaults.standard.string(forKey: "imageProvider") ?? "auto" {
        didSet {
            guard imageProvider != oldValue else { return }
            UserDefaults.standard.set(imageProvider, forKey: "imageProvider")
            if imageProvider != "fal" { ensureLambdaPool() }
            if streamSession != nil { resumeStream() }
        }
    }

    /// Last known Lambda dev-pool state line, shown under the provider picker
    /// in Settings ("H100 ready at <ip>" / "Instance booting (~3 min)…").
    private(set) var lambdaPoolStatus: String = ""

    /// Fire-and-forget: ask the backend to spin up (or keep) the Lambda H100.
    /// Called at sign-in/app-open and when the provider toggle flips to
    /// lambda, so the instance is warming before it's needed. No-op when
    /// signed out; backend 403s for non-test accounts (status shows that).
    func ensureLambdaPool() {
        guard signedInUserId != nil else { return }
        Task { @MainActor in
            do {
                let state = try await authService.ensureLambdaPool()
                self.lambdaPoolStatus = state.message
                Log.info("lambda.pool_state", attributes: [
                    "event": "lambda.pool_state",
                    "status": state.status,
                ])
            } catch {
                self.lambdaPoolStatus = "unavailable: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Edit → pull generated image onto canvas (sketchify)

    /// Sketchify import modes — must match POST /v1/sketchify's `mode` values.
    enum SketchifyMode: String {
        case lines = "lines"
        case linesColors = "lines_colors"
    }

    /// True when the Lambda H100 is serving — gates the Edit button. Kept
    /// fresh by `startLambdaStatusPolling` while the drawing view is visible.
    private(set) var lambdaPoolReady = false
    /// Boot ETA (seconds) while the pool is warming; nil when ready/unknown.
    private(set) var lambdaPoolEtaSeconds: Int?
    /// Full last-known pool state — drives the "Kiki's AI" status badge
    /// (dot color, elapsed-while-warming, provisioning error details).
    private(set) var lambdaPoolState: AuthService.LambdaPoolState?
    /// True while a sketchify request is in flight (button shows a spinner).
    private(set) var sketchifyInProgress = false
    /// Transient toast text (e.g. the "warming up" notice). Auto-clears ~5s
    /// after being set; DrawingView renders + animates it.
    private(set) var transientBanner: String?

    private var lambdaStatusPollTask: Task<Void, Never>?

    /// Poll the dev-pool status every 15s while the drawing view is visible so
    /// the Edit button's enabled state tracks the H100 without user action.
    func startLambdaStatusPolling() {
        guard lambdaStatusPollTask == nil, signedInUserId != nil else { return }
        lambdaStatusPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                if let self {
                    do {
                        let state = try await self.authService.fetchLambdaPoolState()
                        self.lambdaPoolState = state
                        self.lambdaPoolReady = state.status == "ready"
                        self.lambdaPoolEtaSeconds = state.etaSeconds
                    } catch {
                        self.lambdaPoolReady = false
                        self.lambdaPoolState = nil
                    }
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    func stopLambdaStatusPolling() {
        lambdaStatusPollTask?.cancel()
        lambdaStatusPollTask = nil
    }

    /// Show a toast for ~5 seconds. Later banners replace earlier ones; the
    /// timed clear only fires if its own text is still showing.
    func showTransientBanner(_ text: String) {
        transientBanner = text
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if self?.transientBanner == text { self?.transientBanner = nil }
        }
    }

    /// The warming-up notice for Edit taps while the H100 isn't ready. Also
    /// kicks ensure so the tap itself starts (or hurries) the boot.
    func showLambdaWarmingBanner() {
        ensureLambdaPool()
        let eta: String
        if let s = lambdaPoolEtaSeconds {
            eta = s < 100 ? "~\(s) seconds" : "~\(Int((Double(s) / 60).rounded())) minutes"
        } else {
            eta = "a few minutes"
        }
        showTransientBanner("Kiki's magic AI is still warming up! Ready in \(eta).")
    }

    /// Edit → convert the current generated image to an editable sketch and
    /// import it as a new canvas layer (existing layers kept, hidden). One
    /// undo restores the previous layer stack.
    func sketchifyToCanvas(mode: SketchifyMode) {
        guard !sketchifyInProgress else { return }
        guard let image = resultState.displayImage,
              let jpeg = image.jpegData(compressionQuality: 0.92) else { return }
        guard lambdaPoolReady else {
            showLambdaWarmingBanner()
            return
        }
        sketchifyInProgress = true
        Task { @MainActor in
            defer { sketchifyInProgress = false }
            do {
                let sketchData = try await authService.sketchify(imageJpeg: jpeg, mode: mode.rawValue)
                guard let sketch = UIImage(data: sketchData) else {
                    showTransientBanner("Couldn't read the sketch — try again.")
                    return
                }
                if !canvasViewModel.importImageAsNewLayer(sketch, name: "AI Sketch") {
                    showTransientBanner("Layer limit reached — delete a layer first.")
                }
            } catch AuthService.SketchifyError.notReady(let etaSeconds) {
                lambdaPoolReady = false
                lambdaPoolEtaSeconds = etaSeconds
                showLambdaWarmingBanner()
            } catch {
                showTransientBanner("Sketchify failed — try again in a moment.")
                Log.info("sketchify.failed", attributes: [
                    "event": "sketchify.failed",
                    "error": String(describing: error),
                ])
            }
        }
    }

    // MARK: - AI Edit (inpaint via POST /v1/edit)

    enum AIEditPhase: Equatable {
        case idle
        /// Request in flight (~3-5 s on a warm fal pool).
        case generating
        /// Result composited and showing as a visual-only preview over the
        /// canvas; waiting for Accept / Retry / Discard.
        case preview
    }

    /// Presents the AI Edit prompt sheet.
    var showAIEditSheet = false
    private(set) var aiEditPhase: AIEditPhase = .idle
    var aiEditPrompt = ""
    /// Raw model params (surfaced in the sheet's Advanced disclosure).
    var aiEditSteps = 8
    /// Blank = random seed each generation.
    var aiEditSeedText = ""
    /// True when the current/last edit was scoped to a selection.
    private(set) var aiEditIsRegion = false

    /// Captured at Generate time so Retry re-rolls against the exact same
    /// source + mask even if the selection changes meanwhile.
    private var aiEditSourceCG: CGImage?
    private var aiEditMaskCG: CGImage?
    /// Dashed-red marker overlay drawn onto the uploaded image for region
    /// edits, so the model can SEE the target ("fit the new content inside the
    /// marked area"). Without it, content sprawls past the selection and the
    /// masked composite amputates it at the boundary (the "seam" bug).
    private var aiEditMarkerCG: CGImage?
    /// What Accept commits: full result (full scope) or masked region with
    /// transparency outside the selection (region scope).
    private var aiEditCommitImage: UIImage?
    private var aiEditTask: Task<Void, Never>?

    /// Source/mask resolution sent to the model (klein edit caps ~1 MP).
    private static let aiEditSide = 1024
    /// Wide mask feather (gaussian sigma, px at aiEditSide): the region result
    /// blends into the untouched drawing over a ~2·sigma band instead of a
    /// razor cut. Safe to be generous because the marker prompt keeps the
    /// model's new content away from the boundary (measured 2026-07-19).
    private static let aiEditMaskFeather = 20.0
    private static let aiEditCIContext = CIContext(
        options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]
    )

    /// Kick off an AI Edit from the sheet. Scope is implicit: an active lasso
    /// or wand selection → region edit (masked client-side); none → whole
    /// drawing. Captures the flattened composite + mask, then generates.
    func startAIEdit() {
        guard aiEditPhase != .generating else { return }
        let prompt = aiEditPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        guard let source = canvasViewModel.editSourceSnapshot(side: Self.aiEditSide) else {
            showTransientBanner("Draw something first — the canvas is empty.")
            return
        }
        let isRegion = canvasViewModel.hasSelectionForEdit
        let mask = isRegion ? canvasViewModel.selectionMaskForEdit(side: source.width) : nil
        aiEditSourceCG = source
        aiEditMaskCG = mask
        aiEditMarkerCG = isRegion ? canvasViewModel.selectionMarkerForEdit(side: source.width) : nil
        aiEditIsRegion = mask != nil
        Analytics.track(.aiEditRequested, properties: [
            "scope": aiEditIsRegion ? "region" : "full",
            "steps": aiEditSteps,
        ])
        runAIEdit()
    }

    /// Re-roll the last edit (same source + mask; random seed unless pinned).
    func retryAIEdit() {
        guard aiEditPhase == .preview else { return }
        runAIEdit()
    }

    private func runAIEdit() {
        guard let source = aiEditSourceCG else { return }
        // Region edits upload the source WITH the dashed-red marker composited
        // on, and wrap the user's instruction in a containment template. The
        // model reliably places content inside the marker and removes it; the
        // feathered masked composite then guarantees the outside anyway.
        var uploadCG = source
        let userPrompt = aiEditPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var prompt = userPrompt
        if aiEditIsRegion, let marker = aiEditMarkerCG {
            let sourceCI = CIImage(cgImage: source)
            let markedCI = CIImage(cgImage: marker).composited(over: sourceCI)
            if let cg = Self.aiEditCIContext.createCGImage(
                markedCI, from: sourceCI.extent, format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
            ) {
                uploadCG = cg
            }
            prompt = "Inside the area marked with the dashed red outline: \(userPrompt). "
                + "Draw the new content so it fits entirely inside the marked area and "
                + "matches the style of the rest of the image. Completely remove the "
                + "dashed red outline marker and the red tint. Keep everything outside "
                + "the marked area exactly the same."
        }
        guard let jpeg = UIImage(cgImage: uploadCG).jpegData(compressionQuality: 0.92) else { return }
        aiEditPhase = .generating
        let seed = Int(aiEditSeedText.trimmingCharacters(in: .whitespaces))
        let steps = aiEditSteps
        let scope = aiEditIsRegion ? "region" : "full"
        aiEditTask?.cancel()
        aiEditTask = Task { @MainActor in
            do {
                let result = try await authService.editImage(
                    image: jpeg, prompt: prompt, scope: scope, steps: steps,
                    seed: seed, width: source.width, height: source.height
                )
                guard !Task.isCancelled else { return }
                guard let resultUI = UIImage(data: result.image), let resultCG = resultUI.cgImage else {
                    throw AuthService.EditError.failed("unreadable result image")
                }
                applyAIEditResult(resultCG)
            } catch is CancellationError {
                // discarded mid-flight — state already reset
            } catch AuthService.EditError.freeLimitReached {
                aiEditPhase = .idle
                showTransientBanner("You've used this month's free AI budget. Subscribe for unlimited edits.")
            } catch {
                guard !Task.isCancelled else { return }
                aiEditPhase = .idle
                showTransientBanner("AI Edit failed — try again in a moment.")
                Log.info("ai_edit.failed", attributes: [
                    "event": "ai_edit.failed",
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// Composite the returned image and enter preview. Region scope: the
    /// commit image is the result masked to the selection (feathered alpha,
    /// transparent outside — outside-selection pixels are guaranteed
    /// untouched); the preview blends it over the captured source. Full
    /// scope: result is both. All Core Image; the sRGB output tag + the
    /// module's CI-based layer load keep the color pipeline correct.
    private func applyAIEditResult(_ resultCG: CGImage) {
        guard let source = aiEditSourceCG else { return }
        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        var resultCI = CIImage(cgImage: resultCG)
        // fal may return a slightly different size than requested — normalize
        // onto the source grid so the mask lines up pixel-for-pixel.
        if resultCG.width != source.width || resultCG.height != source.height {
            resultCI = resultCI.transformed(by: CGAffineTransform(
                scaleX: CGFloat(source.width) / CGFloat(resultCG.width),
                y: CGFloat(source.height) / CGFloat(resultCG.height)
            ))
        }

        let commitCI: CIImage
        let previewCI: CIImage
        if let mask = aiEditMaskCG {
            let maskCI = CIImage(cgImage: mask)
                .applyingGaussianBlur(sigma: Self.aiEditMaskFeather)
                .cropped(to: extent)
            let sourceCI = CIImage(cgImage: source)

            let commitBlend = CIFilter.blendWithMask()
            commitBlend.inputImage = resultCI
            commitBlend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
            commitBlend.maskImage = maskCI
            guard let commit = commitBlend.outputImage else { return }
            commitCI = commit

            let previewBlend = CIFilter.blendWithMask()
            previewBlend.inputImage = resultCI
            previewBlend.backgroundImage = sourceCI
            previewBlend.maskImage = maskCI
            guard let preview = previewBlend.outputImage else { return }
            previewCI = preview
        } else {
            commitCI = resultCI
            previewCI = resultCI
        }

        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let commitCG = Self.aiEditCIContext.createCGImage(commitCI, from: extent, format: .RGBA8, colorSpace: srgb),
              let previewCG = Self.aiEditCIContext.createCGImage(previewCI, from: extent, format: .RGBA8, colorSpace: srgb)
        else {
            aiEditPhase = .idle
            showTransientBanner("AI Edit failed — try again in a moment.")
            return
        }
        aiEditCommitImage = UIImage(cgImage: commitCG)
        canvasViewModel.setEditPreview(UIImage(cgImage: previewCG))
        aiEditPhase = .preview
    }

    /// Accept → the edit lands as a NEW top layer (existing layers stay
    /// visible; region commits carry transparency outside the mask). One undo
    /// restores the previous stack.
    func acceptAIEdit() {
        guard aiEditPhase == .preview, let image = aiEditCommitImage else { return }
        if !canvasViewModel.addEditResultLayer(image, name: "AI Edit") {
            showTransientBanner("Layer limit reached — delete a layer first.")
            return
        }
        Analytics.track(.aiEditAccepted, properties: ["scope": aiEditIsRegion ? "region" : "full"])
        clearAIEditState()
    }

    /// Discard the preview (or cancel an in-flight generation).
    func discardAIEdit() {
        if aiEditPhase == .preview {
            Analytics.track(.aiEditDiscarded, properties: ["scope": aiEditIsRegion ? "region" : "full"])
        }
        clearAIEditState()
    }

    private func clearAIEditState() {
        aiEditTask?.cancel()
        aiEditTask = nil
        aiEditSourceCG = nil
        aiEditMaskCG = nil
        aiEditMarkerCG = nil
        aiEditCommitImage = nil
        canvasViewModel.setEditPreview(nil)
        aiEditPhase = .idle
    }

    /// LTX-2.3 video override — square resolution (px). Session-only by design:
    /// not @AppStorage, so each app launch resets to the perf baseline (512).
    /// Step 3.5 benchmark needs deterministic baselines per launch.
    var videoResolution: Int = 512 { didSet { syncStreamConfig() } }

    /// LTX-2.3 video override — frame count. Session-only (see `videoResolution`).
    var videoFrames: Int = 145 { didSet { syncStreamConfig() } }

    /// LTX-2.3 video override — cinematic prompt suffix. Session-only (see `videoResolution`).
    var videoPromptSuffix: String = AppCoordinator.defaultVideoPromptSuffix {
        didSet { syncStreamConfig() }
    }

    static let defaultVideoPromptSuffix = (
        "Subtle natural motion throughout the scene with gentle organic movement. "
        + "Slow cinematic camera with a barely perceptible push-in. "
        + "Soft natural lighting, calm atmosphere, high detail."
    )

    /// LTX-2.3 diagnostic — when true, every video request triggers a
    /// `torch.profiler` capture on the pod (Chrome trace JSON + summary
    /// txt + meta JSON written to `/tmp/ltx-profile-*` for SCP-out).
    /// Adds ~15–25% latency to each request while on. Session-only:
    /// resets to false on each app launch so we never accidentally
    /// ship profiled performance to a real test.
    var enableProfiling: Bool = false { didSet { syncStreamConfig() } }

    /// Capture FPS for stream mode.
    var streamCaptureFPS: Double = 5 {
        didSet { streamSession?.captureInterval = 1.0 / streamCaptureFPS }
    }

    // MARK: - Private State

    private var lastSuccessfulImage: UIImage?
    private var canvasObservationTask: Task<Void, Never>?

    // MARK: - Lifecycle

    init(
        modelContext: ModelContext,
        backendURL: URL = URL(string: "https://kiki-backend-production-eb81.up.railway.app")!,
        // Kiki Insights microsite base URL (internal per-user analytics). The
        // sink no-ops while nil; set to the deployed service to enable the
        // event mirror + drawing upload.
        insightsURL: URL? = URL(string: "https://kiki-insights-production.up.railway.app")
    ) {
        self.modelContext = modelContext
        self.backendURL = backendURL
        self.authService = AuthService(backendURL: backendURL)

        // StoreKit manager posts each verified transaction's signed JWS to the
        // backend (which lifts the fal cap). `verify` is injected to keep the
        // manager decoupled from the networking layer.
        let authForSub = self.authService
        self.subscriptionManager = SubscriptionManager(verify: { jws in
            _ = try await authForSub.verifySubscription(jws: jws)
        })

        // Wire the Insights mirror. Reuses the existing access token (no new
        // client secret); events queue until a token exists.
        let auth = self.authService
        Task {
            await InsightsSink.shared.configure(baseURL: insightsURL) {
                try? await auth.currentAccessToken()
            }
        }

        if let stored = UserDefaults.standard.string(forKey: "drawingLayout"),
           let layout = DrawingLayout(rawValue: stored) {
            self.drawingLayout = layout
        }

        // Simulator dev bypass: seed Keychain from launch-argument tokens
        // BEFORE the auth gate below reads it, and start the stroke-replay
        // listener. Both are no-ops outside DEBUG simulator builds.
        DevAutomation.injectAuthIfRequested()
        DevAutomation.startReplayListener()
        #if DEBUG
        WandSelfTest.runIfRequested()
        // Canvas image-load self-test (`-KikiCanvasLoadSelfTest 1`): verifies the
        // save→load pixel round trip on this exact runtime and logs a PASS/FAIL
        // line readable via `ipad.sh logs` / `sim.sh logs`. Added while chasing
        // the reopen-blank data loss (CIContext.render(to:texture) no-op).
        if UserDefaults.standard.bool(forKey: "KikiCanvasLoadSelfTest") {
            let report = CanvasLoadSelfTest.report()
            Logger(subsystem: "com.kiki.app", category: "CanvasLoadSelfTest")
                .warning("self-test: \(report, privacy: .public)")
            // Also ship to Sentry so the verdict is readable when the device
            // has no USB log access (wifi-paired devicectl only).
            SentrySDK.capture(message: "CanvasLoadSelfTest: \(report)")
        }
        #endif
        DevAutomation.onReplayRequested = { [weak self] fixture in
            self?.devReplayFixture(fixture)
        }
        DevAutomation.onUIActionRequested = { [weak self] action in
            self?.devPerformUIAction(action)
        }

        // Gate on auth: if no Keychain token, show sign-in. Otherwise the
        // normal gallery/drawing flow resumes.
        let initialUserId = KeychainStore.default.get("userId")
        self.signedInUserId = initialUserId
        if initialUserId == nil {
            currentScreen = .signIn
        } else {
            // Re-sync subscription entitlements on launch: posts any current
            // StoreKit entitlement to the backend (reconciles a missed webhook /
            // fresh install) and updates local status for the paywall.
            Task { @MainActor [subscriptionManager] in
                await subscriptionManager.refreshEntitlements()
            }
            refreshUsage()
            // Pre-warm the Lambda H100 dev instance at every launch of a
            // signed-in (test) account so it's ready if the provider toggle
            // flips to lambda. Backend-gated; harmless 403 otherwise.
            ensureLambdaPool()

            // A user who has never made a drawing with content goes directly
            // to a drawing instead of the gallery.
            routeToDrawingIfNoContent()
        }

        applyTool()
        startObservingCanvas()

        // Cold launch = first foreground. scenePhase onChange may not fire for
        // the initial .active value, so open the app session here; subsequent
        // foregrounds go through handleScenePhaseChange (idempotent).
        markForegrounded()

        // Start the stream as soon as the app launches with a signed-in
        // user, so the fal relay is connected before the first stroke.
        if signedInUserId != nil {
            startStream()
            seedResultStateForCurrentDrawing()
        }

        // Eyedropper: commit picked colors to currentColor
        canvasViewModel.onColorPicked = { [weak self] uiColor in
            self?.currentColor = Color(uiColor: uiColor)
        }
        // Per-session stroke counter (drawing.closed analytics) + DEV stroke
        // recorder: capture completed strokes while recording is on.
        canvasViewModel.onStrokeCompleted = { [weak self] stroke in
            guard let self else { return }
            self.sessionStrokeCount += 1
            guard self.isRecordingStrokes else { return }
            self.recordedStrokes.append(stroke)
        }
        // Idle stream guard: any canvas mutation (stroke, eraser, undo, fixture
        // replay) counts as activity and wakes a resting stream.
        canvasViewModel.onContentChanged = { [weak self] in
            self?.noteInteraction()
        }
        // Locked layer: tell the user why their stroke did nothing.
        canvasViewModel.onLockedLayerStrokeRefused = { [weak self] in
            self?.showTransientBanner("This layer is locked — unlock it in Layers to draw.")
        }
        // Supply the current brush color to the canvas ring preview
        canvasViewModel.currentBrushColorProvider = { [weak self] in
            UIColor(self?.currentColor ?? .black)
        }
        // QuickShape telemetry — forward recognizer lifecycle events to analytics.
        canvasViewModel.onSnapEvent = { event in
            Self.trackSnapEvent(event)
        }
        // QuickShape NUX tooltip — observed by DrawingView via @Observable.
        canvasViewModel.onFirstBrushStrokeCommitted = { [weak self] in
            self?.shouldShowQuickShapeTooltip = true
        }
        // Selection: segment what the user is actually looking at — the
        // generated image in overlay mode (locked 1:1 over the canvas square),
        // else the flattened canvas itself.
        canvasViewModel.selection.sourceImageProvider = { [weak self] in
            guard let self else { return nil }
            if self.drawingLayout == .overlay, let generated = self.resultState.displayImage?.cgImage {
                return generated
            }
            return self.canvasViewModel.selectionCanvasSnapshot()
        }
    }

    /// Translate a SnapEvent into a typed Analytics call. Property keys are
    /// snake_case to match the rest of our event schema.
    private static func trackSnapEvent(_ event: SnapEvent) {
        switch event {
        case .committed(let info):
            Analytics.track(.strokeSnapCommitted, properties: [
                "verdict": info.verdict,
                "confidence": info.confidence,
                "stroke_duration_sec": info.strokeDurationSec,
                "path_length": Double(info.snapshot.pathLength),
                "bbox_diagonal": Double(info.snapshot.bboxDiagonal),
                "sagitta_ratio": Double(info.snapshot.sagittaRatio),
                "signed_turn_deg": Double(info.snapshot.totalSignedTurnDeg),
                "abs_turn_deg": Double(info.snapshot.totalAbsTurnDeg),
                "line_norm_rms": Double(info.snapshot.lineNormRMS),
                "resampled_n": info.snapshot.resampledPointCount,
                "line_score": Double(info.snapshot.lineScore),
            ])
        case .abstained(let info):
            var props: [String: Any] = [
                "reason": info.reason,
                "confidence": info.confidence,
            ]
            if let s = info.snapshot {
                props["path_length"] = Double(s.pathLength)
                props["bbox_diagonal"] = Double(s.bboxDiagonal)
                props["sagitta_ratio"] = Double(s.sagittaRatio)
                props["signed_turn_deg"] = Double(s.totalSignedTurnDeg)
                props["abs_turn_deg"] = Double(s.totalAbsTurnDeg)
                props["line_norm_rms"] = Double(s.lineNormRMS)
                props["resampled_n"] = s.resampledPointCount
                props["line_score"] = Double(s.lineScore)
            }
            Analytics.track(.strokeSnapAbstained, properties: props)
        case .undoneWithin2s(let info):
            var props: [String: Any] = [
                "original_verdict": info.originalVerdict,
                "elapsed_sec": info.elapsedSec,
            ]
            if let s = info.snapshot {
                props["sagitta_ratio"] = Double(s.sagittaRatio)
                props["signed_turn_deg"] = Double(s.totalSignedTurnDeg)
                props["line_norm_rms"] = Double(s.lineNormRMS)
                props["line_score"] = Double(s.lineScore)
            }
            Analytics.track(.strokeSnapUndoneWithin2s, properties: props)
        case .previewCanceled(let info):
            Analytics.track(.strokeSnapPreviewCanceled, properties: [
                "reason": info.reason,
            ])
        }
    }

    // MARK: - Auth

    /// Exchange an Apple identity token for a backend JWT pair, then navigate
    /// to the main app. Called from SignInView. `email` is the credential's
    /// first-authorization-only one-shot value (nil on every later sign-in).
    func signInWithApple(identityToken: String, email: String? = nil) async throws {
        let transaction = SentrySDK.startTransaction(name: "auth.signIn", operation: "auth.signIn")
        do {
            try await authService.signInWithApple(identityToken: identityToken, nonce: nil, email: email)
            transaction.finish()
        } catch {
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "signInWithApple", key: "op")
            }
            transaction.finish(status: .internalError)
            throw error
        }
        let userId = await authService.userId
        let email = await authService.email
        await MainActor.run {
            // A stale "Please sign in again" banner (set when the token fetch
            // failed and forced sign-out) is resolved by this sign-in — clear
            // it now rather than waiting for the new stream to reach ready.
            self.generationError = nil
            self.signedInUserId = userId
            if let userId {
                Analytics.track(.userSignedIn, properties: ["user_id": userId])
                // Tag every Sentry event/log/span emitted on this device with
                // user.id so cross-stack queries `user_id:<X>` return iOS
                // logs alongside backend + pod. Cleared on sign-out below.
                SentrySDK.setUser(User(userId: userId))
                Log.info("auth.signed_in", attributes: [
                    "event": "auth.signed_in",
                    "user_id": userId,
                ])
                // Pre-warm the Lambda H100 dev instance on fresh sign-in
                // (mirrors the relaunch hook in init).
                self.ensureLambdaPool()
            }

            // After sign-in, route to gallery — or straight into a drawing
            // when the user has never made one with content.
            if !self.routeToDrawingIfNoContent() {
                self.currentScreen = .gallery
            }

            // Start the stream immediately so the fal relay is connected by
            // the time the user taps into a drawing.
            self.startStream()
            self.seedResultStateForCurrentDrawing()
        }
    }

    func signOut() {
        Task {
            // Notify the backend of the sign-out (marker endpoint — nothing
            // server-side to tear down anymore) BEFORE clearing the JWT so
            // the request is still authenticated. Best-effort — never throws.
            await authService.requestServerSignOut()
            await authService.signOut()
            await MainActor.run {
                Analytics.track(.userSignedOut)
                Log.info("auth.signed_out", attributes: ["event": "auth.signed_out"])
                // Clear user attribution so the next signed-in (or anonymous)
                // user's events don't get tagged with this user's id.
                SentrySDK.setUser(nil)
                self.signedInUserId = nil
                self.currentScreen = .signIn
                self.stopStream()
            }
        }
    }

    // MARK: - Actions

    func undo() {
        // Select active: undo steps back through selection edits (cancels an
        // in-flight Move first) before touching canvas history.
        if currentTool == .select, canvasViewModel.selection.canUndoStep {
            canvasViewModel.selection.undoStep()
            return
        }
        canvasViewModel.undo()
    }

    func redo() {
        canvasViewModel.redo()
    }

    func swapStreamImageToCanvas() {
        guard let image = lastSuccessfulImage else { return }
        canvasViewModel.swapLineart(image: image)
    }

    /// True when a generated frame is available to send to the canvas.
    var canSwapStreamImageToCanvas: Bool {
        lastSuccessfulImage != nil
    }

    // MARK: - Sharing / Export

    /// The current generated still available to share, if any. Reads through
    /// `resultState` (the single source of truth for what's on the result pane)
    /// so the private `lastSuccessfulImage` stays encapsulated.
    var shareableImage: UIImage? { resultState.displayImage }

    /// Whether there's a generated result to share — drives the Share button's
    /// enabled state.
    var canShare: Bool { shareableImage != nil }

    /// Encode the current result to a temp file in `format` and return its URL
    /// for the native share sheet. `nil` if there's nothing to share or encoding
    /// fails. The file is named `Kiki.<ext>` so "Save to Files" shows a sensible
    /// name.
    func makeShareFile(_ format: ExportFormat) -> URL? {
        guard let image = shareableImage else { return nil }
        do {
            let url = try ExportFileProducer().makeFile(
                from: image,
                format: format,
                baseName: "Kiki",
                in: FileManager.default.temporaryDirectory
            )
            Analytics.track(.imageShared, properties: ["format": format.id])
            return url
        } catch {
            streamLog.error("Share export failed: \(error.localizedDescription)")
            SentrySDK.capture(error: error)
            return nil
        }
    }

    // MARK: - Selection copy/paste

    /// App-level clipboard for selection content: the masked cutout (with
    /// alpha, cropped to the selection bounds) plus its document-space rect so
    /// paste lands where the copy came from. Survives selection clearing and
    /// drawing switches; also mirrored to the system pasteboard as PNG.
    struct SelectionClipboard {
        let image: CGImage
        let rectInDocPixels: CGRect
    }

    private(set) var selectionClipboard: SelectionClipboard?

    var canCopySelection: Bool { canvasViewModel.hasSelectionForEdit }
    var canPasteSelection: Bool { selectionClipboard != nil && !canvasViewModel.isPasting }

    /// The selection's content as a transparent cutout: visible strokes ×
    /// selection mask, cropped to the selection bounds. Returns the image and
    /// its rect in 2048² document space (position independent of snapshot
    /// resolution). Shared by Copy, Save-to-Objects.
    private func selectionCutout() -> (image: CGImage, rectInDocPixels: CGRect)? {
        guard let source = canvasViewModel.transparentSnapshot(),
              let mask = canvasViewModel.selectionMaskForEdit(side: source.width),
              let bbox = Self.maskBoundingBox(mask) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = CIImage(cgImage: source)
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = CIImage(cgImage: mask).cropped(to: extent)
        guard let out = blend.outputImage else { return nil }
        let maskH = CGFloat(mask.height)
        let cropCI = CGRect(x: bbox.minX, y: maskH - bbox.maxY, width: bbox.width, height: bbox.height)
        guard let cg = Self.aiEditCIContext.createCGImage(
            out, from: cropCI, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ) else { return nil }
        let docScale = CGFloat(2048) / CGFloat(source.width)
        let rect = CGRect(
            x: bbox.minX * docScale, y: bbox.minY * docScale,
            width: bbox.width * docScale, height: bbox.height * docScale
        )
        return (cg, rect)
    }

    // MARK: - Layer Options actions (layer panel side menu)

    /// Procreate "Copy" layer option: put the layer's full contents (with
    /// alpha) on the system pasteboard AND the in-app selection clipboard, so
    /// the existing sidebar Paste can float it right away.
    func copyLayer(at index: Int) {
        guard let cg = canvasViewModel.layerImage(at: index) else { return }
        let image = UIImage(cgImage: cg)
        UIPasteboard.general.image = image
        // Full-document rect: the layer image spans the whole 2048² canvas.
        selectionClipboard = SelectionClipboard(
            image: cg,
            rectInDocPixels: CGRect(x: 0, y: 0, width: 2048, height: 2048)
        )
        showTransientBanner("Layer copied — paste from the left sidebar.")
    }

    /// Procreate "Select" layer option: selection = the layer's painted
    /// pixels. Switches to the Select tool so the ants/panel appear.
    func selectLayerContents(at index: Int) {
        currentTool = .select
        if !canvasViewModel.selectLayerContents(at: index) {
            showTransientBanner("This layer is empty — nothing to select.")
        }
    }

    /// Copy the selection's content (visible strokes only, transparent
    /// elsewhere) into the clipboard + system pasteboard.
    func copySelection() {
        guard let cut = selectionCutout() else { return }
        selectionClipboard = SelectionClipboard(image: cut.image, rectInDocPixels: cut.rectInDocPixels)
        UIPasteboard.general.image = UIImage(cgImage: cut.image)
        Analytics.track(.selectionCopied)
        showTransientBanner("Copied — paste from the left sidebar.")
    }

    /// Paste the clipboard as a floating, movable overlay (offset slightly so
    /// pasting over the source is visible). Commit/cancel via the paste bar.
    func pasteSelection() {
        guard let clip = selectionClipboard else { return }
        let offset: CGFloat = 48
        let rect = clip.rectInDocPixels.offsetBy(dx: offset, dy: offset)
        if canvasViewModel.beginPaste(image: clip.image, rectInDocPixels: rect) {
            Analytics.track(.selectionPasted)
        }
    }

    // MARK: - Object library (grab → reuse across drawings)

    /// Presents the objects drawer (toolbar shippingbox button).
    var showObjectsDrawer = false

    /// Cut the current selection (same masked cutout as Copy) and persist it
    /// as a reusable object in the library.
    func saveSelectionToObjects() {
        guard let cut = selectionCutout(),
              let png = UIImage(cgImage: cut.image).pngData() else { return }
        let object = SavedObject(
            name: "Object \(((try? modelContext.fetchCount(FetchDescriptor<SavedObject>())) ?? 0) + 1)",
            imageData: png,
            docWidth: cut.rectInDocPixels.width,
            docHeight: cut.rectInDocPixels.height
        )
        modelContext.insert(object)
        try? modelContext.save()
        Analytics.track(.objectSaved)
        showTransientBanner("Saved to your Objects — find them in the toolbar.")
    }

    /// Drop a saved object into the current drawing as a paste float
    /// (centered at its original size; drag/pinch to place, then Place).
    func insertObject(_ object: SavedObject) {
        guard let cg = object.image?.cgImage else { return }
        showObjectsDrawer = false
        let w = object.docWidth
        let h = object.docHeight
        let rect = CGRect(x: (2048 - w) / 2, y: (2048 - h) / 2, width: w, height: h)
        if canvasViewModel.beginPaste(image: cg, rectInDocPixels: rect) {
            Analytics.track(.objectInserted)
        }
    }

    func deleteObject(_ object: SavedObject) {
        if pinnedObjectID == object.id { unpinObject() }
        modelContext.delete(object)
        try? modelContext.save()
    }

    // MARK: - Object identity conditioning (pin as generation reference)

    /// The object currently riding the generation stream as an identity
    /// reference (Lambda KV pipeline multi-reference; the fal relay ignores
    /// the key). Session-scoped: cleared on unpin/delete; re-pin per launch.
    private(set) var pinnedObjectID: UUID?
    /// Pre-encoded ≤512px JPEG base64 of the pinned object (composited on
    /// white — klein wants RGB), built once at pin time.
    private var pinnedObjectB64: String?

    func pinObject(_ object: SavedObject) {
        guard let image = object.image else { return }
        let maxSide: CGFloat = 512
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let composited = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = composited.jpegData(compressionQuality: 0.85) else { return }
        pinnedObjectID = object.id
        pinnedObjectB64 = jpeg.base64EncodedString()
        Analytics.track(.objectPinned)
        showTransientBanner("\(object.name) pinned — Kiki keeps its look in mind while generating.")
        syncStreamConfig()
    }

    func unpinObject() {
        pinnedObjectID = nil
        pinnedObjectB64 = nil
        syncStreamConfig()
    }

    // MARK: - Object 3D lift + placement (stage 3)

    /// Object currently being lifted to 3D (drawer shows a spinner on it).
    private(set) var liftingObjectID: UUID?
    /// Object presented in the 3D placement sheet.
    var placingObject: SavedObject?

    /// Lift an object's cutout to a canonical 3D model (USDZ via backend ->
    /// Hunyuan3D). 1-4 min; the drawer stays usable meanwhile.
    func liftObjectTo3D(_ object: SavedObject) {
        guard liftingObjectID == nil, var png = object.imageData else { return }
        // fal's Hunyuan endpoint rejects images with any side under 128 px
        // ("Image resolution only support [128, 5000]") — upscale small
        // cutouts to a 256 px short side before upload.
        if let image = UIImage(data: png), min(image.size.width, image.size.height) < 128 {
            let minDim = max(min(image.size.width, image.size.height), 1)
            let maxDim = max(image.size.width, image.size.height, 1)
            let upscale = max(1, min(256 / minDim, 4000 / maxDim))
            let size = CGSize(
                width: (image.size.width * upscale).rounded(),
                height: (image.size.height * upscale).rounded()
            )
            let format = UIGraphicsImageRendererFormat()
            format.preferredRange = .standard
            format.scale = 1
            let scaled = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: size))
            }
            png = scaled.pngData() ?? png
        }
        liftingObjectID = object.id
        showTransientBanner("Building a 3D model of \(object.name) — takes a minute or two.")
        Analytics.track(.objectLifted, properties: ["object_id": object.id.uuidString])
        Analytics.track(.liftStarted, properties: ["source": "drawer"])
        let t0 = Date()
        Task { @MainActor in
            defer { liftingObjectID = nil }
            do {
                let result = try await authService.lift3d(image: png)
                let ms = Int(-t0.timeIntervalSinceNow * 1000)
                ExtractController.recordLiftDuration(ms: ms)
                Analytics.track(.liftCompleted, properties: [
                    "source": "drawer", "duration_ms": ms, "glb_bytes": result.glb.count,
                ])
                object.meshData = result.glb
                object.meshThumbData = result.thumbnail
                try? modelContext.save()
                showTransientBanner("\(object.name) is 3D now — tap it to place from any angle.")
            } catch {
                Analytics.track(.liftFailed, properties: [
                    "source": "drawer",
                    "duration_ms": Int(-t0.timeIntervalSinceNow * 1000),
                    "error": String(describing: error),
                ])
                showTransientBanner("3D lift failed — try again in a bit.")
                Log.info("lift3d.failed", attributes: [
                    "event": "lift3d.failed",
                    "error": String(describing: error),
                ])
            }
        }
    }

    /// Called by the placement sheet: paste a rendered view of the 3D model
    /// as a float (transparent snapshot, sized relative to the document).
    func placeRenderedObject(_ image: UIImage) {
        placingObject = nil
        showObjectsDrawer = false
        guard let cg = image.cgImage else { return }
        let maxSide: CGFloat = 900 // document px; the float is scalable anyway
        let aspect = image.size.height / max(image.size.width, 1)
        let w = min(maxSide, 2048)
        let h = w * aspect
        let rect = CGRect(x: (2048 - w) / 2, y: (2048 - h) / 2, width: w, height: h)
        if canvasViewModel.beginPaste(image: cg, rectInDocPixels: rect) {
            Analytics.track(.objectInserted, properties: ["mode": "3d"])
        }
    }

    // MARK: - Extract screen (tap the generated image → 3D lifts)

    var showExtract = false
    private(set) var extract: ExtractController?

    /// Open Extract on the current generated image (the high-quality
    /// artifact — extraction never uses the sketch).
    func openExtract() {
        guard let image = resultState.displayImage else { return }
        noteInteraction()
        // The stream has no business running under the Extract cover (same as
        // the Animate screen) — and SAM inference on top of a live relay was
        // pushing the app into watchdog RAM kills (Sentry KIKI-APP-IOS-1).
        stopStream()
        extract = ExtractController(
            image: image, authService: authService, modelContext: modelContext
        )
        showExtract = true
        Analytics.track(.extractOpened)
    }

    func closeExtract() {
        showExtract = false
        if let controller = extract, controller.hasActiveLifts {
            // Lifts keep running after the screen closes (the in-flight Tasks
            // retain the controller): finished ones auto-save into Objects,
            // then toast + badge the objects-drawer button.
            controller.isPresented = false
            controller.onBackgroundLiftResult = { [weak self] name, success in
                guard let self else { return }
                if success {
                    objectsDrawerBadge += 1
                    showTransientBanner("\(name) is 3D now — it's in your Objects (the box icon up top).")
                } else {
                    showTransientBanner("A 3D lift didn't work out — open Extract to retry.")
                }
            }
        }
        extract = nil
        if currentScreen == .drawing {
            startStream()
        }
    }

    /// Count of background lifts finished since the objects drawer was last
    /// opened — shown as a badge on the toolbar's shippingbox button.
    var objectsDrawerBadge = 0

    // MARK: - Sticker sharing

    /// Whether a sticker can be cut: needs an active selection to mask with.
    var canShareSticker: Bool { canvasViewModel.hasSelectionForEdit }

    /// Cut the current selection out of what the user sees (generated image in
    /// overlay layout, else the flattened canvas) as a transparent PNG sticker,
    /// cropped to the selection's bounding box. Returns a temp-file URL for the
    /// native share sheet; nil when there's no selection or the cut fails.
    func makeStickerFile() -> URL? {
        guard canvasViewModel.hasSelectionForEdit else { return nil }
        let sourceCG: CGImage? = if drawingLayout == .overlay, let gen = resultState.displayImage {
            gen.cgImage
        } else {
            canvasViewModel.editSourceSnapshot(side: Self.aiEditSide)
        }
        guard let source = sourceCG,
              let mask = canvasViewModel.selectionMaskForEdit(side: source.width),
              let bbox = Self.maskBoundingBox(mask) else { return nil }

        // Document and mask are the same square space (mask side = source
        // width); the generated image and canvas snapshots are both square.
        guard source.width == source.height, mask.width == source.width else { return nil }
        let extent = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        // Tiny feather so the cut edge doesn't alias.
        let maskCI = CIImage(cgImage: mask)
            .applyingGaussianBlur(sigma: 1)
            .cropped(to: extent)
        let sourceCI = CIImage(cgImage: source)
        let blend = CIFilter.blendWithMask()
        blend.inputImage = sourceCI
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = maskCI
        guard let out = blend.outputImage else { return nil }
        // bbox is in top-left image coords; CI is bottom-left — flip Y.
        let maskH = CGFloat(mask.height)
        let cropCI = CGRect(x: bbox.minX, y: maskH - bbox.maxY, width: bbox.width, height: bbox.height)
        guard let cg = Self.aiEditCIContext.createCGImage(
            out, from: cropCI, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ), let png = UIImage(cgImage: cg).pngData() else { return nil }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("KikiSticker.png")
        do {
            try png.write(to: url, options: .atomic)
            Analytics.track(.imageShared, properties: ["format": "sticker"])
            return url
        } catch {
            streamLog.error("Sticker export failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Bounding box (top-left pixel coords, slightly padded) of non-black
    /// pixels in a grayscale mask image.
    private static func maskBoundingBox(_ mask: CGImage) -> CGRect? {
        guard let data = mask.dataProvider?.data as Data? else { return nil }
        let w = mask.width, h = mask.height, stride = mask.bytesPerRow
        var minX = w, minY = h, maxX = -1, maxY = -1
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            for y in 0..<h {
                let row = base + y * stride
                for x in 0..<w where row.load(fromByteOffset: x, as: UInt8.self) > 8 {
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 4
        return CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(w, maxX + pad) - max(0, minX - pad),
            height: min(h, maxY + pad) - max(0, minY - pad)
        )
    }

    // MARK: - Video sharing

    /// Whether there's a replay to share: either a finalized recording on disk,
    /// or enough live footage captured this session (so the button is available
    /// while drawing, not only after a gallery round-trip).
    var canShareVideo: Bool {
        if let id = currentDrawingId, RecordingStore.shared.hasRecording(id) { return true }
        return recordedCanvasFrames >= 2
    }

    /// Flush the in-progress recording to a stored segment so the replay includes
    /// the latest strokes. Recording continues afterward. Call before opening the
    /// replay modal.
    /// `consolidate: true` additionally merges all stored segments into one
    /// pair (lossless remux) — pass it on the pre-replay-modal flush so the
    /// preview composition references a single file per track (a composition
    /// referencing dozens of files can render black on iOS; see
    /// `RecordingStore.consolidate`). Never consolidate while a replay
    /// preview/export may be reading the segment files.
    func flushRecording(consolidate: Bool = false) async {
        guard let drawingId = currentDrawingId else { return }
        if let recorder, let urls = await recorder.checkpoint() {
            Self.appendSegmentReporting(canvasTemp: urls.canvas, generatedTemp: urls.generated, for: drawingId)
        }
        if consolidate {
            await Self.consolidateReporting(for: drawingId)
        }
    }

    /// `RecordingStore.consolidate` with failure reporting. A failure leaves
    /// the original segments in place — the replay still works, just with
    /// more files.
    private nonisolated static func consolidateReporting(for drawingId: UUID) async {
        do {
            try await RecordingStore.shared.consolidate(for: drawingId)
        } catch {
            streamLog.error("Recording consolidation failed: \(error.localizedDescription)")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "replay.consolidate", key: "op")
            }
        }
    }

    /// `RecordingStore.appendSegment` with failure reporting — a failed move
    /// here silently loses a replay segment, so it must never be `try?`.
    /// Nonisolated: called from `finalizeRecording`'s detached task.
    private nonisolated static func appendSegmentReporting(canvasTemp: URL, generatedTemp: URL, for drawingId: UUID) {
        do {
            try RecordingStore.shared.appendSegment(canvasTemp: canvasTemp, generatedTemp: generatedTemp, for: drawingId)
        } catch {
            streamLog.error("Recording segment append failed: \(error.localizedDescription)")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "replay.appendSegment", key: "op")
            }
        }
    }

    /// Stitch the current drawing's recorded segments into a playable
    /// composition for the replay modal's instant preview (no encode pass —
    /// the player renders layout + speed live).
    /// URL of this drawing's generated animation, when one has been saved.
    /// Backs the Share menu's "Animation (MP4)" item.
    var generatedAnimationURL: URL? {
        currentDrawingId.flatMap { RecordingStore.shared.generatedVideoURL(for: $0) }
    }

    func buildReplayComposition(layout: ReplayLayout, speed: ReplaySpeed) async -> SideBySideVideoComposer.BuiltReplay? {
        guard let drawingId = currentDrawingId else { return nil }
        let segments = RecordingStore.shared.segmentURLs(for: drawingId)
        guard !segments.canvas.isEmpty else {
            Log.error("replay.no_segments", attributes: [
                "event": "replay.no_segments",
                "drawing_id": drawingId.uuidString,
                "recorded_canvas_frames": recordedCanvasFrames,
            ])
            return nil
        }
        do {
            let built = try await SideBySideVideoComposer.build(
                canvasSegments: segments.canvas,
                generatedSegments: segments.generated,
                layout: layout,
                speed: speed
            )
            Log.info("replay.built", attributes: [
                "event": "replay.built",
                "segments": segments.canvas.count,
                "duration_s": built.composition.duration.seconds,
            ])
            Analytics.track(.replayBuilt, properties: [
                "segments": segments.canvas.count,
                "duration_s": built.composition.duration.seconds,
            ])
            return built
        } catch {
            streamLog.error("Replay build failed: \(error.localizedDescription)")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "replay.build", key: "op")
            }
            return nil
        }
    }

    /// Export the replay to an MP4 for sharing (this is where the watermark is
    /// burned). Writes a fresh file in its own temp dir (so a preview player
    /// never reads a file being overwritten), named "Speed Paint.mp4" for a
    /// clean Save-to-Files name.
    func composeReplay(layout: ReplayLayout, speed: ReplaySpeed, watermark: Bool) async -> URL? {
        guard let built = await buildReplayComposition(layout: layout, speed: speed) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = dir.appendingPathComponent("Speed Paint.mp4")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await SideBySideVideoComposer.export(built, outputURL: output, watermark: watermark)
            return output
        } catch is CancellationError {
            // Superseded eager export (settings changed mid-encode) — expected.
            return nil
        } catch {
            streamLog.error("Replay export failed: \(error.localizedDescription)")
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "replay.export", key: "op")
            }
            return nil
        }
    }

    /// Finalize a session recording off the main thread, holding a background
    /// task assertion so `finishWriting` can complete if the app is backgrounding.
    private func finalizeRecording(_ recorder: DrawingVideoRecorder, drawingId: UUID) {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "finalize-recording")
        Task.detached {
            if let urls = await recorder.finish() {
                Self.appendSegmentReporting(canvasTemp: urls.canvas, generatedTemp: urls.generated, for: drawingId)
                // Deliberately NO consolidation here: stopStream also fires
                // when the app backgrounds WHILE the replay modal is open,
                // and consolidation deletes the files the on-screen preview
                // composition is reading. The pre-modal flush consolidates,
                // which is the only moment it matters — segments merely
                // accumulate on disk until then.
            }
            await MainActor.run { UIApplication.shared.endBackgroundTask(bgTask) }
        }
    }

    // MARK: - Gallery / Persistence

    /// New-user routing: someone who has never made a drawing with content
    /// lands directly in a drawing, not an empty gallery. "Never made" means
    /// no drawing has content (`isContentEmpty`), not merely count == 0 — a
    /// blank auto-created drawing persists when the app is killed before
    /// `navigateToGallery()`'s cleanup runs, and must not strand the user in
    /// a gallery with one empty tile. Reuses the newest blank drawing when
    /// one exists instead of stacking new ones. Returns true when it routed.
    @discardableResult
    private func routeToDrawingIfNoContent() -> Bool {
        let descriptor = FetchDescriptor<Drawing>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        let drawings = (try? modelContext.fetch(descriptor)) ?? []
        guard drawings.allSatisfy(\.isContentEmpty) else { return false }
        if let existing = drawings.first {
            currentDrawingId = existing.id
        } else {
            let drawing = Drawing()
            modelContext.insert(drawing)
            try? modelContext.save()
            currentDrawingId = drawing.id
        }
        currentScreen = .drawing
        return true
    }

    func newDrawing() {
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        isSuppressingObservation = true

        // Generate a stable seed for this drawing
        let seed = Int.random(in: 0...Int(UInt32.max))
        let drawing = Drawing(streamSeed: seed)
        modelContext.insert(drawing)
        try? modelContext.save()
        currentDrawingId = drawing.id
        currentDrawingOpenedAt = Date()
        sessionStrokeCount = 0

        // Reset all state
        promptText = ""
        animationPromptText = ""
        selectedStyle = .default
        streamSeed = seed
        lastSuccessfulImage = nil
        panelOffset = .zero
        panelScale = 1.0
        panelHole = PanelHole()

        canvasViewModel.setPendingState(nil)

        currentScreen = .drawing
        isSuppressingObservation = false

        Analytics.track(.drawingCreated, properties: ["drawing_id": drawing.id.uuidString])
        Analytics.track(.drawingOpened, properties: [
            "drawing_id": drawing.id.uuidString,
            "stroke_count": 0,
            "is_new": true,
        ])

        startStream()
        seedResultStateForCurrentDrawing()
    }

    /// Simulator dev automation: replay a recorded stroke fixture onto the live
    /// canvas (triggered via DevAutomation's Darwin notification). Routes into a
    /// drawing first when needed and waits for the canvas view to attach — the
    /// canvas is created lazily when DrawingView appears.
    /// Simulator dev automation: perform a named UI action (DevAutomation
    /// bridge). Deliberately tiny — just the surfaces host-level tooling
    /// can't tap (popovers/modals) plus navigation.
    func devPerformUIAction(_ action: String) {
        switch action {
        case "openDrawing":
            if currentScreen == .gallery { openMostRecentDrawing() }
        case "statusDetails":
            devShowStatusDetails = true
        case "colorPicker":
            devShowColorPicker = true
        case let a where a.hasPrefix("brushStudio"):
            // "brushStudio" or "brushStudio:<StudioSection rawValue>" (e.g.
            // "brushStudio:Apple Pencil") to open on a specific tab.
            if currentScreen == .drawing {
                if let colon = a.firstIndex(of: ":") {
                    devStudioSection = StudioSection(rawValue: String(a[a.index(after: colon)...]))
                }
                showBrushStudio = true
            }
        case "animateModal", "animateScreen":
            // Legacy dev-action name kept: opens the Animate screen now.
            if currentScreen == .drawing {
                openAnimateFromDrawing()
            } else {
                openAnimateFromGallery()
            }
        case "animateGenerate":
            animate?.generate()
        case "animateExtend":
            if let controller = animate, let latest = controller.fetchClips().first {
                controller.extendFromLastFrame(of: latest)
            }
        case "animateExamples":
            animate?.showMotionExamples.toggle()
        #if DEBUG && targetEnvironment(simulator)
        case "replayModal", "replayScreen":
            // Legacy dev-action name kept: opens the replay share page now.
            openReplayFromDrawing()
        // Freehand rect through the REAL loop path (Select tool, current
        // add/remove mode applies).
        case "lasso":
            currentTool = .select
            canvasViewModel.selection.authorMode = .freehand
            canvasViewModel.devSimulateLasso()
        case "selectTool", "wandTool":
            currentTool = .select
        case "selectModeAuto":
            canvasViewModel.selection.authorMode = .auto
        case "selectModeFreehand":
            canvasViewModel.selection.authorMode = .freehand
        case "selectRemove":
            canvasViewModel.selection.mode = .subtract
        case "selectAdd":
            canvasViewModel.selection.mode = .add
        case "selectMove":
            canvasViewModel.selection.beginMove()
        case "selectCommitMove":
            canvasViewModel.selection.commitMove()
        case "wandClear", "selectClear":
            canvasViewModel.clearSelection()
        case "selectUndo":
            canvasViewModel.selection.undoStep()
        case "brushTool":
            currentTool = .brush
        // "wandTap:<u>,<v>[,neg]" — inject a selection prompt at normalized
        // canvas coords (simctl taps can't hit exact canvas UVs).
        case let cmd where cmd.hasPrefix("wandTap:"):
            let parts = cmd.dropFirst("wandTap:".count).split(separator: ",")
            if parts.count >= 2, let u = Double(parts[0]), let v = Double(parts[1]) {
                let positive = parts.count < 3 || parts[2] != "neg"
                currentTool = .select
                canvasViewModel.devSimulateWandTap(u: u, v: v, positive: positive)
            }
        // "wandFake:<u>,<v>,<r>" — synthetic circular mask object (the sim's
        // Core ML can't run SAM's decoder; exercises mask→path→clip).
        case let cmd where cmd.hasPrefix("wandFake:"):
            let parts = cmd.dropFirst("wandFake:".count).split(separator: ",")
            if parts.count >= 3, let u = Double(parts[0]), let v = Double(parts[1]),
               let r = Double(parts[2]) {
                currentTool = .select
                canvasViewModel.devSimulateWandMask(u: u, v: v, radiusFraction: r)
            }
        #endif
        #if DEBUG && targetEnvironment(simulator)
        case "gallery":
            if currentScreen == .drawing { navigateToGallery() }
        case "addLayer":
            canvasViewModel.addLayer()
        case "dupLayer":
            canvasViewModel.duplicateLayer(at: canvasViewModel.activeLayerIndex)
        case "clearLayer":
            canvasViewModel.clearLayer(at: canvasViewModel.activeLayerIndex)
        case "lockLayer":
            let i = canvasViewModel.activeLayerIndex
            canvasViewModel.setLayerLocked(!canvasViewModel.layers[i].isLocked, at: i)
        case "alphaLockLayer":
            let i = canvasViewModel.activeLayerIndex
            canvasViewModel.setLayerAlphaLocked(!canvasViewModel.layers[i].isAlphaLocked, at: i)
        case "copyLayer":
            copyLayer(at: canvasViewModel.activeLayerIndex)
        case "selectLayerContents":
            selectLayerContents(at: canvasViewModel.activeLayerIndex)
        case let cmd where cmd.hasPrefix("renameLayer:"):
            canvasViewModel.renameLayer(at: canvasViewModel.activeLayerIndex,
                                        to: String(cmd.dropFirst("renameLayer:".count)))
        case "deleteTopLayer":
            if canvasViewModel.layers.count > 1 {
                canvasViewModel.deleteLayer(at: canvasViewModel.layers.count - 1)
            }
        case "layerPanel":
            showLayerPanel.toggle()
        case "copySel":
            copySelection()
        case "pasteSel":
            pasteSelection()
        case "pastePlace":
            canvasViewModel.commitPaste()
        case "saveObj":
            saveSelectionToObjects()
        case "liftObj":
            let dl = FetchDescriptor<SavedObject>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            if let obj = (try? modelContext.fetch(dl))?.first { liftObjectTo3D(obj) }
        case "placeObj":
            let dp = FetchDescriptor<SavedObject>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            if let obj = (try? modelContext.fetch(dp))?.first(where: { $0.meshData != nil }) {
                placingObject = obj
            }
        case "insertObj":
            let d = FetchDescriptor<SavedObject>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
            if let obj = (try? modelContext.fetch(d))?.first { insertObject(obj) }
        case "objectsDrawer":
            showObjectsDrawer = true
        case "extractScreen":
            openExtract()
        case let cmd where cmd.hasPrefix("extractFake:"):
            let parts = cmd.dropFirst("extractFake:".count).split(separator: ",")
            if parts.count >= 3, let u = Double(parts[0]), let v = Double(parts[1]),
               let r = Double(parts[2]) {
                extract?.devFakeTap(u: u, v: v, radiusFraction: r)
            }
        case "extractSave":
            if let controller = extract, let item = controller.items.first(where: { $0.state == .lifted }) {
                controller.saveToCollection(item)
            }
        case "forkStartFrame":
            if currentScreen == .animate, let img = animate?.startKeyframe {
                forkFrameIntoDrawing(img, returnSlot: .start)
            }
        case "aiEditSheet":
            showAIEditSheet = true
        case "stickerFile":
            // Export the selection sticker to a host-visible path for the
            // sim harness to inspect.
            if let url = makeStickerFile() {
                try? FileManager.default.removeItem(atPath: "/tmp/kiki-sticker.png")
                try? FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: "/tmp/kiki-sticker.png"))
            }
        #endif
        // "aiEdit:<prompt>" — kick off an AI Edit with the given prompt
        // (region-scoped if a selection is active, else whole drawing).
        case let cmd where cmd.hasPrefix("aiEdit:"):
            aiEditPrompt = String(cmd.dropFirst("aiEdit:".count))
            startAIEdit()
        case "aiEditAccept":
            acceptAIEdit()
        case "aiEditRetry":
            retryAIEdit()
        case "aiEditDiscard":
            discardAIEdit()
        case "dismiss":
            devShowStatusDetails = false
            devShowColorPicker = false
            if showExtract { closeExtract() }
            if currentScreen == .animate { closeAnimate() }
            if currentScreen == .replay { closeReplay() }
        default:
            streamLog.warning("[dev] unknown UI action: \(action)")
        }
    }

    /// Dev-automation binding for the status badge popover (normally
    /// @State-local to the badge; the sim bridge needs to open it).
    var devShowStatusDetails = false
    /// Dev-automation binding for the color-swatch picker popover.
    var devShowColorPicker = false
    /// Dev-action seam: section the next Brush Studio open should land on.
    var devStudioSection: StudioSection?

    func devReplayFixture(_ fixture: BrushFixture) {
        Task { @MainActor in
            if currentScreen != .drawing {
                newDrawing()
            }
            for _ in 0..<20 where !canvasViewModel.isCanvasAttached {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard canvasViewModel.isCanvasAttached else {
                Log.info("dev.replay.no_canvas", attributes: ["event": "dev.replay.no_canvas"])
                return
            }
            canvasViewModel.replayFixture(fixture)
            Log.info("dev.replay.done", attributes: [
                "event": "dev.replay.done",
                "strokes": fixture.strokes.count,
            ])
        }
    }

    /// Dev automation: open the newest drawing from the gallery.
    func openMostRecentDrawing() {
        var descriptor = FetchDescriptor<Drawing>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        if let drawing = try? modelContext.fetch(descriptor).first {
            openDrawing(drawing)
        }
    }

    func openDrawing(_ drawing: Drawing) {
        isSuppressingObservation = true

        currentDrawingId = drawing.id
        currentDrawingOpenedAt = Date()
        sessionStrokeCount = 0

        // Restore settings
        promptText = drawing.promptText
        animationPromptText = drawing.animationPrompt ?? ""
        selectedStyle = PromptStyle.from(id: drawing.styleId)
        streamSeed = drawing.streamSeed

        // Restore generated image
        if let imgData = drawing.generatedImageData {
            lastSuccessfulImage = UIImage(data: imgData)
        } else {
            lastSuccessfulImage = nil
        }
        panelOffset = .zero
        panelScale = 1.0
        panelHole = PanelHole()

        // Prepare canvas state
        canvasViewModel.setPendingState(CanvasState(
            drawingData: drawing.drawingData ?? Data(),
            backgroundImageData: drawing.backgroundImageData
        ))

        currentScreen = .drawing
        isSuppressingObservation = false

        Analytics.track(.drawingOpened, properties: [
            "drawing_id": drawing.id.uuidString,
            "has_background_image": drawing.backgroundImageData != nil,
            "has_generated_image": drawing.generatedImageData != nil,
            "is_new": false,
        ])
        Log.info("drawing.opened", attributes: [
            "event": "drawing.opened",
            "drawing_id": drawing.id.uuidString,
        ])

        startStream()
        seedResultStateForCurrentDrawing()
    }

    func navigateToGallery() {
        // Leaving the drawing abandons any un-accepted AI Edit preview.
        discardAIEdit()
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        // Emit drawing.closed before we clear the id.
        if let drawingId = currentDrawingId, let openedAt = currentDrawingOpenedAt {
            let sessionMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            Analytics.track(.drawingClosed, properties: [
                "drawing_id": drawingId.uuidString,
                "session_duration_ms": sessionMs,
                "generation_count": streamFrameCount,
                "strokes_added": sessionStrokeCount,
            ])
        }
        currentDrawingOpenedAt = nil

        // Delete empty drawings; for non-empty ones, mirror the final thumbnail +
        // generated image to Insights (one upload per close; upserts by id).
        if let drawingId = currentDrawingId {
            let id = drawingId
            var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let drawing = try? modelContext.fetch(descriptor).first {
                if drawing.isContentEmpty {
                    // Discard any in-progress recording — stopStream's finalize
                    // will then no-op — and remove any stored recording.
                    recorder?.cancel()
                    RecordingStore.shared.delete(id)
                    modelContext.delete(drawing)
                    try? modelContext.save()
                } else {
                    let payload = (
                        id: drawing.id.uuidString,
                        prompt: drawing.promptText,
                        styleId: drawing.styleId,
                        updatedAt: drawing.updatedAt,
                        thumbnail: drawing.canvasThumbnailData,
                        generated: drawing.generatedImageData
                    )
                    Task {
                        await InsightsSink.shared.uploadDrawing(
                            id: payload.id,
                            prompt: payload.prompt,
                            styleId: payload.styleId,
                            updatedAt: payload.updatedAt,
                            thumbnail: payload.thumbnail,
                            generated: payload.generated
                        )
                    }
                }
            }
        }

        stopStream()
        currentDrawingId = nil

        // Track gallery navigation with current drawing count.
        let descriptor = FetchDescriptor<Drawing>()
        let drawingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
        Analytics.track(.galleryOpened, properties: ["drawing_count": drawingCount])

        currentScreen = .gallery
    }

    // MARK: - Animate screen

    /// Lazily create the Animate screen's controller (kept for the app's
    /// lifetime so its setup survives leaving/re-entering the screen).
    private func ensureAnimateController() -> AnimateController {
        if let animate { return animate }
        let controller = AnimateController(
            backendURL: backendURL,
            modelContext: modelContext,
            tokenProvider: { [authService] in try await authService.currentAccessToken() },
            onAvailability: { [weak self] video in
                self?.applyVideoAvailability(video)
            }
        )
        animate = controller
        return controller
    }

    /// Enter the Animate screen from the current drawing: its result (or
    /// canvas, when nothing was generated yet) becomes the start keyframe
    /// and the drawing's saved animation prompt prefills the motion field.
    ///
    /// Frame-fork round-trip: when this drawing was created by
    /// `forkFrameIntoDrawing`, the EDITED CANVAS (canvas-first — the frame
    /// was baked as layer 0, so the canvas IS the corrected frame; the
    /// generated result is a restyled derivative) returns to the keyframe
    /// slot it came from, and the rest of the Animate setup is preserved.
    func openAnimateFromDrawing() {
        noteInteraction()
        guard currentScreen == .drawing else { return }
        saveCurrentDrawing()
        let controller = ensureAnimateController()
        if let pending = controller.pendingFrameEdit, pending.drawingID == currentDrawingId {
            if let edited = canvasViewModel.generateThumbnail(maxDimension: 1024) ?? lastSuccessfulImage {
                switch pending.slot {
                case .start: controller.startKeyframe = edited
                case .end: controller.endKeyframe = edited
                }
                controller.showKeyframePreview()
            }
            controller.pendingFrameEdit = nil
        } else if let keyframe = lastSuccessfulImage ?? canvasViewModel.generateThumbnail() {
            controller.startKeyframe = keyframe
            controller.endKeyframe = nil
            controller.sourceDrawingID = currentDrawingId
            // Entering with a fresh keyframe: show it, not an old clip.
            controller.prompt = animationPromptText
        }
        animateReturnScreen = .drawing
        stopStream()
        currentScreen = .animate
    }

    /// Fork a frame into a NEW editable drawing (single-PNG `drawingData`
    /// loads as layer 0 — erasable, paintable, AI-editable) and remember
    /// which keyframe slot the edited result should return to when the user
    /// taps Animate from that drawing.
    func forkFrameIntoDrawing(_ image: UIImage, returnSlot: AnimateController.KeyframeSlot) {
        guard let png = image.pngData() else { return }
        let controller = ensureAnimateController()
        let drawing = Drawing(streamSeed: Int.random(in: 0...Int(UInt32.max)))
        drawing.drawingData = png
        modelContext.insert(drawing)
        try? modelContext.save()
        controller.pendingFrameEdit = .init(drawingID: drawing.id, slot: returnSlot)
        Analytics.track(.animateFrameForked, properties: [
            "slot": returnSlot.rawValue,
            "drawing_id": drawing.id.uuidString,
        ])
        openDrawing(drawing)
    }

    /// Enter the Animate screen from the gallery. Keeps whatever setup the
    /// controller already has (continuity across visits); the user picks
    /// keyframes from the library or Photos.
    func openAnimateFromGallery() {
        _ = ensureAnimateController()
        animateReturnScreen = .gallery
        currentScreen = .animate
    }

    /// Leave the Animate screen, returning to where the user came from.
    /// When re-entering the drawing, persist the motion prompt back onto it
    /// and restart the stream.
    func closeAnimate() {
        if animateReturnScreen == .drawing, let drawingId = currentDrawingId {
            if let controller = animate, controller.sourceDrawingID == currentDrawingId {
                animationPromptText = controller.prompt
            }
            // The drawing screen's Metal canvas was torn down when we left —
            // re-queue the persisted canvas state (saved on the way in by
            // openAnimateFromDrawing) so the recreated canvas restores the
            // strokes instead of coming up blank. Same pending-state pattern
            // as openDrawing().
            let id = drawingId
            var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
            descriptor.fetchLimit = 1
            if let drawing = try? modelContext.fetch(descriptor).first {
                canvasViewModel.setPendingState(CanvasState(
                    drawingData: drawing.drawingData ?? Data(),
                    backgroundImageData: drawing.backgroundImageData
                ))
            }
            currentScreen = .drawing
            startStream()
            seedResultStateForCurrentDrawing()
        } else {
            currentScreen = .gallery
            let descriptor = FetchDescriptor<Drawing>()
            let drawingCount = (try? modelContext.fetchCount(descriptor)) ?? 0
            Analytics.track(.galleryOpened, properties: ["drawing_count": drawingCount])
        }
    }

    /// Enter the speed-paint replay share page from the drawing screen.
    /// Checkpoints the LIVE recorder before the stream (and with it the
    /// recorder) is torn down, so the replay includes strokes drawn moments
    /// ago without racing stopStream's detached finalize.
    func openReplayFromDrawing() {
        noteInteraction()
        guard currentScreen == .drawing else { return }
        saveCurrentDrawing()
        Task { @MainActor in
            await flushRecording()
            stopStream()
            currentScreen = .replay
        }
    }

    /// Leave the replay share page back to the drawing (its only entry
    /// point). Same canvas re-queue + stream restart as closeAnimate().
    func closeReplay() {
        guard let drawingId = currentDrawingId else {
            currentScreen = .gallery
            return
        }
        let id = drawingId
        var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        if let drawing = try? modelContext.fetch(descriptor).first {
            canvasViewModel.setPendingState(CanvasState(
                drawingData: drawing.drawingData ?? Data(),
                backgroundImageData: drawing.backgroundImageData
            ))
        }
        currentScreen = .drawing
        startStream()
        seedResultStateForCurrentDrawing()
    }

    func deleteDrawing(_ drawing: Drawing) {
        RecordingStore.shared.delete(drawing.id)
        modelContext.delete(drawing)
        try? modelContext.save()

        let descriptor = FetchDescriptor<Drawing>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0
        if count == 0 {
            newDrawing()
        }
    }

    func saveCurrentDrawing() {
        guard !isSuppressingObservation else { return }
        guard let drawingId = currentDrawingId else { return }
        guard let drawingData = canvasViewModel.exportDrawingData() else { return }

        let id = drawingId
        var descriptor = FetchDescriptor<Drawing>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let drawing = try? modelContext.fetch(descriptor).first else { return }

        drawing.drawingData = drawingData
        drawing.backgroundImageData = canvasViewModel.exportBackgroundImageData()
        drawing.generatedImageData = lastSuccessfulImage?.jpegData(compressionQuality: 0.85)
        drawing.canvasThumbnailData = canvasViewModel.generateThumbnail()?.jpegData(compressionQuality: 0.7)
        drawing.promptText = promptText
        drawing.animationPrompt = animationPromptText.isEmpty ? nil : animationPromptText
        drawing.styleId = selectedStyle.id
        drawing.streamSeed = streamSeed

        drawing.updatedAt = Date()
        try? modelContext.save()

        Analytics.track(.drawingSaved, properties: [
            "drawing_id": drawing.id.uuidString,
            "has_background_image": drawing.backgroundImageData != nil,
            "has_generated_image": drawing.generatedImageData != nil,
            "style_id": selectedStyle.id,
        ])
    }

    private func scheduleSave() {
        guard currentDrawingId != nil else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            saveCurrentDrawing()
        }
    }

    // MARK: - Canvas Observation

    private func startObservingCanvas() {
        canvasObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in canvasViewModel.canvasChanges {
                guard !Task.isCancelled else { return }
                guard !isSuppressingObservation else { continue }
                guard !canvasViewModel.isEmpty else { continue }
                scheduleSave()
            }
        }
    }

    // MARK: - Stream

    private func startStream() {
        // Idempotent: if a session is already running (e.g. pre-warmed at app
        // launch), just push the latest config and return. The capture loop
        // will pick up the new prompt/seed before the next frame.
        if streamSession != nil {
            streamLog.info("startStream: session already running, syncing config only — readiness=\(String(describing: self.streamReadiness))")
            let crumb = Breadcrumb()
            crumb.category = "stream.lifecycle"
            crumb.message = "startStream noop (already running)"
            crumb.data = ["readiness": String(describing: streamReadiness)]
            SentrySDK.addBreadcrumb(crumb)
            syncStreamConfig()
            return
        }

        // Transaction captures user-perceived spin-up latency: from this call
        // through relay connect to first frame received. `StreamSession`
        // finishes it via the `onImageReceived` first-frame detection below.
        let startupTx = SentrySDK.startTransaction(name: "app.stream.startup", operation: "app.stream.startup")
        self.pendingStartupTransaction = startupTx
        self.streamStartupBeganAt = Date()

        // Per-startStream UUID — joins this attempt across iOS Sentry events
        // and backend Railway logs. One streamId may correspond to N backend
        // connIds if the StreamSession internally reconnects. Search by
        // streamId for the whole user attempt; by connId for one WS upgrade.
        let streamId = String(UUID().uuidString.prefix(8)).lowercased()
        SentrySDK.configureScope { $0.setTag(value: streamId, key: "streamId") }
        // Mirror into the cross-stack-aware static so `Log.X` and `beforeSendLog`
        // tag every iOS log entry with `stream_id`. Cleared in `stopStream()`.
        StreamContext.set(streamId)

        var components = URLComponents(url: backendURL, resolvingAgainstBaseURL: false)!
        components.scheme = backendURL.scheme == "https" ? "wss" : "ws"
        components.path = "/v1/stream"
        components.queryItems = [
            URLQueryItem(name: "streamId", value: streamId),
            // Dev A/B toggle — backend honors it for test accounts only.
            URLQueryItem(name: "imageProvider", value: imageProvider),
        ]
        guard let wsURL = components.url else {
            streamLog.error("Failed to construct WebSocket URL from \(self.backendURL.absoluteString)")
            SentrySDK.capture(message: "stream.startup: failed to construct WebSocket URL") { scope in
                scope.setLevel(.error)
                scope.setTag(value: self.backendURL.absoluteString, key: "backendURL")
            }
            startupTx.finish(status: .internalError)
            self.pendingStartupTransaction = nil
            return
        }

        streamLog.info("Starting stream to \(wsURL.absoluteString)")
        let startCrumb = Breadcrumb()
        startCrumb.category = "stream.lifecycle"
        startCrumb.message = "Starting stream"
        startCrumb.data = ["wsURL": wsURL.absoluteString]
        SentrySDK.addBreadcrumb(startCrumb)
        Analytics.track(.streamStarted, properties: [
            "drawing_id": currentDrawingId?.uuidString ?? "unknown",
        ])
        // Enter `preparing` phase. The `Log` facade reads `Phase.current` at
        // emit time and tags every subsequent log line with `phase: preparing`
        // until we transition to `.drawing` on first frame received (below).
        // Cross-stack `user_id:X phase:preparing` joins these iOS lines with
        // backend's `withPhase('preparing')` block and pod's
        // `with sentry_init.phase("preparing")` block.
        Phase.set(.preparing)
        Log.info("stream.startup_begin", attributes: [
            "event": "stream.startup_begin",
            "drawing_id": currentDrawingId?.uuidString ?? "unknown",
        ])

        // Kick off the async flow to fetch a fresh access token, then connect.
        Task { [weak self] in
            guard let self else { return }
            do {
                let token = try await authService.currentAccessToken()
                var request = URLRequest(url: wsURL)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                // Client fingerprint so backend logs / Insights can tell a
                // SIMULATOR (dev tokens make it look like a real user
                // otherwise — cost us a 10-hour warm-H100 whodunit,
                // 2026-07-19) from a device apart in one glance.
                request.setValue(Self.clientTag, forHTTPHeaderField: "X-Kiki-Client")
                await MainActor.run {
                    self.startStreamSession(request: request, backendWsURL: wsURL)
                }
            } catch {
                // Only credential failures justify signing out (which wipes
                // Keychain). Transport errors (offline, DNS) and backend 5xx
                // (Railway redeploy) are transient: keep credentials, show a
                // banner, and auto-retry — never a manual "Try Again".
                let isCredentialFailure: Bool
                switch error {
                case AuthService.AuthError.noToken,
                     AuthService.AuthError.refreshFailed,
                     AuthService.AuthError.backendRejected:
                    isCredentialFailure = true
                default:
                    isCredentialFailure = false
                }
                await MainActor.run {
                    streamLog.error("Auth token fetch failed: \(error.localizedDescription) credentialFailure=\(isCredentialFailure)")
                    SentrySDK.capture(error: error) { scope in
                        scope.setTag(value: "stream.authTokenFetch", key: "op")
                        scope.setTag(value: isCredentialFailure ? "credential" : "transient", key: "failure_class")
                    }
                    startupTx.finish(status: isCredentialFailure ? .unauthenticated : .aborted)
                    self.pendingStartupTransaction = nil
                    if isCredentialFailure {
                        self.streamReadiness = .failed(message: "Please sign in again")
                        self.generationError = "Please sign in again"
                        self.signOut()
                    } else {
                        self.streamReadiness = .failed(message: "Connecting…")
                        self.generationError = "No connection — retrying…"
                        self.scheduleStreamStartRetry()
                    }
                }
            }
        }
    }

    /// Auto-retry for transient token-fetch failures at stream start. Keeps
    /// retrying every 5s while the user is still on the drawing screen and no
    /// session has been established; goes quiet as soon as either changes.
    private func scheduleStreamStartRetry() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            guard self.currentScreen == .drawing, self.streamSession == nil,
                  !self.isStreamIdlePaused else { return }
            streamLog.info("Retrying stream start after transient auth failure")
            self.startStream()
        }
    }

    /// Records the current drawing's two timelapse tracks (canvas + generated).
    /// Created per stream session, finalized in `stopStream`.
    private var recorder: DrawingVideoRecorder?

    /// Canvas frames captured since this session's recorder started — gates
    /// `canShareVideo` so the replay is offered while drawing, before any segment
    /// has been finalized to disk.
    private var recordedCanvasFrames = 0

    /// Periodic recording checkpoint while a session is live, so a crash or
    /// hard-kill loses at most ~1 min of replay footage instead of the whole
    /// session. `flushRecording` no-ops (returns nil checkpoint) when fewer
    /// than 2 new frames exist, so idle sessions don't accumulate segments.
    private var recordingCheckpointTask: Task<Void, Never>?

    private func startRecordingCheckpoints() {
        recordingCheckpointTask?.cancel()
        recordingCheckpointTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self, !Task.isCancelled else { return }
                await self.flushRecording()
            }
        }
    }

    private func stopRecordingCheckpoints() {
        recordingCheckpointTask?.cancel()
        recordingCheckpointTask = nil
    }

    @MainActor
    private func startStreamSession(request: URLRequest, backendWsURL: URL) {
        isStreamIdlePaused = false
        startIdleGuard()
        let session = StreamSession(
            request: request,
            canvasViewModel: canvasViewModel,
            config: buildStreamConfig()
        )
        session.captureInterval = 1.0 / streamCaptureFPS

        // Record this session's two timelapse tracks. A paired frame is appended
        // whenever either source changes (canvas dirty-tick below, or a new
        // generated frame in onImageReceived).
        let videoRecorder = DrawingVideoRecorder()
        videoRecorder.start()
        // Seed the generated pane with the drawing's last generated image so a
        // resumed session's segment doesn't open on white frames (visible as a
        // flash at each session boundary in the stitched replay).
        if let seed = lastSuccessfulImage {
            videoRecorder.seedGenerated(seed)
        }
        recorder = videoRecorder
        recordedCanvasFrames = 0
        startRecordingCheckpoints()
        session.onCanvasFrameCaptured = { [weak self] canvasImage in
            guard let self else { return }
            self.recordedCanvasFrames += 1
            self.recorder?.canvasChanged(canvasImage)
        }

        session.onImageReceived = { [weak self] image in
            guard let self else { return }
            self.streamFrameCount += 1
            self.lastSuccessfulImage = image
            self.recorder?.generatedChanged(image)
            // Overlay mode: a new generated frame reflects the user's latest strokes
            // via fal's img2img loop → wipe the visual-only fresh-stroke surface so
            // the strokes "hand off" to the generated image. No-op in other layouts.
            self.canvasViewModel.clearOverlayStrokes()
            self.resultState = .streaming(image: image, frameCount: self.streamFrameCount)

            let count = self.streamFrameCount
            if count == 1 {
                // First generated frame — user-perceived spin-up complete.
                self.pendingStartupTransaction?.finish()
                self.pendingStartupTransaction = nil
                let waitMs: Int? = self.streamStartupBeganAt.map {
                    Int(Date().timeIntervalSince($0) * 1000)
                }
                if let waitMs {
                    Analytics.track(.streamFirstFrame, properties: ["wait_ms": waitMs])
                }
                self.streamStartupBeganAt = nil
                // Phase transition: preparing → drawing. Subsequent logs
                // until tear-down (or video animation start) carry
                // `phase: drawing`.
                Phase.set(.drawing)
                Log.info("stream.first_frame", attributes: [
                    "event": "stream.first_frame",
                    "wait_ms": waitMs as Any,
                ])
            } else if Phase.current != .drawing {
                // Resume-drawing after a video animation: flip back to
                // `.drawing` so subsequent img2img logs aren't tagged
                // `animating`. Only emit the structured log on transition,
                // not every frame, to avoid log spam.
                Phase.set(.drawing)
            }
        }

        session.onReadinessChanged = { [weak self] readiness in
            guard let self else { return }
            streamLog.info("Readiness changed: \(String(describing: readiness))")
            // Phase: detect mid-session reconnect. We're in "warming after
            // already reaching ready" if streamFrameCount > 0 AND new state
            // is .warming. Distinct from initial pre-first-frame warming
            // (preparing). Cross-stack: backend's `handleUpstreamClose` is
            // wrapped in `withPhase('reconnecting')` and the pod stays on
            // `.preparing` for the new pod's boot since it can't tell
            // fresh-vs-reconnect from inside.
            if case .warming = readiness, self.streamFrameCount > 0,
               Phase.current != .reconnecting {
                Phase.set(.reconnecting)
                Log.info("stream.reconnecting", attributes: ["event": "stream.reconnecting"])
            }
            self.streamReadiness = readiness
            if case .ready = readiness {
                // Stream is demonstrably healthy again — any lingering error
                // banner (transient failure, stale auth message) is resolved.
                // The out-of-time/paywall banner never reaches here: a capped
                // session is rejected at the backend gate and stays .failed
                // until `subscriptionDidActivate()` clears it.
                self.generationError = nil
            }
            if case .failed(let message) = readiness {
                self.generationError = message
                // End startup transaction with failure status if we never got a frame.
                self.pendingStartupTransaction?.finish(status: .internalError)
                self.pendingStartupTransaction = nil
                let elapsedMs = self.streamStartupBeganAt.map {
                    Int(Date().timeIntervalSince($0) * 1000)
                } ?? 0
                Analytics.track(.streamFailed, properties: [
                    "message": message,
                    "elapsed_ms": elapsedMs,
                    "frames_received": self.streamFrameCount,
                    "got_first_frame": self.streamFrameCount > 0,
                ])
                // The user's-eye view of "what went wrong." Carries the
                // exact `display_message` shown in the UI so support
                // queries (`user_id:X stream.error_shown`) match the
                // verbatim string the user reported. Distinct from
                // backend's `event:provision.failed` — that's the cause;
                // this is the symptom.
                Log.warn("stream.error_shown", attributes: [
                    "event": "stream.error_shown",
                    "display_message": message,
                    "elapsed_ms": elapsedMs,
                    "got_first_frame": self.streamFrameCount > 0,
                ])
            }
            self.applyReadinessToResultState(readiness)
        }

        session.onVideoEvent = { [weak self] event in
            guard let self else { return }
            self.handleVideoEvent(event)
        }

        session.onServerError = { [weak self] code, _ in
            guard let self else { return }
            // Free-tier cap hit: surface the paywall. The readiness `.failed`
            // path (above) still sets `generationError` for the banner text.
            if code == "free_limit_reached" {
                self.isOutOfDrawingTime = true
                self.showPaywall = true
            }
        }

        session.onUsageUpdate = { [weak self] spend, cap in
            guard let self else { return }
            self.usageSpendUsd = spend
            self.usageCapUsd = cap
            // A usage push only fires for metered (non-exempt) sessions.
            self.usageExempt = false
        }

        self.streamSession = session

        Task {
            await session.start()
        }
    }

    /// Called after a successful subscribe/restore. Clears the out-of-time state
    /// and restarts the stream — the backend cap is now lifted, so the start
    /// gate will pass on reconnect.
    func subscriptionDidActivate() {
        showPaywall = false
        isOutOfDrawingTime = false
        generationError = nil
        resumeStream()
    }

    /// Public entry point for restarting the stream (used by the paywall
    /// dismissal and the image-provider toggle).
    /// Tears down the existing (stopped) session and starts a fresh one. The
    /// `startStream()` early-return on `streamSession != nil` would otherwise
    /// no-op, since the session is technically present but stopped.
    func resumeStream() {
        if streamSession != nil {
            streamLog.info("Resume requested — tearing down stopped session")
            streamSession?.stop()
            streamSession = nil
        }
        // Finalize the in-flight timelapse recording before startStream()
        // replaces the recorder — a provider toggle or paywall resume must
        // not discard the footage captured so far.
        stopRecordingCheckpoints()
        if let recorder, let drawingId = currentDrawingId {
            finalizeRecording(recorder, drawingId: drawingId)
        }
        recorder = nil
        startStream()
    }

    private func stopStream() {
        idleGuardTask?.cancel()
        idleGuardTask = nil
        isStreamIdlePaused = false
        let hadSession = streamSession != nil
        let finalFrameCount = streamFrameCount
        streamLog.info("Stopping stream")
        // Clear streamId tag so post-stream events (e.g. an unrelated crash
        // 10 min later) aren't mis-tagged with this stream's id.
        SentrySDK.configureScope { $0.removeTag(key: "streamId") }
        if hadSession {
            // Phase transition: → session_ending. Emit the tear-down log
            // BEFORE clearing StreamContext so the line still carries
            // `stream_id`. Then clear so post-stream activity doesn't leak
            // the just-closed stream's id.
            Phase.set(.sessionEnding)
            Log.info("stream.tore_down", attributes: [
                "event": "stream.tore_down",
                "frames_received": finalFrameCount,
                "reason": "stopped",
            ])
        }
        StreamContext.set(nil)
        Phase.set(nil)
        streamSession?.stop()
        streamSession = nil
        streamReadiness = .disconnected
        streamFrameCount = 0
        // Pull the final billed spend after the session closes (the backend's
        // last usage flush happens post-disconnect, so the live push won't have
        // delivered it). Best-effort.
        if hadSession { refreshUsage() }
        // If we're stopping before first frame, mark the startup tx as cancelled.
        pendingStartupTransaction?.finish(status: .cancelled)
        pendingStartupTransaction = nil
        streamStartupBeganAt = nil

        // Finalize this session's timelapse recording. If the recorder was
        // cancelled (empty drawing) finish() no-ops and stores nothing.
        stopRecordingCheckpoints()
        if let recorder, let drawingId = currentDrawingId {
            finalizeRecording(recorder, drawingId: drawingId)
        }
        recorder = nil

        if hadSession {
            Analytics.track(.streamEnded, properties: [
                "frames_received": finalFrameCount,
                "reason": "stopped",
            ])
        }

        resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
    }

    /// `.ready` shows the bottom-left badge over a preview/streaming image;
    /// every other readiness state shows the corresponding overlay, with
    /// `lastSuccessfulImage` dimmed underneath when one exists.
    private func applyReadinessToResultState(_ readiness: StreamSession.StreamReadiness) {
        switch readiness {
        case .disconnected:
            resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        case .warming(let message):
            resultState = .provisioning(
                message: message,
                previousImage: lastSuccessfulImage
            )
        case .ready:
            // Pod is genuinely ready; the first frame will move us to
            // `.streaming`. Show preview (or empty) until then.
            resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        case .failed(let msg):
            streamLog.error("Stream failed: \(msg)")
            resultState = .error(message: msg, previousImage: lastSuccessfulImage)
        }
    }

    /// Seed `resultState` when entering a drawing so the result pane reflects
    /// any pre-warming already in progress, instead of momentarily flashing
    /// empty.
    private func seedResultStateForCurrentDrawing() {
        applyReadinessToResultState(streamReadiness)
    }

    /// Video-family events on the DRAWING stream. Since the Animate screen
    /// (2026-07-19) owns generation on its own socket, the only event that
    /// still matters here is the `system_availability` push (drives the
    /// status badge + whether Animate entry points are shown). Stray
    /// video_* messages from an old backend are ignored.
    private func handleVideoEvent(_ event: StreamWebSocketClient.VideoEvent) {
        switch event {
        case .availability(let image, let video):
            applyVideoAvailability(video)
            imageAvailability = VideoAvailability(rawValue: image.availability) ?? .off
            imageSystemStatus = image
        case .started, .frame, .complete, .cancelled:
            break
        }
    }

    /// Shared sink for video-system availability from EITHER socket (drawing
    /// stream or the Animate screen's own connection).
    func applyVideoAvailability(_ video: StreamWebSocketClient.SystemStatus) {
        let videoValue = VideoAvailability(rawValue: video.availability) ?? .off
        if videoValue != videoAvailability {
            videoAvailability = videoValue
            streamLog.info("[result] video availability → \(video.availability)")
        }
        videoSystemStatus = video
    }

    /// Push the current config to the stream session. The capture loop will
    /// detect the change and send it to the server before the next frame.
    private func syncStreamConfig() {
        streamSession?.config = buildStreamConfig()
    }

    // MARK: - Style Preview

    private func enterStylePreviewMode() {
        stylePreviewController.reset()

        guard let session = streamSession else {
            // No live pod; show all tiles as failed so they don't shimmer forever.
            stylePreviewController.markAllFailed(styles: PromptStyle.allStyles)
            return
        }
        guard let jpeg = session.captureFrameJPEG() else {
            stylePreviewController.markAllFailed(styles: PromptStyle.allStyles)
            return
        }

        session.enterPreviewMode()
        stylePreviewController.start(
            canvasJPEG: jpeg,
            basePrompt: promptText,
            steps: streamSteps,
            seed: streamSeed,
            styles: PromptStyle.allStyles,
            session: session
        )
    }

    private func exitStylePreviewMode() {
        stylePreviewController.cancel()
        streamSession?.exitPreviewMode()
    }

    // MARK: - App Lifecycle

    func handleScenePhaseChange(_ phase: ScenePhase) {
        let phaseName: String
        switch phase {
        case .background: phaseName = "background"
        case .active: phaseName = "active"
        case .inactive: phaseName = "inactive"
        @unknown default: phaseName = "unknown"
        }
        let crumb = Breadcrumb()
        crumb.category = "app.scenePhase"
        crumb.message = "scenePhase=\(phaseName)"
        crumb.data = [
            "phase": phaseName,
            "hasSession": streamSession != nil,
            "screen": currentScreen.analyticsName,
            "wasActiveBeforeBackground": streamWasActiveBeforeBackground,
            "readiness": String(describing: streamReadiness),
        ]
        SentrySDK.addBreadcrumb(crumb)
        streamLog.info("scenePhase=\(phaseName) hasSession=\(self.streamSession != nil) screen=\(self.currentScreen.analyticsName) wasActiveBeforeBg=\(self.streamWasActiveBeforeBackground)")

        switch phase {
        case .background:
            markBackgrounded()
            if streamSession != nil {
                streamWasActiveBeforeBackground = true
                stopStream()
            }
        case .active:
            markForegrounded()
            if streamWasActiveBeforeBackground
                && currentScreen == .drawing
                && streamSession == nil {
                streamWasActiveBeforeBackground = false
                streamLog.info("scenePhase=active → restarting stream after background")
                startStream()
            }
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    /// Open an app-level session if one isn't already open. Idempotent so the
    /// active→inactive→active churn (Control Center, notifications) doesn't emit
    /// duplicates. Called at launch and on every foreground.
    func markForegrounded() {
        guard appForegroundedAt == nil else { return }
        appForegroundedAt = Date()
        Analytics.track(.appForegrounded)
    }

    /// Close the current app-level session, emitting its duration. No-op if none
    /// is open.
    private func markBackgrounded() {
        guard let openedAt = appForegroundedAt else { return }
        let durationMs = Int(Date().timeIntervalSince(openedAt) * 1000)
        Analytics.track(.appBackgrounded, properties: ["duration_ms": durationMs])
        appForegroundedAt = nil
    }

    private func buildStreamConfig() -> StreamConfig {
        StreamConfig(
            prompt: composedPrompt,
            steps: streamSteps,
            seed: streamSeed,
            imageSize: streamResolution >= 1024 ? "square_hd" : "square",
            scheduleMu: streamScheduleMu,
            referenceScale: streamReferenceScale,
            referenceImages: pinnedObjectB64.map { [$0] },
            videoWidth: videoResolution,
            videoHeight: videoResolution,
            videoFrames: videoFrames,
            videoPromptSuffix: videoPromptSuffix,
            enableProfiling: enableProfiling
        )
    }

    // MARK: - Private

    private var composedPrompt: String? {
        let base = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = base.isEmpty ? selectedStyle.promptSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
                                  : base + selectedStyle.promptSuffix
        return result.isEmpty ? nil : result
    }

    /// Load a brush preset / control-isolation test into the live tool (Brush Studio). Batched so
    /// the brush is rebuilt once. Applies the preset's pin-overrides (baseWidth/opacity/flow) where
    /// set, so a test fully specifies the brush; otherwise the user's values are kept.
    func applyBrushPreset(_ preset: BrushPreset) {
        isSwappingToolValues = true
        toolDynamics = preset.dynamics
        toolHardness = preset.hardness
        toolSpacing = preset.spacing
        toolShapeID = preset.shapeID
        toolWetSmudge = false
        if let bw = preset.baseWidth { toolSize = bw }
        if let op = preset.opacity { toolOpacity = op }
        if let fl = preset.flow { toolFlow = fl }
        isSwappingToolValues = false
        activeTestNote = preset.note
        applyTool()
    }

    /// Apply a curated preset: run its recipe on a plain base carrying the user's
    /// color/size/opacity, then write every resulting knob back into the tool fields so
    /// the popover sliders reflect the preset. Batched (isSwappingToolValues) so the
    /// brush rebuilds once.
    func applyCuratedPreset(_ preset: CuratedPreset) {
        let base = BrushConfig(color: currentColor.codable, baseWidth: toolSize, opacity: toolOpacity)
        writeToolKnobs(from: preset.configure(base))
        activeCuratedPresetID = preset.id
        activeCustomBrushID = nil
        activeTestNote = nil
        applyTool()
    }

    /// Apply a saved custom brush: the config carries the brush's character; the user's
    /// current color and size are kept (same contract as curated presets).
    func applySavedBrush(_ saved: SavedBrush) {
        writeToolKnobs(from: saved.config)
        activeCuratedPresetID = nil
        activeCustomBrushID = saved.id
        activeTestNote = nil
        applyTool()
    }

    /// Snapshot every knob into a config and save it as a named custom brush.
    @discardableResult
    func saveCurrentBrush(named name: String) -> SavedBrush {
        let saved = customBrushLibrary.add(name: name, config: currentBrushConfig())
        activeCuratedPresetID = nil
        activeCustomBrushID = saved.id
        return saved
    }

    /// Everything the Brush Studio can change, captured on open so Cancel can revert.
    struct BrushStudioSnapshot {
        let config: BrushConfig
        let curatedID: String?
        let customID: UUID?
    }

    func takeBrushSnapshot() -> BrushStudioSnapshot {
        BrushStudioSnapshot(config: currentBrushConfig(),
                            curatedID: activeCuratedPresetID,
                            customID: activeCustomBrushID)
    }

    func restoreBrushSnapshot(_ snapshot: BrushStudioSnapshot) {
        writeToolKnobs(from: snapshot.config)
        activeCuratedPresetID = snapshot.curatedID
        activeCustomBrushID = snapshot.customID
        applyTool()
    }

    /// Write every secondary knob from a config back into the tool fields (batched so the
    /// brush rebuilds once). Deliberately does NOT touch color or size — presets and saved
    /// brushes carry character, not identity.
    private func writeToolKnobs(from c: BrushConfig) {
        isSwappingToolValues = true
        toolOpacity = c.opacity
        toolFlow = c.flow
        toolStreamline = c.streamline
        toolStabilization = c.stabilization
        toolPressureSmoothing = c.pressureSmoothing
        toolHardness = c.hardness
        toolSpacing = c.spacing
        toolSpacingJitter = c.spacingJitter
        toolTaperStart = max(c.taper, c.taperStart)
        toolTaperEnd = max(c.taper, c.taperEnd)
        toolRotationJitter = c.rotationJitter
        toolRandomizedRotation = c.randomizedRotation
        toolGrainDepthJitter = c.grainDepthJitter
        toolGrainMovement = c.grainMovement
        toolGrainZoom = c.grainZoom
        toolGrainRotation = c.grainRotation
        toolGrainDepthMinimum = c.grainDepthMinimum
        toolGrainOffsetJitter = c.grainOffsetJitter
        toolGrainBrightness = c.grainBrightness
        toolGrainContrast = c.grainContrast
        toolShapeID = c.shapeID
        toolAspect = c.aspectRatio
        toolGrainID = c.grainID
        toolGrainDepth = c.grainDepth
        toolGrainScale = c.grainScale
        toolTipLightness = c.tipLightness
        toolTipAngle = c.tipAngle
        toolFallOff = c.fallOff
        toolStampCount = CGFloat(c.stampCount)
        toolStampCountJitter = c.stampCountJitter
        toolRotationFollow = c.rotationFollow ?? 1
        toolFlipX = c.flipX
        toolFlipY = c.flipY
        toolDynamics = c.dynamics
        // Knobs added after preset v1 — a preset must fully specify the brush:
        toolGrainMoving = c.grainMoving
        toolTaperOpacity = c.taperOpacity
        toolPressureSmoothing = c.pressureSmoothing
        toolSecondaryColor = c.secondaryColor.map { Color(red: $0.red, green: $0.green, blue: $0.blue) }
        // currentBrushConfig folds wetEnabled = wet-ink || smudge — unfold here so the
        // toggles round-trip: a saved smudge brush shows Smudge on, Wet paint off.
        toolWetSmudge = c.wetSmudge
        toolWetEnabled = c.wetEnabled && !c.wetSmudge
        toolWetStrength = c.wetStrength
        toolWetPickup = c.wetPickup
        toolWetCharge = c.wetCharge
        toolWetRefill = c.wetRefill
        toolWetJitter = c.wetJitter
        toolWetBlur = c.wetBlur
        isSwappingToolValues = false
    }

    /// Reset every secondary knob to the engine default (the "None" preset chip),
    /// keeping color/size/opacity.
    func clearCuratedPreset() {
        let d = BrushConfig(color: currentColor.codable, baseWidth: toolSize, opacity: toolOpacity)
        isSwappingToolValues = true
        toolFlow = d.flow
        toolStreamline = d.streamline
        toolStabilization = d.stabilization
        toolPressureSmoothing = d.pressureSmoothing
        toolHardness = d.hardness
        toolSpacing = d.spacing
        toolSpacingJitter = d.spacingJitter
        toolTaperStart = 0
        toolTaperEnd = 0
        toolRotationJitter = 0
        toolRandomizedRotation = false
        toolGrainDepthJitter = 0
        toolGrainMovement = 0
        toolGrainZoom = 1
        toolGrainRotation = 0
        toolGrainDepthMinimum = 0
        toolGrainOffsetJitter = false
        toolGrainBrightness = 0
        toolGrainContrast = 0
        toolShapeID = nil
        toolAspect = d.aspectRatio
        toolGrainID = nil
        toolGrainDepth = d.grainDepth
        toolGrainScale = d.grainScale
        toolTipLightness = d.tipLightness
        toolTipAngle = d.tipAngle
        toolFallOff = d.fallOff
        toolStampCount = CGFloat(d.stampCount)
        toolStampCountJitter = d.stampCountJitter
        toolRotationFollow = 1
        toolFlipX = false
        toolFlipY = false
        toolDynamics = nil
        toolGrainMoving = false
        toolTaperOpacity = 0
        toolPressureSmoothing = 0
        toolSecondaryColor = nil
        toolWetEnabled = false
        toolWetSmudge = false
        toolWetStrength = d.wetStrength
        toolWetPickup = d.wetPickup
        toolWetCharge = d.wetCharge
        toolWetRefill = d.wetRefill
        toolWetJitter = d.wetJitter
        toolWetBlur = d.wetBlur
        isSwappingToolValues = false
        activeCuratedPresetID = nil
        activeCustomBrushID = nil
        activeTestNote = nil
        applyTool()
    }

    /// Reset the live tool to the plain default pen (no dynamics, no smudge).
    func resetBrushDynamics() {
        isSwappingToolValues = true
        toolDynamics = nil
        toolWetSmudge = false
        isSwappingToolValues = false
        activeTestNote = nil
        applyTool()
    }

    /// The live brush as a full config — the single source both applyTool and the Brush
    /// Studio (preview strip, "Save as brush") read. Keep in sync with writeToolKnobs.
    func currentBrushConfig() -> BrushConfig {
        BrushConfig(
                color: currentColor.codable,
                baseWidth: toolSize,
                opacity: toolOpacity,
                flow: toolFlow,
                pressureGamma: 0.35,
                tiltSensitivity: 1.0,
                streamline: toolStreamline,
                stabilization: toolStabilization,
                pressureSmoothing: toolPressureSmoothing,
                hardness: toolHardness,
                spacing: toolSpacing,
                spacingJitter: toolSpacingJitter,
                taper: 0,
                taperStart: toolTaperStart,
                taperEnd: toolTaperEnd,
                taperOpacity: toolTaperOpacity,
                wetEnabled: toolWetEnabled || toolWetSmudge,
                wetStrength: toolWetStrength,
                wetPickup: toolWetPickup,
                wetSmudge: toolWetSmudge,
                wetCharge: toolWetCharge,
                wetRefill: toolWetRefill,
                wetJitter: toolWetJitter,
                wetBlur: toolWetBlur,
                shapeID: toolShapeID,
                aspectRatio: toolAspect,
                grainID: toolGrainID,
                grainDepth: toolGrainDepth,
                grainScale: toolGrainScale,
                grainMoving: toolGrainMoving,
                grainMovement: toolGrainMovement,
                grainZoom: toolGrainZoom,
                grainRotation: toolGrainRotation,
                grainDepthMinimum: toolGrainDepthMinimum,
                grainOffsetJitter: toolGrainOffsetJitter,
                grainBrightness: toolGrainBrightness,
                grainContrast: toolGrainContrast,
                tipLightness: toolTipLightness,
                tipAngle: toolTipAngle,
                fallOff: toolFallOff,
                stampCount: Int(toolStampCount.rounded()),
                stampCountJitter: toolStampCountJitter,
                rotationFollow: toolRotationFollow,
                rotationJitter: toolRotationJitter,
                randomizedRotation: toolRandomizedRotation,
                grainDepthJitter: toolGrainDepthJitter,
                flipX: toolFlipX,
                flipY: toolFlipY,
                secondaryColor: toolSecondaryColor.map { $0.codable },
                dynamics: toolDynamics
            )
    }

    private func applyTool() {
        switch currentTool {
        case .brush:
            canvasViewModel.selectBrush(currentBrushConfig())
        case .eraser:
            canvasViewModel.selectEraser(width: toolSize)
        case .select:
            canvasViewModel.selectSelectionTool()
        }
    }
}

// MARK: - Color Conversion

extension Color {
    var codable: CodableColor {
        let uiColor = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        return CodableColor(red: r, green: g, blue: b, alpha: a)
    }
}

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
    case lasso
}

enum AppScreen: Equatable {
    case signIn
    case gallery
    case drawing

    var analyticsName: String {
        switch self {
        case .signIn: return "SignIn"
        case .gallery: return "Gallery"
        case .drawing: return "Drawing"
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

    var currentScreen: AppScreen = .gallery {
        didSet {
            guard currentScreen != oldValue else { return }
            Analytics.screen(currentScreen.analyticsName)
        }
    }
    var currentDrawingId: UUID?

    // MARK: - Persistence

    private let modelContext: ModelContext
    private var isSuppressingObservation = false
    private var saveDebounceTask: Task<Void, Never>?

    // MARK: - UI State

    var currentTool: DrawingTool = .brush {
        didSet {
            if canvasViewModel.hasLassoSelection {
                if oldValue == .lasso && currentTool != .lasso {
                    // Phase A → Phase B: commit floating selection, keep clip mask
                    // visible. Brush/eraser strokes are now clipped to the lasso region.
                    canvasViewModel.transitionToClipMode()
                }
                // Switching back to lasso or between pen/eraser: clip mask persists.
                // User must explicitly clear it via "Clear Lasso" button.
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
    /// Stroke-end taper ("Taper"). 0 = none; higher tapers the ends. See Phase 2.
    var toolTaper: CGFloat = 0.0 {
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

    /// Debug: A/B the wet draw-order experiment (per-stamp vs instanced draws).
    var wetOrderingPerStamp = false {
        didSet { canvasViewModel.setWetOrderingPerStamp(wetOrderingPerStamp) }
    }

    /// Whether the brush-settings popover (secondary sliders) is shown.
    var showBrushSettings = false
    /// Whether the Brush Studio (dev) tuning panel is shown. Presented from the sidebar (a
    /// stable parent) rather than from inside the popover, so it survives the popover dismissing.
    var showBrushStudio = false

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
        .lasso: 5
    ]
    private var storedToolOpacities: [DrawingTool: CGFloat] = [
        .brush: 1.0,
        .eraser: 1.0,
        .lasso: 1.0
    ]
    private var storedToolFlows: [DrawingTool: CGFloat] = [
        .brush: 1.0,
        .eraser: 1.0,
        .lasso: 1.0
    ]
    private var storedToolStreamlines: [DrawingTool: CGFloat] = [
        .brush: 0.35,
        .eraser: 0.0,
        .lasso: 0.0
    ]
    private var storedToolHardnesses: [DrawingTool: CGFloat] = [
        .brush: 0.5,
        .eraser: 1.0,
        .lasso: 1.0
    ]
    private var storedToolSpacings: [DrawingTool: CGFloat] = [
        .brush: 0.3,
        .eraser: 0.3,
        .lasso: 0.3
    ]
    private var storedToolTapers: [DrawingTool: CGFloat] = [
        .brush: 0.0,
        .eraser: 0.0,
        .lasso: 0.0
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
        storedToolTapers[oldTool] = toolTaper
        storedToolShapes[oldTool] = toolShapeID  // nil clears the entry
        isSwappingToolValues = true
        toolSize = storedToolSizes[newTool] ?? toolSize
        toolOpacity = storedToolOpacities[newTool] ?? toolOpacity
        toolFlow = storedToolFlows[newTool] ?? toolFlow
        toolStreamline = storedToolStreamlines[newTool] ?? toolStreamline
        toolHardness = storedToolHardnesses[newTool] ?? toolHardness
        toolSpacing = storedToolSpacings[newTool] ?? toolSpacing
        toolTaper = storedToolTapers[newTool] ?? toolTaper
        toolShapeID = storedToolShapes[newTool]
        isSwappingToolValues = false
    }
    var currentColor: Color = .black {
        didSet { applyTool() }
    }
    var promptText = "" {
        didSet {
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

    var drawingLayout: DrawingLayout = .splitScreen {
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
    /// arrival to emit PostHog's `stream.first_frame` with a waitMs property.
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

    /// Currently-playing video MP4 temp path. Tracked so we can delete it
    /// when the user resumes drawing (state leaves video) and avoid
    /// littering NSTemporaryDirectory across many idle/draw cycles.
    private var currentVideoMP4URL: URL?
    private(set) var streamFrameCount = 0

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

        // Gate on auth: if no Keychain token, show sign-in. Otherwise the
        // normal gallery/drawing flow resumes.
        let initialUserId = KeychainStore.default.get("userId")
        let initialEmail = KeychainStore.default.get("email")
        self.signedInUserId = initialUserId
        if initialUserId == nil {
            currentScreen = .signIn
        } else {
            // Re-bind analytics identity on every relaunch of an already-signed-in
            // user. `signInWithApple()` is the only other place `identify` fires,
            // but it only runs on a fresh sign-in — so without this call, returning
            // users stay bound to their anonymous device ID forever and iOS events
            // never stitch to the backend-emitted userId.
            Analytics.identify(userId: initialUserId!, email: initialEmail)

            // Re-sync subscription entitlements on launch: posts any current
            // StoreKit entitlement to the backend (reconciles a missed webhook /
            // fresh install) and updates local status for the paywall.
            Task { @MainActor [subscriptionManager] in
                await subscriptionManager.refreshEntitlements()
            }
            refreshUsage()

            // If no drawings exist, go directly to a new drawing
            let descriptor = FetchDescriptor<Drawing>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            let count = (try? modelContext.fetchCount(descriptor)) ?? 0
            if count == 0 {
                let drawing = Drawing()
                modelContext.insert(drawing)
                try? modelContext.save()
                currentDrawingId = drawing.id
                currentScreen = .drawing
            }
        }

        applyTool()
        startObservingCanvas()

        // Cold launch = first foreground. scenePhase onChange may not fire for
        // the initial .active value, so open the app session here; subsequent
        // foregrounds go through handleScenePhaseChange (idempotent).
        markForegrounded()

        // Pre-warm the GPU pod as soon as the app launches with a signed-in
        // user. ~90s cold start otherwise dominates time-to-first-image and
        // makes the app look broken to App Review and first-time users.
        if signedInUserId != nil {
            startStream()
            seedResultStateForCurrentDrawing()
        }

        // Eyedropper: commit picked colors to currentColor
        canvasViewModel.onColorPicked = { [weak self] uiColor in
            self?.currentColor = Color(uiColor: uiColor)
        }
        // DEV stroke recorder: capture completed strokes while recording is on.
        canvasViewModel.onStrokeCompleted = { [weak self] stroke in
            guard let self, self.isRecordingStrokes else { return }
            self.recordedStrokes.append(stroke)
        }
        // Supply the current brush color to the canvas ring preview
        canvasViewModel.currentBrushColorProvider = { [weak self] in
            UIColor(self?.currentColor ?? .black)
        }
        // Auto-resume after idle timeout: any stroke fires this, and if the
        // session is paused we kick a fresh provision without requiring the
        // user to navigate or tap an overlay.
        canvasViewModel.onUserActivity = { [weak self] in
            self?.handleUserActivity()
        }
        // QuickShape telemetry — forward recognizer lifecycle events to PostHog.
        canvasViewModel.onSnapEvent = { event in
            Self.trackSnapEvent(event)
        }
        // QuickShape NUX tooltip — observed by DrawingView via @Observable.
        canvasViewModel.onFirstBrushStrokeCommitted = { [weak self] in
            self?.shouldShowQuickShapeTooltip = true
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
    /// to the main app. Called from SignInView.
    func signInWithApple(identityToken: String) async throws {
        let transaction = SentrySDK.startTransaction(name: "auth.signIn", operation: "auth.signIn")
        do {
            try await authService.signInWithApple(identityToken: identityToken, nonce: nil)
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
                Analytics.identify(userId: userId, email: email)
                Analytics.track(.userSignedIn, properties: ["user_id": userId])
                // Tag every Sentry event/log/span emitted on this device with
                // user.id so cross-stack queries `user_id:<X>` return iOS
                // logs alongside backend + pod. Cleared on sign-out below.
                SentrySDK.setUser(User(userId: userId))
                Log.info("auth.signed_in", attributes: [
                    "event": "auth.signed_in",
                    "user_id": userId,
                ])
            }

            // After sign-in, route to gallery (or create a new drawing if none exist).
            let descriptor = FetchDescriptor<Drawing>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            let count = (try? self.modelContext.fetchCount(descriptor)) ?? 0
            if count == 0 {
                let drawing = Drawing()
                self.modelContext.insert(drawing)
                try? self.modelContext.save()
                self.currentDrawingId = drawing.id
                self.currentScreen = .drawing
            } else {
                self.currentScreen = .gallery
            }

            // Kick off pod provisioning immediately so the user isn't waiting
            // for ~90s of cold start when they tap into a drawing.
            self.startStream()
            self.seedResultStateForCurrentDrawing()
        }
    }

    func signOut() {
        Task {
            // Ask the backend to terminate the pod and delete the session row
            // BEFORE clearing the JWT. Best-effort — never throws. Without
            // this, the pod leaks for ~10 min until the idle reaper catches it.
            await authService.requestServerSignOut()
            await authService.signOut()
            await MainActor.run {
                Analytics.track(.userSignedOut)
                Analytics.reset()
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
        if canvasViewModel.hasLassoSelection {
            canvasViewModel.cancelLassoSelection()
            return
        }
        canvasViewModel.undo()
    }

    func redo() {
        canvasViewModel.redo()
    }

    func clear() {
        canvasViewModel.clear()
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
    func flushRecording() async {
        guard let drawingId = currentDrawingId, let recorder else { return }
        if let urls = await recorder.checkpoint() {
            try? RecordingStore.shared.appendSegment(canvasTemp: urls.canvas, generatedTemp: urls.generated, for: drawingId)
        }
    }

    /// Compose the current drawing's recorded segments into a speed-paint replay
    /// MP4 in the chosen layout + speed, for preview and sharing. Writes a fresh
    /// file in its own temp dir (so the preview player never reads a file being
    /// overwritten), named "Speed Paint.mp4" for a clean Save-to-Files name.
    func composeReplay(layout: ReplayLayout, speed: Double, watermark: Bool) async -> URL? {
        guard let drawingId = currentDrawingId else { return nil }
        let segments = RecordingStore.shared.segmentURLs(for: drawingId)
        guard !segments.canvas.isEmpty else { return nil }
        let animationURL = RecordingStore.shared.generatedVideoURL(for: drawingId)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let output = dir.appendingPathComponent("Speed Paint.mp4")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try await SideBySideVideoComposer.compose(
                canvasSegments: segments.canvas,
                generatedSegments: segments.generated,
                generatedVideoURL: animationURL,
                outputURL: output,
                layout: layout,
                speed: speed,
                watermark: watermark
            )
            return output
        } catch {
            streamLog.error("Replay compose failed: \(error.localizedDescription)")
            SentrySDK.capture(error: error)
            return nil
        }
    }

    /// Finalize a session recording off the main thread, holding a background
    /// task assertion so `finishWriting` can complete if the app is backgrounding.
    private func finalizeRecording(_ recorder: DrawingVideoRecorder, drawingId: UUID) {
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "finalize-recording")
        Task.detached {
            if let urls = await recorder.finish() {
                try? RecordingStore.shared.appendSegment(
                    canvasTemp: urls.canvas,
                    generatedTemp: urls.generated,
                    for: drawingId
                )
            }
            await MainActor.run { UIApplication.shared.endBackgroundTask(bgTask) }
        }
    }

    // MARK: - Gallery / Persistence

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

        // Reset all state
        promptText = ""
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

    func openDrawing(_ drawing: Drawing) {
        isSuppressingObservation = true

        currentDrawingId = drawing.id
        currentDrawingOpenedAt = Date()

        // Restore settings
        promptText = drawing.promptText
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

        NSLog("%@", "🔬OVL AppCoordinator.openDrawing → .drawing  layout=\(drawingLayout.rawValue)  hasLastImage=\(lastSuccessfulImage != nil)")
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
        saveCurrentDrawing()
        saveDebounceTask?.cancel()

        // Emit drawing.closed before we clear the id.
        if let drawingId = currentDrawingId, let openedAt = currentDrawingOpenedAt {
            let sessionMs = Int(Date().timeIntervalSince(openedAt) * 1000)
            Analytics.track(.drawingClosed, properties: [
                "drawing_id": drawingId.uuidString,
                "session_duration_ms": sessionMs,
                "generation_count": streamFrameCount,
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
        // through pod provisioning to first frame received. `StreamSession`
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
        components.queryItems = [URLQueryItem(name: "streamId", value: streamId)]
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
                await MainActor.run {
                    self.startStreamSession(request: request, backendWsURL: wsURL)
                }
            } catch {
                await MainActor.run {
                    streamLog.error("Auth token fetch failed: \(error.localizedDescription)")
                    SentrySDK.capture(error: error) { scope in
                        scope.setTag(value: "stream.authTokenFetch", key: "op")
                    }
                    startupTx.finish(status: .unauthenticated)
                    self.pendingStartupTransaction = nil
                    self.streamReadiness = .failed(message: "Please sign in again")
                    self.generationError = "Please sign in again"
                    self.signOut()
                }
            }
        }
    }

    /// Records the current drawing's two timelapse tracks (canvas + generated).
    /// Created per stream session, finalized in `stopStream`. Separate from the
    /// ephemeral backend idle-animation MP4 (`currentVideoMP4URL`).
    private var recorder: DrawingVideoRecorder?

    /// Canvas frames captured since this session's recorder started — gates
    /// `canShareVideo` so the replay is offered while drawing, before any segment
    /// has been finalized to disk.
    private var recordedCanvasFrames = 0

    @MainActor
    private func startStreamSession(request: URLRequest, backendWsURL: URL) {
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
        recorder = videoRecorder
        recordedCanvasFrames = 0
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
            // Resuming img2img clobbers any in-flight video state. Drop the
            // looping MP4 from disk now — otherwise NSTemporaryDirectory
            // accumulates one file per draw/idle cycle until stopStream.
            if let prior = self.currentVideoMP4URL {
                try? FileManager.default.removeItem(at: prior)
                self.currentVideoMP4URL = nil
            }
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

    /// Public entry point for resuming a paused/idle session. Used by:
    ///   • The right-pane "Session paused" overlay (tap target)
    ///   • Stroke-triggered auto-resume (canvas onUserActivity)
    /// Tears down the existing (stopped) session and starts a fresh one. The
    /// `startStream()` early-return on `streamSession != nil` would otherwise
    /// no-op, since the session is technically present but stopped.
    func resumeStream() {
        if streamSession != nil {
            streamLog.info("Resume requested — tearing down stopped session")
            streamSession?.stop()
            streamSession = nil
        }
        startStream()
    }

    /// Called whenever the user starts a canvas stroke. If the session is
    /// idle-timed-out, this auto-resumes — no need to navigate or tap.
    fileprivate func handleUserActivity() {
        if case .idleTimeout = streamReadiness {
            streamLog.info("User activity detected during idle timeout — resuming stream")
            resumeStream()
        }
    }

    private func stopStream() {
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
        // Clean up the looping MP4 temp file (if any) so we don't leave
        // junk in NSTemporaryDirectory across many sessions.
        if let url = currentVideoMP4URL {
            try? FileManager.default.removeItem(at: url)
            currentVideoMP4URL = nil
        }

        // Finalize this session's timelapse recording (distinct from the LTX
        // idle-animation MP4 above). If the recorder was cancelled (empty
        // drawing) finish() no-ops and stores nothing.
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

    /// Direct map from stream readiness to `resultState`. The single rule:
    /// `.ready` shows the bottom-left badge over a preview/streaming image;
    /// every other readiness state shows the corresponding overlay, with
    /// `lastSuccessfulImage` dimmed underneath when one exists.
    private func applyReadinessToResultState(_ readiness: StreamSession.StreamReadiness) {
        switch readiness {
        case .disconnected:
            resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        case .warming(let message, let startedAt):
            // `startedAt` is server-authoritative (orchestrator's session.createdAt
            // threaded through state events), so the progress bar reflects the
            // real pod-warm-cycle origin even after gallery↔drawing nav.
            resultState = .provisioning(
                message: message,
                startedAt: startedAt,
                previousImage: lastSuccessfulImage
            )
        case .ready:
            // Pod is genuinely ready; the first frame will move us to
            // `.streaming`. Show preview (or empty) until then.
            resultState = lastSuccessfulImage.map { .preview(image: $0) } ?? .empty
        case .failed(let msg):
            streamLog.error("Stream failed: \(msg)")
            resultState = .error(message: msg, previousImage: lastSuccessfulImage)
        case .idleTimeout:
            resultState = .idleTimeout(previousImage: lastSuccessfulImage)
        }
    }

    /// Seed `resultState` when entering a drawing so the result pane reflects
    /// any pre-warming already in progress, instead of momentarily flashing
    /// empty.
    private func seedResultStateForCurrentDrawing() {
        applyReadinessToResultState(streamReadiness)
    }

    /// Map a video pod event into ResultState transitions. Overall flow:
    ///   .streaming → .videoStreaming(latestFrame) → .videoLooping(mp4) → ...
    /// New img2img frames automatically clobber the video state via
    /// onImageReceived's `.streaming` set, so cancellation of an in-flight
    /// video on resume-drawing happens implicitly. The .cancelled event
    /// here covers the case where the pod aborted before any image
    /// arrived (e.g. during model warmup).
    private func handleVideoEvent(_ event: StreamWebSocketClient.VideoEvent) {
        let prev = String(describing: resultState).prefix(40)
        switch event {
        case .frame(_, let imageData, let index, let total):
            guard let frame = UIImage(data: imageData),
                  let fallback = lastSuccessfulImage else {
                streamLog.warning("[result] video_frame ignored (no fallback or decode failed)")
                return
            }
            resultState = .videoStreaming(latestFrame: frame, fallback: fallback)
            // Overlay mode: clear the visual-only fresh-stroke surface on each video
            // frame too, so the idle-state animation shows cleanly in the locked
            // overlay position. No-op in other layouts.
            canvasViewModel.clearOverlayStrokes()
            streamLog.info("[result] \(prev) → videoStreaming index=\(index ?? -1)/\(total ?? -1)")
            // Phase transition: → animating. Set on every video frame so a
            // resume-drawing → frame-arrives transition cleanly flips back
            // to .drawing in onImageReceived.
            if Phase.current != .animating {
                Phase.set(.animating)
            }
        case .complete(_, let mp4Data, _, let frames):
            guard let fallback = lastSuccessfulImage else { return }
            // Clean up any prior MP4 we wrote — only one in flight at a time.
            if let prior = currentVideoMP4URL {
                try? FileManager.default.removeItem(at: prior)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("kiki-video-\(UUID().uuidString).mp4")
            do {
                try mp4Data.write(to: url, options: .atomic)
                currentVideoMP4URL = url
                resultState = .videoLooping(mp4URL: url, fallback: fallback)
                // Persist the animation per drawing so the speed-paint replay can
                // append it (the temp copy above is cleared on resume/stop).
                if let drawingId = currentDrawingId {
                    try? RecordingStore.shared.saveGeneratedVideo(mp4Data, for: drawingId)
                }
                streamLog.info("[result] \(prev) → videoLooping bytes=\(mp4Data.count) frames=\(frames ?? -1)")
            } catch {
                streamLog.error("[result] mp4 write failed: \(error.localizedDescription)")
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "video.mp4_write", key: "op")
                }
            }
        case .cancelled(_, let atStep, let error):
            // If we're not currently in a video state, nothing to revert
            // (img2img already drove us out). Otherwise pop back to
            // .streaming on the last image.
            if resultState.isVideo, let img = lastSuccessfulImage {
                resultState = .streaming(image: img, frameCount: streamFrameCount)
            }
            if let prior = currentVideoMP4URL {
                try? FileManager.default.removeItem(at: prior)
                currentVideoMP4URL = nil
            }
            streamLog.info("[result] video_cancelled atStep=\(atStep ?? -1) err=\(error ?? "")")
        }
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
        let c = preset.configure(base)
        isSwappingToolValues = true
        toolOpacity = c.opacity
        toolFlow = c.flow
        toolStreamline = c.streamline
        toolStabilization = c.stabilization
        toolPressureSmoothing = c.pressureSmoothing
        toolHardness = c.hardness
        toolSpacing = c.spacing
        toolSpacingJitter = c.spacingJitter
        toolTaper = c.taper
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
        toolWetEnabled = false
        toolWetSmudge = false
        isSwappingToolValues = false
        activeCuratedPresetID = preset.id
        activeTestNote = nil
        applyTool()
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
        toolTaper = d.taper
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
        toolWetEnabled = false
        toolWetSmudge = false
        isSwappingToolValues = false
        activeCuratedPresetID = nil
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

    private func applyTool() {
        switch currentTool {
        case .brush:
            let config = BrushConfig(
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
                taper: toolTaper,
                wetEnabled: toolWetEnabled || toolWetSmudge,
                wetStrength: toolWetStrength,
                wetPickup: toolWetPickup,
                wetSmudge: toolWetSmudge,
                shapeID: toolShapeID,
                aspectRatio: toolAspect,
                grainID: toolGrainID,
                grainDepth: toolGrainDepth,
                grainScale: toolGrainScale,
                tipLightness: toolTipLightness,
                tipAngle: toolTipAngle,
                fallOff: toolFallOff,
                stampCount: Int(toolStampCount.rounded()),
                stampCountJitter: toolStampCountJitter,
                rotationFollow: toolRotationFollow,
                flipX: toolFlipX,
                flipY: toolFlipY,
                dynamics: toolDynamics
            )
            canvasViewModel.selectBrush(config)
        case .eraser:
            canvasViewModel.selectEraser(width: toolSize)
        case .lasso:
            canvasViewModel.selectLasso()
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

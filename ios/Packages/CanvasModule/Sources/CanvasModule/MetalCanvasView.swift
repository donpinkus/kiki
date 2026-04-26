import UIKit
import Metal
import StrokeRecognizerModule

/// Metal-backed drawing canvas. GPU-resident
/// texture pipeline: all painting happens in Metal shaders, display via
/// `CAMetalLayer`, zero CPU↔GPU pixel copies per frame.
///
/// Architecture:
///   - `CanvasRenderer` owns all Metal state (device, pipelines, textures).
///   - Touch events → stamp instances (CPU, fast) → instanced GPU draw (per frame).
///   - `CADisplayLink` drives rendering; only encodes a pass when dirty.
///   - Active stroke lives in a scratch texture; flattened into the canvas on touchesEnded.
public final class MetalCanvasView: UIView {

    // MARK: - Public State

    public var currentTool: ToolState = .brush(.defaultPen)

    /// Layer metadata, read from the renderer (single source of truth).
    public var layers: [LayerInfo] {
        renderer.layers.map { LayerInfo(id: $0.id, name: $0.name, isVisible: $0.isVisible) }
    }
    /// Which layer is currently active for drawing.
    public var activeLayerIndex: Int { renderer.activeLayerIndex }

    /// Tracks canvas-modifying operations (brush, erase, lasso, bake, load).
    /// Used for isEmpty checks and save-trigger telemetry.
    public private(set) var strokeCount: Int = 0

    public var isEmpty: Bool { strokeCount == 0 }

    // MARK: - Callbacks

    public var onDrawingChanged: (() -> Void)?
    /// Fired after any mutation that changes observable state (layers, undo, content).
    /// CanvasViewModel listens to this to sync its @Observable properties.
    public var onStateChanged: (() -> Void)?
    public var onInteractionBegan: (() -> Void)?
    public var onInteractionEnded: (() -> Void)?
    /// Fired when a lasso selection is extracted. No UIImage — the selection lives
    /// as an MTLTexture on the renderer, displayed by the Metal compositor.
    public var onLassoSelectionStarted: ((_ closedPath: CGPath, _ selectionBounds: CGRect) -> Void)?

    // MARK: - Private State

    private let renderer: CanvasRenderer
    private var displayLink: CADisplayLink?
    private var isDirty = true
    /// Canvas bitmap deferred from loadDrawingData until layout is ready.
    private var pendingCanvasImage: CGImage?
    /// Layered drawing deferred from loadDrawingData until layout is ready.
    private var pendingLayeredDrawing: LayeredDrawing?

    // MARK: - Stroke State

    private var drawingTouch: UITouch?
    private var activeStroke: Stroke?
    private var activeStrokeStamps: [CanvasRenderer.StampInstance] = []

    /// For eraser: tracks the last stroke-point index that was applied to the canvas.
    /// Eraser stamps are applied incrementally (each touchesMoved renders only NEW
    /// stamps directly into the canvas), unlike brush which rebuilds all stamps each frame.
    private var lastEraserPointIndex: Int = 0
    /// Position of the last eraser stamp placed, persisted across touchesMoved batches
    /// so spacing is continuous (no gap/clustering at batch boundaries).
    private var lastEraserStampPos: CGPoint = .zero
    /// Spacing from the last eraser stamp, carried across batches.
    private var lastEraserSpacing: CGFloat = 0.5

    // MARK: - Undo

    /// Each undo entry records which layer was affected and a snapshot of that
    /// layer's texture bytes. This gives global undo (last action regardless of
    /// which layer is currently active) while only storing one layer per entry.
    private struct UndoEntry {
        let layerIndex: Int
        let snapshotData: Data
    }
    private var undoSnapshots: [UndoEntry] = []
    private var redoSnapshots: [UndoEntry] = []
    private static let maxUndoDepth = 30

    public var canUndo: Bool { !undoSnapshots.isEmpty }
    public var canRedo: Bool { !redoSnapshots.isEmpty }

    // MARK: - Lasso

    private var lassoPoints: [CGPoint] = []
    private var lassoPath: CGMutablePath?
    public private(set) var lassoClipPath: CGPath?

    /// Marching-ants preview of the lasso path while the user draws it.
    /// Two shape layers (white + black offset dashes) for visibility on any background.
    private let lassoPreviewWhite = CAShapeLayer()
    private let lassoPreviewBlack = CAShapeLayer()

    // MARK: - QuickShape (v0: line only)

    /// Master kill switch for the QuickShape feature. Per user direction
    /// (2026-04), shipping with this always-on; no settings toggle in v0.
    public var isQuickShapeEnabled: Bool = true

    /// Verbose console logging of recognizer state transitions and per-tick
    /// diagnostics. Off by default; flip on in dev builds when tuning seeds.
    public var isQuickShapeLoggingEnabled: Bool = false

    /// Telemetry callback fired at each significant stage of the snap
    /// lifecycle. Wired by the app target to forward to PostHog (or any
    /// other analytics backend).
    public var onSnapEvent: ((SnapEvent) -> Void)?

    /// Wall-clock timestamp of the most recent snap commit. Used by the
    /// undo-within-2s detector to attribute fast undos to wrong-snaps.
    private var lastSnapCommitAt: Date?
    /// Whether the last brush stroke ended in a snap (vs a raw commit).
    /// Cleared when a new stroke begins.
    private var lastStrokeWasSnap: Bool = false
    /// Captured at commit time for `undoneWithin2s` payload.
    private var lastSnapVerdict: String = "line"
    private var lastSnapSnapshot: FeatureSnapshot?
    /// Touch timestamp at touchesBegan, for stroke-duration metric.
    private var currentStrokeStartTime: TimeInterval = 0

    /// Throttle for periodic diagnostic logs (every Nth touchesMoved tick).
    private var qsLogTickCounter: Int = 0

    /// Recognizer instance — created lazily on first brush stroke.
    private var recognizer: StrokeRecognizer?

    /// State of the snap workflow during the current stroke.
    private enum SnapState {
        case drawing
        case preview(verdict: Verdict, enteredAt: TimeInterval)
        case committed
    }
    private var snapState: SnapState = .drawing

    /// Overlay layer showing the snap preview ghost (line outline above active stroke).
    private let snapPreviewLayer = CAShapeLayer()
    private let previewHaptic = UIImpactFeedbackGenerator(style: .light)
    private let commitHaptic = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Init

    override init(frame: CGRect) {
        guard let r = CanvasRenderer() else {
            fatalError("Metal is not available on this device")
        }
        self.renderer = r
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        guard let r = CanvasRenderer() else {
            fatalError("Metal is not available on this device")
        }
        self.renderer = r
        super.init(coder: coder)
        setup()
    }

    deinit {
        displayLink?.invalidate()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false

        // Configure CAMetalLayer (the view's layer IS the metal layer).
        let metalLayer = self.layer as! CAMetalLayer
        metalLayer.device = renderer.device
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = false  // allow drawHierarchy reads for stream capture
        metalLayer.maximumDrawableCount = 2  // double-buffer for lowest latency
        metalLayer.isOpaque = false          // transparent so background UIImageView shows

        // Display link at ProMotion rate. Only fires when dirty.
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.displayLink = link

        // Lasso preview shape layers — marching ants (white + black offset dashes).
        for (shapeLayer, color, phase) in [
            (lassoPreviewWhite, UIColor.white, NSNumber(value: 0)),
            (lassoPreviewBlack, UIColor.black, NSNumber(value: 5))
        ] {
            shapeLayer.fillColor = nil
            shapeLayer.strokeColor = color.cgColor
            shapeLayer.lineWidth = 2
            shapeLayer.lineCap = .round
            shapeLayer.lineJoin = .round
            shapeLayer.lineDashPattern = [6, 4]
            shapeLayer.lineDashPhase = CGFloat(phase.floatValue)
            shapeLayer.isHidden = true
            layer.addSublayer(shapeLayer)
        }

        // QuickShape preview ghost — solid 1.5pt outline above the active stroke.
        // Color/opacity set per-stroke based on the current brush.
        snapPreviewLayer.fillColor = nil
        snapPreviewLayer.lineWidth = 1.5
        snapPreviewLayer.lineCap = .round
        snapPreviewLayer.lineJoin = .round
        snapPreviewLayer.isHidden = true
        layer.addSublayer(snapPreviewLayer)
    }

    public func setQuickShapeEnabled(_ enabled: Bool) {
        isQuickShapeEnabled = enabled
        if !enabled {
            cancelSnapPreview()
        }
    }

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public override func layoutSubviews() {
        super.layoutSubviews()
        let metalLayer = self.layer as! CAMetalLayer
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let pixelW = Int(bounds.width * scale)
        let pixelH = Int(bounds.height * scale)
        metalLayer.drawableSize = CGSize(width: pixelW, height: pixelH)
        renderer.resizeCanvas(width: pixelW, height: pixelH, viewScale: scale)

        // If drawing data was loaded before layout (canvas texture didn't exist
        // yet), apply it now that the texture is allocated.
        if pendingLayeredDrawing != nil {
            applyPendingLayeredDrawing()
        } else if pendingCanvasImage != nil {
            applyPendingCanvasImage()
        }

        isDirty = true
    }

    // MARK: - Display Link

    @objc private func displayLinkFired() {
        guard isDirty else { return }
        isDirty = false
        renderFrame()
    }

    private func renderFrame() {
        let metalLayer = self.layer as! CAMetalLayer
        guard let drawable = metalLayer.nextDrawable() else { return }

        // Populate stamp buffer from active stroke stamps.
        renderer.clearStamps()
        for stamp in activeStrokeStamps {
            renderer.appendStamp(stamp)
        }

        let isErasing: Bool
        if case .eraser = currentTool { isErasing = true } else { isErasing = false }

        renderer.renderFrame(drawable: drawable, isErasing: isErasing)
    }

    // MARK: - Touch Handling

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if isQuickShapeLoggingEnabled {
            print("\n===== [QS] STROKE BEGIN — touches=\(touches.count), tool=\(currentTool) =====")
        }

        guard drawingTouch == nil, let touch = touches.first else {
            if isQuickShapeLoggingEnabled {
                print("[QS] touchesBegan rejected (drawingTouch=\(drawingTouch != nil ? "busy" : "nil"))")
            }
            return
        }
        drawingTouch = touch
        onInteractionBegan?()

        let point = touch.location(in: self)

        switch currentTool {
        case .brush(let config):
            activeStroke = Stroke(points: [makeStrokePoint(from: touch)], brush: config)
            activeStrokeStamps = []
            appendStampsForLatestPoints(touch: touch, event: nil)
            // QuickShape: reset recognizer state for the new stroke.
            if isQuickShapeEnabled {
                ensureRecognizer().reset()
                snapState = .drawing
                qsLogTickCounter = 0
                lastStrokeWasSnap = false
                currentStrokeStartTime = touch.timestamp
                feedRecognizer(touch: touch, event: nil)
                // Pre-prepare haptics so first impact has minimal latency.
                previewHaptic.prepare()
                commitHaptic.prepare()
                if isQuickShapeLoggingEnabled {
                    print("[QS] touchesBegan — recognizer reset")
                }
            }

        case .eraser(let width):
            let brush = BrushConfig(color: .black, baseWidth: width, pressureGamma: 0.7)
            activeStroke = Stroke(points: [makeStrokePoint(from: touch)], brush: brush)
            activeStrokeStamps = []
            lastEraserPointIndex = 0
            lastEraserStampPos = touch.location(in: self)
            lastEraserSpacing = max(width * 0.3, 0.5)
            // Snapshot canvas BEFORE any erasing so undo restores the pre-erase state.
            pushUndoSnapshot()

        case .lasso:
            lassoPoints = [point]
            let path = CGMutablePath()
            path.move(to: point)
            lassoPath = path
            // Snapshot for undo/cancel before lasso extraction modifies the canvas.
            pushUndoSnapshot()
        }

        isDirty = true
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }

        switch currentTool {
        case .brush:
            // Append coalesced points and rebuild all stamps for live preview.
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            for ct in coalesced {
                activeStroke?.points.append(makeStrokePoint(from: ct))
            }
            appendStampsForLatestPoints(touch: touch, event: event)
            // QuickShape: feed recognizer + drive snap state machine.
            if isQuickShapeEnabled, case .committed = snapState {
                // Already snapped — ignore further input until touchesEnded.
            } else if isQuickShapeEnabled {
                feedRecognizer(touch: touch, event: event)
                updateSnapState()
            }

        case .eraser:
            // Append coalesced points, then apply ONLY new stamps directly to canvas.
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            for ct in coalesced {
                activeStroke?.points.append(makeStrokePoint(from: ct))
            }
            applyNewEraserStamps()

        case .lasso:
            let location = touch.location(in: self)
            lassoPoints.append(location)
            let path = CGMutablePath()
            path.move(to: lassoPoints[0])
            for i in 1..<lassoPoints.count { path.addLine(to: lassoPoints[i]) }
            lassoPath = path
            // Update the marching-ants shape layers so the user can see the path.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lassoPreviewWhite.path = path
            lassoPreviewBlack.path = path
            lassoPreviewWhite.isHidden = false
            lassoPreviewBlack.isHidden = false
            CATransaction.commit()
        }

        isDirty = true
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }

        // Telemetry / diagnostic at touchesEnded.
        if isQuickShapeEnabled, let recognizer {
            let v = recognizer.finalize()
            // Fire abstain event if the stroke ended without committing a snap.
            if case .committed = snapState {
                // Already fired .committed in commitSnap; nothing to do here.
            } else if case .abstain(let reason) = v {
                onSnapEvent?(.abstained(SnapAbstainedInfo(
                    reason: reason.rawValue,
                    confidence: Double(recognizer.currentConfidence),
                    snapshot: recognizer.lastFeatureSnapshot
                )))
            } else if case .line = v {
                // Final verdict was a snap-eligible line but we didn't commit
                // (user didn't hold long enough). Treat as "abstained — no hold".
                onSnapEvent?(.abstained(SnapAbstainedInfo(
                    reason: "no_hold",
                    confidence: Double(recognizer.currentConfidence),
                    snapshot: recognizer.lastFeatureSnapshot
                )))
            }

            // Verbose diagnostic logging.
            if isQuickShapeLoggingEnabled {
                let verdictDesc: String
                switch v {
                case .line(let g): verdictDesc = "line[(\(fmt(g.start.x)),\(fmt(g.start.y))) → (\(fmt(g.end.x)),\(fmt(g.end.y)))]"
                case .abstain(let r): verdictDesc = "abstain(\(r.rawValue))"
                }
                print("[QS] touchesEnded — final verdict=\(verdictDesc) conf=\(fmt(recognizer.currentConfidence)) snapState=\(stateDesc(snapState))")
                if let s = recognizer.lastFeatureSnapshot {
                    print("[QS] features: pathLen=\(fmt(s.pathLength)) bbox=\(fmt(s.bboxDiagonal)) sagRatio=\(fmt(s.sagittaRatio)) sgnTurn=\(fmt(s.totalSignedTurnDeg))° absTurn=\(fmt(s.totalAbsTurnDeg))° lineRMS=\(fmt(s.lineNormRMS)) resampledN=\(s.resampledPointCount) score=\(fmt(s.lineScore))")
                }
                print("===== [QS] STROKE END =====\n")
            }
        }

        if case .lasso = currentTool {
            finishLasso()
        } else {
            finishStroke()
        }
    }

    private func fmt(_ v: CGFloat) -> String { String(format: "%.2f", v) }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }

        if case .eraser = currentTool {
            // Eraser stamps were applied directly to canvas — revert by restoring
            // the undo snapshot that was pushed at touchesBegan.
            if let entry = undoSnapshots.popLast() {
                renderer.restoreLayer(at: entry.layerIndex, from: entry.snapshotData)
            }
        }

        cancelSnapPreview()
        recognizer?.reset()
        snapState = .drawing

        activeStroke = nil
        activeStrokeStamps = []
        drawingTouch = nil
        lastEraserPointIndex = 0
        lassoPoints.removeAll()
        lassoPath = nil
        hideLassoPreview()
        onInteractionEnded?()
        isDirty = true
    }

    // MARK: - Stamp Generation

    /// Rebuild all stamp instances for the current active stroke. Delegates to
    /// `generateStampsForStroke` which handles arc-length interpolation with
    /// adaptive spacing.
    private func appendStampsForLatestPoints(touch: UITouch, event: UIEvent?) {
        guard let stroke = activeStroke else { return }
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)
    }

    // MARK: - Eraser (incremental application)

    /// Generate stamps from newly-added stroke points and apply them directly
    /// to the active layer texture with destination-out blend. Called per touchesMoved.
    ///
    /// Unlike brush (which stages stamps in scratch for live preview then flattens
    /// on touchesEnded), eraser commits each batch immediately so the erased region
    /// is visible in real time. Undo snapshot was pre-pushed at touchesBegan.
    ///
    /// Uses adaptive spacing and persists stamp position across batches.
    /// When `lassoClipPath` is set, stamps outside the clip path are skipped.
    private func applyNewEraserStamps() {
        guard let stroke = activeStroke, stroke.points.count > lastEraserPointIndex else { return }

        let brush = stroke.brush
        let scale = canvasScale
        let color = SIMD4<Float>(1, 1, 1, 1)
        let clipPath = lassoClipPath

        var newStamps: [CanvasRenderer.StampInstance] = []
        // Use the persisted last-stamp position for correct cross-batch spacing.
        var stampPos = lastEraserStampPos
        var spacing = lastEraserSpacing

        // Walk from the first unprocessed point to the end of the stroke.
        let startIdx = max(lastEraserPointIndex, 1)
        for i in startIdx..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            let dx = curr.position.x - prev.position.x
            let dy = curr.position.y - prev.position.y
            let segDist = hypot(dx, dy)
            guard segDist > 0 else { continue }

            // How far along this segment do we need to go before the next stamp?
            let distFromLastStamp = hypot(prev.position.x - stampPos.x, prev.position.y - stampPos.y)
            var traveled = max(0, spacing - distFromLastStamp)

            while traveled <= segDist {
                let t = traveled / segDist
                let x = prev.position.x + dx * t
                let y = prev.position.y + dy * t
                let force = prev.force + (curr.force - prev.force) * t
                let altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                let width = brush.effectiveWidth(force: force, altitude: altitude)

                let pos = CGPoint(x: x, y: y)
                if clipPath.map({ $0.contains(pos) }) ?? true {
                    newStamps.append(CanvasRenderer.StampInstance(
                        center: SIMD2<Float>(Float(x * scale), Float(y * scale)),
                        radius: Float(width * 0.5 * scale),
                        rotation: 0,
                        color: color
                    ))
                }

                stampPos = CGPoint(x: x, y: y)
                spacing = max(width * 0.3, 0.5)
                traveled += spacing
            }
        }

        lastEraserPointIndex = stroke.points.count
        lastEraserStampPos = stampPos
        lastEraserSpacing = spacing

        guard !newStamps.isEmpty else { return }
        renderer.applyEraserStamps(newStamps)
    }

    // MARK: - Stroke Completion

    private func finishStroke() {
        defer {
            cancelSnapPreview()
            snapState = .drawing
            recognizer?.reset()
            activeStroke = nil
            activeStrokeStamps = []
            drawingTouch = nil
            lastEraserPointIndex = 0
            lastEraserStampPos = .zero
            lastEraserSpacing = 0.5
            onInteractionEnded?()
        }

        guard let stroke = activeStroke, !stroke.points.isEmpty else { return }

        if case .eraser = currentTool {
            // Eraser stamps were already applied directly to canvas during touchesMoved.
            // Undo snapshot was pushed at touchesBegan. Nothing to flatten.
            strokeCount += 1
            onDrawingChanged?()
            isDirty = true
            return
        }

        // Brush: push undo snapshot, flatten scratch into canvas.
        pushUndoSnapshot()

        renderer.clearStamps()
        for stamp in activeStrokeStamps {
            renderer.appendStamp(stamp)
        }
        renderer.flattenScratchIntoCanvas()

        strokeCount += 1
        onDrawingChanged?()
        isDirty = true
    }

    // MARK: - QuickShape integration (v0)

    private func ensureRecognizer() -> StrokeRecognizer {
        if let r = recognizer { return r }
        let r = StrokeRecognizer()
        recognizer = r
        return r
    }

    private func feedRecognizer(touch: UITouch, event: UIEvent?) {
        guard let recognizer else { return }
        let touches = event?.coalescedTouches(for: touch) ?? [touch]
        for ct in touches {
            let p = ct.location(in: self)
            recognizer.feed(point: RecognizerInputPoint(
                position: p,
                timestamp: ct.timestamp
            ))
        }
    }

    /// Drive the snap state machine. Called after every recognizer feed.
    /// Stays cheap — only inspects `isHolding`, `currentVerdict`, and elapsed time.
    private func updateSnapState() {
        guard let recognizer else { return }
        let seeds = recognizer.seeds
        let now = recognizer.lastInputTimestamp ?? 0

        // Periodic diagnostic log (every ~10 ticks ≈ every ~4-7 frames).
        qsLogTickCounter += 1
        if isQuickShapeLoggingEnabled && qsLogTickCounter % 10 == 0 {
            let diag = recognizer.holdDiagnostic()
            let v = recognizer.currentVerdict()
            let verdictDesc: String
            switch v {
            case .line: verdictDesc = "line"
            case .abstain(let r): verdictDesc = "abstain(\(r.rawValue))"
            }
            let bbox = diag.map { fmt($0.bboxDiagonal) } ?? "-"
            let span = diag.map { String(format: "%.3f", $0.windowSpanSeconds) } ?? "-"
            let pts = diag?.inputPointCount ?? 0
            let conf = fmt(recognizer.currentConfidence)
            let hold = recognizer.isHolding ? "Y" : "N"

            // Most recent point + instantaneous velocity over the last segment.
            var posStr = "-"
            var velStr = "-"
            if let last = recognizer.lastInputPositionTimestamp,
               let prev = recognizer.previousInputPositionTimestamp {
                posStr = "(\(fmt(last.position.x)),\(fmt(last.position.y)))"
                let dt = last.timestamp - prev.timestamp
                if dt > 0 {
                    let dx = last.position.x - prev.position.x
                    let dy = last.position.y - prev.position.y
                    let dist = sqrt(dx * dx + dy * dy)
                    velStr = String(format: "%.0fpt/s", dist / CGFloat(dt))
                }
            }
            // Feature snapshot from the last full classification (refreshed by currentVerdict).
            var featStr = "-"
            if let s = recognizer.lastFeatureSnapshot {
                featStr = "lineRMS=\(fmt(s.lineNormRMS)) sag=\(fmt(s.sagittaRatio)) sgnTurn=\(fmt(s.totalSignedTurnDeg))° absTurn=\(fmt(s.totalAbsTurnDeg))°"
            }

            print("[QS tick] pts=\(pts) pos=\(posStr) vel=\(velStr) holding=\(hold) bbox=\(bbox) winSpan=\(span)s conf=\(conf) verdict=\(verdictDesc) state=\(stateDesc(snapState)) | \(featStr)")
        }

        switch snapState {
        case .drawing:
            // Wait for the user to hold near-stationary at the end of the stroke.
            guard recognizer.isHolding else { return }
            let verdict = recognizer.currentVerdict()
            if case .line = verdict, recognizer.currentConfidence >= seeds.acceptScore {
                showSnapPreview(verdict: verdict)
                snapState = .preview(verdict: verdict, enteredAt: now)
                previewHaptic.impactOccurred()
                previewHaptic.prepare()
                if isQuickShapeLoggingEnabled {
                    print("[QS] → Preview (conf=\(String(format: "%.2f", recognizer.currentConfidence)))")
                }
            } else if isQuickShapeLoggingEnabled, recognizer.isHolding {
                // Holding but no snap candidate — log why.
                let verdictDesc: String
                switch verdict {
                case .line: verdictDesc = "line"
                case .abstain(let r): verdictDesc = "abstain(\(r.rawValue))"
                }
                print("[QS] holding but no snap — verdict=\(verdictDesc) conf=\(String(format: "%.2f", recognizer.currentConfidence)) (need ≥ \(seeds.acceptScore))")
            }

        case .preview(let cachedVerdict, let enteredAt):
            // Movement resumed → cancel preview entirely.
            if !recognizer.isHolding {
                cancelSnapPreview()
                snapState = .drawing
                onSnapEvent?(.previewCanceled(SnapPreviewCanceledInfo(reason: "movement")))
                if isQuickShapeLoggingEnabled { print("[QS] Preview → Drawing (movement resumed)") }
                return
            }
            let confidence = recognizer.currentConfidence
            let floor = seeds.acceptScore - seeds.confidenceHysteresis
            // Confidence dropped past the hysteresis floor → cancel.
            if confidence < floor {
                cancelSnapPreview()
                snapState = .drawing
                onSnapEvent?(.previewCanceled(SnapPreviewCanceledInfo(reason: "confidence")))
                if isQuickShapeLoggingEnabled { print("[QS] Preview → Drawing (conf \(String(format: "%.2f", confidence)) < floor \(String(format: "%.2f", floor)))") }
                return
            }
            // Verdict identity changed → cancel (cheap check: only line is supported in v0).
            let nowVerdict = recognizer.currentVerdict()
            guard case .line = nowVerdict else {
                cancelSnapPreview()
                snapState = .drawing
                onSnapEvent?(.previewCanceled(SnapPreviewCanceledInfo(reason: "verdict_change")))
                if isQuickShapeLoggingEnabled { print("[QS] Preview → Drawing (verdict no longer .line)") }
                return
            }
            // Refresh the preview geometry to track the latest fit.
            showSnapPreview(verdict: nowVerdict)
            // Hold delay elapsed → commit.
            if now - enteredAt >= seeds.holdCommitDelay {
                if isQuickShapeLoggingEnabled { print("[QS] → Commit (after \(String(format: "%.3f", now - enteredAt))s)") }
                commitSnap(verdict: cachedVerdict)
            }

        case .committed:
            break
        }
    }

    private func stateDesc(_ s: SnapState) -> String {
        switch s {
        case .drawing: return "drawing"
        case .preview: return "preview"
        case .committed: return "committed"
        }
    }

    /// Render the snap preview as a 1.5pt outline at 50% brush opacity.
    private func showSnapPreview(verdict: Verdict) {
        guard case .line(let geom) = verdict,
              case .brush(let config) = currentTool else { return }
        let path = CGMutablePath()
        path.move(to: geom.start)
        path.addLine(to: geom.end)
        let baseColor = config.color.uiColor
        let strokeColor = baseColor.withAlphaComponent(0.5).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapPreviewLayer.path = path
        snapPreviewLayer.strokeColor = strokeColor
        snapPreviewLayer.isHidden = false
        CATransaction.commit()
    }

    private func cancelSnapPreview() {
        guard !snapPreviewLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapPreviewLayer.isHidden = true
        snapPreviewLayer.path = nil
        CATransaction.commit()
    }

    /// Commit the current snap: replace the active stroke's points with samples
    /// along the corrected line, with force/altitude reparameterized by
    /// normalized arc-length so the user's full pressure profile is preserved
    /// (not just the endpoints). The brush engine then handles adaptive
    /// stamp spacing as it would for any other stroke.
    private func commitSnap(verdict: Verdict) {
        guard case .line(let geom) = verdict, var stroke = activeStroke else { return }

        let resampled = reparameterizeStrokePoints(
            rawPoints: stroke.points,
            correctedStart: geom.start,
            correctedEnd: geom.end
        )
        stroke.points = resampled
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)

        cancelSnapPreview()
        snapState = .committed
        commitHaptic.impactOccurred()
        if isQuickShapeLoggingEnabled {
            print("[QS] commitSnap — \(stroke.points.count) corrected points")
        }
        isDirty = true

        // Telemetry — capture state for both committed and any subsequent
        // undoneWithin2s event. Payload uses the recognizer's snapshot.
        lastStrokeWasSnap = true
        lastSnapCommitAt = Date()
        lastSnapVerdict = "line"
        lastSnapSnapshot = recognizer?.lastFeatureSnapshot
        if let snapshot = recognizer?.lastFeatureSnapshot,
           let lastTouchTime = recognizer?.lastInputTimestamp {
            onSnapEvent?(.committed(SnapCommittedInfo(
                verdict: "line",
                confidence: Double(recognizer?.currentConfidence ?? 0),
                strokeDurationSec: lastTouchTime - currentStrokeStartTime,
                snapshot: snapshot
            )))
        }
    }

    /// Map the raw stroke's force/altitude curve onto a corrected line segment.
    ///
    /// For each new sample at normalized arc-length t along the **corrected**
    /// line, look up the raw stroke's force/altitude at the same normalized t
    /// along its **own** arc-length and interpolate. This preserves pressure
    /// shape (a tapered stroke stays tapered) regardless of whether the
    /// corrected line is shorter, longer, or the same length as the raw path.
    ///
    /// The hold portion at the end of a stroke contributes negligible
    /// arc-length (positions are stationary), so it doesn't distort the t
    /// mapping — pressure curve from the actual drawing portion is preserved
    /// faithfully.
    private func reparameterizeStrokePoints(
        rawPoints: [StrokePoint],
        correctedStart: CGPoint,
        correctedEnd: CGPoint
    ) -> [StrokePoint] {
        guard rawPoints.count >= 2 else {
            // Degenerate input — fall back to constant pressure at the endpoints.
            let force = rawPoints.first?.force ?? 0.5
            let altitude = rawPoints.first?.altitude ?? .pi / 2
            let timestamp = rawPoints.first?.timestamp ?? 0
            return [
                StrokePoint(position: correctedStart, force: force, altitude: altitude, timestamp: timestamp),
                StrokePoint(position: correctedEnd, force: force, altitude: altitude, timestamp: timestamp),
            ]
        }

        // 1. Compute cumulative arc-length along the raw path.
        var rawCumulative: [CGFloat] = [0]
        rawCumulative.reserveCapacity(rawPoints.count)
        for i in 1..<rawPoints.count {
            let dx = rawPoints[i].position.x - rawPoints[i - 1].position.x
            let dy = rawPoints[i].position.y - rawPoints[i - 1].position.y
            rawCumulative.append(rawCumulative[i - 1] + hypot(dx, dy))
        }
        let totalRawLength = rawCumulative.last ?? 0
        guard totalRawLength > 0 else {
            // All raw points coincide. Use the first sample's properties.
            let p = rawPoints[0]
            return [
                StrokePoint(position: correctedStart, force: p.force, altitude: p.altitude, timestamp: p.timestamp),
                StrokePoint(position: correctedEnd, force: p.force, altitude: p.altitude, timestamp: p.timestamp),
            ]
        }

        // 2. Choose the corrected sample count. Bound between 8 and 64 — enough
        // resolution for the brush engine's adaptive stamp spacing to interpolate
        // smoothly, not so many that it dominates classification.
        let n = max(8, min(64, rawPoints.count))
        let dx = correctedEnd.x - correctedStart.x
        let dy = correctedEnd.y - correctedStart.y

        // 3. For each corrected sample at normalized t, look up the raw point
        // at the same normalized t along the raw arc-length and interpolate
        // force/altitude/timestamp.
        var result: [StrokePoint] = []
        result.reserveCapacity(n)
        var rawIdx = 0  // monotonic — corrected samples advance through raw segments

        for i in 0..<n {
            let t = CGFloat(i) / CGFloat(n - 1)
            let pos = CGPoint(x: correctedStart.x + dx * t, y: correctedStart.y + dy * t)
            let targetRawDist = t * totalRawLength

            // Advance rawIdx until the next raw point is past the target.
            while rawIdx < rawCumulative.count - 2 && rawCumulative[rawIdx + 1] < targetRawDist {
                rawIdx += 1
            }

            let force: CGFloat
            let altitude: CGFloat
            let timestamp: TimeInterval
            if rawIdx >= rawPoints.count - 1 {
                let last = rawPoints[rawPoints.count - 1]
                force = last.force
                altitude = last.altitude
                timestamp = last.timestamp
            } else {
                let segStart = rawCumulative[rawIdx]
                let segEnd = rawCumulative[rawIdx + 1]
                let segLen = segEnd - segStart
                let segT = segLen > 1e-9 ? max(0, min(1, (targetRawDist - segStart) / segLen)) : 0
                let prev = rawPoints[rawIdx]
                let next = rawPoints[rawIdx + 1]
                force = prev.force + (next.force - prev.force) * segT
                altitude = prev.altitude + (next.altitude - prev.altitude) * segT
                timestamp = prev.timestamp + (next.timestamp - prev.timestamp) * Double(segT)
            }

            result.append(StrokePoint(
                position: pos, force: force, altitude: altitude, timestamp: timestamp
            ))
        }

        return result
    }

    private func hideLassoPreview() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        lassoPreviewWhite.path = nil
        lassoPreviewBlack.path = nil
        lassoPreviewWhite.isHidden = true
        lassoPreviewBlack.isHidden = true
        CATransaction.commit()
    }

    /// Set or clear the clip mask path. Automatically manages marching ants display.
    /// When set, brush/eraser stamps outside the path are discarded.
    public func setClipPath(_ path: CGPath?) {
        lassoClipPath = path
        if let path = path {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            lassoPreviewWhite.path = path
            lassoPreviewBlack.path = path
            lassoPreviewWhite.isHidden = false
            lassoPreviewBlack.isHidden = false
            CATransaction.commit()
        } else {
            hideLassoPreview()
        }
    }

    private func finishLasso() {
        defer {
            drawingTouch = nil
            lassoPoints.removeAll()
            lassoPath = nil
            hideLassoPreview()
            onInteractionEnded?()
        }

        guard lassoPoints.count >= 3 else {
            if !undoSnapshots.isEmpty { undoSnapshots.removeLast() }
            isDirty = true
            return
        }

        // Close the lasso path.
        let closedPath = CGMutablePath()
        closedPath.move(to: lassoPoints[0])
        for i in 1..<lassoPoints.count {
            closedPath.addLine(to: lassoPoints[i])
        }
        closedPath.closeSubpath()

        let pathBounds = closedPath.boundingBox
        let fullRect = CGRect(origin: .zero, size: bounds.size)
        let cropRect = pathBounds.intersection(fullRect)
        guard cropRect.width >= 4, cropRect.height >= 4 else {
            if !undoSnapshots.isEmpty { undoSnapshots.removeLast() }
            isDirty = true
            return
        }

        // Metal-native extraction: rasterize path → mask, copy masked pixels → selection
        // texture, clear masked pixels from canvas. No CG color pipeline.
        renderer.extractSelection(canvasPath: closedPath, bounds: cropRect, canvasScale: canvasScale)

        isDirty = true

        // Signal that a selection is active. No UIImage — the texture lives on the renderer.
        onLassoSelectionStarted?(closedPath, cropRect)
    }

    // MARK: - Lasso Public API

    /// Update the floating selection's position from gesture state.
    public func updateSelectionTransform(translation: CGPoint, scale: CGFloat, rotation: CGFloat) {
        renderer.updateSelectionVertices(translation: translation, scale: scale, rotation: rotation)
        isDirty = true
    }

    /// Composite the selection texture onto the canvas at its current transform.
    public func commitSelection() {
        pushUndoSnapshot()
        renderer.commitSelection()
        isDirty = true
    }

    /// Discard the selection and restore pre-lasso canvas state.
    public func cancelSelection() {
        renderer.discardSelection()
        performUndo()
        isDirty = true
    }

    // MARK: - Undo / Redo

    private func pushUndoSnapshot() {
        guard let data = renderer.snapshotLayer(at: activeLayerIndex) else { return }
        undoSnapshots.append(UndoEntry(layerIndex: activeLayerIndex, snapshotData: data))
        if undoSnapshots.count > Self.maxUndoDepth {
            undoSnapshots.removeFirst()
        }
        redoSnapshots.removeAll()
    }

    public func performUndo() {
        guard let entry = undoSnapshots.popLast() else { return }
        if let current = renderer.snapshotLayer(at: entry.layerIndex) {
            redoSnapshots.append(UndoEntry(layerIndex: entry.layerIndex, snapshotData: current))
        }
        renderer.restoreLayer(at: entry.layerIndex, from: entry.snapshotData)
        if strokeCount > 0 { strokeCount -= 1 }

        // QuickShape: if the just-undone stroke was a snap committed within
        // the last 2 seconds, fire the wrong-snap proxy event. Clear the
        // tracking flag so a second undo doesn't double-fire.
        if lastStrokeWasSnap, let committedAt = lastSnapCommitAt {
            let elapsed = Date().timeIntervalSince(committedAt)
            if elapsed <= 2.0 {
                onSnapEvent?(.undoneWithin2s(SnapUndoneInfo(
                    originalVerdict: lastSnapVerdict,
                    elapsedSec: elapsed,
                    snapshot: lastSnapSnapshot
                )))
            }
            lastStrokeWasSnap = false
            lastSnapCommitAt = nil
        }

        onDrawingChanged?()
        onStateChanged?()
        isDirty = true
    }

    public func performRedo() {
        guard let entry = redoSnapshots.popLast() else { return }
        if let current = renderer.snapshotLayer(at: entry.layerIndex) {
            undoSnapshots.append(UndoEntry(layerIndex: entry.layerIndex, snapshotData: current))
        }
        renderer.restoreLayer(at: entry.layerIndex, from: entry.snapshotData)
        strokeCount += 1
        onDrawingChanged?()
        onStateChanged?()
        isDirty = true
    }

    // MARK: - Layer Management

    public func addLayer() {
        let count = renderer.layers.count
        guard count < CanvasRenderer.maxLayerCount else { return }
        let newIndex = renderer.addLayer(name: "Layer \(count + 1)")
        renderer.setActiveLayer(newIndex)
        isDirty = true
        onStateChanged?()
    }

    public func selectLayer(at index: Int) {
        renderer.setActiveLayer(index)
        isDirty = true
        onStateChanged?()
    }

    public func toggleLayerVisibility(at index: Int) {
        renderer.toggleVisibility(at: index)
        isDirty = true
        onStateChanged?()
    }

    public func deleteLayer(at index: Int) {
        renderer.removeLayer(at: index)
        isDirty = true
        onStateChanged?()
    }

    public func moveLayer(from source: Int, to destination: Int) {
        renderer.moveLayer(from: source, to: destination)
        isDirty = true
        onStateChanged?()
    }

    // MARK: - Public API

    /// Clear the entire canvas — resets to a single empty layer.
    public func clearAll() {
        pushUndoSnapshot()
        renderer.resetToSingleLayer()
        strokeCount = 0
        isDirty = true
        onStateChanged?()
    }

    /// Load an image onto the canvas (e.g., "Send to Canvas").
    public func bakeImage(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        renderer.loadImageIntoCanvas(cgImage)
        strokeCount += 1
        isDirty = true
        onStateChanged?()
    }

    /// Export all layers as a JSON envelope with per-layer PNG data.
    /// Returns nil if the canvas has no content.
    public func exportLayeredData() -> Data? {
        guard strokeCount > 0 else { return nil }

        var layerEntries: [LayeredDrawing.LayerEntry] = []
        for (i, info) in layers.enumerated() {
            guard let cgImage = renderer.layerToCGImage(at: i),
                  let png = UIImage(cgImage: cgImage).pngData() else { continue }
            layerEntries.append(LayeredDrawing.LayerEntry(
                id: info.id.uuidString,
                name: info.name,
                isVisible: info.isVisible,
                pngData: png
            ))
        }
        guard !layerEntries.isEmpty else { return nil }

        let drawing = LayeredDrawing(
            version: 1,
            layers: layerEntries,
            activeLayerIndex: activeLayerIndex
        )
        return try? JSONEncoder().encode(drawing)
    }

    /// Export the canvas as a single flattened PNG (used by stream capture).
    public func exportStrokeData() -> Data? {
        guard strokeCount > 0 else { return nil }
        guard let cgImage = renderer.flattenedCGImage() else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }

    /// Load canvas from saved data. Auto-detects format:
    /// 1. Layered JSON envelope (current format — per-layer PNGs)
    /// 2. Single PNG bitmap (pre-layers format — loads as layer 0)
    /// 3. Stroke JSON (legacy fallback — replays through stamp pipeline)
    public func loadDrawingData(_ data: Data) {
        // Try layered JSON first.
        if let layered = try? JSONDecoder().decode(LayeredDrawing.self, from: data) {
            pendingLayeredDrawing = layered
            strokeCount = 1

            guard renderer.hasCanvas else {
                isDirty = true
                return
            }
            applyPendingLayeredDrawing()
            return
        }

        // Try single PNG.
        if let image = UIImage(data: data)?.cgImage {
            pendingCanvasImage = image
            strokeCount = 1

            guard renderer.hasCanvas else {
                isDirty = true
                return
            }
            applyPendingCanvasImage()
            return
        }

        // Legacy stroke JSON fallback — replay immediately.
        if let savedStrokes = try? JSONDecoder().decode([Stroke].self, from: data),
           !savedStrokes.isEmpty, renderer.hasCanvas {
            let scale = canvasScale
            for stroke in savedStrokes {
                let stamps = generateStampsForStroke(stroke, scale: scale)
                if !stamps.isEmpty {
                    renderer.commitStampsToCanvas(stamps)
                }
            }
            strokeCount = savedStrokes.count
            isDirty = true
        }
    }

    /// Apply a deferred canvas bitmap load (single-layer backward compat).
    private func applyPendingCanvasImage() {
        guard let image = pendingCanvasImage else { return }
        pendingCanvasImage = nil
        renderer.loadImageIntoCanvas(image)
        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
        isDirty = true
        onDrawingChanged?()
    }

    /// Apply a deferred layered drawing load.
    private func applyPendingLayeredDrawing() {
        guard let layered = pendingLayeredDrawing else { return }
        pendingLayeredDrawing = nil

        // Create the right number of layer textures.
        // The first layer already exists from resizeCanvas. Add more as needed.
        while renderer.layers.count < layered.layers.count {
            renderer.addLayer()
        }

        for (i, entry) in layered.layers.enumerated() {
            guard i < renderer.layers.count else { break }
            renderer.layers[i] = CanvasRenderer.Layer(
                id: UUID(uuidString: entry.id) ?? UUID(),
                name: entry.name,
                isVisible: entry.isVisible,
                texture: renderer.layers[i].texture
            )
            if let image = UIImage(data: entry.pngData)?.cgImage {
                renderer.loadImageIntoLayer(at: i, image)
            }
        }

        let targetIndex = min(layered.activeLayerIndex, renderer.layers.count - 1)
        renderer.setActiveLayer(targetIndex)
        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
        isDirty = true
        onDrawingChanged?()
    }

    /// Generate stamp instances for a complete stroke (used by replay + active drawing).
    /// When `lassoClipPath` is set, stamps whose center falls outside the clip path
    /// are discarded (CPU-side clip masking).
    private func generateStampsForStroke(_ stroke: Stroke, scale: CGFloat) -> [CanvasRenderer.StampInstance] {
        guard !stroke.points.isEmpty else { return [] }

        let brush = stroke.brush
        let color = premultipliedColor(brush)
        let clipPath = lassoClipPath
        var stamps: [CanvasRenderer.StampInstance] = []

        let first = stroke.points[0]
        let firstWidth = brush.effectiveWidth(force: first.force, altitude: first.altitude)
        if clipPath.map({ $0.contains(first.position) }) ?? true {
            stamps.append(CanvasRenderer.StampInstance(
                center: SIMD2<Float>(Float(first.position.x * scale), Float(first.position.y * scale)),
                radius: Float(firstWidth * 0.5 * scale),
                rotation: 0,
                color: color
            ))
        }

        var lastStampPos = first.position
        var currentSpacing = max(firstWidth * 0.3, 0.5)

        for i in 1..<stroke.points.count {
            let prev = stroke.points[i - 1]
            let curr = stroke.points[i]
            let dx = curr.position.x - prev.position.x
            let dy = curr.position.y - prev.position.y
            let segmentDist = hypot(dx, dy)
            guard segmentDist > 0 else { continue }

            let leftover = hypot(prev.position.x - lastStampPos.x, prev.position.y - lastStampPos.y)
            var traveled = max(0, currentSpacing - leftover)

            while traveled <= segmentDist {
                let t = traveled / segmentDist
                let x = prev.position.x + dx * t
                let y = prev.position.y + dy * t
                let force = prev.force + (curr.force - prev.force) * t
                let altitude = prev.altitude + (curr.altitude - prev.altitude) * t
                let width = brush.effectiveWidth(force: force, altitude: altitude)

                let pos = CGPoint(x: x, y: y)
                if clipPath.map({ $0.contains(pos) }) ?? true {
                    stamps.append(CanvasRenderer.StampInstance(
                        center: SIMD2<Float>(Float(x * scale), Float(y * scale)),
                        radius: Float(width * 0.5 * scale),
                        rotation: 0,
                        color: color
                    ))
                }

                lastStampPos = pos
                currentSpacing = max(width * 0.3, 0.5)
                traveled += currentSpacing
            }
        }

        // End cap.
        if let last = stroke.points.last {
            let width = brush.effectiveWidth(force: last.force, altitude: last.altitude)
            if clipPath.map({ $0.contains(last.position) }) ?? true {
                stamps.append(CanvasRenderer.StampInstance(
                    center: SIMD2<Float>(Float(last.position.x * scale), Float(last.position.y * scale)),
                    radius: Float(width * 0.5 * scale),
                    rotation: 0,
                    color: color
                ))
            }
        }

        return stamps
    }

    /// Read-only access to the flattened canvas (all visible layers) as a CGImage
    /// for snapshots, thumbnails, and stream capture.
    public var persistentImageSnapshot: CGImage? {
        renderer.flattenedCGImage()
    }

    /// Render a thumbnail of a single layer's contents (no compositing). Returns nil
    /// if the layer index is out of range or the texture can't be read.
    public func layerThumbnail(at index: Int, maxDimension: CGFloat = 64) -> UIImage? {
        guard let cgImage = renderer.layerToCGImage(at: index) else { return nil }
        let fullSize = CGSize(width: cgImage.width, height: cgImage.height)
        guard fullSize.width > 0, fullSize.height > 0 else { return nil }
        let scale = min(maxDimension / fullSize.width, maxDimension / fullSize.height, 1.0)
        let thumbSize = CGSize(width: fullSize.width * scale, height: fullSize.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // sRGB — match Metal canvas color space
        let imageRenderer = UIGraphicsImageRenderer(size: thumbSize, format: format)
        return imageRenderer.image { _ in
            UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: thumbSize))
        }
    }

    // MARK: - Helpers

    private var canvasScale: CGFloat {
        window?.screen.scale ?? UIScreen.main.scale
    }

    private func premultipliedColor(_ brush: BrushConfig) -> SIMD4<Float> {
        let r = Float(brush.color.red)
        let g = Float(brush.color.green)
        let b = Float(brush.color.blue)
        let a = Float(brush.opacity)
        return SIMD4<Float>(r * a, g * a, b * a, a)
    }

    private func makeStrokePoint(from touch: UITouch) -> StrokePoint {
        let location = touch.location(in: self)
        let force: CGFloat
        if touch.maximumPossibleForce > 0 {
            force = touch.force / touch.maximumPossibleForce
        } else {
            force = 0.5
        }
        return StrokePoint(
            position: location,
            force: force,
            altitude: touch.altitudeAngle,
            timestamp: touch.timestamp
        )
    }

}

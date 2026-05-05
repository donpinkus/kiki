import UIKit
import Metal
import CoreImage
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

    public var currentTool: ToolState = .brush(.defaultPen) {
        didSet {
            // Switching tools while a snap-edit is pending finalizes it
            // (the user has clearly moved on). The pending shape gets
            // flattened with whatever positions it currently has.
            if isInSnapEditMode {
                finalizeEditedSnap()
            }
        }
    }

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
    /// Encoded canvas bitmap deferred from loadDrawingData until layout is ready.
    private var pendingCanvasImageData: Data?
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

    /// State of the snap workflow.
    ///
    /// LINE flow: hold-commit → `.draggingHandle` (end grabbed by pen) →
    /// `.editingHandles` on lift (re-tappable). Tap elsewhere flattens.
    ///
    /// ELLIPSE/CIRCLE flow: hold-commit → `.editingEllipseHandles` directly
    /// (no immediate-drag — there's no pen-natural mapping like end-of-line).
    /// Subsequent taps on the 4 axis-endpoint handles enter
    /// `.draggingEllipseHandle`. Tap elsewhere flattens.
    private enum SnapState {
        case drawing
        case preview(verdict: Verdict, enteredAt: TimeInterval)
        // Line flow
        case editingHandles(start: CGPoint, end: CGPoint)
        case draggingHandle(which: HandleSide, anchored: CGPoint)
        // Ellipse / circle flow
        case editingEllipseHandles(geometry: EllipseGeometry, isCircle: Bool)
        /// The OPPOSITE handle is fixed (the `anchor`). Pen position defines
        /// the new primary axis endpoint; perpendicular axis scales uniformly
        /// with the primary (`perpRatio` captured at drag-start). For circles,
        /// perpendicular is forced equal to primary so circle stays a circle.
        case draggingEllipseHandle(
            geometry: EllipseGeometry,
            anchor: CGPoint,
            perpRatio: CGFloat,
            isCircle: Bool
        )
        /// Arc edit mode. 3 handles: start, end, and midpoint.
        /// Dragging start/end → rigid rotation+scale of the whole arc around
        /// the OPPOSITE endpoint (preserves coverage angle).
        /// Dragging mid → recomputes the unique circle through start, mid, end
        /// (changes coverage angle).
        case editingArcHandles(geometry: ArcGeometry)
        case draggingArcHandle(
            geometry: ArcGeometry,
            which: ArcHandleSide,
            originalGeometry: ArcGeometry
        )
    }
    /// Which arc handle is being dragged.
    private enum ArcHandleSide { case start, end, mid }
    private enum HandleSide { case start, end }
    /// One of the 4 ellipse axis endpoints. "Plus" / "Minus" refer to the
    /// signed direction along the axis from the center.
    private enum EllipseAxisSide { case majorPlus, majorMinus, minorPlus, minorMinus }
    private var snapState: SnapState = .drawing

    /// Hit radius for handle taps. Larger than the visual handle so finger
    /// taps work well; Apple Pencil precision is fine within this radius too.
    private static let handleHitRadius: CGFloat = 22

    /// Visual diameter of the handle indicator (Procreate-like).
    private static let handleVisualDiameter: CGFloat = 12

    /// Overlay layer showing the snap preview ghost (line/ellipse outline
    /// above the active stroke).
    private let snapPreviewLayer = CAShapeLayer()
    /// Direct-manipulation handles shown when a snapped line is editable.
    /// Reused for ellipse/circle (4 axis-endpoint handles use both + 2 more).
    private let startHandleLayer = CAShapeLayer()
    private let endHandleLayer = CAShapeLayer()
    /// Additional handles for ellipse/circle minor axis endpoints.
    /// Also reused for the arc midpoint handle (uses `minorPlusHandleLayer`).
    private let minorPlusHandleLayer = CAShapeLayer()
    private let minorMinusHandleLayer = CAShapeLayer()
    private let previewHaptic = UIImpactFeedbackGenerator(style: .light)
    private let commitHaptic = UIImpactFeedbackGenerator(style: .medium)

    /// Captured at snap-commit time, preserved through edit mode so each
    /// handle drag can re-call `reparameterizeStrokePoints` against the
    /// original pressure curve. Cleared on finalize/cancel/new-stroke.
    private var preCommitRawPoints: [StrokePoint]?

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

        // Handle indicators for snap edit mode. Procreate-like: white-fill,
        // accent-stroke circles with subtle drop shadow.
        for handle in [startHandleLayer, endHandleLayer, minorPlusHandleLayer, minorMinusHandleLayer] {
            handle.fillColor = UIColor.white.cgColor
            handle.strokeColor = UIColor.tintColor.cgColor
            handle.lineWidth = 1.5
            handle.shadowColor = UIColor.black.cgColor
            handle.shadowOpacity = 0.25
            handle.shadowRadius = 2
            handle.shadowOffset = CGSize(width: 0, height: 1)
            handle.isHidden = true
            layer.addSublayer(handle)
        }
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
        } else if pendingCanvasImageData != nil {
            applyPendingCanvasImageData()
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

        // Snap edit mode: route touch to handle drag, or dismiss if outside.
        if case .editingHandles(let start, let end) = snapState,
           let touch = touches.first {
            let p = touch.location(in: self)
            if let which = handleHitTest(at: p, start: start, end: end) {
                let anchored = (which == .start) ? end : start
                snapState = .draggingHandle(which: which, anchored: anchored)
                drawingTouch = touch
                onInteractionBegan?()
                if isQuickShapeLoggingEnabled {
                    print("[QS] handle drag begin — \(which)")
                }
                return
            } else {
                // Tap elsewhere — finalize and consume this touch (don't
                // start a new stroke; user must lift and re-touch to draw).
                if isQuickShapeLoggingEnabled {
                    print("[QS] tap-elsewhere — finalize line edit")
                }
                finalizeEditedSnap()
                return
            }
        }

        // Arc edit mode: 3 handles (start, end, mid).
        if case .editingArcHandles(let geom) = snapState,
           let touch = touches.first {
            let p = touch.location(in: self)
            if let which = arcHandleHitTest(at: p, geometry: geom) {
                snapState = .draggingArcHandle(
                    geometry: geom, which: which, originalGeometry: geom
                )
                drawingTouch = touch
                onInteractionBegan?()
                if isQuickShapeLoggingEnabled {
                    print("[QS] arc handle drag begin — \(which)")
                }
                return
            } else {
                if isQuickShapeLoggingEnabled {
                    print("[QS] tap-elsewhere — finalize arc edit")
                }
                finalizeEditedSnap()
                return
            }
        }

        // Ellipse / circle edit mode: same routing pattern with 4 handles.
        if case .editingEllipseHandles(let geom, let isCircle) = snapState,
           let touch = touches.first {
            let p = touch.location(in: self)
            if let axis = ellipseHandleHitTest(at: p, geometry: geom) {
                // Capture the anchor (opposite handle position) and current
                // perpendicular/primary ratio. These stay fixed throughout the
                // drag; the live geometry is recomputed each touchesMoved.
                let pts = ellipseHandlePositions(geom)
                let anchor: CGPoint
                let primarySemi: CGFloat
                let perpSemi: CGFloat
                switch axis {
                case .majorPlus:
                    anchor = pts.majorMinus; primarySemi = geom.semiMajor; perpSemi = geom.semiMinor
                case .majorMinus:
                    anchor = pts.majorPlus;  primarySemi = geom.semiMajor; perpSemi = geom.semiMinor
                case .minorPlus:
                    anchor = pts.minorMinus; primarySemi = geom.semiMinor; perpSemi = geom.semiMajor
                case .minorMinus:
                    anchor = pts.minorPlus;  primarySemi = geom.semiMinor; perpSemi = geom.semiMajor
                }
                let perpRatio = primarySemi > 0 ? perpSemi / primarySemi : 1
                snapState = .draggingEllipseHandle(
                    geometry: geom, anchor: anchor, perpRatio: perpRatio, isCircle: isCircle
                )
                drawingTouch = touch
                onInteractionBegan?()
                if isQuickShapeLoggingEnabled {
                    print("[QS] ellipse handle drag begin — \(axis), anchor=(\(fmt(anchor.x)),\(fmt(anchor.y))), perpRatio=\(fmt(perpRatio))")
                }
                return
            } else {
                if isQuickShapeLoggingEnabled {
                    print("[QS] tap-elsewhere — finalize ellipse edit")
                }
                finalizeEditedSnap()
                return
            }
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

        // Snap handle drag: update line endpoints and re-render in scratch.
        if case .draggingHandle(let which, let anchored) = snapState {
            let dragged = touch.location(in: self)
            let (start, end): (CGPoint, CGPoint) = (which == .start)
                ? (dragged, anchored)
                : (anchored, dragged)
            rebuildSnappedLineStamps(start: start, end: end)
            updateDragHandles(start: start, end: end)
            return
        }

        // Arc handle drag — start/end is rigid rotation+scale around opposite
        // endpoint; mid changes coverage via 3-point circle fit.
        if case .draggingArcHandle(_, let which, let originalGeom) = snapState {
            let dragPos = touch.location(in: self)
            if let newGeom = recomputeArcFromHandleDrag(
                originalGeometry: originalGeom,
                which: which,
                dragPos: dragPos
            ) {
                snapState = .draggingArcHandle(
                    geometry: newGeom, which: which, originalGeometry: originalGeom
                )
                rebuildArcStamps(geometry: newGeom)
                updateArcHandles(geometry: newGeom)
            }
            // If degenerate (collinear or zero-length chord), keep prior geometry.
            return
        }

        // Ellipse / circle handle drag — opposite handle is the anchor.
        if case .draggingEllipseHandle(_, let anchor, let perpRatio, let isCircle) = snapState {
            let dragPos = touch.location(in: self)
            let newGeom = recomputeEllipseFromAnchoredDrag(
                anchor: anchor,
                dragPos: dragPos,
                perpRatio: perpRatio,
                isCircle: isCircle
            )
            snapState = .draggingEllipseHandle(
                geometry: newGeom, anchor: anchor, perpRatio: perpRatio, isCircle: isCircle
            )
            rebuildEllipseStamps(geometry: newGeom)
            updateEllipseHandles(geometry: newGeom)
            return
        }

        // Snap committed during the same touch and we're now showing handles
        // (no immediate-drag for closed shapes — stays in .editingEllipseHandles
        // until user lifts). Suppress further pen input on this touch so the
        // brush engine doesn't append the held-pen position to the snapped
        // perimeter (which would draw a chord from the perimeter end back to
        // the pen tip).
        if isInSnapEditMode {
            return
        }

        switch currentTool {
        case .brush:
            // Append coalesced points and rebuild all stamps for live preview.
            let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
            for ct in coalesced {
                activeStroke?.points.append(makeStrokePoint(from: ct))
            }
            appendStampsForLatestPoints(touch: touch, event: event)
            // QuickShape: feed recognizer + drive snap state machine. Only
            // active in `.drawing` and `.preview`; once a snap commits, the
            // touch handler at the top of touchesMoved owns the lifecycle.
            if isQuickShapeEnabled {
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

        // End of a line handle drag: return to editingHandles with new positions.
        if case .draggingHandle(let which, let anchored) = snapState {
            let final = touch.location(in: self)
            let (start, end): (CGPoint, CGPoint) = (which == .start)
                ? (final, anchored)
                : (anchored, final)
            snapState = .editingHandles(start: start, end: end)
            updateDragHandles(start: start, end: end)
            drawingTouch = nil
            onInteractionEnded?()
            isDirty = true
            return
        }

        // End of an ellipse handle drag: return to editingEllipseHandles.
        if case .draggingEllipseHandle(let geom, _, _, let isCircle) = snapState {
            snapState = .editingEllipseHandles(geometry: geom, isCircle: isCircle)
            updateEllipseHandles(geometry: geom)
            drawingTouch = nil
            onInteractionEnded?()
            isDirty = true
            return
        }

        // End of an arc handle drag: return to editingArcHandles.
        if case .draggingArcHandle(let geom, _, _) = snapState {
            snapState = .editingArcHandles(geometry: geom)
            updateArcHandles(geometry: geom)
            drawingTouch = nil
            onInteractionEnded?()
            isDirty = true
            return
        }

        // Snap committed during this touch as an ellipse/circle/arc — no
        // immediate-drag, so we entered the corresponding edit state directly
        // in commitSnap. Just clean up touch state; handles stay visible.
        if case .editingEllipseHandles = snapState {
            drawingTouch = nil
            recognizer?.reset()
            onInteractionEnded?()
            isDirty = true
            return
        }
        if case .editingArcHandles = snapState {
            drawingTouch = nil
            recognizer?.reset()
            onInteractionEnded?()
            isDirty = true
            return
        }

        // Telemetry / diagnostic at touchesEnded.
        if isQuickShapeEnabled, let recognizer {
            // This block is only reached when the stroke ended WITHOUT having
            // entered any handle-drag mode (those cases return earlier above).
            // So we know no snap committed during this touch.
            let v = recognizer.finalize()
            if case .abstain(let reason) = v {
                onSnapEvent?(.abstained(SnapAbstainedInfo(
                    reason: reason.rawValue,
                    confidence: Double(recognizer.currentConfidence),
                    snapshot: recognizer.lastFeatureSnapshot
                )))
            } else if v.isSnap {
                // Final verdict was a snap-eligible shape but we didn't commit
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
                case .arc(let g): verdictDesc = "arc[c=(\(fmt(g.center.x)),\(fmt(g.center.y))), r=\(fmt(g.radius))]"
                case .ellipse(let g): verdictDesc = "ellipse[c=(\(fmt(g.center.x)),\(fmt(g.center.y))), a=\(fmt(g.semiMajor)), b=\(fmt(g.semiMinor))]"
                case .circle(let g): verdictDesc = "circle[c=(\(fmt(g.center.x)),\(fmt(g.center.y))), r=\(fmt(g.radius))]"
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

        // If a handle drag is cancelled mid-stream, snap back to whatever
        // positions the line had at drag-start (the anchored point + the
        // handle's pre-drag location, which we don't have explicitly —
        // closest is the current stroke endpoints, which already track the
        // latest interpolation). Just restore editingHandles state.
        if case .draggingHandle(let which, let anchored) = snapState {
            let pos = touch.location(in: self)
            let (start, end): (CGPoint, CGPoint) = (which == .start)
                ? (pos, anchored) : (anchored, pos)
            snapState = .editingHandles(start: start, end: end)
            updateDragHandles(start: start, end: end)
            drawingTouch = nil
            onInteractionEnded?()
            isDirty = true
            return
        }

        if case .draggingEllipseHandle(let geom, _, _, let isCircle) = snapState {
            snapState = .editingEllipseHandles(geometry: geom, isCircle: isCircle)
            updateEllipseHandles(geometry: geom)
            drawingTouch = nil
            onInteractionEnded?()
            isDirty = true
            return
        }

        if case .draggingArcHandle(let geom, _, _) = snapState {
            snapState = .editingArcHandles(geometry: geom)
            updateArcHandles(geometry: geom)
            drawingTouch = nil
            onInteractionEnded?()
            isDirty = true
            return
        }

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

    // MARK: - Snap Edit Mode (handle dragging post-commit)

    /// Flatten the pending snapped line into the canvas and exit edit mode.
    /// Called when the user taps elsewhere, switches tools, or otherwise
    /// dismisses the handles.
    private func finalizeEditedSnap() {
        guard isInSnapEditMode else { return }
        guard !activeStrokeStamps.isEmpty else {
            cancelPendingSnapEdit()
            return
        }
        pushUndoSnapshot()
        renderer.clearStamps()
        for stamp in activeStrokeStamps {
            renderer.appendStamp(stamp)
        }
        renderer.flattenScratchIntoCanvas()
        strokeCount += 1
        onDrawingChanged?()

        clearSnapEditState()
        isDirty = true
    }

    /// Discard the pending snapped shape without flattening — used when the
    /// user undoes during edit mode.
    private func cancelPendingSnapEdit() {
        guard isInSnapEditMode else { return }
        clearSnapEditState()
        isDirty = true
    }

    /// True when the snap state is in any "editable / handles visible" state.
    /// Used to gate finalize / cancel operations.
    private var isInSnapEditMode: Bool {
        switch snapState {
        case .editingHandles, .editingEllipseHandles, .editingArcHandles: return true
        default: return false
        }
    }

    /// Common cleanup shared by finalize + cancel paths.
    private func clearSnapEditState() {
        hideDragHandles()
        activeStroke = nil
        activeStrokeStamps = []
        preCommitRawPoints = nil
        snapState = .drawing
    }

    // MARK: - Handle UI

    private func showDragHandles(start: CGPoint, end: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureHandlePath(startHandleLayer, at: start)
        configureHandlePath(endHandleLayer, at: end)
        startHandleLayer.isHidden = false
        endHandleLayer.isHidden = false
        CATransaction.commit()
    }

    private func updateDragHandles(start: CGPoint, end: CGPoint) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureHandlePath(startHandleLayer, at: start)
        configureHandlePath(endHandleLayer, at: end)
        CATransaction.commit()
    }

    private func hideDragHandles() {
        let allHidden = startHandleLayer.isHidden && endHandleLayer.isHidden
            && minorPlusHandleLayer.isHidden && minorMinusHandleLayer.isHidden
        guard !allHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        startHandleLayer.isHidden = true
        endHandleLayer.isHidden = true
        minorPlusHandleLayer.isHidden = true
        minorMinusHandleLayer.isHidden = true
        startHandleLayer.path = nil
        endHandleLayer.path = nil
        minorPlusHandleLayer.path = nil
        minorMinusHandleLayer.path = nil
        CATransaction.commit()
    }

    /// Show the 4 axis-endpoint handles for an ellipse/circle. The two
    /// existing handle layers (start/end) are reused for the major-axis
    /// endpoints; the minor-axis endpoints get the additional layers.
    private func showEllipseHandles(geometry: EllipseGeometry) {
        let pts = ellipseHandlePositions(geometry)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureHandlePath(startHandleLayer, at: pts.majorPlus)
        configureHandlePath(endHandleLayer, at: pts.majorMinus)
        configureHandlePath(minorPlusHandleLayer, at: pts.minorPlus)
        configureHandlePath(minorMinusHandleLayer, at: pts.minorMinus)
        startHandleLayer.isHidden = false
        endHandleLayer.isHidden = false
        minorPlusHandleLayer.isHidden = false
        minorMinusHandleLayer.isHidden = false
        CATransaction.commit()
    }

    private func updateEllipseHandles(geometry: EllipseGeometry) {
        let pts = ellipseHandlePositions(geometry)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureHandlePath(startHandleLayer, at: pts.majorPlus)
        configureHandlePath(endHandleLayer, at: pts.majorMinus)
        configureHandlePath(minorPlusHandleLayer, at: pts.minorPlus)
        configureHandlePath(minorMinusHandleLayer, at: pts.minorMinus)
        CATransaction.commit()
    }

    // MARK: - Arc handles

    /// Show the 3 arc handles (start, end, midpoint). Reuses `startHandleLayer`,
    /// `endHandleLayer`, and `minorPlusHandleLayer`.
    private func showArcHandles(geometry: ArcGeometry) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        configureHandlePath(startHandleLayer, at: geometry.startPoint)
        configureHandlePath(endHandleLayer, at: geometry.endPoint)
        configureHandlePath(minorPlusHandleLayer, at: geometry.midPoint)
        startHandleLayer.isHidden = false
        endHandleLayer.isHidden = false
        minorPlusHandleLayer.isHidden = false
        // Minor-minus is unused for arcs.
        minorMinusHandleLayer.isHidden = true
        CATransaction.commit()
    }

    private func updateArcHandles(geometry: ArcGeometry) {
        showArcHandles(geometry: geometry)  // same as show — just reset positions
    }

    /// Hit-test against the 3 arc handles (start, end, mid). Returns the
    /// closest one within hit radius.
    private func arcHandleHitTest(at p: CGPoint, geometry: ArcGeometry) -> ArcHandleSide? {
        let candidates: [(ArcHandleSide, CGFloat)] = [
            (.start, hypot(p.x - geometry.startPoint.x, p.y - geometry.startPoint.y)),
            (.end,   hypot(p.x - geometry.endPoint.x,   p.y - geometry.endPoint.y)),
            (.mid,   hypot(p.x - geometry.midPoint.x,   p.y - geometry.midPoint.y)),
        ]
        let inRange = candidates.filter { $0.1 <= Self.handleHitRadius }
        return inRange.min(by: { $0.1 < $1.1 })?.0
    }

    /// Compute the unique circle through 3 non-collinear points. Returns
    /// (center, radius), or nil if they're collinear or coincident.
    private func circleThrough(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint) -> (center: CGPoint, radius: CGFloat)? {
        // Standard circumcircle formula.
        let ax = p1.x, ay = p1.y
        let bx = p2.x, by = p2.y
        let cx = p3.x, cy = p3.y
        let d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        guard abs(d) > 1e-6 else { return nil }
        let ux = ((ax * ax + ay * ay) * (by - cy)
                + (bx * bx + by * by) * (cy - ay)
                + (cx * cx + cy * cy) * (ay - by)) / d
        let uy = ((ax * ax + ay * ay) * (cx - bx)
                + (bx * bx + by * by) * (ax - cx)
                + (cx * cx + cy * cy) * (bx - ax)) / d
        let center = CGPoint(x: ux, y: uy)
        let radius = hypot(ax - ux, ay - uy)
        return (center, radius)
    }

    /// Recompute arc geometry when a handle is dragged.
    ///
    /// **Start/end drag** = rigid rotation+scale of the entire arc around
    /// the OPPOSITE endpoint. Coverage angle is preserved; the arc just
    /// rotates and scales as the user moves the dragged endpoint.
    ///
    /// **Mid drag** = recomputes the unique circle through (start, dragPos,
    /// end) and rebuilds an arc passing through dragPos. Changes coverage.
    private func recomputeArcFromHandleDrag(
        originalGeometry og: ArcGeometry,
        which: ArcHandleSide,
        dragPos: CGPoint
    ) -> ArcGeometry? {
        switch which {
        case .start:
            return rigidlyTransformedArc(
                original: og, anchor: og.endPoint, originalDragged: og.startPoint, newDragged: dragPos
            )
        case .end:
            return rigidlyTransformedArc(
                original: og, anchor: og.startPoint, originalDragged: og.endPoint, newDragged: dragPos
            )
        case .mid:
            // Three-point fit; start/end stay where they were.
            let start = og.startPoint
            let end = og.endPoint
            guard let circ = circleThrough(start, dragPos, end) else { return nil }
            let startAngle = atan2(start.y - circ.center.y, start.x - circ.center.x)
            let endAngle = atan2(end.y - circ.center.y, end.x - circ.center.x)
            let midAngle = atan2(dragPos.y - circ.center.y, dragPos.x - circ.center.x)
            let sweep: ArcGeometry.Sweep =
                angleIsBetweenCCW(midAngle, from: startAngle, to: endAngle) ? .counterClockwise : .clockwise
            return ArcGeometry(
                center: circ.center,
                radius: circ.radius,
                startAngle: startAngle,
                endAngle: endAngle,
                sweep: sweep
            )
        }
    }

    /// Apply a rigid rotation+scale to an arc, anchored at one endpoint.
    /// The arc keeps its shape (coverage angle, sweep direction); only its
    /// position, scale, and orientation change.
    private func rigidlyTransformedArc(
        original og: ArcGeometry,
        anchor: CGPoint,
        originalDragged: CGPoint,
        newDragged: CGPoint
    ) -> ArcGeometry? {
        let oldDx = originalDragged.x - anchor.x
        let oldDy = originalDragged.y - anchor.y
        let newDx = newDragged.x - anchor.x
        let newDy = newDragged.y - anchor.y
        let oldLen = hypot(oldDx, oldDy)
        let newLen = hypot(newDx, newDy)
        guard oldLen > 1e-6, newLen > 1e-6 else { return nil }
        let scale = newLen / oldLen
        let oldAngle = atan2(oldDy, oldDx)
        let newAngle = atan2(newDy, newDx)
        let dTheta = newAngle - oldAngle

        // Rotate + scale the center around the anchor.
        let cdx = og.center.x - anchor.x
        let cdy = og.center.y - anchor.y
        let cosT = cos(dTheta)
        let sinT = sin(dTheta)
        let rotatedCx = cdx * cosT - cdy * sinT
        let rotatedCy = cdx * sinT + cdy * cosT
        let newCenter = CGPoint(
            x: anchor.x + rotatedCx * scale,
            y: anchor.y + rotatedCy * scale
        )

        // Clamp radius to a sensible minimum so the arc never collapses to a point.
        let newRadius = max(og.radius * scale, 5)
        let newStartAngle = og.startAngle + dTheta
        let newEndAngle = og.endAngle + dTheta

        return ArcGeometry(
            center: newCenter,
            radius: newRadius,
            startAngle: newStartAngle,
            endAngle: newEndAngle,
            sweep: og.sweep
        )
    }

    /// True if angle θ lies on the counter-clockwise arc from `from` to `to`.
    private func angleIsBetweenCCW(_ theta: CGFloat, from a: CGFloat, to b: CGFloat) -> Bool {
        // Normalize all to [0, 2π).
        let twoPi = 2 * CGFloat.pi
        let na = (a.truncatingRemainder(dividingBy: twoPi) + twoPi).truncatingRemainder(dividingBy: twoPi)
        var nb = (b.truncatingRemainder(dividingBy: twoPi) + twoPi).truncatingRemainder(dividingBy: twoPi)
        var nt = (theta.truncatingRemainder(dividingBy: twoPi) + twoPi).truncatingRemainder(dividingBy: twoPi)
        // CCW from na to nb. If nb < na, wrap.
        if nb < na { nb += twoPi }
        if nt < na { nt += twoPi }
        return nt > na && nt < nb
    }

    /// Rebuild stamps for an arc after a handle drag.
    private func rebuildArcStamps(geometry: ArcGeometry) {
        guard var stroke = activeStroke,
              let raw = preCommitRawPoints else { return }
        stroke.points = arcPerimeterStrokePoints(geometry: geometry, raw: raw)
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)
        isDirty = true
    }

    /// Build a CGPath for an arc preview (used by snapPreviewLayer for arc verdicts).
    private func arcPreviewPath(_ g: ArcGeometry) -> CGPath {
        let path = CGMutablePath()
        // CGPath.addArc clockwise param matches our convention if we map
        // CCW → false (since UIKit y is down, the convention may feel
        // inverted; this matches the rendering of ellipses we already do).
        let clockwise = g.sweep == .clockwise
        path.addArc(
            center: g.center,
            radius: g.radius,
            startAngle: g.startAngle,
            endAngle: g.endAngle,
            clockwise: !clockwise  // CG convention is inverted from ours
        )
        return path
    }

    /// Compute the 4 axis-endpoint positions for an ellipse, accounting for rotation.
    private func ellipseHandlePositions(_ g: EllipseGeometry) -> (
        majorPlus: CGPoint, majorMinus: CGPoint,
        minorPlus: CGPoint, minorMinus: CGPoint
    ) {
        let cosT = cos(g.rotation)
        let sinT = sin(g.rotation)
        let majorDx = g.semiMajor * cosT
        let majorDy = g.semiMajor * sinT
        let minorDx = -g.semiMinor * sinT
        let minorDy = g.semiMinor * cosT
        return (
            majorPlus:  CGPoint(x: g.center.x + majorDx, y: g.center.y + majorDy),
            majorMinus: CGPoint(x: g.center.x - majorDx, y: g.center.y - majorDy),
            minorPlus:  CGPoint(x: g.center.x + minorDx, y: g.center.y + minorDy),
            minorMinus: CGPoint(x: g.center.x - minorDx, y: g.center.y - minorDy)
        )
    }

    private func configureHandlePath(_ layer: CAShapeLayer, at center: CGPoint) {
        let r = Self.handleVisualDiameter / 2
        let rect = CGRect(x: center.x - r, y: center.y - r,
                          width: Self.handleVisualDiameter,
                          height: Self.handleVisualDiameter)
        layer.path = CGPath(ellipseIn: rect, transform: nil)
    }

    /// Hit-test a touch location against the two visible handles. Returns
    /// the closer handle if either is within `handleHitRadius` of the touch,
    /// else nil. Choosing the closer one prevents ambiguity at degenerate
    /// short lines where both handles overlap.
    private func handleHitTest(at p: CGPoint, start: CGPoint, end: CGPoint) -> HandleSide? {
        let dStart = hypot(p.x - start.x, p.y - start.y)
        let dEnd = hypot(p.x - end.x, p.y - end.y)
        let r = Self.handleHitRadius
        if dStart <= r && dEnd <= r {
            return dStart <= dEnd ? .start : .end
        }
        if dStart <= r { return .start }
        if dEnd <= r { return .end }
        return nil
    }

    /// Hit-test against ellipse axis handles. Returns the closest one within
    /// the hit radius, or nil.
    private func ellipseHandleHitTest(at p: CGPoint, geometry: EllipseGeometry) -> EllipseAxisSide? {
        let pts = ellipseHandlePositions(geometry)
        let candidates: [(EllipseAxisSide, CGFloat)] = [
            (.majorPlus,  hypot(p.x - pts.majorPlus.x,  p.y - pts.majorPlus.y)),
            (.majorMinus, hypot(p.x - pts.majorMinus.x, p.y - pts.majorMinus.y)),
            (.minorPlus,  hypot(p.x - pts.minorPlus.x,  p.y - pts.minorPlus.y)),
            (.minorMinus, hypot(p.x - pts.minorMinus.x, p.y - pts.minorMinus.y)),
        ]
        let r = Self.handleHitRadius
        let inRange = candidates.filter { $0.1 <= r }
        return inRange.min(by: { $0.1 < $1.1 })?.0
    }

    /// Recompute ellipse geometry when a handle is dragged with the OPPOSITE
    /// handle as a fixed pivot ("anchor").
    ///
    /// The pen position defines the new primary axis endpoint. The center
    /// becomes the midpoint of anchor↔pen; rotation matches the new direction;
    /// primary semi-axis = half the anchor↔pen distance; perpendicular axis
    /// scales uniformly with the primary (preserves the aspect ratio captured
    /// at drag-start). For circles, perpendicular is forced equal to primary.
    ///
    /// Effect: dragging straight away/toward the anchor scales the whole
    /// ellipse; dragging sideways rotates it around the anchor with whatever
    /// scale the new distance produces.
    private func recomputeEllipseFromAnchoredDrag(
        anchor: CGPoint,
        dragPos: CGPoint,
        perpRatio: CGFloat,
        isCircle: Bool
    ) -> EllipseGeometry {
        let dx = dragPos.x - anchor.x
        let dy = dragPos.y - anchor.y
        let distance = hypot(dx, dy)
        let newPrimary = max(distance / 2, 5)
        let newPerp = isCircle ? newPrimary : max(newPrimary * perpRatio, 5)
        let center = CGPoint(x: (anchor.x + dragPos.x) / 2, y: (anchor.y + dragPos.y) / 2)
        let rotation = atan2(dy, dx)
        return EllipseGeometry(
            center: center,
            semiMajor: newPrimary,
            semiMinor: newPerp,
            rotation: rotation
        )
    }

    /// Rebuild stamps for an ellipse/circle after a handle drag.
    private func rebuildEllipseStamps(geometry: EllipseGeometry) {
        guard var stroke = activeStroke,
              let raw = preCommitRawPoints else { return }
        stroke.points = ellipsePerimeterStrokePoints(geometry: geometry, raw: raw)
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)
        isDirty = true
    }

    /// Rebuild the snapped line's stamps for a new (start, end) pair. Used
    /// during handle drag to live-update the brush stroke in scratch.
    private func rebuildSnappedLineStamps(start: CGPoint, end: CGPoint) {
        guard var stroke = activeStroke,
              let raw = preCommitRawPoints else { return }
        let resampled = reparameterizeStrokePoints(
            rawPoints: raw,
            correctedStart: start,
            correctedEnd: end
        )
        stroke.points = resampled
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)
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
            case .arc: verdictDesc = "arc"
            case .ellipse: verdictDesc = "ellipse"
            case .circle: verdictDesc = "circle"
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
            // Any snap-eligible verdict (line, ellipse, circle) can enter
            // preview when confidence passes acceptScore.
            if verdict.isSnap, recognizer.currentConfidence >= seeds.acceptScore {
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
                case .arc: verdictDesc = "arc"
                case .ellipse: verdictDesc = "ellipse"
                case .circle: verdictDesc = "circle"
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
            // Verdict identity changed → cancel.
            let nowVerdict = recognizer.currentVerdict()
            guard verdictsHaveSameKind(cachedVerdict, nowVerdict) else {
                cancelSnapPreview()
                snapState = .drawing
                onSnapEvent?(.previewCanceled(SnapPreviewCanceledInfo(reason: "verdict_change")))
                if isQuickShapeLoggingEnabled { print("[QS] Preview → Drawing (verdict kind changed)") }
                return
            }
            // Refresh the preview geometry to track the latest fit.
            showSnapPreview(verdict: nowVerdict)
            // Hold delay elapsed → commit.
            if now - enteredAt >= seeds.holdCommitDelay {
                if isQuickShapeLoggingEnabled { print("[QS] → Commit (after \(String(format: "%.3f", now - enteredAt))s)") }
                commitSnap(verdict: cachedVerdict)
            }

        case .editingHandles, .draggingHandle,
             .editingEllipseHandles, .draggingEllipseHandle,
             .editingArcHandles, .draggingArcHandle:
            // No recognizer-driven transitions in these states; touch handlers
            // own the lifecycle here.
            break
        }
    }

    private func stateDesc(_ s: SnapState) -> String {
        switch s {
        case .drawing: return "drawing"
        case .preview: return "preview"
        case .editingHandles: return "editingHandles"
        case .draggingHandle: return "draggingHandle"
        case .editingEllipseHandles: return "editingEllipseHandles"
        case .draggingEllipseHandle: return "draggingEllipseHandle"
        case .editingArcHandles: return "editingArcHandles"
        case .draggingArcHandle: return "draggingArcHandle"
        }
    }

    /// True when both verdicts are the same shape kind. Used to detect
    /// verdict-kind changes mid-preview that should cancel.
    private func verdictsHaveSameKind(_ a: Verdict, _ b: Verdict) -> Bool {
        switch (a, b) {
        case (.line, .line), (.arc, .arc),
             (.ellipse, .ellipse), (.circle, .circle): return true
        case (.abstain, .abstain): return true
        default: return false
        }
    }

    /// Render the snap preview as a 1.5pt outline at 50% brush opacity.
    private func showSnapPreview(verdict: Verdict) {
        guard case .brush(let config) = currentTool else { return }
        let path: CGPath
        switch verdict {
        case .line(let geom):
            let m = CGMutablePath()
            m.move(to: geom.start)
            m.addLine(to: geom.end)
            path = m
        case .arc(let geom):
            path = arcPreviewPath(geom)
        case .ellipse, .circle:
            // Per user direction: no preview ghost for closed shapes.
            // The haptic + handles-on-commit are sufficient feedback.
            return
        case .abstain:
            return
        }
        let baseColor = config.color.uiColor
        let strokeColor = baseColor.withAlphaComponent(0.5).cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        snapPreviewLayer.path = path
        snapPreviewLayer.strokeColor = strokeColor
        snapPreviewLayer.isHidden = false
        CATransaction.commit()
    }

    /// Build a CGPath for an ellipse with rotation. CoreGraphics has no
    /// built-in rotated ellipse, so build from the axis-aligned ellipse-in-rect
    /// and apply the rotation transform around the center.
    private func ellipsePreviewPath(_ geom: EllipseGeometry) -> CGPath {
        let rect = CGRect(
            x: geom.center.x - geom.semiMajor,
            y: geom.center.y - geom.semiMinor,
            width: geom.semiMajor * 2,
            height: geom.semiMinor * 2
        )
        var transform = CGAffineTransform(translationX: geom.center.x, y: geom.center.y)
            .rotated(by: geom.rotation)
            .translatedBy(x: -geom.center.x, y: -geom.center.y)
        return CGPath(ellipseIn: rect, transform: &transform)
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
    ///
    /// Immediately enters handle-drag mode for the END handle: both handles
    /// appear, the start is anchored at the projected fit-line start, and
    /// the end is set to the **current pen position** (not the algebraic
    /// projection) so the line tracks the pen exactly. Subsequent
    /// touchesMoved events continue dragging the end as if the user had
    /// just grabbed it. On touchesEnded the state transitions to
    /// editingHandles where both handles are re-tappable.
    ///
    /// Stashes the raw points so each drag tick can re-reparameterize
    /// against the original pressure curve.
    private func commitSnap(verdict: Verdict) {
        guard var stroke = activeStroke else { return }
        preCommitRawPoints = stroke.points

        switch verdict {
        case .line(let geom):
            commitLineSnap(geom: geom, stroke: &stroke)
        case .arc(let geom):
            commitArcSnap(geom: geom, stroke: &stroke)
        case .ellipse(let geom):
            commitEllipseSnap(geom: geom, isCircle: false, stroke: &stroke)
        case .circle(let geom):
            // Promote to ellipse internally for unified rendering / handles.
            let ellipse = EllipseGeometry(
                center: geom.center,
                semiMajor: geom.radius, semiMinor: geom.radius, rotation: 0
            )
            commitEllipseSnap(geom: ellipse, isCircle: true, stroke: &stroke)
        case .abstain:
            return
        }
    }

    private func commitLineSnap(geom: LineGeometry, stroke: inout Stroke) {
        // Treat the user's hold position as the end-handle position so the
        // line reaches exactly to the pen at the moment of commit.
        let penPos = recognizer?.lastInputPositionTimestamp?.position ?? geom.end

        let resampled = reparameterizeStrokePoints(
            rawPoints: stroke.points,
            correctedStart: geom.start,
            correctedEnd: penPos
        )
        stroke.points = resampled
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)

        cancelSnapPreview()
        snapState = .draggingHandle(which: .end, anchored: geom.start)
        showDragHandles(start: geom.start, end: penPos)
        commitHaptic.impactOccurred()
        if isQuickShapeLoggingEnabled {
            print("[QS] commitSnap (line) — \(stroke.points.count) corrected points")
        }
        isDirty = true

        emitCommittedTelemetry(verdict: "line")
    }

    private func commitArcSnap(geom: ArcGeometry, stroke: inout Stroke) {
        let pts = arcPerimeterStrokePoints(geometry: geom, raw: stroke.points)
        stroke.points = pts
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)

        cancelSnapPreview()
        // Open shape: enter editing-handles directly. Same rationale as the
        // ellipse path — there's no obvious "pen-grabs-an-endpoint" mapping
        // since the user's finishing position is at one end of the arc, but
        // the ARC isn't anchored at start/end the way a line is anchored at
        // its endpoints — radius/center can change too. Keep it simple.
        snapState = .editingArcHandles(geometry: geom)
        showArcHandles(geometry: geom)
        commitHaptic.impactOccurred()
        if isQuickShapeLoggingEnabled {
            print("[QS] commitSnap (arc) — \(pts.count) perimeter samples, coverage=\(geom.midAngle * 180 / .pi)")
        }
        isDirty = true
        emitCommittedTelemetry(verdict: "arc")
    }

    private func commitEllipseSnap(geom: EllipseGeometry, isCircle: Bool, stroke: inout Stroke) {
        let pts = ellipsePerimeterStrokePoints(geometry: geom, raw: stroke.points)
        stroke.points = pts
        activeStroke = stroke
        activeStrokeStamps = generateStampsForStroke(stroke, scale: canvasScale)

        cancelSnapPreview()
        // Closed shape: enter editing-handles directly (no immediate-drag —
        // there's no pen-natural mapping like end-of-line for closed shapes).
        snapState = .editingEllipseHandles(geometry: geom, isCircle: isCircle)
        showEllipseHandles(geometry: geom)
        commitHaptic.impactOccurred()
        if isQuickShapeLoggingEnabled {
            print("[QS] commitSnap (\(isCircle ? "circle" : "ellipse")) — \(pts.count) perimeter samples")
        }
        isDirty = true

        emitCommittedTelemetry(verdict: isCircle ? "circle" : "ellipse")
    }

    private func emitCommittedTelemetry(verdict: String) {
        lastStrokeWasSnap = true
        lastSnapCommitAt = Date()
        lastSnapVerdict = verdict
        lastSnapSnapshot = recognizer?.lastFeatureSnapshot
        if let snapshot = recognizer?.lastFeatureSnapshot,
           let lastTouchTime = recognizer?.lastInputTimestamp {
            onSnapEvent?(.committed(SnapCommittedInfo(
                verdict: verdict,
                confidence: Double(recognizer?.currentConfidence ?? 0),
                strokeDurationSec: lastTouchTime - currentStrokeStartTime,
                snapshot: snapshot
            )))
        }
    }

    /// Walk the arc from startAngle to endAngle (in the swept direction)
    /// emitting StrokePoints. Uniform pressure for the same reason as the
    /// ellipse perimeter.
    private func arcPerimeterStrokePoints(
        geometry: ArcGeometry,
        raw: [StrokePoint]
    ) -> [StrokePoint] {
        // Compute swept angle in [-2π, 2π].
        var sweptAngle = geometry.endAngle - geometry.startAngle
        switch geometry.sweep {
        case .counterClockwise:
            while sweptAngle <= 0 { sweptAngle += 2 * .pi }
        case .clockwise:
            while sweptAngle >= 0 { sweptAngle -= 2 * .pi }
        }
        // ~64 samples per full circle worth of sweep; minimum 16 for short arcs.
        let n = max(16, Int(64 * abs(sweptAngle) / (2 * .pi)))
        let forces = raw.map { $0.force }
        let altitudes = raw.map { $0.altitude }
        let meanForce = forces.isEmpty ? 0.5 : forces.reduce(0, +) / CGFloat(forces.count)
        let meanAlt = altitudes.isEmpty ? .pi / 2 : altitudes.reduce(0, +) / CGFloat(altitudes.count)
        let baseTime = raw.first?.timestamp ?? 0

        var pts: [StrokePoint] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let t = CGFloat(i) / CGFloat(n)
            let theta = geometry.startAngle + sweptAngle * t
            let x = geometry.center.x + geometry.radius * cos(theta)
            let y = geometry.center.y + geometry.radius * sin(theta)
            pts.append(StrokePoint(
                position: CGPoint(x: x, y: y),
                force: meanForce,
                altitude: meanAlt,
                timestamp: baseTime + TimeInterval(i) * 0.001
            ))
        }
        return pts
    }

    /// Walk the ellipse perimeter at fixed parameter intervals and emit
    /// StrokePoints suitable for the brush engine. v0 uses uniform pressure
    /// (mean of raw forces) — pressure variation around an ellipse rim isn't
    /// expected by users for a snapped shape.
    private func ellipsePerimeterStrokePoints(
        geometry: EllipseGeometry,
        raw: [StrokePoint]
    ) -> [StrokePoint] {
        let n = 64  // sufficient for visually smooth perimeter at typical sizes
        let cosT = cos(geometry.rotation)
        let sinT = sin(geometry.rotation)
        let a = geometry.semiMajor
        let b = geometry.semiMinor

        // Uniform brush properties from the raw stroke.
        let forces = raw.map { $0.force }
        let altitudes = raw.map { $0.altitude }
        let meanForce = forces.isEmpty ? 0.5 : forces.reduce(0, +) / CGFloat(forces.count)
        let meanAlt = altitudes.isEmpty ? .pi / 2 : altitudes.reduce(0, +) / CGFloat(altitudes.count)
        let baseTime = raw.first?.timestamp ?? 0

        // Sample perimeter; emit n+1 points to close the loop (last == first).
        var pts: [StrokePoint] = []
        pts.reserveCapacity(n + 1)
        for i in 0...n {
            let theta = (CGFloat(i) / CGFloat(n)) * 2 * .pi
            let lx = a * cos(theta)
            let ly = b * sin(theta)
            let x = geometry.center.x + lx * cosT - ly * sinT
            let y = geometry.center.y + lx * sinT + ly * cosT
            pts.append(StrokePoint(
                position: CGPoint(x: x, y: y),
                force: meanForce,
                altitude: meanAlt,
                timestamp: baseTime + TimeInterval(i) * 0.001
            ))
        }
        return pts
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
        // If a snap-edit is pending (shape in scratch, handles visible),
        // undo discards the pending shape rather than popping an undo
        // snapshot. The user expects undo to dismiss the in-progress edit.
        if isInSnapEditMode {
            cancelPendingSnapEdit()
            onStateChanged?()
            return
        }

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
            guard let png = renderer.layerPNGData(at: i) else { continue }
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
            pendingCanvasImageData = nil
            pendingCanvasImage = nil
            strokeCount = 1

            guard renderer.hasCanvas else {
                isDirty = true
                return
            }
            applyPendingLayeredDrawing()
            return
        }

        // Try single PNG.
        if CIImage(data: data, options: [.colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]) != nil {
            pendingCanvasImageData = data
            pendingCanvasImage = nil
            strokeCount = 1

            guard renderer.hasCanvas else {
                isDirty = true
                return
            }
            applyPendingCanvasImageData()
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

    /// Apply a deferred encoded canvas bitmap load (single-layer backward compat).
    private func applyPendingCanvasImageData() {
        guard let data = pendingCanvasImageData else { return }
        pendingCanvasImageData = nil
        if !renderer.loadImageDataIntoCanvas(data),
           let image = UIImage(data: data)?.cgImage {
            renderer.loadImageIntoCanvas(image)
        }
        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
        isDirty = true
        onDrawingChanged?()
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
            if renderer.loadImageDataIntoLayer(at: i, entry.pngData) {
                continue
            }
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

    /// Read-only access to the canvas composited over an opaque background using
    /// the same Metal source-over path as on-screen drawing.
    public func opaqueImageSnapshot(backgroundImage: UIImage?, maxPixelDimension: Int? = nil) -> UIImage? {
        let cgImage = renderer.flattenedOpaqueCGImage(
            backgroundImage: backgroundImage?.cgImage,
            maxPixelDimension: maxPixelDimension
        )
        guard let cgImage else { return nil }
        return UIImage(cgImage: cgImage, scale: canvasScale, orientation: .up)
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

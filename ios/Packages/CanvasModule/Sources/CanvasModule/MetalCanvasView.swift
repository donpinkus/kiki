import UIKit
import Metal

/// Metal-backed drawing canvas. Replaces `DrawingCanvasView` with a GPU-resident
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

    public private(set) var strokes: [Stroke] = []
    public var currentTool: ToolState = .brush(.defaultPen)

    public var isEmpty: Bool {
        strokes.isEmpty && !hasContent
    }

    // MARK: - Callbacks

    public var onDrawingChanged: (() -> Void)?
    public var onInteractionBegan: (() -> Void)?
    public var onInteractionEnded: (() -> Void)?
    public var onLassoCompleted: ((_ closedPath: CGPath, _ selectionImage: UIImage, _ selectionBounds: CGRect, _ preLassoSnapshot: CGImage?) -> Void)?
    public var backgroundImageProvider: (() -> UIImage?)?

    // MARK: - Private State

    private let renderer: CanvasRenderer
    private var displayLink: CADisplayLink?
    private var isDirty = true
    private var hasContent = false
    /// True when loadStrokes was called before the canvas texture was ready.
    /// layoutSubviews checks this flag and replays after resizeCanvas.
    private var needsStrokeReplay = false
    /// Canvas bitmap deferred from loadDrawingData until layout is ready.
    private var pendingCanvasImage: CGImage?

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

    private var undoSnapshots: [Data] = []
    private var redoSnapshots: [Data] = []
    private static let maxUndoDepth = 30

    public var canUndo: Bool { !undoSnapshots.isEmpty }
    public var canRedo: Bool { !redoSnapshots.isEmpty }

    // MARK: - Lasso

    private var lassoPoints: [CGPoint] = []
    private var lassoPath: CGMutablePath?
    private var preLassoSnapshot: CGImage?
    public var lassoClipPath: CGPath?

    /// Marching-ants preview of the lasso path while the user draws it.
    /// Two shape layers (white + black offset dashes) for visibility on any background.
    private let lassoPreviewWhite = CAShapeLayer()
    private let lassoPreviewBlack = CAShapeLayer()

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
        renderer.resizeCanvas(width: pixelW, height: pixelH)

        // If drawing data was loaded before layout (canvas texture didn't exist
        // yet), apply it now that the texture is allocated.
        if pendingCanvasImage != nil {
            applyPendingCanvasImage()
        } else if needsStrokeReplay {
            replayPendingStrokes()
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
        guard drawingTouch == nil, let touch = touches.first else { return }
        drawingTouch = touch
        onInteractionBegan?()

        let point = touch.location(in: self)

        switch currentTool {
        case .brush(let config):
            activeStroke = Stroke(points: [makeStrokePoint(from: touch)], brush: config)
            activeStrokeStamps = []
            appendStampsForLatestPoints(touch: touch, event: nil)

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

        if case .lasso = currentTool {
            finishLasso()
        } else {
            finishStroke()
        }
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }

        if case .eraser = currentTool {
            // Eraser stamps were applied directly to canvas — revert by restoring
            // the undo snapshot that was pushed at touchesBegan.
            if let snapshot = undoSnapshots.popLast() {
                renderer.restoreCanvas(from: snapshot)
            }
        }

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
    /// to the canvas texture with destination-out blend. Called per touchesMoved.
    /// Uses adaptive spacing and persists stamp position across batches.
    private func applyNewEraserStamps() {
        guard let stroke = activeStroke, stroke.points.count > lastEraserPointIndex else { return }

        let brush = stroke.brush
        let scale = canvasScale
        let color = SIMD4<Float>(1, 1, 1, 1)

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

                newStamps.append(CanvasRenderer.StampInstance(
                    center: SIMD2<Float>(Float(x * scale), Float(y * scale)),
                    radius: Float(width * 0.5 * scale),
                    rotation: 0,
                    color: color
                ))

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
            // Don't append to strokes — eraser operations are baked into the canvas
            // bitmap and saved/restored via PNG, not stroke replay.
            hasContent = true
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
        renderer.flattenScratchIntoCanvas(isEraser: false)

        strokes.append(stroke)
        hasContent = true
        onDrawingChanged?()
        isDirty = true
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

    private func finishLasso() {
        defer {
            drawingTouch = nil
            lassoPoints.removeAll()
            lassoPath = nil
            hideLassoPreview()
            onInteractionEnded?()
        }

        guard lassoPoints.count >= 3 else {
            // Too few points — cancel. Pop the undo snapshot we pushed at touchesBegan.
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
        guard pathBounds.width >= 4, pathBounds.height >= 4 else {
            if !undoSnapshots.isEmpty { undoSnapshots.removeLast() }
            isDirty = true
            return
        }

        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            if !undoSnapshots.isEmpty { undoSnapshots.removeLast() }
            isDirty = true
            return
        }

        // 1. Get the canvas as a CGImage (CIImage path — correct colors).
        guard let canvasCGImage = renderer.canvasToCGImage() else {
            if !undoSnapshots.isEmpty { undoSnapshots.removeLast() }
            isDirty = true
            return
        }

        let fullRect = CGRect(origin: .zero, size: size)

        // 2. Composite white + background + canvas into one image.
        //    Force sRGB to match the Metal canvas — UIGraphicsImageRenderer defaults
        //    to Display P3 on modern iPads, causing a saturation shift vs CAMetalLayer.
        let srgbFormat = UIGraphicsImageRendererFormat()
        srgbFormat.preferredRange = .standard

        let compositeRenderer = UIGraphicsImageRenderer(size: size, format: srgbFormat)
        let composite = compositeRenderer.image { _ in
            UIColor.white.setFill()
            UIRectFill(fullRect)
            backgroundImageProvider?()?.draw(in: fullRect)
            UIImage(cgImage: canvasCGImage).draw(in: fullRect)
        }

        // 3. Extract pixels inside the lasso path, crop to bounding box.
        let extractionRenderer = UIGraphicsImageRenderer(size: size, format: srgbFormat)
        let fullExtraction = extractionRenderer.image { ctx in
            let cgCtx = ctx.cgContext
            cgCtx.addPath(closedPath)
            cgCtx.clip()
            composite.draw(in: fullRect)
        }

        let cropRect = pathBounds.intersection(fullRect)
        guard !cropRect.isEmpty,
              let croppedCG = fullExtraction.cgImage?.cropping(to: CGRect(
                  x: cropRect.origin.x * fullExtraction.scale,
                  y: cropRect.origin.y * fullExtraction.scale,
                  width: cropRect.width * fullExtraction.scale,
                  height: cropRect.height * fullExtraction.scale
              )) else {
            if !undoSnapshots.isEmpty { undoSnapshots.removeLast() }
            isDirty = true
            return
        }
        let croppedImage = UIImage(cgImage: croppedCG, scale: fullExtraction.scale, orientation: .up)

        // 4. Clear the lasso area from the canvas texture.
        let clearRenderer = UIGraphicsImageRenderer(size: size, format: srgbFormat)
        let clearedImage = clearRenderer.image { ctx in
            let cgCtx = ctx.cgContext
            UIImage(cgImage: canvasCGImage).draw(in: fullRect)
            // Disable anti-aliasing so the clear has a crisp edge — anti-aliased
            // clear creates partially-transparent pixels at the boundary that let
            // the white background bleed through as a visible white outline.
            cgCtx.setShouldAntialias(false)
            cgCtx.addPath(closedPath)
            cgCtx.setBlendMode(.clear)
            cgCtx.fillPath()
        }
        if let clearedCG = clearedImage.cgImage {
            renderer.loadImageIntoCanvas(clearedCG)
        }

        isDirty = true

        // 5. Fire callback — CanvasViewModel shows the floating selection.
        onLassoCompleted?(closedPath, croppedImage, cropRect, nil)
    }

    // MARK: - Lasso Public API

    /// Composite a transformed selection image back onto the canvas.
    /// Called when committing a lasso selection (Phase A → canvas).
    public func compositeSelectionImage(_ image: UIImage, at rect: CGRect, transform: CGAffineTransform) {
        guard let canvasCGImage = renderer.canvasToCGImage() else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard  // sRGB to match Metal canvas
        let compositeRenderer = UIGraphicsImageRenderer(size: size, format: format)
        let result = compositeRenderer.image { ctx in
            UIImage(cgImage: canvasCGImage).draw(in: CGRect(origin: .zero, size: size))
            let cgCtx = ctx.cgContext
            cgCtx.saveGState()
            cgCtx.concatenate(transform)
            image.draw(in: rect)
            cgCtx.restoreGState()
        }
        if let resultCG = result.cgImage {
            renderer.loadImageIntoCanvas(resultCG)
        }
        isDirty = true
    }

    /// Restore the canvas to a previous state (used by lasso cancel).
    public func restorePersistentImage(_ image: CGImage?) {
        guard let image else { return }
        renderer.loadImageIntoCanvas(image)
        isDirty = true
    }

    // MARK: - Undo / Redo

    private func pushUndoSnapshot() {
        guard let data = renderer.snapshotCanvas() else { return }
        undoSnapshots.append(data)
        if undoSnapshots.count > Self.maxUndoDepth {
            undoSnapshots.removeFirst()
        }
        redoSnapshots.removeAll()
    }

    public func performUndo() {
        guard let snapshot = undoSnapshots.popLast() else { return }
        // Save current state for redo.
        if let current = renderer.snapshotCanvas() {
            redoSnapshots.append(current)
        }
        renderer.restoreCanvas(from: snapshot)
        if !undoSnapshots.isEmpty || hasContent {
            // Remove the last stroke from data (approximate — full replay would be more correct).
            if !strokes.isEmpty { strokes.removeLast() }
        }
        hasContent = !strokes.isEmpty
        onDrawingChanged?()
        isDirty = true
    }

    public func performRedo() {
        guard let snapshot = redoSnapshots.popLast() else { return }
        if let current = renderer.snapshotCanvas() {
            undoSnapshots.append(current)
        }
        renderer.restoreCanvas(from: snapshot)
        hasContent = true
        onDrawingChanged?()
        isDirty = true
    }

    // MARK: - Public API

    /// Clear the entire canvas. Returns previous state info for undo support.
    public func clearAll() {
        pushUndoSnapshot()
        renderer.resizeCanvas(width: renderer.canvasWidth, height: renderer.canvasHeight)
        strokes.removeAll()
        hasContent = false
        isDirty = true
    }

    /// Load an image onto the canvas (e.g., "Send to Canvas").
    public func bakeImage(_ image: UIImage) {
        guard let cgImage = image.cgImage else { return }
        renderer.loadImageIntoCanvas(cgImage)
        hasContent = true
        isDirty = true
    }

    /// Export the canvas as PNG data for persistence. This captures the exact
    /// pixel state including eraser holes and blended edges — no stroke replay
    /// needed on restore.
    public func exportStrokeData() -> Data? {
        guard hasContent || !strokes.isEmpty else { return nil }
        guard let cgImage = renderer.canvasToCGImage() else { return nil }
        return UIImage(cgImage: cgImage).pngData()
    }

    /// Load strokes from saved data. Accepts either:
    /// - Canvas bitmap PNG (current format — pixel-perfect restore via bakeImage)
    /// - Stroke JSON (legacy format — replayed through stamp pipeline)
    public func loadStrokes(_ savedStrokes: [Stroke]) {
        // This method is kept for API compat but the primary persistence path
        // now saves/loads canvas PNG via exportStrokeData/loadDrawingData.
        strokes = savedStrokes
        hasContent = !strokes.isEmpty
        needsStrokeReplay = hasContent

        guard renderer.hasCanvas else {
            isDirty = true
            return
        }

        replayPendingStrokes()
    }

    /// Load canvas from PNG bitmap data (primary persistence path).
    /// If the canvas texture isn't allocated yet, defers to layoutSubviews.
    public func loadDrawingData(_ data: Data) {
        guard let image = UIImage(data: data)?.cgImage else {
            // Not a valid image — try legacy stroke JSON path.
            if let strokes = try? JSONDecoder().decode([Stroke].self, from: data) {
                loadStrokes(strokes)
            }
            return
        }
        pendingCanvasImage = image
        hasContent = true
        needsStrokeReplay = false // bitmap load, not stroke replay

        guard renderer.hasCanvas else {
            isDirty = true
            return
        }

        applyPendingCanvasImage()
    }

    /// Apply a deferred canvas bitmap load.
    private func applyPendingCanvasImage() {
        guard let image = pendingCanvasImage else { return }
        pendingCanvasImage = nil
        renderer.loadImageIntoCanvas(image)
        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
        isDirty = true
    }

    /// Replay all stored strokes into the canvas texture (legacy path).
    private func replayPendingStrokes() {
        guard needsStrokeReplay, !strokes.isEmpty, renderer.hasCanvas else { return }
        needsStrokeReplay = false

        let scale = canvasScale
        for stroke in strokes {
            let stamps = generateStampsForStroke(stroke, scale: scale)
            if !stamps.isEmpty {
                renderer.commitStampsToCanvas(stamps)
            }
        }

        undoSnapshots.removeAll()
        redoSnapshots.removeAll()
        isDirty = true
    }

    /// Generate stamp instances for a complete stroke (used by replay + active drawing).
    private func generateStampsForStroke(_ stroke: Stroke, scale: CGFloat) -> [CanvasRenderer.StampInstance] {
        guard !stroke.points.isEmpty else { return [] }

        let brush = stroke.brush
        let color = premultipliedColor(brush)
        var stamps: [CanvasRenderer.StampInstance] = []

        let first = stroke.points[0]
        let firstWidth = brush.effectiveWidth(force: first.force, altitude: first.altitude)
        stamps.append(CanvasRenderer.StampInstance(
            center: SIMD2<Float>(Float(first.position.x * scale), Float(first.position.y * scale)),
            radius: Float(firstWidth * 0.5 * scale),
            rotation: 0,
            color: color
        ))

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

                stamps.append(CanvasRenderer.StampInstance(
                    center: SIMD2<Float>(Float(x * scale), Float(y * scale)),
                    radius: Float(width * 0.5 * scale),
                    rotation: 0,
                    color: color
                ))

                lastStampPos = CGPoint(x: x, y: y)
                currentSpacing = max(width * 0.3, 0.5)
                traveled += currentSpacing
            }
        }

        // End cap.
        if let last = stroke.points.last {
            let width = brush.effectiveWidth(force: last.force, altitude: last.altitude)
            stamps.append(CanvasRenderer.StampInstance(
                center: SIMD2<Float>(Float(last.position.x * scale), Float(last.position.y * scale)),
                radius: Float(width * 0.5 * scale),
                rotation: 0,
                color: color
            ))
        }

        return stamps
    }

    /// Read-only access to the current canvas as a CGImage (for snapshots, thumbnails).
    public var persistentImageSnapshot: CGImage? {
        renderer.canvasToCGImage()
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

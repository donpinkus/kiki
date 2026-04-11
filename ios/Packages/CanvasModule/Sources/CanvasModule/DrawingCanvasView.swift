import UIKit

/// Custom drawing canvas that replaces PKCanvasView.
///
/// Uses Core Graphics with a two-bitmap architecture:
/// - `persistentImage`: all completed strokes, flattened into one CGImage
/// - Active stroke: rendered live during touch, flattened on touchesEnded
///
/// The eraser modifies the persistent bitmap incrementally during touch
/// for immediate visual feedback (pixels disappear as you drag).
public final class DrawingCanvasView: UIView {

    // MARK: - Public State

    public private(set) var strokes: [Stroke] = []
    public let undoStack = UndoStack<CanvasAction>(maxDepth: 50)
    public var currentTool: ToolState = .brush(.defaultPen)

    public var isEmpty: Bool {
        strokes.isEmpty && persistentImage == nil && bakedBaseImage == nil
    }

    // MARK: - Callbacks

    public var onDrawingChanged: (() -> Void)?
    public var onInteractionBegan: (() -> Void)?
    public var onInteractionEnded: (() -> Void)?

    // MARK: - Private Rendering State

    /// Flattened bitmap of all completed strokes (transparent background).
    private var persistentImage: CGImage?

    /// Base image baked into the canvas via "Send to Canvas".
    /// Composited below strokes in rebuildPersistent so stroke undo doesn't lose it.
    private var bakedBaseImage: CGImage?

    /// Stroke currently being drawn — nil when not actively drawing.
    private var activeStroke: Stroke?

    /// Smoothed + tessellated path for the active stroke (pen only), updated on each touchesMoved.
    private var activeStrokePath: CGPath?

    /// Tracks which touch is our drawing touch (to reject additional fingers).
    private var drawingTouch: UITouch?

    // MARK: - Eraser State

    /// Snapshot of persistent bitmap taken at eraser touchesBegan, for undo.
    private var preEraseSnapshot: CGImage?

    /// Index of the last point processed for incremental erasing.
    /// We tessellate from (lastEraserIndex - 1) to avoid gaps between segments.
    private var lastEraserIndex: Int = 0

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        contentMode = .redraw
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Recover from a deferred load: if strokes were loaded while bounds
        // were still zero (during makeUIView, before SwiftUI laid us out),
        // rebuildPersistent bailed out and persistentImage is nil. Now that
        // bounds are valid, rebuild it.
        if persistentImage == nil
            && !strokes.isEmpty
            && bounds.size.width > 0
            && bounds.size.height > 0 {
            rebuildPersistent()
            setNeedsDisplay()
        }
    }

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        // Draw persistent (completed) strokes + any in-progress erasing.
        // Use UIImage wrapper to avoid CGContext Y-flip in UIKit coordinate space.
        if let persistent = persistentImage {
            UIImage(cgImage: persistent).draw(in: bounds)
        }

        // Draw active pen stroke in progress (eraser has no overlay — it modifies persistent directly)
        if let path = activeStrokePath, isCurrentToolBrush {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            if case .brush(let config) = currentTool {
                ctx.setFillColor(config.color.uiColor.cgColor)
            }
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    private var isCurrentToolBrush: Bool {
        if case .brush = currentTool { return true }
        return false
    }

    // MARK: - Touch Handling

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawingTouch == nil, let touch = touches.first else { return }

        drawingTouch = touch
        onInteractionBegan?()

        let point = makeStrokePoint(from: touch)

        switch currentTool {
        case .brush(let config):
            activeStroke = Stroke(points: [point], brush: config)
            updateActiveStrokePath()

        case .eraser(let width):
            let brush = BrushConfig(color: .black, baseWidth: width, pressureGamma: 0.7)
            activeStroke = Stroke(points: [point], brush: brush)
            // Snapshot persistent bitmap before any erasing (for undo)
            preEraseSnapshot = persistentImage
            lastEraserIndex = 0
        }

        setNeedsDisplay()
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }

        // Use coalesced touches for full 240Hz Apple Pencil sampling
        let coalescedTouches = event?.coalescedTouches(for: touch) ?? [touch]
        for coalescedTouch in coalescedTouches {
            let point = makeStrokePoint(from: coalescedTouch)
            activeStroke?.points.append(point)
        }

        switch currentTool {
        case .brush:
            updateActiveStrokePath()

        case .eraser:
            eraseIncrementally()
        }

        setNeedsDisplay()
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        finishStroke()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }

        if case .eraser = currentTool {
            // Restore pre-erase state — cancel means discard the partial erase
            if let snapshot = preEraseSnapshot {
                persistentImage = snapshot
            }
            preEraseSnapshot = nil
        }

        activeStroke = nil
        activeStrokePath = nil
        drawingTouch = nil
        lastEraserIndex = 0
        onInteractionEnded?()
        setNeedsDisplay()
    }

    // MARK: - Incremental Erasing

    /// Erase new segments since the last touchesMoved. Modifies persistentImage directly.
    private func eraseIncrementally() {
        guard let stroke = activeStroke else { return }
        let points = stroke.points

        // Overlap by 1 point with the previous segment to avoid gaps.
        let segmentStart = max(0, lastEraserIndex - 1)
        guard points.count > segmentStart else { return }

        // Build a simple line path through the new points (no tessellation needed).
        let path = CGMutablePath()
        path.move(to: points[segmentStart].position)
        for i in (segmentStart + 1)..<points.count {
            path.addLine(to: points[i].position)
        }

        eraseStrokePath(path, width: stroke.brush.baseWidth)
        lastEraserIndex = points.count - 1
    }

    // MARK: - Stroke Completion

    private func finishStroke() {
        defer {
            activeStroke = nil
            activeStrokePath = nil
            drawingTouch = nil
            preEraseSnapshot = nil
            lastEraserIndex = 0
            onInteractionEnded?()
        }

        guard var stroke = activeStroke, !stroke.points.isEmpty else { return }

        switch currentTool {
        case .brush:
            // Smooth the final stroke
            stroke.points = StrokeSmoother.smooth(stroke.points)
            if stroke.points.count >= 2 {
                stroke.points = StrokeSmoother.interpolate(stroke.points, segmentsPerInterval: 2)
            }
            flattenStroke(stroke)
            strokes.append(stroke)
            undoStack.push(.stroke(stroke))

        case .eraser:
            // Erasing was already applied incrementally during touchesMoved.
            // Push undo action with both pre- and post-erase snapshots.
            if let pre = preEraseSnapshot, let post = persistentImage {
                undoStack.push(.erase(preEraseSnapshot: pre, postEraseSnapshot: post))
            }
        }

        onDrawingChanged?()
        setNeedsDisplay()
    }

    // MARK: - Active Stroke Path (pen only)

    private func updateActiveStrokePath() {
        guard let stroke = activeStroke, !stroke.points.isEmpty else {
            activeStrokePath = nil
            return
        }

        // Smooth in real-time (lightweight — moving average only, no interpolation)
        let smoothed = StrokeSmoother.smooth(stroke.points)
        activeStrokePath = StrokeTessellator.tessellate(points: smoothed, brush: stroke.brush)
    }

    // MARK: - Persistent Bitmap Operations

    /// Flatten a completed stroke onto the persistent bitmap.
    private func flattenStroke(_ stroke: Stroke) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let path = StrokeTessellator.tessellate(points: stroke.points, brush: stroke.brush)

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            // Draw existing persistent content (UIImage wrapper avoids CG Y-flip)
            if let existing = persistentImage {
                UIImage(cgImage: existing).draw(in: CGRect(origin: .zero, size: size))
            }
            // Draw the new stroke on top
            ctx.cgContext.setFillColor(stroke.brush.color.uiColor.cgColor)
            ctx.cgContext.addPath(path)
            ctx.cgContext.fillPath()
        }
        persistentImage = image.cgImage
    }

    /// Erase pixels along the given path using a stroked line with round caps.
    private func eraseStrokePath(_ path: CGPath, width: CGFloat) {
        let size = bounds.size
        guard size.width > 0, size.height > 0, persistentImage != nil else { return }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            if let existing = persistentImage {
                UIImage(cgImage: existing).draw(in: CGRect(origin: .zero, size: size))
            }
            cgCtx.setBlendMode(.clear)
            cgCtx.setLineWidth(width)
            cgCtx.setLineCap(.round)
            cgCtx.setLineJoin(.round)
            cgCtx.addPath(path)
            cgCtx.strokePath()
        }
        persistentImage = image.cgImage
    }

    /// Re-render the persistent bitmap from the baked base image (if any) plus all current strokes.
    private func rebuildPersistent() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            persistentImage = nil
            return
        }
        guard !strokes.isEmpty || bakedBaseImage != nil else {
            persistentImage = nil
            return
        }

        let rect = CGRect(origin: .zero, size: size)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            if let base = bakedBaseImage {
                UIImage(cgImage: base).draw(in: rect)
            }
            for stroke in strokes {
                let path = StrokeTessellator.tessellate(points: stroke.points, brush: stroke.brush)
                cgCtx.setFillColor(stroke.brush.color.uiColor.cgColor)
                cgCtx.addPath(path)
                cgCtx.fillPath()
            }
        }
        persistentImage = image.cgImage
    }

    // MARK: - Public Undo/Redo

    /// Undo the last action. Returns the action so the caller can handle
    /// side effects (e.g. restoring the background image on the container).
    @discardableResult
    public func performUndo() -> CanvasAction? {
        guard let action = undoStack.undo() else { return nil }
        switch action {
        case .stroke(let stroke):
            strokes.removeAll { $0.id == stroke.id }
            rebuildPersistent()

        case .erase(let snapshot, _):
            persistentImage = snapshot

        case .lineartSwap(let prevStrokes, let prevPersistent, let prevBase, _, _):
            strokes = prevStrokes
            persistentImage = prevPersistent
            bakedBaseImage = prevBase

        case .clear(let prevStrokes, let prevPersistent, let prevBase, _):
            strokes = prevStrokes
            persistentImage = prevPersistent
            bakedBaseImage = prevBase
        }
        onDrawingChanged?()
        setNeedsDisplay()
        return action
    }

    /// Redo the last undone action. Returns the action so the caller can handle side effects.
    @discardableResult
    public func performRedo() -> CanvasAction? {
        guard let action = undoStack.redo() else { return nil }
        switch action {
        case .stroke(let stroke):
            strokes.append(stroke)
            flattenStroke(stroke)

        case .erase(_, let postSnapshot):
            persistentImage = postSnapshot

        case .lineartSwap:
            // Strokes cleared; CanvasViewModel will re-bake the image via bakeImageIntoCanvas.
            strokes.removeAll()
            persistentImage = nil
            bakedBaseImage = nil

        case .clear:
            strokes.removeAll()
            persistentImage = nil
            bakedBaseImage = nil
        }
        onDrawingChanged?()
        setNeedsDisplay()
        return action
    }

    // MARK: - Public API

    /// Render an external image into the persistent bitmap at the canvas's current size.
    /// Used by "Send to Canvas" so the image lives on the same erasable layer as strokes.
    public func bakeImage(_ image: UIImage) {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let renderer = UIGraphicsImageRenderer(size: size)
        let result = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        let cgImg = result.cgImage
        bakedBaseImage = cgImg
        persistentImage = cgImg
        setNeedsDisplay()
    }

    /// Clear all strokes and the persistent bitmap. Returns previous state for undo.
    public func clearAll() -> (strokes: [Stroke], persistent: CGImage?, baseImage: CGImage?) {
        let prevStrokes = strokes
        let prevPersistent = persistentImage
        let prevBase = bakedBaseImage
        strokes.removeAll()
        persistentImage = nil
        bakedBaseImage = nil
        setNeedsDisplay()
        return (prevStrokes, prevPersistent, prevBase)
    }

    /// Load strokes from saved data and rebuild the persistent bitmap.
    public func loadStrokes(_ savedStrokes: [Stroke]) {
        strokes = savedStrokes
        undoStack.clear()
        rebuildPersistent()
        setNeedsDisplay()
    }

    /// Export all stroke data as JSON for persistence.
    public func exportStrokeData() -> Data? {
        guard !strokes.isEmpty else { return nil }
        return try? JSONEncoder().encode(strokes)
    }

    // MARK: - Touch → StrokePoint

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

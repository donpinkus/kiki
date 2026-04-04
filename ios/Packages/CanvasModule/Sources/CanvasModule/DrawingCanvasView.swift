import UIKit

/// Custom drawing canvas that replaces PKCanvasView.
///
/// Uses Core Graphics with a two-bitmap architecture:
/// - `persistentImage`: all completed strokes, flattened into one CGImage
/// - Active stroke: rendered live during touch, flattened on touchesEnded
///
/// Supports pressure-sensitive pen and pixel eraser with undo/redo.
public final class DrawingCanvasView: UIView {

    // MARK: - Public State

    public private(set) var strokes: [Stroke] = []
    public let undoStack = UndoStack<CanvasAction>(maxDepth: 50)
    public var currentTool: ToolState = .brush(.defaultPen)

    public var isEmpty: Bool {
        strokes.isEmpty && persistentImage == nil
    }

    // MARK: - Callbacks

    public var onDrawingChanged: (() -> Void)?
    public var onInteractionBegan: (() -> Void)?
    public var onInteractionEnded: (() -> Void)?

    // MARK: - Private Rendering State

    /// Flattened bitmap of all completed strokes (transparent background).
    private var persistentImage: CGImage?

    /// Stroke currently being drawn — nil when not actively drawing.
    private var activeStroke: Stroke?

    /// Smoothed + tessellated path for the active stroke, updated on each touchesMoved.
    private var activeStrokePath: CGPath?

    /// Tracks which touch is our drawing touch (to reject additional fingers).
    private var drawingTouch: UITouch?

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

    // MARK: - Drawing

    public override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }

        // Draw persistent (completed) strokes.
        // Use UIImage wrapper to avoid CGContext Y-flip in UIKit coordinate space.
        if let persistent = persistentImage {
            UIImage(cgImage: persistent).draw(in: bounds)
        }

        // Draw active stroke in progress
        if let path = activeStrokePath {
            drawStrokePath(path, tool: currentTool, in: ctx)
        }
    }

    private func drawStrokePath(_ path: CGPath, tool: ToolState, in ctx: CGContext) {
        switch tool {
        case .brush(let config):
            ctx.setFillColor(config.color.uiColor.cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        case .eraser:
            // Eraser draws with clear blend mode — handled differently during flattening.
            // During live preview, show a light gray to indicate eraser path.
            ctx.setFillColor(UIColor(white: 0.8, alpha: 0.5).cgColor)
            ctx.addPath(path)
            ctx.fillPath()
        }
    }

    // MARK: - Touch Handling

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard drawingTouch == nil, let touch = touches.first else { return }

        drawingTouch = touch
        onInteractionBegan?()

        let point = makeStrokePoint(from: touch)
        var brush = BrushConfig.defaultPen
        if case .brush(let config) = currentTool {
            brush = config
        } else if case .eraser(let width) = currentTool {
            brush = BrushConfig(color: .black, baseWidth: width, pressureGamma: 0.7)
        }

        activeStroke = Stroke(points: [point], brush: brush)
        updateActiveStrokePath()
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

        updateActiveStrokePath()
        setNeedsDisplay()
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        finishStroke()
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = drawingTouch, touches.contains(touch) else { return }
        // Discard the active stroke on cancel
        activeStroke = nil
        activeStrokePath = nil
        drawingTouch = nil
        onInteractionEnded?()
        setNeedsDisplay()
    }

    // MARK: - Stroke Completion

    private func finishStroke() {
        defer {
            activeStroke = nil
            activeStrokePath = nil
            drawingTouch = nil
            onInteractionEnded?()
        }

        guard var stroke = activeStroke, !stroke.points.isEmpty else { return }

        // Smooth the final stroke
        stroke.points = StrokeSmoother.smooth(stroke.points)
        if stroke.points.count >= 2 {
            stroke.points = StrokeSmoother.interpolate(stroke.points, segmentsPerInterval: 2)
        }

        switch currentTool {
        case .brush:
            // Flatten stroke onto persistent bitmap
            flattenStroke(stroke)
            strokes.append(stroke)
            undoStack.push(.stroke(stroke))

        case .eraser:
            // Snapshot the affected region before erasing
            let path = StrokeTessellator.tessellate(points: stroke.points, brush: stroke.brush)
            let eraseBounds = path.boundingBoxOfPath.insetBy(dx: -2, dy: -2)
            let snapshot = snapshotRegion(eraseBounds)

            eraseWithPath(path)
            undoStack.push(.erase(snapshotRegion: snapshot, bounds: eraseBounds))
        }

        onDrawingChanged?()
        setNeedsDisplay()
    }

    // MARK: - Active Stroke Path

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

    /// Erase pixels under the given path (destination-out blending).
    private func eraseWithPath(_ path: CGPath) {
        let size = bounds.size
        guard size.width > 0, size.height > 0, persistentImage != nil else { return }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            // Draw existing persistent content
            if let existing = persistentImage {
                UIImage(cgImage: existing).draw(in: CGRect(origin: .zero, size: size))
            }
            // Erase with clear blend mode
            cgCtx.setBlendMode(.clear)
            cgCtx.addPath(path)
            cgCtx.fillPath()
        }
        persistentImage = image.cgImage
    }

    /// Re-render the persistent bitmap from all current strokes.
    private func rebuildPersistent() {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else {
            persistentImage = nil
            return
        }
        guard !strokes.isEmpty else {
            persistentImage = nil
            return
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            let cgCtx = ctx.cgContext
            for stroke in strokes {
                let path = StrokeTessellator.tessellate(points: stroke.points, brush: stroke.brush)
                cgCtx.setFillColor(stroke.brush.color.uiColor.cgColor)
                cgCtx.addPath(path)
                cgCtx.fillPath()
            }
        }
        persistentImage = image.cgImage
    }

    /// Snapshot a region of the persistent bitmap for undo support.
    private func snapshotRegion(_ regionBounds: CGRect) -> CGImage {
        let size = self.bounds.size
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            if let existing = persistentImage {
                UIImage(cgImage: existing).draw(in: CGRect(origin: .zero, size: size))
            }
        }
        // Crop to the region. If cropping fails, return the full image.
        if let cgImage = image.cgImage {
            let scale = image.scale
            let cropRect = CGRect(
                x: regionBounds.origin.x * scale,
                y: regionBounds.origin.y * scale,
                width: regionBounds.width * scale,
                height: regionBounds.height * scale
            ).intersection(CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            if !cropRect.isEmpty, let cropped = cgImage.cropping(to: cropRect) {
                return cropped
            }
            return cgImage
        }
        // Fallback: 1x1 transparent pixel
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }.cgImage!
    }

    /// Restore a previously snapshotted region (for undo of pixel erase).
    private func restoreRegion(_ snapshot: CGImage, regionBounds: CGRect) {
        let size = self.bounds.size
        guard size.width > 0, size.height > 0 else { return }

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            // Draw full persistent image
            if let existing = persistentImage {
                UIImage(cgImage: existing).draw(in: CGRect(origin: .zero, size: size))
            }
            // Clear the affected region, then patch with snapshot
            let ctx = UIGraphicsGetCurrentContext()!
            ctx.setBlendMode(.clear)
            ctx.fill(regionBounds)
            ctx.setBlendMode(.normal)
            UIImage(cgImage: snapshot).draw(in: regionBounds)
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

        case .erase(let snapshot, let regionBounds):
            restoreRegion(snapshot, regionBounds: regionBounds)

        case .lineartSwap(let prevStrokes, let prevPersistent, _, _):
            strokes = prevStrokes
            persistentImage = prevPersistent

        case .clear(let prevStrokes, let prevPersistent, _):
            strokes = prevStrokes
            persistentImage = prevPersistent
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

        case .erase:
            // Re-applying an erase would need the original erase path which we don't store.
            // Rebuild from stroke data — the erase won't be replayed. Acceptable for Phase 1.
            rebuildPersistent()

        case .lineartSwap, .clear:
            // These operations result in an empty canvas (strokes cleared).
            // Background image is handled by the CanvasViewModel.
            strokes.removeAll()
            persistentImage = nil
        }
        onDrawingChanged?()
        setNeedsDisplay()
        return action
    }

    // MARK: - Public API

    /// Clear all strokes and the persistent bitmap. Returns previous state for undo.
    public func clearAll() -> (strokes: [Stroke], persistent: CGImage?) {
        let prevStrokes = strokes
        let prevPersistent = persistentImage
        strokes.removeAll()
        persistentImage = nil
        setNeedsDisplay()
        return (prevStrokes, prevPersistent)
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

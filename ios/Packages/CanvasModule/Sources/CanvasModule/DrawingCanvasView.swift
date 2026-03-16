import UIKit

// MARK: - Data Types

struct StrokePoint {
    let location: CGPoint
    let width: CGFloat
}

struct Stroke {
    let points: [StrokePoint]
    let color: UIColor
    let lineWidth: CGFloat
    let isEraser: Bool
}

struct ToolConfig {
    var lineWidth: CGFloat = 5
    var color: UIColor = .black
    var isEraser: Bool = false
}

// MARK: - DrawingCanvasView

final class DrawingCanvasView: UIView {

    // MARK: - Public Properties

    var currentTool = ToolConfig() {
        didSet { updateLazyBrushRadius() }
    }

    var stabilizationAmount: CGFloat = 0.0 {
        didSet { updateLazyBrushRadius() }
    }

    var onDrawingChanged: (() -> Void)?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isEmpty: Bool { completedStrokes.isEmpty && currentPoints.isEmpty }

    // MARK: - Private Properties

    private var completedStrokes: [Stroke] = []
    private var currentPoints: [StrokePoint] = []
    private var frozenImage: UIImage?
    private var undoStack: [[Stroke]] = []
    private var redoStack: [[Stroke]] = []
    private var lazyBrush = LazyBrush(radius: 0)
    private var activeTouch: UITouch?

    // MARK: - Lifecycle

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isOpaque = true
        isMultipleTouchEnabled = false
        contentMode = .redrawing
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Public API

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(completedStrokes)
        completedStrokes = previous
        rebuildFrozenImage()
        setNeedsDisplay()
        onDrawingChanged?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(completedStrokes)
        completedStrokes = next
        rebuildFrozenImage()
        setNeedsDisplay()
        onDrawingChanged?()
    }

    func clear() {
        guard !isEmpty else { return }
        undoStack.append(completedStrokes)
        redoStack.removeAll()
        completedStrokes.removeAll()
        currentPoints.removeAll()
        frozenImage = nil
        setNeedsDisplay()
        onDrawingChanged?()
    }

    func captureSnapshot() -> UIImage? {
        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        return renderer.image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
    }

    // MARK: - Touch Handling

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard activeTouch == nil, let touch = touches.first else { return }
        activeTouch = touch

        let location = touch.location(in: self)
        lazyBrush.reset(to: location)

        // Save state for undo before starting new stroke
        undoStack.append(completedStrokes)
        redoStack.removeAll()

        currentPoints = [StrokePoint(location: location, width: currentTool.lineWidth)]
        setNeedsDisplay(dirtyRect(around: location))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }

        let coalescedTouches = event?.coalescedTouches(for: touch) ?? [touch]
        var dirtyBounds = CGRect.null

        for coalescedTouch in coalescedTouches {
            let target = coalescedTouch.location(in: self)

            if lazyBrush.update(toward: target) {
                let point = StrokePoint(
                    location: lazyBrush.position,
                    width: currentTool.lineWidth
                )
                currentPoints.append(point)
                dirtyBounds = dirtyBounds.union(dirtyRect(around: lazyBrush.position))
            }
        }

        if !dirtyBounds.isNull {
            setNeedsDisplay(dirtyBounds)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        finishStroke()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        // Discard the in-progress stroke and restore undo state
        currentPoints.removeAll()
        _ = undoStack.popLast()
        activeTouch = nil
        setNeedsDisplay()
    }

    // MARK: - Rendering

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        // White background
        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)

        // Draw cached completed strokes
        if let frozenImage = frozenImage {
            frozenImage.draw(at: .zero)
        }

        // Draw in-progress stroke
        if !currentPoints.isEmpty {
            drawStrokePoints(currentPoints, tool: currentTool, in: context)
        }
    }

    // MARK: - Private

    private func finishStroke() {
        guard !currentPoints.isEmpty else {
            activeTouch = nil
            return
        }

        let stroke = Stroke(
            points: currentPoints,
            color: currentTool.color,
            lineWidth: currentTool.lineWidth,
            isEraser: currentTool.isEraser
        )
        completedStrokes.append(stroke)
        currentPoints.removeAll()
        activeTouch = nil

        rebuildFrozenImage()
        setNeedsDisplay()
        onDrawingChanged?()
    }

    private func rebuildFrozenImage() {
        guard !completedStrokes.isEmpty else {
            frozenImage = nil
            return
        }

        let renderer = UIGraphicsImageRenderer(bounds: bounds)
        frozenImage = renderer.image { rendererContext in
            let context = rendererContext.cgContext

            // White background
            context.setFillColor(UIColor.white.cgColor)
            context.fill(bounds)

            for stroke in completedStrokes {
                let tool = ToolConfig(
                    lineWidth: stroke.lineWidth,
                    color: stroke.color,
                    isEraser: stroke.isEraser
                )
                drawStrokePoints(stroke.points, tool: tool, in: context)
            }
        }
    }

    private func drawStrokePoints(_ points: [StrokePoint], tool: ToolConfig, in context: CGContext) {
        guard points.count >= 2 else {
            // Single point — draw a dot
            if let point = points.first {
                let dotRect = CGRect(
                    x: point.location.x - tool.lineWidth / 2,
                    y: point.location.y - tool.lineWidth / 2,
                    width: tool.lineWidth,
                    height: tool.lineWidth
                )
                context.saveGState()
                if tool.isEraser {
                    context.setBlendMode(.clear)
                }
                context.setFillColor(tool.isEraser ? UIColor.white.cgColor : tool.color.cgColor)
                context.fillEllipse(in: dotRect)
                context.restoreGState()
            }
            return
        }

        context.saveGState()

        if tool.isEraser {
            context.setBlendMode(.clear)
            context.setStrokeColor(UIColor.white.cgColor)
        } else {
            context.setStrokeColor(tool.color.cgColor)
        }

        context.setLineWidth(tool.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        // Draw smooth path using quadratic curves through midpoints
        let path = CGMutablePath()
        path.move(to: points[0].location)

        if points.count == 2 {
            path.addLine(to: points[1].location)
        } else {
            for i in 1..<points.count - 1 {
                let mid = CGPoint(
                    x: (points[i].location.x + points[i + 1].location.x) / 2,
                    y: (points[i].location.y + points[i + 1].location.y) / 2
                )
                path.addQuadCurve(to: mid, control: points[i].location)
            }
            path.addLine(to: points[points.count - 1].location)
        }

        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    private func dirtyRect(around point: CGPoint) -> CGRect {
        let padding = currentTool.lineWidth + 10
        return CGRect(
            x: point.x - padding,
            y: point.y - padding,
            width: padding * 2,
            height: padding * 2
        )
    }

    private func updateLazyBrushRadius() {
        // No stabilization for eraser
        if currentTool.isEraser {
            lazyBrush.radius = 0
        } else {
            lazyBrush.radius = stabilizationAmount * 30.0
        }
    }
}

import CoreGraphics

/// Converts stroke points into a filled CGPath with variable width from pressure.
///
/// The tessellation strategy: at each point, compute the width from pressure, then extrude
/// perpendicular to the stroke direction by half-width on each side. Connect the left edges
/// and right edges into a closed polygon. Add round end caps.
enum StrokeTessellator {

    /// Tessellate a stroke into a filled CGPath polygon with variable width.
    static func tessellate(points: [StrokePoint], brush: BrushConfig) -> CGPath {
        guard points.count >= 2 else {
            return singlePointPath(points: points, brush: brush)
        }

        // Precompute cumulative arc-length distances for taper
        var distances: [CGFloat] = [0]
        for i in 1..<points.count {
            let dx = points[i].position.x - points[i - 1].position.x
            let dy = points[i].position.y - points[i - 1].position.y
            distances.append(distances[i - 1] + hypot(dx, dy))
        }
        let totalLength = distances.last ?? 0

        let path = CGMutablePath()
        var leftEdge: [CGPoint] = []
        var rightEdge: [CGPoint] = []

        for i in 0..<points.count {
            let point = points[i]
            var width = brush.effectiveWidth(force: point.force, altitude: point.altitude)

            // Taper in
            if brush.taperIn > 0 && distances[i] < brush.taperIn {
                width *= distances[i] / brush.taperIn
            }
            // Taper out
            if brush.taperOut > 0 {
                let distFromEnd = totalLength - distances[i]
                if distFromEnd < brush.taperOut {
                    width *= distFromEnd / brush.taperOut
                }
            }

            let halfWidth = max(width / 2, 0.1)

            // Compute stroke direction at this point
            let direction = strokeDirection(at: i, in: points)
            // Perpendicular (rotated 90°)
            let perp = CGPoint(x: -direction.y, y: direction.x)

            leftEdge.append(CGPoint(
                x: point.position.x + perp.x * halfWidth,
                y: point.position.y + perp.y * halfWidth
            ))
            rightEdge.append(CGPoint(
                x: point.position.x - perp.x * halfWidth,
                y: point.position.y - perp.y * halfWidth
            ))
        }

        // Build closed polygon: left edge forward, right edge reversed
        guard let firstLeft = leftEdge.first else { return path }
        path.move(to: firstLeft)
        for i in 1..<leftEdge.count {
            path.addLine(to: leftEdge[i])
        }

        // Round end cap at the end
        if let lastPoint = points.last {
            let endWidth = brush.effectiveWidth(force: lastPoint.force, altitude: lastPoint.altitude)
            var capRadius = endWidth / 2
            if brush.taperOut > 0 { capRadius = 0.1 }
            addRoundCap(to: path, center: lastPoint.position, radius: capRadius,
                        from: leftEdge[leftEdge.count - 1], to: rightEdge[rightEdge.count - 1])
        }

        // Right edge in reverse
        for i in stride(from: rightEdge.count - 1, through: 0, by: -1) {
            path.addLine(to: rightEdge[i])
        }

        // Round end cap at the start
        if let firstPoint = points.first {
            let startWidth = brush.effectiveWidth(force: firstPoint.force, altitude: firstPoint.altitude)
            var capRadius = startWidth / 2
            if brush.taperIn > 0 { capRadius = 0.1 }
            addRoundCap(to: path, center: firstPoint.position, radius: capRadius,
                        from: rightEdge[0], to: leftEdge[0])
        }

        path.closeSubpath()
        return path
    }

    // MARK: - Single Point

    /// For a single point (tap), draw a circle.
    private static func singlePointPath(points: [StrokePoint], brush: BrushConfig) -> CGPath {
        let path = CGMutablePath()
        guard let point = points.first else { return path }
        let width = brush.effectiveWidth(force: point.force, altitude: point.altitude)
        let rect = CGRect(
            x: point.position.x - width / 2,
            y: point.position.y - width / 2,
            width: width,
            height: width
        )
        path.addEllipse(in: rect)
        return path
    }

    // MARK: - Direction

    /// Compute the normalized stroke direction at a given index.
    /// Uses central difference for interior points, forward/backward for endpoints.
    private static func strokeDirection(at index: Int, in points: [StrokePoint]) -> CGPoint {
        let prev: CGPoint
        let next: CGPoint

        if index == 0 {
            prev = points[0].position
            next = points[1].position
        } else if index == points.count - 1 {
            prev = points[index - 1].position
            next = points[index].position
        } else {
            prev = points[index - 1].position
            next = points[index + 1].position
        }

        let dx = next.x - prev.x
        let dy = next.y - prev.y
        let length = hypot(dx, dy)

        guard length > 0.001 else {
            return CGPoint(x: 1, y: 0) // Default direction for zero-length segments
        }

        return CGPoint(x: dx / length, y: dy / length)
    }

    // MARK: - Round Cap

    /// Add a semicircular end cap to the path.
    private static func addRoundCap(
        to path: CGMutablePath,
        center: CGPoint,
        radius: CGFloat,
        from startPoint: CGPoint,
        to endPoint: CGPoint
    ) {
        let startAngle = atan2(startPoint.y - center.y, startPoint.x - center.x)
        let endAngle = atan2(endPoint.y - center.y, endPoint.x - center.x)
        path.addArc(center: center, radius: radius,
                    startAngle: startAngle, endAngle: endAngle, clockwise: false)
    }
}

import Foundation
import CoreGraphics

/// Smooths raw Apple Pencil input points for cleaner stroke rendering.
///
/// Uses a moving-average filter to reduce jitter and Catmull-Rom interpolation
/// to add intermediate points between sparse touch samples.
enum StrokeSmoother {

    // MARK: - Streamline (EMA)

    /// Exponential moving average for path stabilization.
    /// `strength` 0 = raw input, 1 = maximum smoothing (heavy lag).
    static func applyStreamline(_ points: [StrokePoint], strength: CGFloat) -> [StrokePoint] {
        guard points.count > 1, strength > 0.01 else { return points }
        var result = points
        for i in 1..<points.count {
            let prev = result[i - 1].position
            let curr = points[i].position
            result[i].position = CGPoint(
                x: prev.x * strength + curr.x * (1 - strength),
                y: prev.y * strength + curr.y * (1 - strength)
            )
        }
        return result
    }

    // MARK: - Moving Average

    /// Smooth positions using a simple moving-average filter.
    /// `windowSize` is the number of trailing points to average (minimum 1).
    static func smooth(_ points: [StrokePoint], windowSize: Int = 3) -> [StrokePoint] {
        guard points.count > 1, windowSize > 1 else { return points }
        var result = points
        for i in 0..<points.count {
            let start = max(0, i - windowSize + 1)
            let window = points[start...i]
            let count = CGFloat(window.count)
            var sumX: CGFloat = 0
            var sumY: CGFloat = 0
            for p in window {
                sumX += p.position.x
                sumY += p.position.y
            }
            result[i].position = CGPoint(x: sumX / count, y: sumY / count)
        }
        return result
    }

    // MARK: - Catmull-Rom Interpolation

    /// Interpolate between points using Catmull-Rom splines to fill gaps.
    /// `segmentsPerInterval` controls how many intermediate points are inserted between each pair.
    static func interpolate(_ points: [StrokePoint], segmentsPerInterval: Int = 3) -> [StrokePoint] {
        guard points.count >= 2 else { return points }
        var result: [StrokePoint] = []

        for i in 0..<(points.count - 1) {
            let p0 = points[max(0, i - 1)]
            let p1 = points[i]
            let p2 = points[min(points.count - 1, i + 1)]
            let p3 = points[min(points.count - 1, i + 2)]

            result.append(p1)

            for s in 1..<segmentsPerInterval {
                let t = CGFloat(s) / CGFloat(segmentsPerInterval)
                let position = catmullRomPoint(
                    p0: p0.position, p1: p1.position,
                    p2: p2.position, p3: p3.position, t: t
                )
                let force = lerp(p1.force, p2.force, t: t)
                let altitude = lerp(p1.altitude, p2.altitude, t: t)
                let timestamp = lerp(p1.timestamp, p2.timestamp, t: t)

                result.append(StrokePoint(
                    position: position,
                    force: force,
                    altitude: altitude,
                    timestamp: timestamp
                ))
            }
        }

        // Add the last point
        if let last = points.last {
            result.append(last)
        }

        return result
    }

    // MARK: - Private Helpers

    private static func catmullRomPoint(
        p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint, t: CGFloat
    ) -> CGPoint {
        let t2 = t * t
        let t3 = t2 * t

        let x = 0.5 * (
            (2 * p1.x) +
            (-p0.x + p2.x) * t +
            (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2 +
            (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
        )
        let y = 0.5 * (
            (2 * p1.y) +
            (-p0.y + p2.y) * t +
            (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2 +
            (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
        )

        return CGPoint(x: x, y: y)
    }

    private static func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * t
    }

    private static func lerp(_ a: TimeInterval, _ b: TimeInterval, t: CGFloat) -> TimeInterval {
        a + (b - a) * Double(t)
    }
}

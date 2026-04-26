import CoreGraphics
import Foundation

/// Preprocessing pipeline: dedupe → arc-length resample → smooth → trim hooks.
/// Operates in canvas space (pt). Stateless — fed the raw point array, returns
/// a clean `[CGPoint]` ready for feature extraction and fitting.
enum Preprocessing {

    // MARK: - Public

    /// Run the full preprocessing pipeline.
    ///
    /// `rawPoints` is the input from the recognizer's accumulation buffer
    /// (positions only, in canvas space). Returns the classification copy
    /// and the bounding-box diagonal used to derive resample spacing.
    /// Returns nil if the input is degenerate (< 2 unique points).
    static func process(
        _ rawPoints: [CGPoint],
        seeds: RecognizerSeeds
    ) -> (classification: [CGPoint], bboxDiagonal: CGFloat)? {
        let deduped = dedupe(rawPoints, minDistance: seeds.dedupeMinDistance)
        guard deduped.count >= 2 else { return nil }

        let bbox = boundingBoxDiagonal(deduped)
        guard bbox > 0 else { return nil }

        let spacing = max(bbox * seeds.targetSpacingFraction, seeds.minTargetSpacing)
        let resampled = arcLengthResample(deduped, spacing: spacing)
        guard resampled.count >= 2 else { return nil }

        let smoothed = movingAverage(resampled, windowRadius: seeds.smoothingWindow / 2)
        let trimmed = trimEndpointHooks(
            smoothed,
            angleDeg: seeds.endpointTrimAngleDeg,
            lengthRatio: seeds.endpointTrimLengthRatio
        )
        return (trimmed, bbox)
    }

    // MARK: - Stages

    /// Drop consecutive points within `minDistance` of each other. Prevents
    /// divide-by-zero in tangent computation; rare but happens on stationary
    /// coalesced touches.
    static func dedupe(_ points: [CGPoint], minDistance: CGFloat) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result: [CGPoint] = [first]
        result.reserveCapacity(points.count)
        let minSq = minDistance * minDistance
        for i in 1..<points.count {
            let p = points[i]
            let prev = result[result.count - 1]
            let dx = p.x - prev.x
            let dy = p.y - prev.y
            if dx * dx + dy * dy >= minSq {
                result.append(p)
            }
        }
        return result
    }

    /// Bounding-box diagonal length.
    static func boundingBoxDiagonal(_ points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return 0 }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            if p.x < minX { minX = p.x } else if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y } else if p.y > maxY { maxY = p.y }
        }
        let dx = maxX - minX
        let dy = maxY - minY
        return sqrt(dx * dx + dy * dy)
    }

    /// Total path length (sum of segment distances).
    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            let dx = points[i].x - points[i - 1].x
            let dy = points[i].y - points[i - 1].y
            total += sqrt(dx * dx + dy * dy)
        }
        return total
    }

    /// Arc-length resample: walk the input path and emit a new point every
    /// `spacing` units. The first input point is always emitted; the last
    /// is appended verbatim if it isn't already the final emitted point.
    static func arcLengthResample(_ points: [CGPoint], spacing: CGFloat) -> [CGPoint] {
        guard points.count >= 2, spacing > 0 else { return points }
        var result: [CGPoint] = [points[0]]
        var distanceSinceLast: CGFloat = 0
        var prev = points[0]

        for i in 1..<points.count {
            let curr = points[i]
            var segDx = curr.x - prev.x
            var segDy = curr.y - prev.y
            var segLen = sqrt(segDx * segDx + segDy * segDy)

            // Walk along this segment, dropping samples at fixed `spacing`.
            while distanceSinceLast + segLen >= spacing && segLen > 0 {
                let needed = spacing - distanceSinceLast
                let t = needed / segLen
                let nx = prev.x + segDx * t
                let ny = prev.y + segDy * t
                let newPoint = CGPoint(x: nx, y: ny)
                result.append(newPoint)
                prev = newPoint
                segDx = curr.x - prev.x
                segDy = curr.y - prev.y
                segLen = sqrt(segDx * segDx + segDy * segDy)
                distanceSinceLast = 0
            }

            distanceSinceLast += segLen
            prev = curr
        }

        // Append the final raw endpoint if we haven't already emitted it.
        if let last = result.last, points.last != last {
            result.append(points.last!)
        }
        return result
    }

    /// Centered moving average. Endpoints kept verbatim (no smoothing on
    /// first/last sample). `windowRadius = 2` gives a 5-tap filter.
    static func movingAverage(_ points: [CGPoint], windowRadius w: Int) -> [CGPoint] {
        guard w > 0, points.count > 2 * w else { return points }
        var result = points
        for i in w..<(points.count - w) {
            var sumX: CGFloat = 0
            var sumY: CGFloat = 0
            for j in (i - w)...(i + w) {
                sumX += points[j].x
                sumY += points[j].y
            }
            let count = CGFloat(2 * w + 1)
            result[i] = CGPoint(x: sumX / count, y: sumY / count)
        }
        return result
    }

    /// Endpoint hook trim: drop a 1–3 sample tail on either end if the local
    /// turn exceeds `angleDeg` and the tail is shorter than `lengthRatio` of
    /// the total path. Apple Pencil strokes commonly have a small "drag" at
    /// lift-off; the leading-end mirror handles tap-down jitter.
    static func trimEndpointHooks(
        _ points: [CGPoint],
        angleDeg: CGFloat,
        lengthRatio: CGFloat
    ) -> [CGPoint] {
        guard points.count >= 8 else { return points }
        let total = pathLength(points)
        guard total > 0 else { return points }
        let maxTailLength = total * lengthRatio
        let angleThreshold = angleDeg * .pi / 180

        var startIdx = 0
        var endIdx = points.count - 1

        // Trailing trim: examine last 3 samples relative to the prior tangent.
        if let n = trailingHookCount(points, maxTailLength: maxTailLength, angleThreshold: angleThreshold) {
            endIdx = max(startIdx, points.count - 1 - n)
        }
        // Leading trim: mirror.
        if let n = leadingHookCount(points, maxTailLength: maxTailLength, angleThreshold: angleThreshold) {
            startIdx = min(endIdx, n)
        }

        if startIdx == 0 && endIdx == points.count - 1 { return points }
        return Array(points[startIdx...endIdx])
    }

    // MARK: - Hook detection helpers

    private static func trailingHookCount(
        _ points: [CGPoint],
        maxTailLength: CGFloat,
        angleThreshold: CGFloat
    ) -> Int? {
        let n = points.count
        // Need a "prior tangent" — use the segment from points[n-5] to points[n-4].
        guard n >= 8 else { return nil }
        let prior = unitVector(from: points[n - 5], to: points[n - 4])
        guard let prior = prior else { return nil }

        var tailLength: CGFloat = 0
        var cumulativeTurn: CGFloat = 0
        var prevTangent = prior

        // Walk the last 3 segments, accumulating turn and length.
        for i in (n - 3)..<n {
            guard let tangent = unitVector(from: points[i - 1], to: points[i]) else { continue }
            cumulativeTurn += abs(signedAngle(from: prevTangent, to: tangent))
            tailLength += distance(points[i - 1], points[i])
            prevTangent = tangent
        }

        if cumulativeTurn > angleThreshold && tailLength < maxTailLength {
            return 3
        }
        return nil
    }

    private static func leadingHookCount(
        _ points: [CGPoint],
        maxTailLength: CGFloat,
        angleThreshold: CGFloat
    ) -> Int? {
        let n = points.count
        guard n >= 8 else { return nil }
        // "Next tangent" — use segment from points[3] to points[4].
        guard let next = unitVector(from: points[3], to: points[4]) else { return nil }

        var tailLength: CGFloat = 0
        var cumulativeTurn: CGFloat = 0
        var prevTangent = next

        // Walk the first 3 segments backward.
        for i in stride(from: 3, to: 0, by: -1) {
            guard let tangent = unitVector(from: points[i], to: points[i - 1]) else { continue }
            // Reverse tangent to match stroke direction
            let forward = CGVector(dx: -tangent.dx, dy: -tangent.dy)
            cumulativeTurn += abs(signedAngle(from: forward, to: prevTangent))
            tailLength += distance(points[i - 1], points[i])
            prevTangent = forward
        }

        if cumulativeTurn > angleThreshold && tailLength < maxTailLength {
            return 3
        }
        return nil
    }

    // MARK: - Vector helpers

    private static func unitVector(from a: CGPoint, to b: CGPoint) -> CGVector? {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len = sqrt(dx * dx + dy * dy)
        guard len > 1e-9 else { return nil }
        return CGVector(dx: dx / len, dy: dy / len)
    }

    private static func signedAngle(from a: CGVector, to b: CGVector) -> CGFloat {
        let cross = a.dx * b.dy - a.dy * b.dx
        let dot = a.dx * b.dx + a.dy * b.dy
        return atan2(cross, dot)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        return sqrt(dx * dx + dy * dy)
    }
}

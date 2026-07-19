import Accelerate
import CoreGraphics
import Foundation

/// Raster-mask → vector-path utilities for the magic wand.
///
/// The wand's SAM masks are 256² logit grids; the lasso clip machinery
/// (`setClipPath` + CPU `CGPath.contains` stamp tests + marching-ants layers)
/// wants a CGPath. This bridges the two: bilinear-upsample the logits, threshold
/// to a binary bitmap, union multiple object bitmaps, then trace the boundary
/// with marching squares and simplify. Disjoint objects become separate
/// subpaths; negative-point holes come out as inner contours — both behave
/// correctly under the even-odd contains rule.
///
/// UIKit-free (Accelerate + CoreGraphics only) so it compiles in the macOS
/// offline harness.
public enum MaskContour {

    /// Bilinear-upsample `logits` (w×h) to `side`×`side` and threshold at 0
    /// (SAM convention: positive logit = inside). Returns a binary bitmap
    /// (0 / 1 bytes, row-major, side²).
    public static func binaryMask(
        fromLogits logits: [Float], width: Int, height: Int, upsampledSide side: Int
    ) -> [UInt8] {
        var src = logits
        var upsampled = [Float](repeating: 0, count: side * side)
        src.withUnsafeMutableBufferPointer { srcBuf in
            upsampled.withUnsafeMutableBufferPointer { dstBuf in
                var srcVB = vImage_Buffer(
                    data: srcBuf.baseAddress!, height: vImagePixelCount(height),
                    width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
                var dstVB = vImage_Buffer(
                    data: dstBuf.baseAddress!, height: vImagePixelCount(side),
                    width: vImagePixelCount(side), rowBytes: side * MemoryLayout<Float>.stride)
                vImageScale_PlanarF(&srcVB, &dstVB, nil, vImage_Flags(kvImageNoFlags))
            }
        }
        var binary = [UInt8](repeating: 0, count: side * side)
        for i in 0..<(side * side) where upsampled[i] > 0 { binary[i] = 1 }
        return binary
    }

    /// Element-wise union (max) of two same-size binary bitmaps, in place.
    public static func union(_ a: inout [UInt8], with b: [UInt8]) {
        precondition(a.count == b.count)
        for i in 0..<a.count where b[i] != 0 { a[i] = 1 }
    }

    public static func isEmpty(_ mask: [UInt8]) -> Bool {
        !mask.contains(where: { $0 != 0 })
    }

    /// Keep only the 4-connected component containing `seed` ("Contiguous"
    /// mode). If the seed pixel is outside the mask, searches a small
    /// neighborhood for the nearest inside pixel (taps often land a hair off
    /// the decoded mask edge); if none is found the mask is returned unchanged.
    public static func connectedComponent(
        of mask: [UInt8], side: Int, seedX: Int, seedY: Int
    ) -> [UInt8] {
        var sx = min(max(seedX, 0), side - 1)
        var sy = min(max(seedY, 0), side - 1)
        if mask[sy * side + sx] == 0 {
            var found = false
            search: for r in 1...8 {
                for dy in -r...r {
                    for dx in -r...r where abs(dx) == r || abs(dy) == r {
                        let x = sx + dx, y = sy + dy
                        guard x >= 0, x < side, y >= 0, y < side else { continue }
                        if mask[y * side + x] != 0 { sx = x; sy = y; found = true; break search }
                    }
                }
            }
            guard found else { return mask }
        }

        var out = [UInt8](repeating: 0, count: mask.count)
        var stack: [Int32] = [Int32(sy * side + sx)]
        out[sy * side + sx] = 1
        while let idx32 = stack.popLast() {
            let idx = Int(idx32)
            let x = idx % side, y = idx / side
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                guard nx >= 0, nx < side, ny >= 0, ny < side else { continue }
                let n = ny * side + nx
                if mask[n] != 0 && out[n] == 0 {
                    out[n] = 1
                    stack.append(Int32(n))
                }
            }
        }
        return out
    }

    /// Morphological expand (`radius` > 0) / contract (`radius` < 0) of the
    /// binary mask, in mask pixels. Separable 1-D passes (horizontal then
    /// vertical per step) give a diamond-ish structuring element — visually
    /// fine for a selection grow/shrink, and O(radius·side²).
    public static func expand(_ mask: [UInt8], side: Int, by radius: Int) -> [UInt8] {
        guard radius != 0, !mask.isEmpty else { return mask }
        var current = mask
        let steps = abs(radius)
        let dilating = radius > 0
        var next = [UInt8](repeating: 0, count: current.count)
        for _ in 0..<steps {
            for y in 0..<side {
                let row = y * side
                for x in 0..<side {
                    let i = row + x
                    let c = current[i]
                    let l = x > 0 ? current[i - 1] : 0
                    let r = x < side - 1 ? current[i + 1] : 0
                    let u = y > 0 ? current[i - side] : 0
                    let d = y < side - 1 ? current[i + side] : 0
                    if dilating {
                        next[i] = (c | l | r | u | d) != 0 ? 1 : 0
                    } else {
                        next[i] = (c & l & r & u & d) != 0 ? 1 : 0
                    }
                }
            }
            swap(&current, &next)
        }
        return current
    }

    /// Trace all boundary contours of a binary bitmap (side²) via marching
    /// squares, simplify with Douglas-Peucker (`tolerance` in mask pixels), and
    /// return a closed multi-subpath CGPath in NORMALIZED [0,1]² coordinates
    /// (scale to view/canvas space with a transform). Returns nil for an empty
    /// mask. Use the even-odd rule for containment — holes are inner subpaths.
    public static func path(
        fromBinary mask: [UInt8], side: Int, simplifyTolerance: CGFloat = 1.25
    ) -> CGPath? {
        let loops = traceLoops(mask: mask, side: side)
        guard !loops.isEmpty else { return nil }

        let path = CGMutablePath()
        let inv = 1.0 / CGFloat(side)
        for loop in loops {
            let simplified = simplify(loop, tolerance: simplifyTolerance)
            guard simplified.count >= 3 else { continue }
            path.move(to: CGPoint(x: simplified[0].x * inv, y: simplified[0].y * inv))
            for p in simplified.dropFirst() {
                path.addLine(to: CGPoint(x: p.x * inv, y: p.y * inv))
            }
            path.closeSubpath()
        }
        return path.isEmpty ? nil : path
    }

    // MARK: - Marching squares

    /// Contour points live on the half-integer edge-midpoint lattice; keys
    /// quantize by ×2 so they hash exactly.
    private struct EdgeKey: Hashable {
        let x2: Int32
        let y2: Int32
        init(_ p: CGPoint) {
            x2 = Int32((p.x * 2).rounded())
            y2 = Int32((p.y * 2).rounded())
        }
    }

    private static func traceLoops(mask: [UInt8], side: Int) -> [[CGPoint]] {
        // Undirected segments between crossed cell-edge midpoints. With saddles
        // resolved consistently every endpoint has degree exactly 2, so greedy
        // endpoint-linking recovers closed loops without needing orientation
        // (containment uses even-odd, which ignores winding).
        var segments: [(a: CGPoint, b: CGPoint)] = []

        mask.withUnsafeBufferPointer { m in
            @inline(__always) func value(_ x: Int, _ y: Int) -> Int {
                guard x >= 0, x < side, y >= 0, y < side else { return 0 }
                return Int(m[y * side + x])
            }

            // Cells span corners (x,y)..(x+1,y+1); iterate one beyond each border
            // so contours close around content touching the bitmap edge.
            for y in -1..<side {
                for x in -1..<side {
                    let tl = value(x, y), tr = value(x + 1, y)
                    let bl = value(x, y + 1), br = value(x + 1, y + 1)
                    let c = tl << 3 | tr << 2 | br << 1 | bl
                    guard c != 0, c != 15 else { continue }

                    let fx = CGFloat(x), fy = CGFloat(y)
                    let top = CGPoint(x: fx + 0.5, y: fy)
                    let right = CGPoint(x: fx + 1, y: fy + 0.5)
                    let bottom = CGPoint(x: fx + 0.5, y: fy + 1)
                    let left = CGPoint(x: fx, y: fy + 0.5)

                    switch c {
                    case 1, 14: segments.append((left, bottom))
                    case 2, 13: segments.append((bottom, right))
                    case 3, 12: segments.append((left, right))
                    case 4, 11: segments.append((top, right))
                    case 6, 9: segments.append((top, bottom))
                    case 7, 8: segments.append((top, left))
                    case 5: segments.append((top, left)); segments.append((bottom, right))
                    case 10: segments.append((top, right)); segments.append((bottom, left))
                    default: break
                    }
                }
            }
        }

        // Endpoint → indices of incident segments (each endpoint has degree 2).
        var adjacency = [EdgeKey: [Int]](minimumCapacity: segments.count * 2)
        for (idx, seg) in segments.enumerated() {
            adjacency[EdgeKey(seg.a), default: []].append(idx)
            adjacency[EdgeKey(seg.b), default: []].append(idx)
        }

        var visited = [Bool](repeating: false, count: segments.count)
        var loops: [[CGPoint]] = []

        for start in segments.indices where !visited[start] {
            visited[start] = true
            let seg = segments[start]
            var loop: [CGPoint] = [seg.a, seg.b]
            var currentKey = EdgeKey(seg.b)
            let startKey = EdgeKey(seg.a)

            while currentKey != startKey {
                guard let nextIdx = adjacency[currentKey]?.first(where: { !visited[$0] }) else {
                    break // open chain — shouldn't happen, but never loop forever
                }
                visited[nextIdx] = true
                let next = segments[nextIdx]
                let nextPoint = EdgeKey(next.a) == currentKey ? next.b : next.a
                loop.append(nextPoint)
                currentKey = EdgeKey(nextPoint)
            }

            // The walk appends the closing point equal to the start — drop it.
            if loop.count >= 4, EdgeKey(loop.last!) == startKey {
                loop.removeLast()
            }
            if loop.count >= 3 { loops.append(loop) }
        }
        return loops
    }

    // MARK: - Douglas-Peucker simplification

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 4, tolerance > 0 else { return points }
        var keep = [Bool](repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        simplifyRange(points, 0, points.count - 1, tolerance, &keep)
        return points.indices.compactMap { keep[$0] ? points[$0] : nil }
    }

    private static func simplifyRange(
        _ pts: [CGPoint], _ first: Int, _ last: Int, _ tol: CGFloat, _ keep: inout [Bool]
    ) {
        guard last > first + 1 else { return }
        let a = pts[first], b = pts[last]
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 1e-9)
        var maxDist: CGFloat = 0
        var maxIdx = first
        for i in (first + 1)..<last {
            let p = pts[i]
            let dist = abs(dy * p.x - dx * p.y + b.x * a.y - b.y * a.x) / len
            if dist > maxDist { maxDist = dist; maxIdx = i }
        }
        if maxDist > tol {
            keep[maxIdx] = true
            simplifyRange(pts, first, maxIdx, tol, &keep)
            simplifyRange(pts, maxIdx, last, tol, &keep)
        }
    }
}

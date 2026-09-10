import Foundation
import CoreGraphics

/// A rasterized clip region for the stamp walks (brush / eraser / wet).
///
/// The selection clip used to be tested per dab with `CGPath.contains(_:using:)`
/// against the live clip path. A magic-wand contour is a marching-squares polygon
/// with thousands of segments, so every dab cost O(segments) — and the dry brush
/// re-walked the whole stroke per touch event, so a long stroke inside a wand
/// selection went quadratic in path segments × dabs. This bakes the path ONCE
/// (even-odd, matching every other consumer of the selection) into a `side²`
/// bitmap over the space the path was authored in (view points), so the per-dab
/// test is one array read.
///
/// Pure Foundation + CoreGraphics — compiles into the BrushHarness / OfflineTests.
struct StampClip {
    /// Bitmap side (pixels). 2048 = the document resolution, so the clip is at
    /// least as fine as anything that can be painted through it.
    let side: Int
    /// The space (width × height, view points) the path was authored in.
    let space: CGSize
    private let bits: [UInt8]
    private let scaleX: CGFloat
    private let scaleY: CGFloat

    init?(path: CGPath, space: CGSize, side: Int = 2048) {
        guard space.width > 0, space.height > 0, side > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: side * side)
        var ok = false
        pixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(
                    data: base, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Y-flip: CGContext origin is bottom-left; the bitmap is top-left row order.
            ctx.translateBy(x: 0, y: CGFloat(side))
            ctx.scaleBy(x: CGFloat(side) / space.width, y: -CGFloat(side) / space.height)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(path)
            ctx.fillPath(using: .evenOdd)
            ok = true
        }
        guard ok else { return nil }
        self.side = side
        self.space = space
        self.bits = pixels
        self.scaleX = CGFloat(side) / space.width
        self.scaleY = CGFloat(side) / space.height
    }

    /// Direct bitmap construction (tests / synthetic clips). `bits` is `side²`
    /// top-left row order, nonzero = inside.
    init(bits: [UInt8], side: Int, space: CGSize) {
        precondition(bits.count == side * side)
        self.side = side
        self.space = space
        self.bits = bits
        self.scaleX = CGFloat(side) / max(space.width, 1)
        self.scaleY = CGFloat(side) / max(space.height, 1)
    }

    /// Is the point (in the path's own space) inside the clip? Points outside
    /// the authored space are outside the clip.
    @inline(__always)
    func contains(_ p: CGPoint) -> Bool {
        let x = Int(p.x * scaleX)
        let y = Int(p.y * scaleY)
        guard x >= 0, y >= 0, x < side, y < side else { return false }
        return bits[y * side + x] > 127
    }
}

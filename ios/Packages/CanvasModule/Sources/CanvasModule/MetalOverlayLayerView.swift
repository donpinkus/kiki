import UIKit
import Metal

/// A lightweight `CAMetalLayer`-backed view used as the overlay-stroke surface in
/// overlay drawing mode. It owns no render loop of its own — the `MetalCanvasView`'s
/// existing `CADisplayLink` composites the overlay-stroke texture into this layer's
/// drawable each tick (see `CanvasRenderer.renderOverlayFrame`). The view only:
///   - exposes its `CAMetalLayer` (configured with the shared device + `.bgra8Unorm_srgb`),
///   - keeps `drawableSize` tracking its on-screen size (like `MetalCanvasView`), and
///   - stays transparent so the opaque generated image below shows through except
///     where strokes have been drawn.
///
/// Same pixel format + transparency as `MetalCanvasView` so the overlay strokes match
/// the canvas's color pipeline exactly (Metal owns the sRGB↔linear gamma at the texture
/// boundary; the renderer feeds linear `s2l` premultiplied stamps).
final class MetalOverlayLayerView: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .clear
        isOpaque = false
        let metalLayer = self.metalLayer
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false           // transparent except where strokes paint
        metalLayer.maximumDrawableCount = 2
    }

    /// Attach the canvas's Metal device (idempotent). Must be set before the canvas
    /// requests a drawable from this layer.
    func configureDevice(_ device: MTLDevice) {
        if metalLayer.device == nil {
            metalLayer.device = device
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Drawable tracks the on-screen size, matching MetalCanvasView so the overlay
        // strokes register pixel-for-pixel with the canvas underneath.
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        let pixelW = Int(bounds.width * scale)
        let pixelH = Int(bounds.height * scale)
        if pixelW > 0, pixelH > 0 {
            metalLayer.drawableSize = CGSize(width: pixelW, height: pixelH)
        }
    }
}

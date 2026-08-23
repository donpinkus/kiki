import UIKit

/// Prepares an image for `POST /v1/lift3d` (fal Hunyuan). ONE place owns the
/// endpoint's input bounds — shared by the Extract screen and the object
/// drawer so the copies can't diverge again:
/// - fal rejects any side under 128 px ("Image resolution only support
///   [128, 5000]"). Small cutouts are upscaled to a 256 px short side; extreme
///   slivers whose long side would blow past the cap are PADDED up to 128
///   instead (scaling alone can't satisfy both bounds past ~31:1 aspect).
/// - long side capped at 4000 (margin under fal's 5000).
/// - composited on white: the canonical, lift-tested Hunyuan input (RGB, no
///   alpha surprises).
enum Lift3DUpload {
    /// Returns the upload PNG and its pixel size (for logging/analytics).
    static func preparePNG(from image: UIImage) -> (png: Data, pixelSize: CGSize)? {
        let w = max(image.size.width, 1)
        let h = max(image.size.height, 1)
        let minDim = min(w, h)
        let maxDim = max(w, h)
        let upscale = max(1, min(256 / minDim, 4000 / maxDim))
        let scaled = CGSize(width: (w * upscale).rounded(), height: (h * upscale).rounded())
        let canvas = CGSize(width: max(scaled.width, 128), height: max(scaled.height, 128))

        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let out = UIGraphicsImageRenderer(size: canvas, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: canvas))
            image.draw(in: CGRect(
                x: ((canvas.width - scaled.width) / 2).rounded(),
                y: ((canvas.height - scaled.height) / 2).rounded(),
                width: scaled.width, height: scaled.height
            ))
        }
        guard let png = out.pngData() else { return nil }
        return (png, canvas)
    }
}

import SwiftUI
import UIKit
import ResultModule

/// Geometry for the fullscreen floating result panel. Shared between the
/// visual rendering (in `DrawingView`) and the canvas container's hit-region
/// test, so the rect the canvas treats as "the panel" always matches what the
/// user sees. The panel sits at the top-trailing corner of the drawing pane
/// (inset by `edgeInset`), sized to the image's aspect ratio, then translated
/// by `offset` and uniformly scaled by `scale` about its center.
enum PanelLayout {
    /// Inset from the pane edges for the panel's default position. Must match
    /// the `.padding(...)` applied to the panel view in `DrawingView`.
    static let edgeInset: CGFloat = 16
    static let cornerRadius: CGFloat = 12

    /// The panel's unscaled size: the image fitted (aspect-preserved) into a
    /// fraction of the pane.
    static func baseSize(for image: UIImage, in pane: CGSize) -> CGSize {
        let maxW = pane.width * 0.42
        let maxH = pane.height * 0.55
        let aspect = image.size.width / max(image.size.height, 1)
        var w = maxW
        var h = w / max(aspect, 0.01)
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        return CGSize(width: max(w, 1), height: max(h, 1))
    }

    /// The panel's current on-screen rect in pane coordinates, accounting for
    /// the user's accumulated translation and scale. Mirrors the SwiftUI layout
    /// (`.scaleEffect` about center + `.offset`, positioned top-trailing inside
    /// the `edgeInset` padding).
    static func rect(for image: UIImage, in pane: CGSize, offset: CGSize, scale: CGFloat) -> CGRect {
        let base = baseSize(for: image, in: pane)
        let baseCenterX = pane.width - edgeInset - base.width / 2
        let baseCenterY = edgeInset + base.height / 2
        let centerX = baseCenterX + offset.width
        let centerY = baseCenterY + offset.height
        let w = base.width * scale
        let h = base.height * scale
        return CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h)
    }
}

/// Visual-only floating preview of the generated image. It never intercepts
/// touches (`allowsHitTesting(false)` is applied at the call site) — a single
/// finger / pencil draws straight through to the canvas, and two fingers over
/// it are handled by the canvas container, which moves/scales it via
/// `AppCoordinator.panelOffset` / `panelScale`. Renders the image only, with
/// rounded corners + a drop shadow so it reads as floating above the canvas.
struct FloatingResultPanel: View {
    let image: UIImage
    let baseSize: CGSize

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: baseSize.width, height: baseSize.height)
            .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }
}

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

/// The moving "transparency hole" punched into the panel around the pencil
/// while drawing. `center`/`radius` are in the panel's UNSCALED base coordinate
/// space (the `.scaleEffect` is applied on top by SwiftUI). `isActive` false
/// means no contact — the hole animates closed.
struct PanelHole {
    var center: CGPoint = .zero
    var radius: CGFloat = 0
    var isActive: Bool = false
}

/// Visual-only floating preview of the generated image. It never intercepts
/// touches (`allowsHitTesting(false)` is applied at the call site) — a single
/// finger / pencil draws straight through to the canvas, and two fingers over
/// it are handled by the canvas container, which moves/scales it via
/// `AppCoordinator.panelOffset` / `panelScale`. Renders the image only, with
/// rounded corners + a drop shadow so it reads as floating above the canvas.
///
/// While drawing, a soft radial transparency hole follows the pencil so the
/// user can see the canvas underneath. The hole state is read from the
/// coordinator HERE (not in `DrawingView`), so the 120 Hz contact updates only
/// re-render this leaf — never the whole drawing view.
struct FloatingResultPanel: View {
    @Environment(AppCoordinator.self) private var coordinator
    let image: UIImage
    let baseSize: CGSize

    var body: some View {
        let hole = coordinator.panelHole
        let radius = hole.isActive ? hole.radius : 0
        return Image(uiImage: image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: baseSize.width, height: baseSize.height)
            .clipShape(RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous))
            .mask(holeMask(center: hole.center, radius: radius))
            // Shadow is outside the mask so the floating drop shadow is preserved.
            .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }

    /// Opaque everywhere except a soft-edged circle at `center` (base coords),
    /// which is punched out via `.destinationOut`. The blur gives the feathered
    /// falloff. Radius 0 → no hole (fully opaque), so the panel is intact when
    /// not drawing and during the fade-closed.
    private func holeMask(center: CGPoint, radius: CGFloat) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
            Circle()
                .fill(Color.black)
                .frame(width: radius * 2, height: radius * 2)
                .blur(radius: max(radius * 0.5, 0.5))
                .position(center)
                .blendMode(.destinationOut)
        }
        .compositingGroup()
    }
}

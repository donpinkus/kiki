import SwiftUI

/// Procreate-style dark chrome palette (owner request 2026-07-16, sampled from
/// a Procreate screenshot). The drawing chrome is always dark regardless of
/// system appearance — like Procreate's — so these are fixed colors, not
/// semantic/adaptive ones. Canvas surround: dark gray backing with a slightly
/// lighter 1pt grid (the pattern itself lives in `RotatableCanvasContainer`,
/// which must stay UIKit/CanvasModule-local; keep the two in sync by eye).
enum KikiTheme {
    /// Near-black top toolbar (Procreate's bar reads ~#0D0D0D).
    static let barBackground = Color(white: 0.05)
    /// Dark circle behind toolbar buttons (~#1E1F20).
    static let buttonCircle = Color(white: 0.12)
    /// Default icon/text gray on dark chrome (~#C9CACC).
    static let icon = Color(white: 0.80)
    /// Dimmed icon (disabled / inactive tool).
    static let iconDim = Color(white: 0.38)
    /// Canvas surround backing (~#222) — mirrored by the UIKit grid pattern
    /// in RotatableCanvasContainer.
    static let canvasBacking = Color(white: 0.135)
    /// Left sidebar strip (slightly darker than the canvas backing).
    static let sidebarBackground = Color(white: 0.09)
    /// Slider track on dark chrome.
    static let sliderTrack = Color(white: 0.25)
    /// Slider fill / handle gray (the light-gray handles in Procreate's strip).
    static let sliderFill = Color(white: 0.72)

    /// Standard circular chrome button size.
    static let buttonDiameter: CGFloat = 36
}

import SwiftUI
import CanvasModule

/// The Brush Studio's interactive drawing pad: a bare `MetalCanvasView` (no rotate/zoom
/// container — a flat scratch surface) that always holds the live brush. Strokes persist
/// while knobs change (existing paint doesn't re-render — same as Procreate's pad), are
/// never saved, and feed the live-input marker so the Dynamics curves dance as you draw.
struct BrushTryPadView: UIViewRepresentable {
    let brush: BrushConfig
    /// Bump to wipe the pad.
    let clearToken: Int
    let onBrushInputSample: (BrushInputSample) -> Void
    let devMaxSpeed: Double
    let devDistancePeriod: Double
    let devFadePeriod: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var lastClearToken = 0
        var lastBrush: BrushConfig?
    }

    func makeUIView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView()
        view.backgroundColor = .white
        // Pad mode: keep raw stroke geometry so knob changes live re-render the paint
        // already down (Procreate behavior); no undo snapshots (Clear + re-render
        // replace them); no QuickShape (snapped geometry wouldn't survive re-render,
        // and shape-snapping isn't what a brush try pad is for).
        view.retainStrokeGeometry = true
        view.isUndoEnabled = false
        view.isQuickShapeEnabled = false
        context.coordinator.lastClearToken = clearToken
        apply(to: view, context.coordinator)
        return view
    }

    func updateUIView(_ view: MetalCanvasView, context: Context) {
        apply(to: view, context.coordinator)
        if context.coordinator.lastClearToken != clearToken {
            context.coordinator.lastClearToken = clearToken
            view.clearAll()
        }
    }

    private func apply(to view: MetalCanvasView, _ coordinator: Coordinator) {
        // Only push the tool when a knob actually changed — updateUIView can fire for
        // unrelated parent re-renders, and swapping the tool mid-stroke is not free.
        if coordinator.lastBrush != brush {
            coordinator.lastBrush = brush
            view.currentTool = .brush(brush)
            // Procreate behavior: knob changes re-paint the strokes already on the pad.
            view.setRetainedStrokesBrush(brush)
        }
        view.onBrushInputSample = onBrushInputSample
        view.devMaxSpeed = devMaxSpeed
        view.devDistancePeriod = devDistancePeriod
        view.devFadePeriod = devFadePeriod
    }
}

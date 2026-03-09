import SwiftUI
import PencilKit

/// A SwiftUI wrapper around PKCanvasView for Apple Pencil drawing.
public struct CanvasView: UIViewRepresentable {

    @Bindable var viewModel: CanvasViewModel

    public init(viewModel: CanvasViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        canvasView.drawingPolicy = .pencilOnly
        canvasView.tool = viewModel.currentTool
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
        canvasView.delegate = context.coordinator
        canvasView.drawing = viewModel.drawing
        viewModel.setUndoManager(canvasView.undoManager)
        return canvasView
    }

    public func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        // Guard against re-entrant updates from the delegate callback.
        // Only push drawing changes that originate from the view model (e.g. clear),
        // not ones echoed back from canvasViewDrawingDidChange.
        if context.coordinator.isUpdatingFromDelegate { return }

        if canvasView.drawing != viewModel.drawing {
            canvasView.drawing = viewModel.drawing
        }

        canvasView.tool = viewModel.currentTool
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, PKCanvasViewDelegate {
        let viewModel: CanvasViewModel
        var isUpdatingFromDelegate = false

        init(viewModel: CanvasViewModel) {
            self.viewModel = viewModel
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            isUpdatingFromDelegate = true
            viewModel.drawingDidChange(canvasView.drawing, canvasView: canvasView)
            isUpdatingFromDelegate = false
        }
    }
}

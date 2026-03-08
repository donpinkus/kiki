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
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 5)
        canvasView.backgroundColor = .white
        canvasView.isOpaque = true
        canvasView.delegate = context.coordinator
        canvasView.drawing = viewModel.drawing
        viewModel.setUndoManager(canvasView.undoManager)
        return canvasView
    }

    public func updateUIView(_ canvasView: PKCanvasView, context: Context) {
        if canvasView.drawing != viewModel.drawing {
            canvasView.drawing = viewModel.drawing
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, PKCanvasViewDelegate {
        let viewModel: CanvasViewModel

        init(viewModel: CanvasViewModel) {
            self.viewModel = viewModel
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            viewModel.drawingDidChange(canvasView.drawing, canvasView: canvasView)
        }
    }
}

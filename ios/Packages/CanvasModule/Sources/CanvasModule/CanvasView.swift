import SwiftUI
import PencilKit

public struct CanvasView: UIViewRepresentable {
    private let viewModel: CanvasViewModel

    public init(viewModel: CanvasViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> PKCanvasView {
        let canvasView = PKCanvasView()
        viewModel.attach(canvasView)
        canvasView.delegate = context.coordinator
        return canvasView
    }

    public func updateUIView(_ uiView: PKCanvasView, context: Context) {}

    public func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    public final class Coordinator: NSObject, PKCanvasViewDelegate {
        private let viewModel: CanvasViewModel

        init(viewModel: CanvasViewModel) {
            self.viewModel = viewModel
        }

        public func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            Task { @MainActor in
                viewModel.handleDrawingChanged()
            }
        }
    }
}

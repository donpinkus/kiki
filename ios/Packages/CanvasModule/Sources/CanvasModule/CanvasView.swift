import SwiftUI

public struct CanvasView: UIViewRepresentable {
    private let viewModel: CanvasViewModel

    public init(viewModel: CanvasViewModel) {
        self.viewModel = viewModel
    }

    public func makeUIView(context: Context) -> DrawingCanvasView {
        let canvasView = DrawingCanvasView()
        viewModel.attach(canvasView)
        return canvasView
    }

    public func updateUIView(_ uiView: DrawingCanvasView, context: Context) {}
}

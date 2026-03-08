import Testing
@testable import CanvasModule

@Suite("CanvasViewModel Tests")
struct CanvasViewModelTests {
    @Test func initialState() {
        let viewModel = CanvasViewModel()
        #expect(viewModel.canUndo == false)
        #expect(viewModel.canRedo == false)
    }
}

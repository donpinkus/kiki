import Testing
@testable import ResultModule

@Suite("ResultViewModel Tests")
struct ResultViewModelTests {
    @Test func initialStateIsEmpty() {
        let viewModel = ResultViewModel()
        #expect(viewModel.displayImage == nil)
        #expect(viewModel.isLoading == false)
    }
}

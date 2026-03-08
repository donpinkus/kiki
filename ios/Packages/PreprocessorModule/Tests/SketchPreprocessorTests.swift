import Testing
@testable import PreprocessorModule

@Suite("SketchPreprocessor Tests")
struct SketchPreprocessorTests {
    @Test func preprocessorInitializes() {
        let preprocessor = SketchPreprocessor()
        #expect(preprocessor != nil)
    }
}

import Testing
@testable import NetworkModule

@Suite("Network Models Tests")
struct NetworkModelsTests {
    @Test func generateRequestEncodes() throws {
        let request = GenerateRequest(
            sessionId: "test-session",
            requestId: "test-request",
            mode: .preview,
            sketchImageBase64: "base64data"
        )
        let data = try JSONEncoder().encode(request)
        #expect(data.count > 0)
    }
}

import Foundation

/// REST API client for communicating with the Kiki backend.
public actor APIClient {

    private let session: URLSession
    private let baseURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - Public API

    public func generate(_ request: GenerateRequest) async throws -> GenerateResponse {
        let urlRequest = try buildRequest(path: "/v1/generate", body: request)
        let (data, response) = try await session.data(for: urlRequest)
        try validateResponse(response)
        return try decoder.decode(GenerateResponse.self, from: data)
    }

    public func cancel(sessionId: String, requestId: String) async throws {
        let body = CancelRequest(sessionId: sessionId, requestId: requestId)
        let urlRequest = try buildRequest(path: "/v1/cancel", body: body)
        let (_, response) = try await session.data(for: urlRequest)
        try validateResponse(response)
    }

    // MARK: - Private

    private func buildRequest<T: Encodable>(path: String, body: T) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        return request
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw NetworkError.unauthorized
        case 429:
            throw NetworkError.rateLimited
        default:
            throw NetworkError.serverError(statusCode: httpResponse.statusCode)
        }
    }
}

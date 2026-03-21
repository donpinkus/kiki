import Foundation

/// REST client for communicating with the Kiki backend API.
public final class APIClient: Sendable {

    // MARK: - Properties

    private let baseURL: URL
    private let session: URLSession

    // MARK: - Lifecycle

    /// Creates a new API client.
    /// - Parameter baseURL: The base URL for the backend API (e.g. `https://api.kiki.app`).
    public init(baseURL: URL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public API

    /// Sends a generation request to the backend and returns the response.
    /// - Parameter request: The generation request containing sketch data and parameters.
    /// - Returns: The generation response with the result image URL and metadata.
    /// - Throws: `GenerationError` on failure.
    public func generate(_ request: GenerateRequest) async throws -> GenerateResponse {
        let url = baseURL.appendingPathComponent("v1/generate")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let encoder = JSONEncoder()
        do {
            urlRequest.httpBody = try encoder.encode(request)
        } catch {
            throw GenerationError.invalidRequest(message: "Failed to encode request")
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let urlError as URLError {
            switch urlError.code {
            case .timedOut:
                throw GenerationError.networkTimeout
            case .cancelled:
                throw GenerationError.cancelled
            default:
                throw GenerationError.networkTimeout
            }
        } catch {
            throw GenerationError.networkTimeout
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GenerationError.networkTimeout
        }

        switch httpResponse.statusCode {
        case 200:
            return try decodeSuccessResponse(from: data)

        case 400:
            let message = extractErrorMessage(from: data) ?? "Invalid request"
            throw GenerationError.invalidRequest(message: message)

        case 429:
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0) }
            throw GenerationError.rateLimited(retryAfter: retryAfter)

        default:
            let message = extractErrorMessage(from: data) ?? "Server error"
            throw GenerationError.serverError(
                statusCode: httpResponse.statusCode,
                message: message
            )
        }
    }

    /// Sends a cancellation request for an in-flight generation.
    /// - Parameters:
    ///   - sessionId: The session that owns the request.
    ///   - requestId: The request to cancel.
    public func cancel(sessionId: UUID, requestId: UUID) async throws {
        let url = baseURL.appendingPathComponent("v1/cancel")

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "sessionId": sessionId.uuidString,
            "requestId": requestId.uuidString
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw GenerationError.serverError(
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                message: "Cancel request failed"
            )
        }
    }

    // MARK: - Private

    private func decodeSuccessResponse(from data: Data) throws -> GenerateResponse {
        struct APIResponse: Decodable {
            let requestId: String
            let status: String
            let error: String?
            let imageUrl: String?
            let inputImageUrl: String?
            let lineartImageUrl: String?
            let seed: UInt64?
            let provider: String?
            let latencyMs: Int?
            let mode: String
        }

        let decoded: APIResponse
        do {
            let decoder = JSONDecoder()
            decoded = try decoder.decode(APIResponse.self, from: data)
        } catch {
            print("[APIClient] Decoding failed: \(error)")
            print("[APIClient] Raw response: \(String(data: data, encoding: .utf8) ?? "non-utf8")")
            throw GenerationError.decodingError
        }

        guard let requestUUID = UUID(uuidString: decoded.requestId) else {
            throw GenerationError.decodingError
        }

        guard let status = ResponseStatus(rawValue: decoded.status) else {
            throw GenerationError.decodingError
        }

        guard let mode = GenerationMode(rawValue: decoded.mode) else {
            throw GenerationError.decodingError
        }

        if status == .filtered {
            throw GenerationError.contentFiltered(categories: [])
        }

        if status == .error {
            let message = decoded.error ?? "Unknown server error"
            throw GenerationError.serverError(statusCode: 200, message: message)
        }

        let imageURL: URL?
        if let urlString = decoded.imageUrl {
            imageURL = URL(string: urlString)
        } else {
            imageURL = nil
        }

        let inputImageURL = decoded.inputImageUrl.flatMap { URL(string: $0) }
        let lineartImageURL = decoded.lineartImageUrl.flatMap { URL(string: $0) }

        // Extract workflow JSON as a pretty-printed string
        var workflowJSON: String?
        if let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let workflow = rawObject["workflow"] {
            if let workflowData = try? JSONSerialization.data(withJSONObject: workflow, options: .prettyPrinted) {
                workflowJSON = String(data: workflowData, encoding: .utf8)
            }
        }

        return GenerateResponse(
            requestId: requestUUID,
            status: status,
            imageURL: imageURL,
            inputImageURL: inputImageURL,
            lineartImageURL: lineartImageURL,
            seed: decoded.seed,
            provider: decoded.provider,
            latencyMs: decoded.latencyMs,
            mode: mode,
            workflowJSON: workflowJSON
        )
    }

    private func extractErrorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable {
            let message: String?
            let error: String?
        }
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data) else {
            return nil
        }
        return body.message ?? body.error
    }
}

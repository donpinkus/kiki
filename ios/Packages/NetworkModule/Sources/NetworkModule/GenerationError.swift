import Foundation

/// Errors that can occur during image generation requests.
public enum GenerationError: Error {
    case networkTimeout
    case serverError(statusCode: Int, message: String)
    case rateLimited(retryAfter: TimeInterval?)
    case contentFiltered(categories: [String])
    case invalidRequest(message: String)
    case cancelled
    case decodingError
}

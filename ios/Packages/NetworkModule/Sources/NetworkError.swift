import Foundation

public enum NetworkError: Error {
    case invalidResponse
    case unauthorized
    case rateLimited
    case serverError(statusCode: Int)
}

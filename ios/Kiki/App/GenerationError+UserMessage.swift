import NetworkModule

extension GenerationError {
    var userMessage: String {
        switch self {
        case .networkTimeout:
            return "Connection timed out"
        case .serverError(_, let message):
            return message
        case .rateLimited:
            return "Too many requests. Try again soon."
        case .contentFiltered:
            return "Content was filtered"
        case .invalidRequest(let message):
            return message
        case .cancelled:
            return "Generation cancelled"
        case .decodingError:
            return "Unexpected server response"
        }
    }
}

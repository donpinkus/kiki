import SwiftUI

@Observable
public final class ResultViewModel {

    // MARK: - Properties

    public private(set) var state: ResultState = .empty
    public private(set) var lastSuccessfulImage: UIImage?

    /// The image to display — always keeps the last successful image visible.
    public var displayImage: UIImage? {
        switch state {
        case .preview(let image), .refined(let image):
            return image
        case .empty, .generating, .refining, .error:
            return lastSuccessfulImage
        }
    }

    public var isLoading: Bool {
        switch state {
        case .generating, .refining: return true
        default: return false
        }
    }

    public var errorMessage: String? {
        if case .error(let message) = state {
            return message
        }
        return nil
    }

    // MARK: - Lifecycle

    public init() {}

    // MARK: - Public API

    public func setGenerating() {
        state = .generating
    }

    public func setRefining() {
        state = .refining
    }

    public func setPreviewImage(_ image: UIImage) {
        lastSuccessfulImage = image
        state = .preview(image)
    }

    public func setRefinedImage(_ image: UIImage) {
        lastSuccessfulImage = image
        state = .refined(image)
    }

    public func setError(_ message: String) {
        state = .error(message)
    }
}

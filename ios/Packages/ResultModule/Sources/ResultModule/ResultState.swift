import Foundation

/// Represents the current state of the result pane.
public enum ResultState {
    case empty
    case generating(previousImageURL: URL?)
    case preview(imageURL: URL)
    case error(message: String, previousImageURL: URL?)
}

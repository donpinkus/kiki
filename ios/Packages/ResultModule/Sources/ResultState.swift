import UIKit

/// The display state of the result pane.
public enum ResultState: Sendable {
    case empty
    case generating
    case preview(UIImage)
    case refining
    case refined(UIImage)
    case error(String)
}

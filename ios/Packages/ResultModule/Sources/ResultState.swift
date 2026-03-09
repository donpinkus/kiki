import UIKit

/// The display state of the result pane.
///
/// UIImage is thread-safe for read access once created, so we use @unchecked Sendable.
public enum ResultState: @unchecked Sendable {
    case empty
    case generating
    case preview(UIImage)
    case refining
    case refined(UIImage)
    case error(String)
}

import UIKit

/// A snapshot of the canvas at a point in time.
///
/// UIImage is thread-safe for read access once created, so we use @unchecked Sendable.
public struct SketchSnapshot: @unchecked Sendable {
    public let image: UIImage
    public let timestamp: Date
    public let strokeCount: Int

    public init(image: UIImage, timestamp: Date = .now, strokeCount: Int) {
        self.image = image
        self.timestamp = timestamp
        self.strokeCount = strokeCount
    }

    public var isEmpty: Bool {
        strokeCount == 0
    }
}

import UIKit

public struct SketchSnapshot: @unchecked Sendable {
    public let image: UIImage
    public let strokeCount: Int
    public let bounds: CGRect
    public let timestamp: Date

    public init(image: UIImage, strokeCount: Int, bounds: CGRect, timestamp: Date = Date()) {
        self.image = image
        self.strokeCount = strokeCount
        self.bounds = bounds
        self.timestamp = timestamp
    }

    public var isEmpty: Bool {
        strokeCount == 0
    }
}

import UIKit
import PencilKit

/// A snapshot of the canvas at a point in time.
public struct SketchSnapshot: Sendable {
    public let image: UIImage
    public let drawing: PKDrawing
    public let timestamp: Date
    public let strokeCount: Int

    public init(image: UIImage, drawing: PKDrawing, timestamp: Date = .now, strokeCount: Int) {
        self.image = image
        self.drawing = drawing
        self.timestamp = timestamp
        self.strokeCount = strokeCount
    }

    public var isEmpty: Bool {
        strokeCount == 0
    }
}

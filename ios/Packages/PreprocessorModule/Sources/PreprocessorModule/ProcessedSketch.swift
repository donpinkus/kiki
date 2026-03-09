import Foundation

public struct ProcessedSketch: Sendable {
    public let imageData: Data
    public let caption: String?
    public let originalBounds: CGRect

    public init(imageData: Data, caption: String? = nil, originalBounds: CGRect) {
        self.imageData = imageData
        self.caption = caption
        self.originalBounds = originalBounds
    }
}

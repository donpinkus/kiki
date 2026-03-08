import Foundation
import UIKit

/// The result of preprocessing a canvas snapshot for generation.
public struct ProcessedSketch: Sendable {
    public let imageData: Data
    public let base64Image: String
    public let caption: String?
    public let width: Int
    public let height: Int

    public init(imageData: Data, base64Image: String, caption: String?, width: Int, height: Int) {
        self.imageData = imageData
        self.base64Image = base64Image
        self.caption = caption
        self.width = width
        self.height = height
    }
}

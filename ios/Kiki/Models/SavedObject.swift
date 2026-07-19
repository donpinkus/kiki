import Foundation
import SwiftData
import UIKit

/// A reusable object lifted from a drawing (via the selection tools) into the
/// user's persistent object library — characters, props, houses, islands —
/// that can be dropped into any drawing as a movable/scalable paste float.
/// The image is a transparent-PNG cutout (selection-masked, cropped).
///
/// v1 is 2D drop-in reuse; identity conditioning (multi-reference klein) and
/// 3D lift/pose are later stages of the object-library roadmap.
@Model
final class SavedObject {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    /// Transparent PNG cutout.
    @Attribute(.externalStorage) var imageData: Data?
    /// Source size in 2048² document pixels — preserves the object's original
    /// scale when dropped into a drawing.
    var docWidth: Double
    var docHeight: Double

    init(name: String, imageData: Data, docWidth: Double, docHeight: Double) {
        self.id = UUID()
        self.name = name
        self.createdAt = Date()
        self.imageData = imageData
        self.docWidth = docWidth
        self.docHeight = docHeight
    }

    var image: UIImage? {
        imageData.flatMap { UIImage(data: $0) }
    }
}

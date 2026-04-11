import SwiftData
import SwiftUI

@Model
final class Drawing {

    // MARK: - Identity

    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Canvas State

    @Attribute(.externalStorage) var drawingData: Data?
    @Attribute(.externalStorage) var backgroundImageData: Data?

    // MARK: - Generation Results

    @Attribute(.externalStorage) var generatedImageData: Data?

    // MARK: - Thumbnail

    @Attribute(.externalStorage) var canvasThumbnailData: Data?

    // MARK: - Settings

    var promptText: String
    var stylePresetRawValue: String

    // MARK: - Init

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        promptText: String = "",
        stylePresetRawValue: String = PromptStyle.default.id
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.promptText = promptText
        self.stylePresetRawValue = stylePresetRawValue
    }
}

// MARK: - Computed Helpers

extension Drawing {

    var styleId: String {
        get { stylePresetRawValue }
        set { stylePresetRawValue = newValue }
    }

    var canvasThumbnail: UIImage? {
        guard let data = canvasThumbnailData else { return nil }
        return UIImage(data: data)
    }

    var generatedImage: UIImage? {
        guard let data = generatedImageData else { return nil }
        return UIImage(data: data)
    }

    /// True when the drawing has no meaningful content.
    var isContentEmpty: Bool {
        canvasThumbnailData == nil && promptText.isEmpty && generatedImageData == nil
    }
}

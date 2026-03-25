import SwiftData
import SwiftUI
import NetworkModule

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
    @Attribute(.externalStorage) var lineartImageData: Data?

    // MARK: - Thumbnail

    @Attribute(.externalStorage) var canvasThumbnailData: Data?

    // MARK: - Settings

    var promptText: String
    var stylePresetRawValue: String
    var advancedParametersJSON: Data?
    var isSeedLocked: Bool

    // MARK: - Init

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        promptText: String = "",
        stylePresetRawValue: String = StylePreset.photoreal.rawValue,
        isSeedLocked: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.promptText = promptText
        self.stylePresetRawValue = stylePresetRawValue
        self.isSeedLocked = isSeedLocked
    }
}

// MARK: - Computed Helpers

extension Drawing {

    var stylePreset: StylePreset {
        get { StylePreset(rawValue: stylePresetRawValue) ?? .photoreal }
        set { stylePresetRawValue = newValue.rawValue }
    }

    var advancedParameters: AdvancedParameters {
        get {
            guard let data = advancedParametersJSON else { return AdvancedParameters() }
            return (try? JSONDecoder().decode(AdvancedParameters.self, from: data)) ?? AdvancedParameters()
        }
        set {
            advancedParametersJSON = try? JSONEncoder().encode(newValue)
        }
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
    /// Uses canvasThumbnailData as the canvas indicator because PKDrawing.dataRepresentation()
    /// returns non-empty data even for an empty canvas (format header bytes).
    var isContentEmpty: Bool {
        canvasThumbnailData == nil && promptText.isEmpty && generatedImageData == nil
    }
}

import Foundation

public extension SAM2Segmenter {
    /// Load the bundled SAM 2.1-small models (pre-compiled .mlmodelc under
    /// Resources/SAM2 — see `ios/scripts/fetch-sam-models.sh` for provenance:
    /// apple/coreml-sam2.1-small on Hugging Face, Apache 2.0).
    static func bundled() throws -> SAM2Segmenter {
        func url(_ name: String) throws -> URL {
            guard let u = Bundle.module.url(
                forResource: name, withExtension: "mlmodelc", subdirectory: "SAM2") else {
                throw WandError.modelMissing(name)
            }
            return u
        }
        return try SAM2Segmenter(
            imageEncoderURL: url("SAM2_1SmallImageEncoderFLOAT16"),
            promptEncoderURL: url("SAM2_1SmallPromptEncoderFLOAT16"),
            maskDecoderURL: url("SAM2_1SmallMaskDecoderFLOAT16"))
    }
}

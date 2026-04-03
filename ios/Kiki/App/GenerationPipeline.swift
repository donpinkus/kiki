import UIKit
import CanvasModule
import NetworkModule
import ResultModule

@MainActor
final class GenerationPipeline {

    struct Input {
        let sessionId: UUID
        let requestId: UUID
        let canvasViewModel: CanvasViewModel
        let prompt: String?
        let advancedParameters: AdvancedParameters?
        let isSeedLocked: Bool
        let compareWithoutControlNet: Bool
    }

    struct Output {
        let image: UIImage
        let seed: UInt64?
        let generatedLineartImage: UIImage?
        let comparisonData: ComparisonData?
        let comparisonError: String?
    }

    private let apiClient: APIClient

    init(apiClient: APIClient) {
        self.apiClient = apiClient
    }

    /// Runs the full generation pipeline: snapshot → JPEG → API → image download.
    ///
    /// Reports progress via `onPhase`. Returns the generated image on success.
    /// Throws on any failure. Respects Task cancellation at each phase boundary.
    /// Returns `nil` if the canvas is empty (no generation needed).
    func run(
        input: Input,
        onPhase: @escaping (GenerationPhase, [GenerationPhase: TimeInterval]) -> Void
    ) async throws -> Output? {
        var durations: [GenerationPhase: TimeInterval] = [:]
        var phaseStart = Date()

        // Phase: preparing (snapshot + JPEG encoding)
        onPhase(.preparing, durations)

        guard let snapshot = input.canvasViewModel.captureSnapshot(),
              !snapshot.isEmpty else {
            return nil
        }

        guard let jpegData = snapshot.image.jpegData(compressionQuality: 0.85) else {
            throw PipelineError.jpegEncodingFailed
        }
        print("[Generate] JPEG: \(jpegData.count) bytes, image: \(snapshot.image.size)")

        try Task.checkCancellation()

        // Phase: uploading (network round-trip)
        durations[.preparing] = Date().timeIntervalSince(phaseStart)
        phaseStart = Date()
        onPhase(.uploading, durations)

        let request = GenerateRequest(
            sessionId: input.sessionId,
            requestId: input.requestId,
            mode: .preview,
            prompt: input.prompt,
            sketchImageBase64: jpegData.base64EncodedString(),
            advancedParameters: input.advancedParameters,
            compareWithoutControlNet: input.compareWithoutControlNet ? true : nil
        )

        let response = try await apiClient.generate(request)
        print("[Generate] Response: status=\(response.status), imageURL=\(response.imageURL?.absoluteString ?? "nil")")
        print("[Generate] lineartImageURL: \(response.lineartImageURL?.absoluteString ?? "nil")")
        print("[Generate] generatedLineartImageURL: \(response.generatedLineartImageURL?.absoluteString ?? "nil")")

        try Task.checkCancellation()

        guard response.status == .completed, let imageURL = response.imageURL else {
            throw PipelineError.generationFailed(
                status: "\(response.status)",
                imageURL: response.imageURL?.absoluteString
            )
        }

        let seed: UInt64? = input.isSeedLocked ? response.seed : nil

        // Phase: downloading
        durations[.uploading] = Date().timeIntervalSince(phaseStart)
        phaseStart = Date()
        onPhase(.downloading, durations)

        let (data, _) = try await URLSession.shared.data(from: imageURL)
        guard let mainImage = UIImage(data: data) else {
            throw PipelineError.imageDecodeFailed(
                byteCount: data.count,
                url: imageURL.lastPathComponent
            )
        }

        try Task.checkCancellation()

        // Download generated lineart — we always expect this from our API
        var generatedLineartImage: UIImage?
        if let generatedLineartURL = response.generatedLineartImageURL {
            do {
                let (lineartData, _) = try await URLSession.shared.data(from: generatedLineartURL)
                if let img = UIImage(data: lineartData) {
                    generatedLineartImage = img
                    print("[Generate] Generated lineart downloaded: \(img.size)")
                } else {
                    print("[Generate] ERROR: Generated lineart data (\(lineartData.count) bytes) could not be decoded to UIImage")
                }
            } catch {
                print("[Generate] ERROR: Generated lineart download failed: \(error.localizedDescription)")
            }
        } else {
            print("[Generate] ERROR: No generatedLineartImageURL in response — expected lineart from API")
        }

        // Comparison downloads (best-effort — never fails the primary generation)
        var comparisonData: ComparisonData?
        var comparisonError: String?

        if input.compareWithoutControlNet {
            if let backendError = response.comparisonError, response.comparisonImageURL == nil {
                comparisonError = backendError
            } else if let lineartURL = response.lineartImageURL,
                      let comparisonURL = response.comparisonImageURL {
                do {
                    async let lineartDownload = URLSession.shared.data(from: lineartURL)
                    async let compDownload = URLSession.shared.data(from: comparisonURL)
                    let (lineartData, _) = try await lineartDownload
                    let (compData, _) = try await compDownload
                    guard let lineartImage = UIImage(data: lineartData) else {
                        throw PipelineError.imageDecodeFailed(byteCount: lineartData.count, url: lineartURL.lastPathComponent)
                    }
                    guard let compImage = UIImage(data: compData) else {
                        throw PipelineError.imageDecodeFailed(byteCount: compData.count, url: comparisonURL.lastPathComponent)
                    }
                    let cnStrength = input.advancedParameters?.controlNetStrength
                        ?? AdvancedParameters.defaultControlNetStrength
                    comparisonData = ComparisonData(
                        snapshotImage: snapshot.image,
                        lineartImage: lineartImage,
                        generatedImage: mainImage,
                        comparisonImage: compImage,
                        controlNetStrength: cnStrength
                    )
                } catch {
                    comparisonError = "Comparison download failed: \(error.localizedDescription)"
                }
            } else {
                comparisonError = "Server returned no comparison image URL"
            }
        }

        return Output(image: mainImage, seed: seed, generatedLineartImage: generatedLineartImage, comparisonData: comparisonData, comparisonError: comparisonError)
    }
}

// MARK: - Comparison Data

struct ComparisonData {
    let snapshotImage: UIImage
    let lineartImage: UIImage
    let generatedImage: UIImage
    let comparisonImage: UIImage
    let controlNetStrength: Double
}

// MARK: - Pipeline Errors

enum PipelineError: Error {
    case jpegEncodingFailed
    case generationFailed(status: String, imageURL: String?)
    case imageDecodeFailed(byteCount: Int, url: String)

    var userMessage: String {
        switch self {
        case .jpegEncodingFailed:
            return "Failed to process sketch"
        case .generationFailed(let status, let imageURL):
            return "Generation failed — status: \(status), imageURL: \(imageURL ?? "nil")"
        case .imageDecodeFailed(let byteCount, let url):
            return "Image decode failed — \(byteCount) bytes from \(url)"
        }
    }
}

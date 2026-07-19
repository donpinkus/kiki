import CoreML
import CoreImage
import CoreVideo
import Foundation

/// A single prompt point in SAM model space (0..1024, origin top-left).
public struct WandSample: Sendable, Equatable {
    public var x: Float
    public var y: Float
    public var positive: Bool

    public init(x: Float, y: Float, positive: Bool) {
        self.x = x
        self.y = y
        self.positive = positive
    }
}

/// The decoder's best mask as raw logits (256×256). Positive logit = inside.
public struct WandMaskLogits: Sendable {
    public let width: Int
    public let height: Int
    public let logits: [Float]
    public let score: Float
}

/// All decoder candidates for one prompt (SAM emits 3 at different
/// granularities — roughly subpart / part / whole). Kept so the wand's
/// selection-size control can switch candidates without re-running the model.
public struct WandMaskCandidates: Sendable {
    public let width: Int
    public let height: Int
    /// Per-candidate logit grids (positive = inside), each width×height.
    public let logits: [[Float]]
    public let scores: [Float]
    /// Per-candidate inside-pixel count at threshold 0 (in decoder resolution).
    public let areas: [Int]

    public var bestScoreIndex: Int {
        scores.indices.max(by: { scores[$0] < scores[$1] }) ?? 0
    }
}

public enum WandError: Error, CustomStringConvertible {
    case modelMissing(String)
    case pixelBufferCreationFailed
    case notEncoded
    case noPoints
    case unexpectedModelOutput(String)

    public var description: String {
        switch self {
        case .modelMissing(let name): return "SAM model missing: \(name)"
        case .pixelBufferCreationFailed: return "could not create pixel buffer"
        case .notEncoded: return "no image embedding — call encode first"
        case .noPoints: return "mask requested with zero prompt points"
        case .unexpectedModelOutput(let what): return "unexpected model output: \(what)"
        }
    }
}

/// On-device SAM 2.1 (Apple's official Core ML conversion, apple/coreml-sam2.1-small).
/// Three-model split: the image encoder runs ONCE per canvas snapshot (~1-3 s),
/// then the prompt encoder + mask decoder re-run per tap in milliseconds — that's
/// what makes interactive positive/negative refinement feel instant.
///
/// Actor so all Core ML work happens off the main thread; UIKit-free so the same
/// file compiles in the macOS offline harness (see scratchpad wand harness).
public actor SAM2Segmenter {
    /// SAM's fixed square input side (model image space).
    public static let inputSide = 1024

    private let imageEncoder: MLModel
    private let promptEncoder: MLModel
    private let maskDecoder: MLModel
    private let ciContext: CIContext
    private var embedding: (image: MLFeatureValue, s0: MLFeatureValue, s1: MLFeatureValue)?

    public init(imageEncoderURL: URL, promptEncoderURL: URL, maskDecoderURL: URL) throws {
        let cfg = MLModelConfiguration()
        // sam2-studio ships .cpuAndGPU (the Hiera encoder doesn't convert well to ANE).
        // Simulator: the GPU path is a Metal translation layer that returned
        // all-negative mask logits (empty masks) for prompts that work on
        // real hardware and in the macOS harness — force CPU there.
        #if targetEnvironment(simulator)
        cfg.computeUnits = .cpuOnly
        #else
        cfg.computeUnits = .cpuAndGPU
        #endif
        // Debug override for the offline harness (compare backends).
        if let forced = ProcessInfo.processInfo.environment["KIKI_SAM_COMPUTE"] {
            switch forced {
            case "cpu": cfg.computeUnits = .cpuOnly
            case "gpu": cfg.computeUnits = .cpuAndGPU
            case "all": cfg.computeUnits = .all
            default: break
            }
        }
        imageEncoder = try MLModel(contentsOf: imageEncoderURL, configuration: cfg)
        promptEncoder = try MLModel(contentsOf: promptEncoderURL, configuration: cfg)
        maskDecoder = try MLModel(contentsOf: maskDecoderURL, configuration: cfg)
        ciContext = CIContext(options: [.cacheIntermediates: false])
    }

    public var hasEmbedding: Bool { embedding != nil }

    public func clearEmbedding() { embedding = nil }

    /// Run the image encoder over a snapshot. The image is resampled (stretched)
    /// to 1024×1024 — callers map tap coords into the same normalized square, so
    /// non-square inputs stay consistent end-to-end.
    public func encode(_ image: CGImage) throws {
        let side = Self.inputSide
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { throw WandError.pixelBufferCreationFailed }

        let sx = CGFloat(side) / CGFloat(image.width)
        let sy = CGFloat(side) / CGFloat(image.height)
        let ci = CIImage(cgImage: image).transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(
            ci, to: buffer,
            bounds: CGRect(x: 0, y: 0, width: side, height: side),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "image": MLFeatureValue(pixelBuffer: buffer)
        ])
        let out = try imageEncoder.prediction(from: input)
        guard let e = out.featureValue(for: "image_embedding"),
              let s0 = out.featureValue(for: "feats_s0"),
              let s1 = out.featureValue(for: "feats_s1") else {
            throw WandError.unexpectedModelOutput("image encoder outputs")
        }
        embedding = (e, s0, s1)
    }

    /// Prompt-encode the points and decode the best-scoring mask candidate.
    public func mask(for points: [WandSample]) throws -> WandMaskLogits {
        let all = try maskCandidates(for: points)
        let best = all.bestScoreIndex
        return WandMaskLogits(
            width: all.width, height: all.height,
            logits: all.logits[best], score: all.scores[best])
    }

    /// Prompt-encode the points and decode ALL mask candidates.
    public func maskCandidates(for points: [WandSample]) throws -> WandMaskCandidates {
        guard let emb = embedding else { throw WandError.notEncoded }
        guard !points.isEmpty else { throw WandError.noPoints }

        let n = points.count
        let pts = try MLMultiArray(shape: [1, NSNumber(value: n), 2], dataType: .float32)
        let labels = try MLMultiArray(shape: [1, NSNumber(value: n)], dataType: .float32)
        for (i, p) in points.enumerated() {
            pts[[0, NSNumber(value: i), 0]] = NSNumber(value: p.x)
            pts[[0, NSNumber(value: i), 1]] = NSNumber(value: p.y)
            labels[[0, NSNumber(value: i)]] = NSNumber(value: p.positive ? Float(1) : Float(0))
        }

        let pOut = try promptEncoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "points": MLFeatureValue(multiArray: pts),
            "labels": MLFeatureValue(multiArray: labels),
        ]))
        guard let sparse = pOut.featureValue(for: "sparse_embeddings"),
              let dense = pOut.featureValue(for: "dense_embeddings") else {
            throw WandError.unexpectedModelOutput("prompt encoder outputs")
        }

        let dOut = try maskDecoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "image_embedding": emb.image,
            "sparse_embedding": sparse,
            "dense_embedding": dense,
            "feats_s0": emb.s0,
            "feats_s1": emb.s1,
        ]))
        guard let masks = dOut.featureValue(for: "low_res_masks")?.multiArrayValue,
              let scores = dOut.featureValue(for: "scores")?.multiArrayValue else {
            throw WandError.unexpectedModelOutput("mask decoder outputs")
        }

        // scores: [1, K]; low_res_masks: [1, K, H, W].
        let k = scores.count
        let shape = masks.shape.map(\.intValue)
        guard shape.count == 4, shape[1] == k else {
            throw WandError.unexpectedModelOutput("low_res_masks shape \(shape)")
        }
        let h = shape[2], w = shape[3]

        var allScores = [Float](repeating: 0, count: k)
        for i in 0..<k { allScores[i] = scores[i].floatValue }

        // Subscript access (not withUnsafeBufferPointer): the CPU backend can
        // return a lazily-materialized/strided buffer where raw pointer reads
        // see zeros. Subscripts are backend-agnostic and convert dtype for us;
        // 3×65k reads is a few ms — fine for a per-tap path.
        var allLogits: [[Float]] = []
        var areas: [Int] = []
        for c in 0..<k {
            var logits = [Float](repeating: 0, count: h * w)
            var area = 0
            let cIdx = NSNumber(value: c)
            for y in 0..<h {
                let yIdx = NSNumber(value: y)
                for x in 0..<w {
                    let v = masks[[0, cIdx, yIdx, NSNumber(value: x)]].floatValue
                    logits[y * w + x] = v
                    if v > 0 { area += 1 }
                }
            }
            allLogits.append(logits)
            areas.append(area)
        }

        return WandMaskCandidates(
            width: w, height: h, logits: allLogits, scores: allScores, areas: areas)
    }
}

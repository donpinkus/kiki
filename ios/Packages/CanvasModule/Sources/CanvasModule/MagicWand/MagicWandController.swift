import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import os

private let wandLog = Logger(subsystem: "com.kiki.canvas", category: "MagicWand")

/// A wand tap marker for display (view-point space).
public struct WandMarker: Sendable, Equatable {
    public let point: CGPoint
    public let positive: Bool

    public init(point: CGPoint, positive: Bool) {
        self.point = point
        self.positive = positive
    }
}

/// Magic-wand selection session: turns canvas taps into SAM point prompts,
/// accumulates multiple selected objects (each its own positive/negative point
/// set + frozen mask bitmap), and publishes the union as a clip CGPath that
/// rides the existing lasso clip machinery.
///
/// Object model:
///  - The CURRENT object is refined live — every tap re-runs the decoder over
///    the object's full point list (add mode → positive point, subtract mode →
///    negative point, e.g. tap a person then subtract the body to keep the face).
///  - "New object" freezes the current object's mask and starts a fresh point
///    list, so disjoint things (several trees) can each be selected and the
///    union clips drawing.
///  - Committed masks are frozen bitmaps; only the current object needs the
///    image embedding, so canvas edits between objects trigger a re-encode
///    without invalidating what's already selected.
@MainActor
@Observable
public final class MagicWandController {

    public enum PointMode: String, CaseIterable, Sendable {
        case add
        case subtract
    }

    /// Which of SAM's 3 candidate masks to use — the "tolerance" analog for a
    /// semantic wand. SAM decodes subpart / part / whole-object candidates per
    /// prompt; auto takes the best-scored one, small/large pick by area.
    public enum Granularity: String, CaseIterable, Sendable {
        case small
        case auto
        case large
    }

    private struct TapPoint {
        /// Normalized [0,1]² position within the canvas square.
        let normalized: CGPoint
        let positive: Bool
    }

    // MARK: - Observable state (drives the wand contextual UI)

    public var mode: PointMode = .add
    /// Selection-size control (see `Granularity`). Applies to the CURRENT
    /// object instantly (no model re-run — candidates are cached per decode);
    /// already-committed objects keep the mask they were frozen with.
    public var granularity: Granularity = .auto {
        didSet { guard granularity != oldValue else { return }; recomputeCurrentMask() }
    }
    /// Keep only the connected region containing the tapped point.
    public var contiguous: Bool = false {
        didSet { guard contiguous != oldValue else { return }; recomputeCurrentMask() }
    }
    /// Grow (+) / shrink (−) the current mask edge, in mask pixels (1024²
    /// space ≈ 2 canvas px each). Applied after granularity + contiguous.
    public var expansion: Int = 0 {
        didSet { guard expansion != oldValue else { return }; recomputeCurrentMask() }
    }
    /// True while the encoder or decoder is running (spinner in the wand panel).
    public private(set) var isBusy = false
    /// True only during the one-time-per-image encoder pass (the slow part).
    public private(set) var isEncoding = false
    /// Any selection at all (current or committed) — gates "Clear Masks".
    public private(set) var hasSelection = false
    /// Points on the object currently being refined — gates "New Object".
    public private(set) var currentPointCount = 0
    public private(set) var committedObjectCount = 0
    /// Transient failure surface (auto-clears). Segmentation failures must
    /// never block drawing — worst case the wand just doesn't select.
    public private(set) var lastError: String?

    public var canUndoStep: Bool { currentPointCount > 0 || committedObjectCount > 0 }

    // MARK: - Wiring (set by CanvasViewModel / AppCoordinator)

    /// Supplies the image to segment (canvas snapshot, or the generated image in
    /// overlay mode). Must be the same square the canvas view displays.
    public var sourceImageProvider: (@MainActor () -> CGImage?)?
    /// Monotonic canvas content version — bumps on every committed change. Used
    /// to re-encode when starting a new object after the drawing changed.
    public var contentVersionProvider: (@MainActor () -> Int)?
    /// Publishes the union selection: clip path in view-point space (nil =
    /// no selection) + tap markers for display.
    public var onSelectionChanged: (@MainActor (CGPath?, [WandMarker]) -> Void)?
    /// Loads the segmenter's three Core ML models (injected so the controller
    /// stays bundle-agnostic and harness-testable).
    public var segmenterFactory: (@Sendable () throws -> SAM2Segmenter)?

    // MARK: - Private state

    private var segmenter: SAM2Segmenter?
    private var encodedVersion: Int?
    private var currentPoints: [TapPoint] = []
    private var currentMask: [UInt8]?
    /// The last decode's full candidate set for the current object — granularity/
    /// contiguous/expansion re-derive the mask from this without re-running SAM.
    private var currentCandidates: WandMaskCandidates?
    private var committedPoints: [[TapPoint]] = []
    private var committedMasks: [[UInt8]] = []
    /// View size at the time of the last publish (tap coords normalize against
    /// the live canvas-square bounds; masks are resolution-independent).
    private var viewSize: CGSize = .zero
    /// Serializes all async ops (taps queue behind the in-flight decode).
    private var opChain: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?

    /// Trace resolution for the union bitmap + contours. 1024 matches SAM's
    /// input space; contour steps are sub-pixel after view scaling.
    private let maskSide = SAM2Segmenter.inputSide

    public init() {}

    // MARK: - Public API

    /// Handle a wand tap at `viewPoint` within a canvas square of `viewSize`.
    /// Uses the current add/subtract mode.
    public func handleTap(at viewPoint: CGPoint, viewSize: CGSize) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        self.viewSize = viewSize
        let normalized = CGPoint(x: viewPoint.x / viewSize.width, y: viewPoint.y / viewSize.height)
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return }
        let tap = TapPoint(normalized: normalized, positive: mode == .add)

        // A subtract tap with no object yet has nothing to subtract from.
        if currentPoints.isEmpty && !tap.positive { return }

        currentPoints.append(tap)
        currentPointCount = currentPoints.count
        publishMarkers()
        enqueueSegmentCurrentObject()
    }

    /// Freeze the current object and start selecting another (disjoint) one.
    public func startNewObject() {
        guard !currentPoints.isEmpty else { return }
        if let mask = currentMask, !MaskContour.isEmpty(mask) {
            committedPoints.append(currentPoints)
            committedMasks.append(mask)
            committedObjectCount = committedMasks.count
        }
        currentPoints = []
        currentPointCount = 0
        currentMask = nil
        currentCandidates = nil
        publishSelection()
    }

    /// Clear the whole wand selection (the "Clear Masks" button).
    public func clearAll() {
        opChain?.cancel()
        opChain = nil
        currentPoints = []
        currentPointCount = 0
        currentMask = nil
        currentCandidates = nil
        committedPoints = []
        committedMasks = []
        committedObjectCount = 0
        isBusy = false
        isEncoding = false
        hasSelection = false
        lastPath = nil
        onSelectionChanged?(nil, [])
    }

    /// Undo one wand step: drop the last point of the current object (and
    /// re-segment), or if the current object is empty, reopen the most recently
    /// committed object for refinement.
    public func undoStep() {
        if !currentPoints.isEmpty {
            currentPoints.removeLast()
            currentPointCount = currentPoints.count
            if currentPoints.isEmpty {
                currentMask = nil
                currentCandidates = nil
                publishSelection()
            } else {
                enqueueSegmentCurrentObject()
            }
        } else if !committedPoints.isEmpty {
            currentPoints = committedPoints.removeLast()
            currentMask = committedMasks.removeLast()
            committedObjectCount = committedMasks.count
            currentPointCount = currentPoints.count
            // The reopened object's points may predate the live embedding; its
            // mask is still valid, and the next tap re-segments from its points
            // against the current embedding (close enough in practice — the
            // canvas hasn't changed if the user is still inside a wand session).
            enqueueSegmentCurrentObject()
        }
    }

    /// Called when the user leaves the wand tool: freeze the current object so
    /// a later wand session (possibly after canvas edits) starts clean.
    public func toolDeactivated() {
        startNewObject()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Sim-only: inject a synthetic circular mask as the current object. The
    /// iOS-simulator Core ML backend returns all-zero mask logits for SAM's
    /// decoder (scores fine; verified broken on 18.3.1 + 26.5 runtimes, CPU and
    /// GPU, while the identical mlmodelc files work on macOS and real devices),
    /// so sim UI tests drive the mask→path→clip pipeline through this instead.
    public func devInjectCircleMask(centerU: CGFloat, centerV: CGFloat, radiusFraction: CGFloat, viewSize: CGSize) {
        self.viewSize = viewSize
        currentPoints.append(TapPoint(normalized: CGPoint(x: centerU, y: centerV), positive: true))
        currentPointCount = currentPoints.count
        var mask = [UInt8](repeating: 0, count: maskSide * maskSide)
        let c = CGFloat(maskSide)
        let cx = centerU * c, cy = centerV * c, r = radiusFraction * c
        for y in 0..<maskSide {
            for x in 0..<maskSide {
                let dx = CGFloat(x) - cx, dy = CGFloat(y) - cy
                if dx * dx + dy * dy <= r * r { mask[y * maskSide + x] = 1 }
            }
        }
        currentMask = mask
        publishSelection()
    }
    #endif

    // MARK: - Segmentation pipeline

    private func enqueueSegmentCurrentObject() {
        let previous = opChain
        opChain = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await self.segmentCurrentObject()
        }
    }

    private func segmentCurrentObject() async {
        guard !currentPoints.isEmpty else { return }
        isBusy = true
        defer { isBusy = false }

        do {
            let segmenter = try await ensureSegmenter()
            try await ensureEmbedding(segmenter)

            let side = Float(SAM2Segmenter.inputSide)
            let samples = currentPoints.map {
                WandSample(x: Float($0.normalized.x) * side, y: Float($0.normalized.y) * side, positive: $0.positive)
            }
            let result = try await segmenter.maskCandidates(for: samples)
            guard !Task.isCancelled else { return }
            currentCandidates = result
            deriveCurrentMask()
            let area = currentMask.map { m in m.reduce(0) { $0 + Int($1) } } ?? 0
            wandLog.info("decode done: points=\(self.currentPoints.count) scores=\(result.scores) areas=\(result.areas) chosenArea=\(area)")
            publishSelection()
        } catch is CancellationError {
            // Cleared mid-flight — nothing to do.
        } catch {
            wandLog.error("segmentation failed: \(String(describing: error))")
            reportError("\(error)")
        }
    }

    /// Derive the current object's binary mask from the cached candidates +
    /// the granularity / contiguous / expansion settings. Pure post-processing.
    private func deriveCurrentMask() {
        guard let cands = currentCandidates else { return }
        let idx: Int
        switch granularity {
        case .auto:
            idx = cands.bestScoreIndex
        case .small:
            let nonzero = cands.areas.indices.filter { cands.areas[$0] > 0 }
            idx = nonzero.min(by: { cands.areas[$0] < cands.areas[$1] }) ?? cands.bestScoreIndex
        case .large:
            idx = cands.areas.indices.max(by: { cands.areas[$0] < cands.areas[$1] }) ?? cands.bestScoreIndex
        }
        var mask = MaskContour.binaryMask(
            fromLogits: cands.logits[idx], width: cands.width, height: cands.height,
            upsampledSide: maskSide)
        if contiguous, let seed = currentPoints.first(where: { $0.positive }) {
            mask = MaskContour.connectedComponent(
                of: mask, side: maskSide,
                seedX: Int(seed.normalized.x * CGFloat(maskSide)),
                seedY: Int(seed.normalized.y * CGFloat(maskSide)))
        }
        if expansion != 0 {
            mask = MaskContour.expand(mask, side: maskSide, by: expansion)
        }
        currentMask = mask
    }

    /// Param change on the current object: re-derive + republish, no model run.
    private func recomputeCurrentMask() {
        guard currentCandidates != nil else { return }
        deriveCurrentMask()
        publishSelection()
    }

    private func ensureSegmenter() async throws -> SAM2Segmenter {
        if let segmenter { return segmenter }
        guard let factory = segmenterFactory else {
            throw WandError.modelMissing("segmenterFactory not wired")
        }
        // Model load is seconds-class on first use; off the main thread.
        let built = try await Task.detached(priority: .userInitiated) {
            try factory()
        }.value
        segmenter = built
        return built
    }

    private func ensureEmbedding(_ segmenter: SAM2Segmenter) async throws {
        let version = contentVersionProvider?() ?? 0
        let hasEmbedding = await segmenter.hasEmbedding
        // Re-encode when nothing is encoded yet, or the canvas changed AND this
        // is the first point of a fresh object (mid-object refinement must keep
        // the embedding its earlier points refer to).
        let isFreshObject = currentPoints.count <= 1
        guard !hasEmbedding || (encodedVersion != version && isFreshObject) else { return }

        guard let image = sourceImageProvider?() else {
            throw WandError.modelMissing("no source image for segmentation")
        }
        isEncoding = true
        defer { isEncoding = false }
        wandLog.info("encoding image \(image.width)x\(image.height) (version \(version))")
        #if DEBUG && targetEnvironment(simulator)
        // Dev loop: dump exactly what the segmenter sees (sim apps can write host /tmp).
        if let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: "/tmp/kiki-wand-source.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        #endif
        let start = ContinuousClock.now
        try await segmenter.encode(image)
        wandLog.info("encode done in \(String(describing: ContinuousClock.now - start))")
        encodedVersion = version
    }

    // MARK: - Publishing

    private var lastPath: CGPath?

    private func publishSelection() {
        var unionMask: [UInt8]?
        for mask in committedMasks {
            if unionMask == nil { unionMask = mask } else { MaskContour.union(&unionMask!, with: mask) }
        }
        if let current = currentMask, !MaskContour.isEmpty(current) {
            if unionMask == nil { unionMask = current } else { MaskContour.union(&unionMask!, with: current) }
        }

        var viewPath: CGPath?
        if let mask = unionMask, !MaskContour.isEmpty(mask),
           let normalizedPath = MaskContour.path(fromBinary: mask, side: maskSide),
           viewSize.width > 0 {
            var transform = CGAffineTransform(scaleX: viewSize.width, y: viewSize.height)
            viewPath = normalizedPath.copy(using: &transform)
        }
        lastPath = viewPath
        hasSelection = viewPath != nil
        wandLog.info("publish: path=\(viewPath == nil ? "nil" : "set") viewSize=\(self.viewSize.width)x\(self.viewSize.height) objects=\(self.committedMasks.count)")
        onSelectionChanged?(viewPath, markers())
    }

    /// Markers update immediately on tap (before the decode lands) so the touch
    /// feels acknowledged; the path keeps its last published value until the
    /// segmentation result replaces it.
    private func publishMarkers() {
        onSelectionChanged?(lastPath, markers())
    }

    private func markers() -> [WandMarker] {
        guard viewSize.width > 0 else { return [] }
        return currentPoints.map {
            WandMarker(
                point: CGPoint(x: $0.normalized.x * viewSize.width, y: $0.normalized.y * viewSize.height),
                positive: $0.positive)
        }
    }

    private func reportError(_ message: String) {
        lastError = message
        errorClearTask?.cancel()
        errorClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.lastError = nil
        }
    }
}

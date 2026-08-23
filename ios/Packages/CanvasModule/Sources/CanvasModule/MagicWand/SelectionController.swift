import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import os

private let selLog = Logger(subsystem: "com.kiki.canvas", category: "Selection")

/// A selection prompt-point marker for display (view-point space).
public struct WandMarker: Sendable, Equatable {
    public let point: CGPoint
    public let positive: Bool

    public init(point: CGPoint, positive: Bool) {
        self.point = point
        self.positive = positive
    }
}

/// The unified Selection: ONE mask, two authors, three uses
/// (documents/plans/unified-selection.md).
///
/// - **Authors:** Auto (SAM tap prompts) and Freehand (drawn loops) both write
///   into the same selection — a list of per-object 1024² bitmaps whose union
///   (plus a selection-wide Expand) becomes the clip path.
/// - **Uses:** paint inside it (clip, automatic), Move the selected content
///   (float/transform via the renderer's selection machinery), and re-edit it
///   (persistent across tool switches; reopen-on-tap refinement).
/// - **Tap routing (Auto mode):** Add-tap outside the selection starts a new
///   object (auto-committing the current one); any tap inside an auto object
///   REOPENS that object and refines it jointly with the new point; Remove-tap
///   on a freehand region SAM-decodes the tapped thing and carves it out.
///   There is no "New Object" button — objects are invisible plumbing.
/// - **Undo:** snapshot stack of selection state (cheap via array COW). While
///   moving, undo cancels the move.
@MainActor
@Observable
public final class SelectionController {

    public enum AuthorMode: String, CaseIterable, Sendable {
        case auto
        case freehand
    }

    public enum PointMode: String, CaseIterable, Sendable {
        case add
        case subtract
    }

    /// Which of SAM's 3 candidate masks to use — the "tolerance" analog for a
    /// semantic wand. Auto takes the best-scored one, small/large pick by area.
    public enum Granularity: String, CaseIterable, Sendable {
        case small
        case auto
        case large
    }

    private struct TapPoint: Sendable {
        /// Normalized [0,1]² position within the canvas square.
        let normalized: CGPoint
        let positive: Bool
    }

    private struct SelectionObject: Sendable {
        enum Source: Sendable {
            /// SAM-authored; points kept so the object can be reopened+refined.
            case auto(points: [TapPoint])
            /// Hand-drawn, or an auto object whose bitmap was geometrically
            /// edited (carved) — its points no longer describe it.
            case freehand
        }
        var source: Source
        /// Pre-expansion bitmap, maskSide².
        var mask: [UInt8]
    }

    /// Selection-state snapshot for undo. Arrays are COW — snapshots share
    /// storage with live state until an edit copies, so pushing is ~free.
    private struct Snapshot {
        let objects: [SelectionObject]
        let currentPoints: [TapPoint]
        let currentCandidates: WandMaskCandidates?
        let currentBase: [UInt8]?
    }

    // MARK: - Observable state (drives the Select panel)

    /// Auto (SAM taps) vs Freehand (drawn loops). The canvas view's input
    /// capture follows this (tap capture vs loop capture).
    public var authorMode: AuthorMode = .auto {
        didSet {
            guard authorMode != oldValue else { return }
            onAuthorModeChanged?()
        }
    }
    public var mode: PointMode = .add
    /// Auto-mode candidate pick; applies to the CURRENT object.
    public var granularity: Granularity = .auto {
        didSet { guard granularity != oldValue, currentCandidates != nil else { return }; bumpAndRefresh() }
    }
    /// Keep only the connected region at the tapped point (auto mode). ON by
    /// default (Donald 2026-07-19).
    public var contiguous: Bool = true {
        didSet { guard contiguous != oldValue, currentCandidates != nil else { return }; bumpAndRefresh() }
    }
    /// Grow/shrink the WHOLE selection uniformly, in mask pixels — a union-
    /// level post-process (freehand regions included), never baked into object
    /// bitmaps. Slider-hot: cached-distance-field threshold off-main.
    public var expansion: Int = 0 {
        didSet { guard expansion != oldValue, hasSelection || currentBase != nil else { return }; scheduleRefresh() }
    }
    public private(set) var isBusy = false
    public private(set) var isEncoding = false
    public private(set) var hasSelection = false
    public private(set) var currentPointCount = 0
    public private(set) var objectCount = 0
    /// Move-the-content mode: selected pixels are floating on the renderer.
    public private(set) var isMoving = false
    /// Transient failure surface (auto-clears).
    public private(set) var lastError: String?

    public var canUndoStep: Bool { isMoving || !undoStack.isEmpty }

    // MARK: - Wiring (CanvasViewModel / AppCoordinator)

    public var sourceImageProvider: (@MainActor () -> CGImage?)?
    public var contentVersionProvider: (@MainActor () -> Int)?
    /// Publishes the selection: clip path in view-point space + tap markers.
    public var onSelectionChanged: (@MainActor (CGPath?, [WandMarker]) -> Void)?
    public var segmenterFactory: (@Sendable () throws -> SAM2Segmenter)?
    /// Author-mode toggle → CanvasViewModel remaps the canvas input capture.
    public var onAuthorModeChanged: (@MainActor () -> Void)?
    /// Move lifecycle → CanvasViewModel drives extraction/float/commit/cancel.
    /// onBeginMove returns false when extraction failed (selection too small) —
    /// the controller then rolls back silently with no cancel side effects.
    public var onBeginMove: (@MainActor (CGPath) -> Bool)?
    public var onCommitMove: (@MainActor () -> Void)?
    public var onCancelMove: (@MainActor () -> Void)?

    // MARK: - Private state

    private var segmenter: SAM2Segmenter?
    private var encodedVersion: Int?
    private var objects: [SelectionObject] = []
    private var currentPoints: [TapPoint] = []
    private var currentCandidates: WandMaskCandidates?
    /// Current object's derived bitmap (candidate pick + contiguous, pre-expansion).
    private var currentBase: [UInt8]?
    private var undoStack: [Snapshot] = []
    private static let maxUndoDepth = 24
    private var viewSize: CGSize = .zero
    /// Serializes SAM ops (taps queue behind the in-flight decode).
    private var opChain: Task<Void, Never>?
    private var errorClearTask: Task<Void, Never>?
    /// Move bookkeeping.
    private var moveTransform: (translation: CGPoint, scale: CGFloat, rotation: CGFloat) = (.zero, 1, 0)
    private var moveCenter: CGPoint = .zero // normalized
    private var preMoveSnapshot: Snapshot?

    private let maskSide = SAM2Segmenter.inputSide

    public init() {}

    // MARK: - Auto-mode taps

    /// Handle a tap at `viewPoint` within a canvas square of `viewSize`,
    /// routed per the reopen-on-tap rules.
    public func handleTap(at viewPoint: CGPoint, viewSize: CGSize) {
        guard !isMoving else { return }
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        self.viewSize = viewSize
        let normalized = CGPoint(x: viewPoint.x / viewSize.width, y: viewPoint.y / viewSize.height)
        guard (0...1).contains(normalized.x), (0...1).contains(normalized.y) else { return }

        let px = maskPixelIndex(normalized)
        let inCurrent = currentBase.map { $0[px] != 0 } ?? false
        let hitObject = objects.lastIndex(where: { $0.mask[px] != 0 })
        let positive = mode == .add

        if inCurrent {
            // Refine the open object (positive extends, negative carves — SAM
            // interprets the whole point set jointly).
            pushUndo()
            currentPoints.append(TapPoint(normalized: normalized, positive: positive))
        } else if let k = hitObject {
            switch objects[k].source {
            case .auto(let points):
                // Reopen the tapped object and refine it with the new point.
                // commitCurrent appends at the END, so index k stays valid.
                pushUndo()
                commitCurrent()
                currentBase = objects[k].mask
                currentPoints = points + [TapPoint(normalized: normalized, positive: positive)]
                currentCandidates = nil
                objects.remove(at: k)
            case .freehand:
                if positive {
                    // Growing over a freehand region: start a fresh SAM object
                    // (union only grows — harmless and useful).
                    pushUndo()
                    commitCurrent()
                    currentPoints = [TapPoint(normalized: normalized, positive: true)]
                    currentCandidates = nil
                    currentBase = nil
                } else {
                    // Remove-tap on a hand-drawn region: SAM identifies the
                    // tapped thing, and we carve it out of that object.
                    carveByDecode(at: normalized, objectIndex: k)
                    return
                }
            }
        } else {
            guard positive else { return } // nothing to remove out there
            pushUndo()
            commitCurrent()
            currentPoints = [TapPoint(normalized: normalized, positive: true)]
            currentCandidates = nil
            currentBase = nil
        }

        currentPointCount = currentPoints.count
        objectCount = objects.count
        publishMarkers()
        enqueueSegmentCurrentObject()
    }

    // MARK: - Freehand loops

    /// A closed freehand loop (view-point space): Add → new selection object;
    /// Remove → subtract the region from everything it overlaps.
    public func addFreehandPath(_ path: CGPath, viewSize: CGSize) {
        guard !isMoving else { return }
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        self.viewSize = viewSize
        let mask = MaskContour.rasterize(path: path, viewSize: viewSize, side: maskSide)
        guard !MaskContour.isEmpty(mask) else { return }

        pushUndo()
        commitCurrent()
        if mode == .add {
            objects.append(SelectionObject(source: .freehand, mask: mask))
        } else {
            subtractFromObjects(mask)
        }
        objectCount = objects.count
        bumpAndRefresh()
    }

    // MARK: - Move (float + transform the selected content)

    public func beginMove() {
        guard !isMoving, hasSelection, let selectionPath = lastPath,
              viewSize.width > 0 else { return }
        pushUndo()
        commitCurrent()
        preMoveSnapshot = snapshot()
        let bounds = selectionPath.boundingBox.intersection(
            CGRect(origin: .zero, size: viewSize))
        moveCenter = CGPoint(
            x: bounds.midX / viewSize.width, y: bounds.midY / viewSize.height)
        moveTransform = (.zero, 1, 0)
        isMoving = true
        // Hide the clip visuals while floating — the float has its own ants.
        onSelectionChanged?(nil, [])
        if onBeginMove?(selectionPath) != true {
            // Extraction failed — roll back silently (no cancel side effects).
            isMoving = false
            preMoveSnapshot = nil
            if !undoStack.isEmpty { undoStack.removeLast() }
            scheduleRefresh()
        }
    }

    /// Forwarded from the float gesture view (cumulative values, view points).
    public func moveTransformChanged(translation: CGPoint, scale: CGFloat, rotation: CGFloat) {
        guard isMoving else { return }
        moveTransform = (translation, scale, rotation)
    }

    public func commitMove() {
        guard isMoving else { return }
        isMoving = false
        onCommitMove?()
        preMoveSnapshot = nil
        let t = moveTransform
        let identity = t.translation == .zero && abs(t.scale - 1) < 0.0001 && abs(t.rotation) < 0.0001
        if !identity, viewSize.width > 0 {
            applyMoveTransformToSelection(t)
        } else {
            bumpAndRefresh()
        }
    }

    public func cancelMove() {
        guard isMoving else { return }
        isMoving = false
        onCancelMove?()
        if let snap = preMoveSnapshot { restore(snap) }
        preMoveSnapshot = nil
        // The pushUndo from beginMove would now be a no-op step — drop it.
        if !undoStack.isEmpty { undoStack.removeLast() }
        bumpAndRefresh()
    }

    /// Transform every object bitmap (and auto points) by the committed move so
    /// the selection follows the content to its new home. Heavy → off-main.
    private func applyMoveTransformToSelection(
        _ t: (translation: CGPoint, scale: CGFloat, rotation: CGFloat)
    ) {
        let normalized = CGPoint(
            x: t.translation.x / viewSize.width, y: t.translation.y / viewSize.height)
        let center = moveCenter
        let side = maskSide
        let snapshotObjects = objects
        let generation = sessionGeneration

        Task { @MainActor [weak self] in
            let transformed = await Task.detached(priority: .userInitiated) { () -> [SelectionObject] in
                snapshotObjects.compactMap { obj in
                    var out = obj
                    out.mask = MaskContour.transform(
                        obj.mask, side: side, translation: normalized,
                        scale: t.scale, rotation: t.rotation, center: center)
                    guard !MaskContour.isEmpty(out.mask) else { return nil }
                    if case .auto(let points) = out.source {
                        // Same forward affine on the points: p' = c + t + R(s(p−c)).
                        let c = cos(t.rotation), sn = sin(t.rotation)
                        let moved = points.map { p -> TapPoint in
                            let dx = (p.normalized.x - center.x) * t.scale
                            let dy = (p.normalized.y - center.y) * t.scale
                            return TapPoint(
                                normalized: CGPoint(
                                    x: center.x + normalized.x + dx * c - dy * sn,
                                    y: center.y + normalized.y + dx * sn + dy * c),
                                positive: p.positive)
                        }
                        out.source = .auto(points: moved)
                    }
                    return out
                }
            }.value
            guard let self, self.sessionGeneration == generation else { return }
            self.objects = transformed
            self.objectCount = transformed.count
            // The canvas content changed (pixels moved) — SAM candidates for
            // reopened objects will re-decode against a fresh embedding.
            self.bumpAndRefresh()
        }
    }

    // MARK: - Clear / undo / lifecycle

    /// Clear the whole selection (the "Clear Selection" button). Undoable.
    public func clearAll() {
        if isMoving { cancelMove() }
        guard hasSelection || !currentPoints.isEmpty || !objects.isEmpty else { return }
        pushUndo()
        opChain?.cancel()
        opChain = nil
        sessionGeneration &+= 1
        refreshDirty = false
        currentPoints = []
        currentPointCount = 0
        currentBase = nil
        currentCandidates = nil
        distCache = nil
        objects = []
        objectCount = 0
        isBusy = false
        isEncoding = false
        hasSelection = false
        lastPath = nil
        onSelectionChanged?(nil, [])
    }

    /// Undo one selection edit (or cancel an in-flight move).
    public func undoStep() {
        if isMoving {
            cancelMove()
            return
        }
        guard let snap = undoStack.popLast() else { return }
        restore(snap)
        bumpAndRefresh()
    }

    /// Leaving the Select tool: commit any floating move + freeze the current
    /// object. The selection itself PERSISTS (clip stays active).
    public func toolDeactivated() {
        if isMoving { commitMove() }
        guard !currentPoints.isEmpty else { return }
        commitCurrent()
        objectCount = objects.count
        bumpAndRefresh()
    }

    // MARK: - Programmatic selection (layer contents)

    /// The mask bitmap side used by this controller (SAM's input side) — build
    /// `selectFromBitmap` masks at this resolution.
    public var bitmapSide: Int { maskSide }

    /// Replace the whole selection with one ready-made mask bitmap (maskSide²,
    /// nonzero = selected, top-left row order) — the "Select layer contents"
    /// menu action. Undoable as a single selection-undo step; the previous
    /// objects are dropped (Procreate's Select replaces, never adds).
    public func selectFromBitmap(_ mask: [UInt8], viewSize: CGSize) {
        guard mask.count == maskSide * maskSide, mask.contains(where: { $0 != 0 }) else { return }
        self.viewSize = viewSize
        pushUndo()
        sessionGeneration &+= 1 // drop in-flight decode/derive results
        objects = [SelectionObject(source: .freehand, mask: mask)]
        currentPoints = []
        currentCandidates = nil
        currentBase = nil
        objectCount = objects.count
        bumpAndRefresh()
    }

    // MARK: - Dev shims (simulator automation)

    #if DEBUG && targetEnvironment(simulator)
    /// Sim-only: inject a synthetic circular mask as a committed object (the
    /// iOS-simulator Core ML backend zeroes SAM mask logits — see CLAUDE.md).
    public func devInjectCircleMask(centerU: CGFloat, centerV: CGFloat, radiusFraction: CGFloat, viewSize: CGSize) {
        self.viewSize = viewSize
        pushUndo()
        var mask = [UInt8](repeating: 0, count: maskSide * maskSide)
        let c = CGFloat(maskSide)
        let cx = centerU * c, cy = centerV * c, r = radiusFraction * c
        for y in 0..<maskSide {
            for x in 0..<maskSide {
                let dx = CGFloat(x) - cx, dy = CGFloat(y) - cy
                if dx * dx + dy * dy <= r * r { mask[y * maskSide + x] = 1 }
            }
        }
        objects.append(SelectionObject(source: .freehand, mask: mask))
        objectCount = objects.count
        bumpAndRefresh()
    }
    #endif

    // MARK: - Internals

    private func maskPixelIndex(_ normalized: CGPoint) -> Int {
        let x = min(maskSide - 1, max(0, Int(normalized.x * CGFloat(maskSide))))
        let y = min(maskSide - 1, max(0, Int(normalized.y * CGFloat(maskSide))))
        return y * maskSide + x
    }

    private func snapshot() -> Snapshot {
        Snapshot(
            objects: objects, currentPoints: currentPoints,
            currentCandidates: currentCandidates, currentBase: currentBase)
    }

    private func restore(_ snap: Snapshot) {
        sessionGeneration &+= 1 // discard in-flight decode/derive results
        objects = snap.objects
        currentPoints = snap.currentPoints
        currentCandidates = snap.currentCandidates
        currentBase = snap.currentBase
        currentPointCount = currentPoints.count
        objectCount = objects.count
    }

    private func pushUndo() {
        undoStack.append(snapshot())
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
    }

    /// Freeze the current auto object into the committed list.
    private func commitCurrent() {
        defer {
            currentPoints = []
            currentPointCount = 0
            currentCandidates = nil
            currentBase = nil
        }
        guard !currentPoints.isEmpty, let base = currentBase, !MaskContour.isEmpty(base) else { return }
        objects.append(SelectionObject(source: .auto(points: currentPoints), mask: base))
    }

    /// Subtract `mask` from every overlapping object; carved auto objects
    /// become freehand (their points no longer describe their bitmap — see
    /// unified-selection.md); emptied objects are dropped.
    private func subtractFromObjects(_ mask: [UInt8]) {
        var kept: [SelectionObject] = []
        for var obj in objects {
            let (result, changed) = MaskContour.subtracting(obj.mask, mask)
            if changed {
                obj.mask = result
                if case .auto = obj.source { obj.source = .freehand }
            }
            if !MaskContour.isEmpty(obj.mask) { kept.append(obj) }
        }
        objects = kept
    }

    /// Remove-tap on a freehand region: SAM-decode the tapped thing (single
    /// positive prompt) and carve (decoded ∩ that object) out of it.
    private func carveByDecode(at normalized: CGPoint, objectIndex: Int) {
        pushUndo()
        commitCurrent()
        let generation = sessionGeneration
        let side = Float(maskSide)
        let sample = WandSample(x: Float(normalized.x) * side, y: Float(normalized.y) * side, positive: true)
        let previous = opChain
        opChain = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            self.isBusy = true
            defer { self.isBusy = false }
            do {
                let segmenter = try await self.ensureSegmenter()
                try await self.ensureEmbedding(segmenter)
                let cands = try await segmenter.maskCandidates(for: [sample])
                guard self.sessionGeneration == generation else { return }
                let best = cands.bestScoreIndex
                var carve = MaskContour.binaryMask(
                    fromLogits: cands.logits[best], width: cands.width, height: cands.height,
                    upsampledSide: self.maskSide)
                // Contiguous around the tap so a stray decode can't nuke the
                // whole region.
                carve = MaskContour.connectedComponent(
                    of: carve, side: self.maskSide,
                    seedX: Int(normalized.x * CGFloat(self.maskSide)),
                    seedY: Int(normalized.y * CGFloat(self.maskSide)))
                guard !MaskContour.isEmpty(carve) else { return }
                self.subtractFromObjects(carve)
                self.objectCount = self.objects.count
                self.bumpAndRefresh()
            } catch is CancellationError {
            } catch {
                selLog.error("carve failed: \(String(describing: error))")
                self.reportError("\(error)")
            }
        }
    }

    // MARK: - SAM decode of the current object

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
        let generation = sessionGeneration
        isBusy = true
        defer { isBusy = false }

        do {
            let segmenter = try await ensureSegmenter()
            try await ensureEmbedding(segmenter)

            let side = Float(maskSide)
            let samples = currentPoints.map {
                WandSample(x: Float($0.normalized.x) * side, y: Float($0.normalized.y) * side, positive: $0.positive)
            }
            let result = try await segmenter.maskCandidates(for: samples)
            guard !Task.isCancelled, sessionGeneration == generation else { return }
            currentCandidates = result
            decodeGeneration &+= 1
            selLog.info("decode done: points=\(self.currentPoints.count) scores=\(result.scores) areas=\(result.areas)")
            bumpAndRefresh()
        } catch is CancellationError {
        } catch {
            selLog.error("segmentation failed: \(String(describing: error))")
            reportError("\(error)")
        }
    }

    private func ensureSegmenter() async throws -> SAM2Segmenter {
        if let segmenter { return segmenter }
        guard let factory = segmenterFactory else {
            throw WandError.modelMissing("segmenterFactory not wired")
        }
        let built = try await Task.detached(priority: .userInitiated) {
            try factory()
        }.value
        segmenter = built
        return built
    }

    private func ensureEmbedding(_ segmenter: SAM2Segmenter) async throws {
        let version = contentVersionProvider?() ?? 0
        let hasEmbedding = await segmenter.hasEmbedding
        // Re-encode when nothing is encoded, or the canvas changed AND we're at
        // the start of a fresh prompt (mid-object refinement keeps the
        // embedding its earlier points refer to).
        let isFreshObject = currentPoints.count <= 1
        guard !hasEmbedding || (encodedVersion != version && isFreshObject) else { return }

        guard let image = sourceImageProvider?() else {
            throw WandError.modelMissing("no source image for segmentation")
        }
        isEncoding = true
        defer { isEncoding = false }
        selLog.info("encoding image \(image.width)x\(image.height) (version \(version))")
        #if DEBUG && targetEnvironment(simulator)
        if let dest = CGImageDestinationCreateWithURL(
            URL(fileURLWithPath: "/tmp/kiki-wand-source.png") as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        #endif
        let start = ContinuousClock.now
        try await segmenter.encode(image)
        selLog.info("encode done in \(String(describing: ContinuousClock.now - start))")
        encodedVersion = version
    }

    // MARK: - Async derivation (off-main, coalesced)

    /// Signed-distance field of the UNION (pre-expansion) — Expand is a single
    /// threshold against it. Keyed by everything that shapes the union.
    private struct DistanceCache: Sendable {
        let key: String
        let signed: [Int32]
    }

    private var distCache: DistanceCache?
    private var decodeGeneration = 0
    /// Bumped whenever objects/current change shape (not on expansion).
    private var unionRevision = 0
    /// Bumped on clear/undo/restore so in-flight work discards its results.
    private var sessionGeneration = 0
    private var refreshDirty = false
    private var refreshTask: Task<Void, Never>?

    /// Union content changed → invalidate the distance cache + refresh.
    private func bumpAndRefresh() {
        unionRevision &+= 1
        scheduleRefresh()
    }

    private func scheduleRefresh() {
        refreshDirty = true
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            while let s = self, s.refreshDirty {
                s.refreshDirty = false
                await s.refreshOnce()
            }
            self?.refreshTask = nil
        }
    }

    private func refreshOnce() async {
        let generation = sessionGeneration
        let cacheKey = "\(unionRevision)-\(decodeGeneration)-\(granularity.rawValue)-\(contiguous)"
        let input = DeriveInput(
            candidates: currentCandidates,
            granularity: granularity,
            contiguous: contiguous,
            expansion: expansion,
            seed: currentPoints.first(where: { $0.positive })?.normalized,
            fallbackCurrent: currentBase,
            committed: objects.map(\.mask),
            maskSide: maskSide,
            cache: distCache,
            cacheKey: cacheKey)

        let result = await Task.detached(priority: .userInitiated) {
            Self.derive(input)
        }.value

        guard sessionGeneration == generation else { return }
        if input.candidates != nil { currentBase = result.currentBase }
        if let cache = result.newCache { distCache = cache }
        guard !isMoving else { return } // float owns the visuals; publish after
        publish(loops: result.loops)
    }

    private struct DeriveInput: Sendable {
        let candidates: WandMaskCandidates?
        let granularity: Granularity
        let contiguous: Bool
        let expansion: Int
        let seed: CGPoint?
        let fallbackCurrent: [UInt8]?
        let committed: [[UInt8]]
        let maskSide: Int
        let cache: DistanceCache?
        let cacheKey: String
    }

    private struct DeriveResult: Sendable {
        let currentBase: [UInt8]?
        let loops: [[CGPoint]]
        let newCache: DistanceCache?
    }

    /// The heavy pipeline, pure + off-main: candidate pick → contiguous →
    /// union with committed objects → distance-field Expand → contour trace.
    private nonisolated static func derive(_ input: DeriveInput) -> DeriveResult {
        var currentBase = input.fallbackCurrent

        if let cands = input.candidates {
            let idx: Int
            switch input.granularity {
            case .auto:
                idx = cands.bestScoreIndex
            case .small:
                let nonzero = cands.areas.indices.filter { cands.areas[$0] > 0 }
                idx = nonzero.min(by: { cands.areas[$0] < cands.areas[$1] }) ?? cands.bestScoreIndex
            case .large:
                idx = cands.areas.indices.max(by: { cands.areas[$0] < cands.areas[$1] }) ?? cands.bestScoreIndex
            }
            var base = MaskContour.binaryMask(
                fromLogits: cands.logits[idx], width: cands.width, height: cands.height,
                upsampledSide: input.maskSide)
            if input.contiguous, let seed = input.seed {
                base = MaskContour.connectedComponent(
                    of: base, side: input.maskSide,
                    seedX: Int(seed.x * CGFloat(input.maskSide)),
                    seedY: Int(seed.y * CGFloat(input.maskSide)))
            }
            currentBase = base
        }

        var unionMask: [UInt8]?
        for mask in input.committed {
            if unionMask == nil { unionMask = mask } else { MaskContour.union(&unionMask!, with: mask) }
        }
        if let cur = currentBase, !MaskContour.isEmpty(cur) {
            if unionMask == nil { unionMask = cur } else { MaskContour.union(&unionMask!, with: cur) }
        }

        var loops: [[CGPoint]] = []
        var newCache: DistanceCache?
        if var final = unionMask, !MaskContour.isEmpty(final) {
            if input.expansion != 0 {
                let signed: [Int32]
                if let cache = input.cache, cache.key == input.cacheKey {
                    signed = cache.signed
                } else {
                    signed = MaskContour.signedDistance(final, side: input.maskSide)
                    newCache = DistanceCache(key: input.cacheKey, signed: signed)
                }
                final = MaskContour.expandByDistance(signed, by: input.expansion)
            }
            if !MaskContour.isEmpty(final) {
                loops = MaskContour.normalizedLoops(fromBinary: final, side: input.maskSide)
            }
        }
        return DeriveResult(currentBase: currentBase, loops: loops, newCache: newCache)
    }

    // MARK: - Publishing

    private var lastPath: CGPath?

    /// The current view-space selection path (Move extraction input).
    public var currentSelectionPath: CGPath? { lastPath }

    private func publish(loops: [[CGPoint]]) {
        var viewPath: CGPath?
        if !loops.isEmpty, viewSize.width > 0 {
            let scaled = loops.map { loop in
                loop.map { CGPoint(x: $0.x * viewSize.width, y: $0.y * viewSize.height) }
            }
            viewPath = MaskContour.path(fromLoops: scaled)
        }
        lastPath = viewPath
        hasSelection = viewPath != nil
        onSelectionChanged?(viewPath, markers())
    }

    /// Markers update immediately on tap so the touch feels acknowledged; the
    /// path follows when the decode/derive lands.
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

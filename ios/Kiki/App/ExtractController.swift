import CanvasModule
import CoreImage.CIFilterBuiltins
import NetworkModule
import Sentry
import SwiftData
import SwiftUI

/// The Extract screen's engine: tap anything in the GENERATED image (the
/// high-quality artifact, not the sketch) → SAM segments it (add/remove
/// points refine the selection, exactly like the canvas Select tool) → "Lift
/// to 3D" sends the cutout to Hunyuan → "Save to Collection" persists it to
/// the object library (cutout + mesh + thumbnail).
///
/// Lifts keep running after the screen closes (`isPresented = false`):
/// finished ones auto-save into the object library and surface through
/// `onBackgroundLiftResult` (toast + objects-drawer badge in AppCoordinator).
@MainActor
@Observable
final class ExtractController {
    struct ExtractItem: Identifiable, Equatable {
        enum State: Equatable {
            case lifting
            case lifted
            case saved
            case failed
        }

        let id = UUID()
        /// Transparent cutout of the tapped region.
        let cutout: UIImage
        /// Cutout size as a fraction of the source image (drives the saved
        /// object's document-space size).
        let sizeFraction: CGSize
        var state: State = .lifting
        /// When the current lift attempt started (reset on retry) — drives
        /// the determinate ETA bar.
        var liftStartedAt = Date()
        var glb: Data?
        var meshThumb: UIImage?
    }

    /// One refinement tap, in normalized image coords (for markers).
    struct SelectionPoint: Equatable {
        var u: Double
        var v: Double
        var positive: Bool
    }

    enum PointMode {
        case add
        case remove
    }

    let sourceImage: UIImage
    private(set) var isEncoding = true
    private(set) var lastError: String?
    private(set) var items: [ExtractItem] = []

    // MARK: Current selection (multi-point SAM refinement)

    var pointMode: PointMode = .add
    private(set) var selectionPoints: [SelectionPoint] = []
    /// Contour loops of the current mask in normalized [0,1]² coords — the
    /// view scales these into the fitted image rect for the preview overlay.
    private(set) var selectionLoops: [[CGPoint]] = []
    private var currentMask: [UInt8]?
    /// Guards stale async decodes after Clear (points changed underneath).
    private var selectionGeneration = 0

    var hasSelection: Bool { currentMask != nil && !selectionLoops.isEmpty }
    var hasActiveLifts: Bool { items.contains { $0.state == .lifting } }

    /// False once the screen is dismissed; finished lifts then auto-save
    /// into the object library instead of waiting for a Save tap.
    var isPresented = true
    /// (objectName, success) — fired for lifts that finish while the screen
    /// is closed, so the coordinator can toast + badge the objects drawer.
    var onBackgroundLiftResult: ((String, Bool) -> Void)?

    private let authService: AuthService
    private let modelContext: ModelContext
    private var segmenter: SAM2Segmenter?
    private static let side = SAM2Segmenter.inputSide // 1024
    private static let ciContext = CIContext(
        options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!]
    )

    // Set once in init, read in deinit (which is nonisolated) — no races.
    nonisolated(unsafe) private var memoryWarningObserver: NSObjectProtocol?

    init(image: UIImage, authService: AuthService, modelContext: ModelContext) {
        self.sourceImage = image
        self.authService = authService
        self.modelContext = modelContext
        Self.log("extract.opened", [
            "image_w": Int(image.size.width * image.scale),
            "image_h": Int(image.size.height * image.scale),
        ])
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { _ in
            Self.log("extract.memory_warning")
        }
        encode()
    }

    deinit {
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    // MARK: - Lift duration stats (drives the ETA bar + copy)

    /// Median of the last few measured lift durations, seeded with the
    /// 2026-07-19 measurement (~89 s for a 100k-face lift) until real data
    /// accrues. Self-tuning: every successful lift records into UserDefaults.
    private static let durationsKey = "extract.liftDurationsMs"

    static var estimatedLiftMs: Int {
        let stored = (UserDefaults.standard.array(forKey: durationsKey) as? [Int]) ?? []
        guard !stored.isEmpty else { return 90_000 }
        let sorted = stored.sorted()
        return sorted[sorted.count / 2]
    }

    static func recordLiftDuration(ms: Int) {
        guard ms > 1000 else { return }
        var stored = (UserDefaults.standard.array(forKey: durationsKey) as? [Int]) ?? []
        stored.append(ms)
        UserDefaults.standard.set(Array(stored.suffix(8)), forKey: durationsKey)
    }

    /// "~1½ min"-style copy for the current estimate.
    static var estimatedLiftText: String {
        let secs = Double(estimatedLiftMs) / 1000
        switch secs {
        case ..<75: return "usually ~\(Int((secs / 15).rounded() * 15))s"
        case ..<105: return "usually ~1½ min"
        default: return "usually ~\(Int((secs / 60).rounded())) min"
        }
    }

    // MARK: - Debug logging (jetsam forensics)

    /// The extract session's deaths are watchdog RAM kills (Sentry
    /// KIKI-APP-IOS-1) which leave no stack — so every step logs the numbers
    /// jetsam acts on: `phys_footprint` (the kill metric) and
    /// `os_proc_available_memory` (remaining budget). Each event also lands as
    /// a Sentry BREADCRUMB: breadcrumbs persist to disk and ride along on the
    /// next WatchdogTermination event, which is the only way to see what the
    /// app was doing right before a jetsam (buffered logs can be lost).
    private static func memAttributes() -> [String: Any] {
        var attrs: [String: Any] = [
            "mem_available_mb": Int(os_proc_available_memory() / 1_048_576)
        ]
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            attrs["mem_footprint_mb"] = Int(info.phys_footprint / 1_048_576)
        }
        return attrs
    }

    private static func log(_ event: String, _ extra: [String: Any] = [:]) {
        var attrs = memAttributes()
        attrs["event"] = event
        for (key, value) in extra { attrs[key] = value }
        Log.info(event, attributes: attrs)
        let crumb = Breadcrumb(level: .info, category: "extract")
        crumb.message = event
        crumb.data = attrs
        SentrySDK.addBreadcrumb(crumb)
    }

    private func encode() {
        guard let cg = sourceImage.cgImage else {
            isEncoding = false
            lastError = "Couldn't read the image."
            Self.log("extract.encode_failed", ["error": "source image has no cgImage"])
            return
        }
        let t0 = Date()
        Task { @MainActor in
            do {
                let seg = try SAM2Segmenter.bundled()
                try await seg.encode(cg)
                segmenter = seg
                isEncoding = false
                Self.log("extract.encode_ok", [
                    "encode_ms": Int(-t0.timeIntervalSinceNow * 1000)
                ])
            } catch {
                isEncoding = false
                lastError = "Image analysis failed — tap-to-lift is unavailable."
                Self.log("extract.encode_failed", [
                    "error": String(describing: error),
                    "encode_ms": Int(-t0.timeIntervalSinceNow * 1000),
                ])
            }
        }
    }

    // MARK: - Selection (tap → SAM joint refinement over all points)

    /// Tap at normalized (u, v): adds an Add/Remove point and re-decodes the
    /// selection over ALL accumulated points (SAM joint refinement — the same
    /// interaction as the canvas Select tool).
    func handleTap(u: Double, v: Double) {
        guard !isEncoding, let segmenter else {
            Self.log("extract.tap_ignored", [
                "is_encoding": isEncoding,
                "has_segmenter": self.segmenter != nil,
            ])
            return
        }
        // A Remove tap with nothing selected can't carve anything.
        let positive = pointMode == .add || selectionPoints.isEmpty
        selectionPoints.append(SelectionPoint(u: u, v: v, positive: positive))
        Self.log("extract.tap", [
            "u": u, "v": v, "positive": positive, "points": selectionPoints.count,
        ])
        redecodeSelection(segmenter: segmenter)
    }

    func clearSelection() {
        selectionGeneration += 1
        selectionPoints = []
        selectionLoops = []
        currentMask = nil
        lastError = nil
    }

    /// Drop the most recent point and re-decode (mirrors Select-tool undo).
    func undoPoint() {
        guard !selectionPoints.isEmpty else { return }
        selectionPoints.removeLast()
        guard let segmenter else { return }
        if selectionPoints.isEmpty {
            clearSelection()
        } else {
            redecodeSelection(segmenter: segmenter)
        }
    }

    private func redecodeSelection(segmenter: SAM2Segmenter) {
        selectionGeneration += 1
        let generation = selectionGeneration
        let points = selectionPoints
        let samples = points.map {
            WandSample(
                x: Float($0.u) * Float(Self.side),
                y: Float($0.v) * Float(Self.side),
                positive: $0.positive
            )
        }
        guard let seed = points.first(where: { $0.positive }) else {
            clearSelection()
            return
        }
        let t0 = Date()
        Task { @MainActor in
            do {
                let logits = try await segmenter.mask(for: samples)
                guard generation == self.selectionGeneration else { return }
                var mask = MaskContour.binaryMask(
                    fromLogits: logits.logits, width: logits.width, height: logits.height,
                    upsampledSide: Self.side
                )
                // Keep just the tapped object, not disconnected same-class blobs.
                mask = MaskContour.connectedComponent(
                    of: mask, side: Self.side,
                    seedX: Int(seed.u * Double(Self.side)), seedY: Int(seed.v * Double(Self.side))
                )
                currentMask = mask
                selectionLoops = MaskContour.normalizedLoops(fromBinary: mask, side: Self.side)
                Self.log("extract.mask_ok", [
                    "score": logits.score,
                    "points": points.count,
                    "mask_px": mask.lazy.filter { $0 != 0 }.count,
                    "mask_ms": Int(-t0.timeIntervalSinceNow * 1000),
                ])
            } catch {
                lastError = "Couldn't select that — try tapping elsewhere."
                Self.log("extract.mask_failed", [
                    "error": String(describing: error),
                    "mask_ms": Int(-t0.timeIntervalSinceNow * 1000),
                ])
            }
        }
    }

    /// Confirm the refined selection: cutout → lift. Clears the selection so
    /// the user can start picking the next object while this one lifts.
    func liftCurrentSelection() {
        guard let mask = currentMask else { return }
        addItem(fromMask: mask)
        clearSelection()
    }

    #if DEBUG && targetEnvironment(simulator)
    /// Sim-only: the simulator's Core ML zeroes SAM's decoder masks, so dev
    /// automation injects a synthetic circular mask and lifts it directly.
    func devFakeTap(u: Double, v: Double, radiusFraction: Double) {
        let s = Self.side
        var mask = [UInt8](repeating: 0, count: s * s)
        let cx = u * Double(s), cy = v * Double(s), r = radiusFraction * Double(s)
        for y in 0..<s {
            for x in 0..<s where pow(Double(x) - cx, 2) + pow(Double(y) - cy, 2) <= r * r {
                mask[y * s + x] = 1
            }
        }
        addItem(fromMask: mask)
    }
    #endif

    /// Cutout the masked region from the source and start its 3D lift.
    private func addItem(fromMask mask: [UInt8]) {
        guard let sourceCG = sourceImage.cgImage else {
            Self.log("extract.cutout_failed", ["reason": "no_source_cg"])
            return
        }
        let s = Self.side
        // Mask bitmap → gray CGImage.
        var bytes = [UInt8](repeating: 0, count: s * s)
        for i in 0..<(s * s) where mask[i] != 0 { bytes[i] = 255 }
        var minX = s, minY = s, maxX = -1, maxY = -1
        for y in 0..<s {
            for x in 0..<s where mask[y * s + x] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX > minX + 8, maxY > minY + 8 else {
            lastError = "That selection was too small."
            Self.log("extract.cutout_too_small", [
                "min_x": minX, "max_x": maxX, "min_y": minY, "max_y": maxY,
            ])
            return
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
              let maskCG = CGImage(
                  width: s, height: s, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: s,
                  space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            Self.log("extract.cutout_failed", ["reason": "mask_cgimage"])
            return
        }

        let extent = CGRect(x: 0, y: 0, width: s, height: s)
        var sourceCI = CIImage(cgImage: sourceCG)
        if sourceCG.width != s {
            sourceCI = sourceCI.transformed(by: CGAffineTransform(
                scaleX: CGFloat(s) / CGFloat(sourceCG.width),
                y: CGFloat(s) / CGFloat(sourceCG.height)
            ))
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = sourceCI
        blend.backgroundImage = CIImage(color: .clear).cropped(to: extent)
        blend.maskImage = CIImage(cgImage: maskCG).applyingGaussianBlur(sigma: 1).cropped(to: extent)
        guard let out = blend.outputImage else {
            Self.log("extract.cutout_failed", ["reason": "blend"])
            return
        }
        let pad = 4
        let bbox = CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(s, maxX + pad) - max(0, minX - pad),
            height: min(s, maxY + pad) - max(0, minY - pad)
        )
        let cropCI = CGRect(x: bbox.minX, y: CGFloat(s) - bbox.maxY, width: bbox.width, height: bbox.height)
        guard let cg = Self.ciContext.createCGImage(
            out, from: cropCI, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ) else {
            Self.log("extract.cutout_failed", ["reason": "render"])
            return
        }

        Self.log("extract.cutout_ok", ["cutout_w": Int(bbox.width), "cutout_h": Int(bbox.height)])
        let item = ExtractItem(
            cutout: UIImage(cgImage: cg),
            sizeFraction: CGSize(width: bbox.width / CGFloat(s), height: bbox.height / CGFloat(s))
        )
        items.insert(item, at: 0)
        lift(itemID: item.id)
    }

    /// Run the 3D lift for an item (Hunyuan via backend).
    private func lift(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        let cutout = items[index].cutout
        // fal's Hunyuan endpoint rejects images with any side under 128 px
        // ("Image resolution only support [128, 5000]", hit 2026-08-23 — a
        // small tapped object makes a tiny bbox crop). Upscale to a 256 px
        // short side (capped so the long side stays well under 5000).
        let minDim = max(min(cutout.size.width, cutout.size.height), 1)
        let maxDim = max(cutout.size.width, cutout.size.height, 1)
        let upscale = max(1, min(256 / minDim, 4000 / maxDim))
        let size = CGSize(
            width: (cutout.size.width * upscale).rounded(),
            height: (cutout.size.height * upscale).rounded()
        )
        // Hunyuan wants RGB — composite the transparent cutout on white.
        let format = UIGraphicsImageRendererFormat()
        format.preferredRange = .standard
        format.scale = 1
        let white = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            cutout.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = white.pngData() else {
            Self.log("extract.lift_failed", ["error": "cutout pngData() returned nil"])
            return
        }
        Self.log("extract.lift_started", [
            "png_bytes": png.count,
            "upload_w": Int(size.width), "upload_h": Int(size.height),
        ])
        Analytics.track(.liftStarted, properties: [
            "source": "extract",
            "upload_w": Int(size.width), "upload_h": Int(size.height),
        ])
        let t0 = Date()
        Task { @MainActor in
            do {
                let result = try await authService.lift3d(image: png)
                let ms = Int(-t0.timeIntervalSinceNow * 1000)
                Self.recordLiftDuration(ms: ms)
                Self.log("extract.lift_ok", ["glb_bytes": result.glb.count, "lift_ms": ms])
                Analytics.track(.liftCompleted, properties: [
                    "source": "extract", "duration_ms": ms, "glb_bytes": result.glb.count,
                ])
                if let i = items.firstIndex(where: { $0.id == itemID }) {
                    items[i].glb = result.glb
                    items[i].meshThumb = result.thumbnail.flatMap { UIImage(data: $0) }
                    items[i].state = .lifted
                    if !isPresented {
                        let name = persistToCollection(index: i)
                        onBackgroundLiftResult?(name ?? "Your object", true)
                    }
                }
            } catch {
                let ms = Int(-t0.timeIntervalSinceNow * 1000)
                if let i = items.firstIndex(where: { $0.id == itemID }) {
                    items[i].state = .failed
                }
                Self.log("extract.lift_failed", [
                    "error": String(describing: error), "lift_ms": ms,
                ])
                Analytics.track(.liftFailed, properties: [
                    "source": "extract", "duration_ms": ms,
                    "error": String(describing: error),
                ])
                if !isPresented {
                    onBackgroundLiftResult?("", false)
                }
            }
        }
    }

    func retry(_ item: ExtractItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[i].state = .lifting
        items[i].liftStartedAt = Date()
        lift(itemID: item.id)
    }

    /// Persist a lifted item into the object library.
    func saveToCollection(_ item: ExtractItem) {
        guard let i = items.firstIndex(where: { $0.id == item.id }),
              items[i].state == .lifted else { return }
        _ = persistToCollection(index: i)
    }

    /// Shared save path (Save button + background auto-save). Returns the
    /// saved object's name.
    @discardableResult
    private func persistToCollection(index i: Int) -> String? {
        guard let png = items[i].cutout.pngData() else { return nil }
        let count = (try? modelContext.fetchCount(FetchDescriptor<SavedObject>())) ?? 0
        let object = SavedObject(
            name: "Object \(count + 1)",
            imageData: png,
            docWidth: Double(items[i].sizeFraction.width) * 2048,
            docHeight: Double(items[i].sizeFraction.height) * 2048
        )
        object.meshData = items[i].glb
        object.meshThumbData = items[i].meshThumb?.pngData()
        modelContext.insert(object)
        try? modelContext.save()
        items[i].state = .saved
        Analytics.track(.objectExtracted)
        return object.name
    }
}

// Deliberately UIKit-free (Foundation + CoreGraphics + ImageIO instead) so the
// BrushHarness can compile this file for macOS and run the real engine headless —
// see BrushHarness/README.md. Keep it that way: UIImage/UIColor conversions belong
// in MetalCanvasView / CanvasViewModel, not here.
import Foundation
import CoreGraphics
import ImageIO
import Metal
import QuartzCore
import CoreImage
import simd

/// GPU-accelerated canvas renderer. Owns all Metal state: device, command queue,
/// pipeline states, textures. `MetalCanvasView` owns one of these and delegates
/// all rendering to it.
///
/// Architecture:
///   - One `canvasTexture` per layer (persistent drawing surface).
///   - One `scratchTexture` for the active stroke (rebuilt each frame from
///     accumulated stamp instances; memoryless — never stored to system memory).
///   - Compositing pass: layers bottom-to-top → scratch overlay → drawable.
///   - Brush mask texture: soft-circle (quadratic falloff), generated once at init.
public final class CanvasRenderer {

    // MARK: - Metal Core

    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // MARK: - Pipeline States

    private let brushStampPSO: MTLRenderPipelineState
    /// Textured-shape brush (pro-brush Phase 3): samples a grayscale stamp mask instead
    /// of the procedural circle. Same source-over blend as `brushStampPSO`. Optional only
    /// for defensive degradation to the round brush if compilation ever fails.
    private let shapedBrushStampPSO: MTLRenderPipelineState?
    /// P8 grain: a compositor variant that carves the SCRATCH's accumulated alpha with
    /// the document-space grain as it's composited (live preview + flatten). Applying at
    /// composite time — once per stroke pixel, not per dab — is what keeps overlapping
    /// stamps from refilling the tooth (Procreate's "Texturized" behavior).
    private let grainCompositorPSO: MTLRenderPipelineState?
    /// P4a: shaped-tip fragment that maps tip luma → ink VALUE (Schatz quadratic in sRGB).
    private let lightnessShapedStampPSO: MTLRenderPipelineState?
    /// Procedural tileable grain textures (256² R8), generated once at init from
    /// deterministic hash noise — no bundle resources, so BrushHarness gets them free.
    private let grainTextures: [String: MTLTexture]
    private let eraserStampPSO: MTLRenderPipelineState
    /// Wet-mix brush: programmable framebuffer-read RMW into the layer (pro-brush
    /// Phase 4). nil if pipeline creation failed (e.g. on the Simulator, which doesn't
    /// support framebuffer fetch) — callers must guard on it.
    private let wetStampPSO: MTLRenderPipelineState?
    /// Wet INK via scratch (P7 core) — texture-sampled KM, no framebuffer fetch.
    private let wetInkScratchPSO: MTLRenderPipelineState?
    /// Max-blend dry stamp PSOs (moving grain — see makeMaxBlendStampPSO).
    private let brushStampMaxPSO: MTLRenderPipelineState?
    private let shapedStampMaxPSO: MTLRenderPipelineState?
    private let lightnessShapedStampMaxPSO: MTLRenderPipelineState?

    /// False where framebuffer fetch is unsupported (the Simulator), i.e. the wet PSO
    /// failed to build. Callers use this to skip wet-stroke bookkeeping (undo snapshot,
    /// dirty/stroke count) so an invisible no-op stroke doesn't create undo entries.
    var isWetRenderingAvailable: Bool { wetStampPSO != nil }
    /// Wet ink (scratch path) has no framebuffer-fetch dependency — true wherever the
    /// PSO compiled (including the Simulator). Smudge still needs `isWetRenderingAvailable`.
    var isWetInkAvailable: Bool { wetInkScratchPSO != nil }
    private let compositorPSO: MTLRenderPipelineState
    /// Compositor variant whose blend preserves the DESTINATION's alpha
    /// exactly (out.a = dst.a; src rgb is scaled by dst.a) — the alpha-locked
    /// stroke flatten. Fixed-function, so it works on the simulator too.
    private lazy var alphaLockCompositorPSO: MTLRenderPipelineState? =
        Self.makeAlphaLockCompositorPSO(device: device, library: library)

    /// Debug toggle for the Phase-4 draw-order experiment: when true, wet stamps are
    /// issued as N separate single-instance draws (serialized by submission order)
    /// instead of one instanced draw, to A/B whether overlapping wet stamps need
    /// explicit ordering. Default false (one instanced draw — the cheap path).
    var wetOrderingPerStamp = false

    // MARK: - Wet Kubelka-Munk tables (pro-brush Phase 4 Step 2)
    // Spectral pigment-mixing model (tuned in km_tune_final spike). Mixing happens in a
    // 36-band reflectance spectrum: RGB→spectrum (Mallett-Yuksel 7-basis), KM-mix per
    // band, integrate back to linear RGB, with endpoint-exact residual correction.
    static let wetNB = 36
    /// 7 basis reflectance spectra × 36 bands, k-major (basis k, band i → [k*36+i]).
    private var wetBasisBuffer: MTLBuffer?
    /// 36 bands × 3 (linear-RGB contribution per unit reflectance), band-major ([i*3+c]).
    private var wetMatBuffer: MTLBuffer?
    private var wetBasisD: [[Double]] = []          // CPU copy for brush-color upsampling
    private var wetMat: [SIMD3<Double>] = []        // CPU copy: spectrum band → linear RGB

    /// Cached CIContext for texture→CGImage conversion. CIImage handles sRGB
    /// conversion and premultiplied alpha correctly, avoiding the color artifacts
    /// from manual getBytes + CGDataProvider construction.
    private let ciContext: CIContext
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let linearSRGBColorSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!

    // MARK: - Layers

    /// A canvas layer: texture + metadata. CanvasRenderer is the single source
    /// of truth for layer state — MetalCanvasView reads from here.
    struct Layer {
        let id: UUID
        var name: String
        var isVisible: Bool
        /// Fully locked: brush/eraser/clear are refused for this layer.
        var isLocked: Bool = false
        /// Alpha lock: flatten preserves the layer's alpha channel, so strokes
        /// only land where content already exists.
        var isAlphaLocked: Bool = false
        /// Composite-time blend mode; never baked into the texture.
        var blendMode: LayerBlendMode = .normal
        /// Composite-time whole-layer opacity 0…1; never baked into the texture.
        var opacity: Float = 1
        let texture: MTLTexture
    }

    /// All canvas layers. Index 0 = bottom (drawn first).
    /// Internal setter: MetalCanvasView updates metadata during load.
    var layers: [Layer] = []

    /// Which layer receives brush/eraser/lasso operations.
    private(set) var activeLayerIndex: Int = 0

    /// Convenience: the texture for the currently active layer.
    var activeLayerTexture: MTLTexture? {
        guard activeLayerIndex >= 0, activeLayerIndex < layers.count else { return nil }
        return layers[activeLayerIndex].texture
    }

    /// Scratch texture for the active (in-progress) stroke. Rebuilt each frame
    /// from stamp instances; conceptually memoryless between frames.
    private(set) var scratchTexture: MTLTexture?

    /// Overlay-stroke accumulation texture (overlay drawing mode only). Holds the
    /// fresh strokes drawn *since the last generated frame* — a visual-only surface
    /// shown above the opaque generated image in `.overlay` layout. NOT part of the
    /// drawing/generation pipeline: it never feeds the canvas layers, has no undo,
    /// no layers, and is wiped (`clearOverlayStrokes`) on every returned generation
    /// frame. Allocated lazily on first overlay use so split-screen/fullscreen never
    /// pay for it. `.bgra8Unorm_srgb` + `.shared`, identical format to the canvas so
    /// the exact same stamp pipeline + color path applies (linear `s2l` premultiplied).
    private(set) var overlayStrokeTexture: MTLTexture?

    /// Per-stroke opacity ceiling for the live render path — the on-screen preview
    /// (`compositeToDrawable`) and the stroke-end flatten (`flattenScratchIntoCanvas`).
    /// `MetalCanvasView` sets this immediately before each of those calls, so it's never
    /// read stale (and only read at all when `stampCount > 0`). Stamp alpha carries the
    /// brush's flow; this caps the whole stroke. Snapshot/export paths take an explicit
    /// `strokeOpacity` parameter instead of reading this, so they don't depend on render
    /// ordering. Layers and the lasso selection always composite at 1.0.
    var activeStrokeOpacity: Float = 1.0

    /// Soft-circle brush mask (single-channel, R8Unorm). Quadratic falloff:
    /// α(r) = (1 − (r/R)²)², matching the plan's 5-stop gradient.
    private let brushMaskTexture: MTLTexture

    /// Loaded grayscale stamp textures keyed by `BrushShapeDescriptor.id` (pro-brush
    /// Phase 3). Built once at init from `Resources/BrushShapes`. The procedural round
    /// brush has no entry here.
    private let shapeTextures: [String: MTLTexture]
    /// Runtime caches for user-imported assets (loaded lazily from
    /// `BrushAssetStore.directory` when an id isn't in the built-in catalogs).
    private var userShapeTextures: [String: MTLTexture] = [:]
    private var userShapeLumaMeans: [String: Float] = [:]
    private var userGrainTextures: [String: (texture: MTLTexture, tilePx: Double)] = [:]
    /// 1×1 black — bound to the stamp fragments' moving-grain slot when moving grain is
    /// off (Metal requires referenced textures to be bound; the enabled flag gates use).
    private let blackDummyTexture: MTLTexture
    /// Mean in-shape luma per tip id (P4a recentering; see `shapeMeanLuma`).
    private let shapeLumaMeans: [String: Float]

    /// The stamp texture for the stroke currently being drawn/flattened, or nil for the
    /// procedural round brush. `MetalCanvasView` sets this when a stroke starts (alongside
    /// `activeStrokeOpacity`); the live + flatten render paths read it to pick the shaped
    /// PSO and bind the texture.
    var activeShapeTexture: MTLTexture?

    /// Grain settings for the stroke currently being drawn/flattened (P8), or nil for
    /// no grain. `MetalCanvasView` resolves from the brush at stroke start; the live +
    /// flatten stamp passes read it to pick the grain PSO + bind the texture/params.
    /// depth [0,1]; invScale multiplies document-space pixel coords into grain UV.
    /// One resolved grain binding: texture + carve depth + UV scale, plus the
    /// moving-mode frame factors (Movement smear↔rolling anisotropy, per-stroke
    /// Offset Jitter, Rotation) and the shared adjustments (Depth Minimum,
    /// Brightness/Contrast). All precomputed here so the shaders just consume.
    struct GrainSettings {
        let texture: MTLTexture
        let moving: Bool
        let depth: Float
        let invScale: Float
        let alongMul: Float     // moving: along-stroke UV factor (smear 0.45 → rolling 1)
        let latMul: Float       // moving: lateral UV factor (smear 3.5 → rolling 1)
        let offU: Float         // moving: per-stroke Offset Jitter, canvas px
        let offV: Float
        let cosR: Float         // moving: Rotation vs stroke direction
        let sinR: Float
        let brightness: Float   // both modes: grain pre-adjust [-1,1]
        let contrastMul: Float  // both modes: precomputed multiplier (pow(3, contrast))
        let depthMin: Float     // moving: floor for modulated (pressure/jitter) depth
    }
    var activeGrain: GrainSettings?

    /// P4a lightness-map uniform for the stroke being drawn/flattened, or nil for the
    /// flat-ink path: (hue, saturation, lightness z of the brush sRGB color, strength).
    /// Precomputed CPU-side so the fragment only runs quadratic + HSL→RGB + s2l.
    var activeLightness: (params: SIMD4<Float>, recenter: SIMD4<Float>)?
    /// Tip-art mirror for the ACTIVE brush (Flip X/Y, cheap-knobs batch 2): (1,0)/(0,1)
    /// flags fed to the stamp vertex's UV flip. Zero for eraser/wet/round.
    var activeFlip = SIMD2<Float>(0, 0)
    /// True while the ACTIVE stroke is wet INK (non-smudge): the scratch stamp pass
    /// routes through `wetInkScratchPSO` (KM vs the pristine canvas) instead of the dry
    /// brush PSOs. Set per frame by MetalCanvasView alongside activeGrain/activeLightness.
    var activeWetInk = false

    /// Quad vertex buffer: 6 vertices for two triangles covering [-1,1]² with
    /// texcoords [0,1]². Shared by brush stamps and compositor.
    private let quadVertexBuffer: MTLBuffer

    // MARK: - Canvas State

    /// Fixed document resolution (square), decoupled from the view's pixel size.
    private(set) var canvasWidth: Int = 0
    private(set) var canvasHeight: Int = 0
    /// Live canvas-pixels-per-view-point ratio (document side ÷ current view
    /// width). Unlike a retina scale this varies with the view size while the
    /// document stays fixed. Refreshed every layout by `configureDocument`.
    private(set) var canvasScale: CGFloat = 1

    var hasCanvas: Bool { !layers.isEmpty }

    /// Maximum number of layers allowed.
    static let maxLayerCount = 16

    // MARK: - Selection State (active during lasso floating phase)

    /// The extracted selection pixels (canvas-only, no background baked in).
    private(set) var selectionTexture: MTLTexture?
    /// Bounding box of the selection in canvas-pixel coordinates.
    private(set) var selectionBounds: CGRect = .zero
    /// Vertex buffer for the selection quad, recomputed when transform changes.
    private var selectionVertexBuffer: MTLBuffer?
    /// Whether a floating selection is active.
    var hasActiveSelection: Bool { selectionTexture != nil }
    /// Pipeline for masked copy (canvas → selection texture).
    private var maskedCopyPSO: MTLRenderPipelineState?
    /// Pipeline for masked clear (clear canvas inside lasso mask, destination-out).
    private var maskedClearPSO: MTLRenderPipelineState?

    // MARK: - Stamp Instance Buffer

    /// Per-frame stamp instances for the active stroke. Populated by
    /// `MetalCanvasView` during touch handling; consumed during render.
    struct StampInstance {
        var center: SIMD2<Float>    // canvas pixel coords
        var radius: Float           // pressure-modulated
        var rotation: Float         // pencil azimuth
        var color: SIMD4<Float>     // premultiplied RGBA
        var hardness: Float = 1.0   // edge hardness [0,1]; 1 = crisp. Default hard for shapes/eraser.
        // P4b anisotropy: local-Y scale of the stamp quad, applied BEFORE rotation.
        // 1 = round (all legacy stamps); <1 flattens the tip into a chisel/nib. Lives in
        // the 12 bytes of tail padding after `hardness` (SIMD4 16-byte alignment), so the
        // stride stays 48 and the MSL struct matches — keep both declarations in sync.
        var aspect: Float = 1.0
        // Smudge alpha-carry (2026-07-15): the target alpha the wet fragment moves dst.a
        // toward at the deposit rate. -1 = legacy coverage mode (wet INK builds opaque
        // by coverage — unchanged). Smudge packs its carried load's alpha here, so
        // smudging 40%-opacity paint keeps it ~40% instead of opacifying, and the
        // drag-off tail thins as the load depletes. Also in padding; stride stays 48.
        var wetTargetAlpha: Float = -1.0
        // Moving grain (2026-07-16): the dab's arc position along its stroke, in canvas
        // px — the along-stroke grain coordinate, so the tooth travels WITH the stroke
        // (streaky dry media) instead of living in document space.
        var arcU: Float = 0
        // Per-dab grain-depth multiplier (grain CurveOption, 2026-07-16): sensors drive
        // how much tooth each dab shows — pressure fills the tooth, light touch reveals
        // it. Consumed by movingGrainCarve only (document grain gets its pressure
        // response through flow at the composite carve). This field grew the stride
        // from 48 to 64 (SIMD4 alignment) — the MSL mirror pads explicitly; keep both
        // declarations in sync.
        var grainMul: Float = 1.0
        // Flat-sided interior dab (2026-07-16, the Procreate square-stamp insight): 1 =
        // the procedural tip uses a stroke-aligned SUPERELLIPSE (x⁴+y⁴ metric — flat
        // sides, rounded corners) so consecutive dabs slide into a mathematically flat
        // edge (circle scallop sag ~0.35px at the spacing cap; superellipse ~0.003px).
        // Only interior walk dabs of smooth-intent procedural strokes set it; first/cap
        // dabs stay round so stroke ENDS keep the round brush-tip profile. (In the pad
        // space of the 64-byte stride; two pad floats remain.)
        var edgeFlat: Float = 0
    }

    /// Initial stamp-buffer capacity. 240 Hz pencil × ~6 interpolated steps per
    /// touch ≈ 3000 covers the incremental case, but the brush path regenerates
    /// the ENTIRE stroke's stamps every frame (and funnels the same buffer into
    /// the permanent flatten), so a long dense stroke can exceed any fixed cap.
    /// The buffer grows by doubling on demand; the hard ceiling only bounds
    /// pathological cases (64 B/stamp × 262144 = 16 MB).
    private static let initialStampCapacity = 4096
    private static let maxStampCapacity = 262_144
    private var stampBuffer: MTLBuffer
    private var stampCapacity = CanvasRenderer.initialStampCapacity
    private(set) var stampCount: Int = 0

    // MARK: - Init

    init?() {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.ciContext = CIContext(mtlDevice: device, options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

        // Compile shaders from embedded source.
        guard let lib = try? device.makeLibrary(source: Self.shaderSource, options: nil) else {
            return nil
        }
        self.library = lib

        // Build pipeline states.
        guard let brushPSO = Self.makeBrushStampPSO(device: device, library: lib, eraser: false),
              let erasePSO = Self.makeBrushStampPSO(device: device, library: lib, eraser: true),
              let compPSO = Self.makeCompositorPSO(device: device, library: lib) else {
            return nil
        }
        self.brushStampPSO = brushPSO
        self.eraserStampPSO = erasePSO
        self.compositorPSO = compPSO
        // Textured-shape brush PSO (pro-brush Phase 3). Optional: degrade to round if it
        // ever fails to compile.
        self.shapedBrushStampPSO = Self.makeShapedBrushStampPSO(device: device, library: lib)
        self.grainCompositorPSO = Self.makeGrainStampPSO(device: device, library: lib, fragment: "grainCompositorFragment", vertex: "compositorVertex")
        self.lightnessShapedStampPSO = Self.makeGrainStampPSO(device: device, library: lib, fragment: "lightnessShapedStampFragment")
        self.grainTextures = Self.makeGrainTextures(device: device, queue: commandQueue)
        // Wet PSO uses framebuffer fetch — unsupported on the Simulator, so this may
        // be nil there; the wet tool guards on it and no-ops if unavailable.
        self.wetStampPSO = Self.makeWetStampPSO(device: device, library: lib)
        self.wetInkScratchPSO = Self.makeWetInkScratchPSO(device: device, library: lib)
        self.brushStampMaxPSO = Self.makeMaxBlendStampPSO(device: device, library: lib, fragment: "brushStampFragment")
        self.shapedStampMaxPSO = Self.makeMaxBlendStampPSO(device: device, library: lib, fragment: "shapedStampFragment")
        self.lightnessShapedStampMaxPSO = Self.makeMaxBlendStampPSO(device: device, library: lib, fragment: "lightnessShapedStampFragment")
        self.maskedCopyPSO = Self.makeMaskedCopyPSO(device: device, library: lib)
        self.maskedClearPSO = Self.makeMaskedClearPSO(device: device, library: lib)

        // Quad vertex buffer (shared).
        let quadVerts: [Float] = [
            // pos.x, pos.y, tex.u, tex.v
            -1, -1,  0, 1,
             1, -1,  1, 1,
            -1,  1,  0, 0,
            -1,  1,  0, 0,
             1, -1,  1, 1,
             1,  1,  1, 0,
        ]
        guard let qbuf = device.makeBuffer(bytes: quadVerts, length: quadVerts.count * MemoryLayout<Float>.size, options: .storageModeShared) else { return nil }
        self.quadVertexBuffer = qbuf

        // Stamp instance buffer.
        let stampBufSize = Self.initialStampCapacity * MemoryLayout<StampInstance>.stride
        guard let sbuf = device.makeBuffer(length: stampBufSize, options: .storageModeShared) else { return nil }
        self.stampBuffer = sbuf

        // Brush mask texture (64×64 soft circle).
        guard let mask = Self.generateBrushMask(device: device, size: 64) else { return nil }
        self.brushMaskTexture = mask

        // Moving-grain dummy (see property doc).
        let dummyDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        dummyDesc.usage = .shaderRead
        guard let dummy = device.makeTexture(descriptor: dummyDesc) else { return nil }
        var zero: UInt8 = 0
        dummy.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &zero, bytesPerRow: 1)
        self.blackDummyTexture = dummy

        // Load textured brush-shape stamps (pro-brush Phase 3). Missing/failed assets are
        // skipped — that shape just falls back to the procedural round brush at draw time.
        let shapes = Self.loadShapeTextures(device: device, queue: queue)
        self.shapeTextures = shapes.textures
        self.shapeLumaMeans = shapes.lumaMeans

        // All stored properties initialized — build the wet KM spectral tables.
        setupWetKMTables()
    }

    // MARK: - Texture Management

    /// Reusable texture descriptor for canvas-sized layers.
    private func makeLayerDescriptor() -> MTLTextureDescriptor {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: canvasWidth,
            height: canvasHeight,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        return desc
    }

    /// Allocate the document layer textures at a FIXED resolution, decoupled from
    /// the view's pixel size. The compositor scales this document texture to the
    /// drawable (`compositeToDrawable`), so view/layout changes — a modal
    /// present/dismiss that perturbs the canvas bounds, the fullscreen↔split-screen
    /// toggle, rotation — only restride the *display*. They never reallocate or
    /// resample the document, so the drawing's resolution is never degraded and
    /// strokes are never wiped.
    ///
    /// `viewScale` is the live canvas-pixels-per-view-point ratio (document side ÷
    /// view width). It changes as the view resizes even though the texture doesn't,
    /// so it's refreshed on every call (before the allocation guard) to keep
    /// touch→texture mapping and the floating selection transform correct.
    func configureDocument(side: Int, viewScale: CGFloat = 0) {
        if viewScale > 0 { canvasScale = viewScale }
        guard side > 0 else { return }
        // Document resolution is fixed for the canvas's lifetime: allocate once,
        // then short-circuit on every subsequent layout pass.
        guard side != canvasWidth || side != canvasHeight else {
            return
        }

        canvasWidth = side
        canvasHeight = side

        let desc = makeLayerDescriptor()
        guard let tex = device.makeTexture(descriptor: desc) else {
            canvasWidth = 0; canvasHeight = 0
            return
        }
        clearTexture(tex)
        layers = [Layer(id: UUID(), name: "Layer 1", isVisible: true, texture: tex)]
        activeLayerIndex = 0
        scratchTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - Layer Management

    /// Add a new empty layer on top. Returns the index of the new layer.
    @discardableResult
    func addLayer(name: String = "Layer", id: UUID = UUID()) -> Int {
        guard layers.count < Self.maxLayerCount else { return activeLayerIndex }
        let desc = makeLayerDescriptor()
        guard let texture = device.makeTexture(descriptor: desc) else { return activeLayerIndex }
        clearTexture(texture)
        layers.append(Layer(id: id, name: name, isVisible: true, texture: texture))
        return layers.count - 1
    }

    /// Remove a layer. Must keep at least 1 layer.
    func removeLayer(at index: Int) {
        guard layers.count > 1, index >= 0, index < layers.count else { return }
        layers.remove(at: index)
        if activeLayerIndex >= layers.count {
            activeLayerIndex = layers.count - 1
        } else if activeLayerIndex > index {
            activeLayerIndex -= 1
        }
    }

    /// Set the active layer index.
    func setActiveLayer(_ index: Int) {
        guard index >= 0, index < layers.count else { return }
        activeLayerIndex = index
    }

    /// Toggle visibility for a layer.
    func toggleVisibility(at index: Int) {
        guard index >= 0, index < layers.count else { return }
        layers[index].isVisible.toggle()
    }

    /// Rename a layer.
    func renameLayer(at index: Int, to name: String) {
        guard index >= 0, index < layers.count else { return }
        layers[index].name = name
    }

    /// Toggle the full edit lock for a layer.
    func setLocked(_ locked: Bool, at index: Int) {
        guard index >= 0, index < layers.count else { return }
        layers[index].isLocked = locked
    }

    /// Toggle alpha lock for a layer.
    func setAlphaLocked(_ locked: Bool, at index: Int) {
        guard index >= 0, index < layers.count else { return }
        layers[index].isAlphaLocked = locked
    }

    /// Set a layer's composite blend mode.
    func setBlendMode(_ mode: LayerBlendMode, at index: Int) {
        guard index >= 0, index < layers.count else { return }
        layers[index].blendMode = mode
    }

    /// Set a layer's composite opacity (clamped 0…1).
    func setLayerOpacity(_ opacity: Float, at index: Int) {
        guard index >= 0, index < layers.count else { return }
        layers[index].opacity = min(1, max(0, opacity))
    }

    /// Duplicate a layer: blit-copy its texture and insert the copy directly
    /// above the source. Returns the new layer's index, or nil at the layer
    /// cap / on allocation failure. The copy carries visibility + alpha lock
    /// but drops the full lock (Procreate duplicates unlocked-editable too,
    /// and a locked fresh copy is never what the user wants).
    func duplicateLayer(at index: Int) -> Int? {
        guard layers.count < Self.maxLayerCount,
              index >= 0, index < layers.count else { return nil }
        let source = layers[index]
        let desc = makeLayerDescriptor()
        guard let texture = device.makeTexture(descriptor: desc),
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let blit = cmdBuf.makeBlitCommandEncoder() else { return nil }
        blit.copy(from: source.texture, to: texture)
        blit.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted() // cold path: menu action, not per-frame
        let copy = Layer(id: UUID(), name: source.name + " copy",
                         isVisible: source.isVisible, isLocked: false,
                         isAlphaLocked: source.isAlphaLocked,
                         blendMode: source.blendMode, opacity: source.opacity,
                         texture: texture)
        let newIndex = index + 1
        layers.insert(copy, at: newIndex)
        if activeLayerIndex >= newIndex { activeLayerIndex += 1 }
        return newIndex
    }

    /// Clear one layer's texture to transparent (cold path — menu action).
    func clearLayer(at index: Int) {
        guard index >= 0, index < layers.count else { return }
        clearTexture(layers[index].texture)
    }

    /// Reorder a layer from one position to another.
    func moveLayer(from source: Int, to destination: Int) {
        guard source >= 0, source < layers.count,
              destination >= 0, destination < layers.count,
              source != destination else { return }
        let layer = layers.remove(at: source)
        layers.insert(layer, at: destination)

        // Adjust active layer index to follow the moved layer if needed.
        if activeLayerIndex == source {
            activeLayerIndex = destination
        } else {
            if activeLayerIndex > source { activeLayerIndex -= 1 }
            if activeLayerIndex >= destination { activeLayerIndex += 1 }
        }
    }

    /// A full snapshot of one layer (bytes + metadata) for compound undo
    /// entries that must survive layer-structure changes (clearAll).
    struct LayerStackSnapshot {
        let id: UUID
        let name: String
        let isVisible: Bool
        let isLocked: Bool
        let isAlphaLocked: Bool
        let blendMode: LayerBlendMode
        let opacity: Float
        let data: Data
    }

    /// Stable id for a layer index (nil if out of range).
    func layerID(at index: Int) -> UUID? {
        guard index >= 0, index < layers.count else { return nil }
        return layers[index].id
    }

    /// Current index of a layer id (nil if the layer was deleted).
    func layerIndex(id: UUID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    /// Snapshot every layer (bytes + metadata) plus the active index.
    /// Returns nil if any layer read fails — a partial stack snapshot would
    /// restore a corrupted document.
    func snapshotLayerStack() -> (layers: [LayerStackSnapshot], activeIndex: Int)? {
        var snaps: [LayerStackSnapshot] = []
        for (i, layer) in layers.enumerated() {
            guard let data = snapshotLayer(at: i) else { return nil }
            snaps.append(LayerStackSnapshot(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                                            isLocked: layer.isLocked, isAlphaLocked: layer.isAlphaLocked,
                                            blendMode: layer.blendMode, opacity: layer.opacity,
                                            data: data))
        }
        return (snaps, activeLayerIndex)
    }

    /// Rebuild the whole layer stack from a snapshot (inverse of
    /// `snapshotLayerStack`). Used to undo/redo clearAll.
    func restoreLayerStack(_ snaps: [LayerStackSnapshot], activeIndex: Int) {
        guard !snaps.isEmpty else { return }
        var rebuilt: [Layer] = []
        for snap in snaps {
            let desc = makeLayerDescriptor()
            guard let tex = device.makeTexture(descriptor: desc) else { return }
            clearTexture(tex)
            rebuilt.append(Layer(id: snap.id, name: snap.name, isVisible: snap.isVisible,
                                 isLocked: snap.isLocked, isAlphaLocked: snap.isAlphaLocked,
                                 blendMode: snap.blendMode, opacity: snap.opacity, texture: tex))
        }
        layers = rebuilt
        activeLayerIndex = min(max(0, activeIndex), layers.count - 1)
        for (i, snap) in snaps.enumerated() {
            restoreLayer(at: i, from: snap.data)
        }
    }

    /// Reset to a single empty layer. Used by clearAll.
    func resetToSingleLayer() {
        let desc = makeLayerDescriptor()
        guard let tex = device.makeTexture(descriptor: desc) else { return }
        clearTexture(tex)
        layers = [Layer(id: UUID(), name: "Layer 1", isVisible: true, texture: tex)]
        activeLayerIndex = 0
    }

    // MARK: - Stamp Buffer

    func clearStamps() {
        stampCount = 0
    }

    func appendStamp(_ stamp: StampInstance) {
        if stampCount == stampCapacity {
            guard growStampBuffer() else { return } // at the hard ceiling — drop
        }
        let ptr = stampBuffer.contents().bindMemory(to: StampInstance.self, capacity: stampCapacity)
        ptr[stampCount] = stamp
        stampCount += 1
    }

    /// Double the stamp buffer. The old buffer is only swapped out of the
    /// property — any in-flight command buffer that encoded it keeps its own
    /// retain, so this is safe mid-stroke.
    private func growStampBuffer() -> Bool {
        guard stampCapacity < Self.maxStampCapacity else { return false }
        let newCapacity = min(stampCapacity * 2, Self.maxStampCapacity)
        guard let newBuf = device.makeBuffer(
            length: newCapacity * MemoryLayout<StampInstance>.stride,
            options: .storageModeShared
        ) else { return false }
        memcpy(newBuf.contents(), stampBuffer.contents(), stampCount * MemoryLayout<StampInstance>.stride)
        stampBuffer = newBuf
        stampCapacity = newCapacity
        return true
    }

    // MARK: - Rendering

    /// Render one frame: clear scratch → draw stamps into scratch → composite
    /// all visible layers + scratch into the given drawable texture.
    func renderFrame(drawable: CAMetalDrawable, isErasing: Bool) {
        guard !layers.isEmpty, let scratch = scratchTexture else {
            return
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Clear scratch + render stamps into it.
        renderStampsIntoScratch(commandBuffer: cmdBuf, scratch: scratch, isEraser: isErasing)

        // Pass 2: Composite all visible layers + scratch into the drawable.
        compositeToDrawable(commandBuffer: cmdBuf, drawable: drawable, scratch: scratch)

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Flatten the scratch texture into the active layer (stroke completion).
    /// Source-over blend. Eraser does not use this path — it writes directly
    /// to the canvas via `applyEraserStamps`.
    /// Draw the scratch through the grain compositor when `grain` is set, else the
    /// plain compositor. Restores the plain compositor PSO afterwards so surrounding
    /// draws in the same encoder are unaffected. (P8: grain carves at composite time.)
    private func drawScratch(_ enc: MTLRenderCommandEncoder, scratch: MTLTexture, opacity: Float,
                             grain: GrainSettings?) {
        var op = opacity
        // Moving grain carves per DAB in the stamp fragments — at composite time it must
        // be a plain draw or the tooth would be applied twice.
        if let grain, !grain.moving, let grainPSO = grainCompositorPSO {
            enc.setRenderPipelineState(grainPSO)
            enc.setFragmentTexture(scratch, index: 0)
            enc.setFragmentBytes(&op, length: MemoryLayout<Float>.size, index: 0)
            bindGrainCompositor(enc, grain)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.setRenderPipelineState(compositorPSO)
        } else {
            enc.setRenderPipelineState(compositorPSO)
            enc.setFragmentTexture(scratch, index: 0)
            enc.setFragmentBytes(&op, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    func flattenScratchIntoCanvas() {
        guard let canvas = activeLayerTexture, let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Re-render the scratch from the CURRENT stamp buffer before compositing.
        // Historically flatten only composited the last FRAME's scratch — but both
        // flatten call sites mutate the stamp set right before flattening (stabilizer
        // catch-up tail, end cap), and no display frame runs in between, so those final
        // stamps silently never reached the canvas (found 2026-07-16 during the wet-ink
        // rework). Re-rendering is idempotent when nothing changed.
        renderStampsIntoScratch(commandBuffer: cmdBuf, scratch: scratch, isEraser: false)

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        if layers.indices.contains(activeLayerIndex), layers[activeLayerIndex].isAlphaLocked,
           let lockPSO = alphaLockCompositorPSO {
            // Alpha lock: flatten through the dst-alpha-preserving blend so the
            // stroke only lands where the layer already has content. Grain is
            // bypassed here (the grain compositor has no alpha-lock variant);
            // the live preview is NOT masked — the scratch composites over the
            // whole stack on screen — so the stroke visually clips on lift.
            var op = activeStrokeOpacity
            enc.setRenderPipelineState(lockPSO)
            enc.setFragmentTexture(scratch, index: 0)
            enc.setFragmentBytes(&op, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        } else {
            drawScratch(enc, scratch: scratch, opacity: activeStrokeOpacity, grain: activeGrain)
        }
        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Overlay Stroke Surface (overlay drawing mode)

    /// Lazily allocate the overlay-stroke accumulation texture (overlay mode only),
    /// matching the document resolution + format. Cleared to transparent. No-op if
    /// the document isn't configured yet or the texture already exists.
    func ensureOverlayStrokeTexture() {
        guard overlayStrokeTexture == nil, canvasWidth > 0, canvasHeight > 0 else {
            return
        }
        let desc = makeLayerDescriptor()
        guard let tex = device.makeTexture(descriptor: desc) else {
            return
        }
        clearTexture(tex)
        overlayStrokeTexture = tex
    }

    /// Wipe the overlay-stroke accumulation texture to fully transparent. Called on
    /// every returned generation frame (still + video, ~2 FPS) so fresh strokes flash,
    /// then the generated image takes over. No-op when the overlay texture isn't
    /// allocated (i.e. not in overlay mode) → harmless in split-screen/fullscreen.
    ///
    /// Uses an async clear render pass — NOT the blocking `clearTexture` — because
    /// this runs on the (main-thread) per-generation-frame cadence, and the overlay is
    /// visual-only: it's same-queue-ordered with the next `renderOverlayFrame`, so no
    /// CPU-coherent readback/`waitUntilCompleted` is needed. (`clearTexture`'s wait is
    /// reserved for alloc/resize, per CanvasModule/CLAUDE.md.)
    func clearOverlayStrokes() {
        guard let tex = overlayStrokeTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tex
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        cmdBuf.commit()
    }

    /// Release the overlay-stroke accumulation texture (~16 MB) when leaving overlay
    /// mode, so split-screen/fullscreen don't carry it for the canvas's lifetime after
    /// a single overlay visit. Re-allocated lazily (`ensureOverlayStrokeTexture`) on the
    /// next overlay activation — and because the fresh texture is cleared on alloc, this
    /// also guarantees stale strokes from a prior overlay session never reappear.
    func releaseOverlayStrokeTexture() {
        overlayStrokeTexture = nil
    }

    /// Render the overlay-stroke surface into its own drawable: the accumulated
    /// overlay strokes (source-over) plus the live in-progress stroke (the same
    /// `scratch` the canvas uses this frame), capped at `activeStrokeOpacity`.
    /// Transparent everywhere there's no stroke so the opaque generated image
    /// underneath shows through. Mirrors `compositeToDrawable`'s blend setup, so
    /// color is identical to the canvas (linear `s2l` premultiplied → `_srgb` store).
    ///
    /// Runs on the same display tick as `renderFrame`; the scratch already holds this
    /// frame's stamps (populated by the caller before `renderFrame`), so no extra
    /// stamp work is added. No `waitUntilCompleted` — async present, hot-path safe.
    ///
    /// Takes the LAYER, not a pre-acquired drawable: `nextDrawable()` is called only
    /// AFTER the render guards pass, so we never acquire a drawable we won't present.
    /// Acquiring without presenting (e.g. when `overlayStrokeTexture` isn't allocated
    /// yet on the first frames after entering overlay mode) leaks the drawable, and
    /// after the 2-deep pool exhausts `nextDrawable()` blocks the main thread forever
    /// → hard UI freeze. (Root cause of the 2026-06-22 gallery freeze.)
    func renderOverlayFrame(layer: CAMetalLayer) {
        guard let overlay = overlayStrokeTexture, let scratch = scratchTexture else {
            return
        }
        guard let drawable = layer.nextDrawable() else {
            return
        }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(compositorPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        // Accumulated overlay strokes (full opacity — already flattened at their ceiling).
        var full: Float = 1.0
        enc.setFragmentTexture(overlay, index: 0)
        enc.setFragmentBytes(&full, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Live in-progress stroke on top, capped at the per-stroke opacity ceiling;
        // grain-aware (P8) so the overlay preview matches the committed look.
        if stampCount > 0 {
            drawScratch(enc, scratch: scratch, opacity: activeStrokeOpacity, grain: activeGrain)
        }

        enc.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Flatten the active stroke's `scratch` into the overlay accumulation texture
    /// (stroke completion in overlay mode). Source-over, capped at `strokeOpacity` —
    /// the same ceiling the canvas applies, so the accumulated overlay matches the
    /// live preview. No-op when the overlay texture isn't allocated. Async commit
    /// (no `waitUntilCompleted`): this is the visual-only surface, not the canvas
    /// persistence path, so we never need a CPU-coherent readback here.
    func flattenScratchIntoOverlay(strokeOpacity: Float) {
        guard let overlay = overlayStrokeTexture, let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = overlay
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        drawScratch(enc, scratch: scratch, opacity: strokeOpacity, grain: activeGrain)
        enc.endEncoding()

        cmdBuf.commit()
    }

    /// Render eraser stamps directly into the canvas texture with destination-out
    /// blend. Called per touchesMoved for real-time eraser feedback.
    ///
    /// Creates a temporary `MTLBuffer` from the stamp array (retained by the
    /// command buffer until GPU completion — no shared-buffer race). The command
    /// buffer commits asynchronously; Metal's same-queue ordering guarantees the
    /// next compositor pass sees the updated canvas.
    func applyEraserStamps(_ stamps: [StampInstance]) {
        guard let canvas = activeLayerTexture, !stamps.isEmpty else { return }

        let byteCount = stamps.count * MemoryLayout<StampInstance>.stride
        guard let stampBuf = stamps.withUnsafeBytes({ ptr -> MTLBuffer? in
            guard let base = ptr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: byteCount, options: .storageModeShared)
        }) else { return }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(eraserStampPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(stampBuf, offset: 0, index: 1)
        var canvasSizeFlip = SIMD4<Float>(Float(canvasWidth), Float(canvasHeight), 0, 0)
        enc.setVertexBytes(&canvasSizeFlip, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        enc.setFragmentTexture(brushMaskTexture, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stamps.count)
        enc.endEncoding()

        cmdBuf.commit()
    }

    /// Wet-mix brush (pro-brush Phase 4, Step 1). Writes stamps DIRECTLY into the active
    /// layer texture per touchesMoved, eraser-style: programmable framebuffer read of the
    /// pixels under each stamp, mixed toward the stamp's color in-shader, written back.
    /// Async commit, no waitUntilCompleted, no CPU readback. Each `StampInstance.color`
    /// carries the brush's STRAIGHT (un-premultiplied) color in rgb and the per-stamp
    /// deposit weight in alpha. No-op if the wet PSO is unavailable (e.g. Simulator).
    ///
    /// `wetOrderingPerStamp` toggles the draw-order experiment: one instanced draw (cheap)
    /// vs. N single-instance draws (serialized by submission order). If overlapping wet
    /// stamps mix wrong in the instanced path, the per-stamp path will look correct — that
    /// tells us whether framebuffer-fetch RMW needs explicit ordering here.
    func applyWetStamps(_ stamps: [StampInstance]) {
        guard let wetPSO = wetStampPSO, let canvas = activeLayerTexture, !stamps.isEmpty,
              let basisBuf = wetBasisBuffer, let matBuf = wetMatBuffer else { return }

        let byteCount = stamps.count * MemoryLayout<StampInstance>.stride
        guard let stampBuf = stamps.withUnsafeBytes({ ptr -> MTLBuffer? in
            guard let base = ptr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: byteCount, options: .storageModeShared)
        }) else { return }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(wetPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        enc.setVertexBuffer(stampBuf, offset: 0, index: 1)
        var canvasSizeFlip = SIMD4<Float>(Float(canvasWidth), Float(canvasHeight), 0, 0)
        enc.setVertexBytes(&canvasSizeFlip, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
        // Fragment KM tables (the carried-load + canvas colors are upsampled in-shader).
        enc.setFragmentBuffer(basisBuf, offset: 0, index: 0)
        enc.setFragmentBuffer(matBuf, offset: 0, index: 1)
        let stride = MemoryLayout<StampInstance>.stride
        if wetOrderingPerStamp {
            // N serialized single-instance draws (submission-ordered RMW).
            for i in 0..<stamps.count {
                enc.setVertexBufferOffset(i * stride, index: 1)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            }
        } else {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stamps.count)
        }
        enc.endEncoding()

        cmdBuf.commit()
    }

    /// Block until every command buffer submitted so far on the renderer's queue has
    /// completed (empty buffer + same-queue ordering). Callers: BrushHarness's headless
    /// replay AND the Brush Studio pad's stroke re-render (`paintRetained`) — both
    /// submit batches back-to-back and would sample a much staler canvas without
    /// draining. On device, live touch batches arrive ~8 ms apart so the GPU keeps up
    /// without this. NEVER call this on the interactive per-touch/per-frame path
    /// (see Performance invariants in CLAUDE.md).
    func waitUntilQueueDrained() {
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Wet Kubelka-Munk setup + CPU helpers (pro-brush Phase 4 Step 2)

    /// Build the spectral-mixing tables once. The math lives in `WetKM` (UIKit/Metal-free
    /// so OfflineTests can assert the shipped tables + mix on macOS); this keeps the CPU
    /// copies for per-stroke brush upsampling and uploads Float buffers for the shader.
    private func setupWetKMTables() {
        let NB = Self.wetNB
        let tables = WetKM.buildTables()
        wetBasisD = tables.basis
        wetMat = tables.mat

        var basisF = [Float](repeating: 0, count: 7*NB)
        for k in 0..<7 { for i in 0..<NB { basisF[k*NB+i] = Float(tables.basis[k][i]) } }
        var matF = [Float](repeating: 0, count: NB*3)
        for i in 0..<NB { matF[i*3+0] = Float(tables.mat[i].x); matF[i*3+1] = Float(tables.mat[i].y); matF[i*3+2] = Float(tables.mat[i].z) }
        wetBasisBuffer = device.makeBuffer(bytes: basisF, length: basisF.count * MemoryLayout<Float>.size, options: .storageModeShared)
        wetMatBuffer = device.makeBuffer(bytes: matF, length: matF.count * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    /// Spectral Kubelka-Munk mix of two linear-RGB colors on the CPU (same model as the
    /// wet shader). Used to evolve the brush's carried LOAD as it picks up canvas color
    /// (Step 3 smear). Endpoint-exact: t=0 → a, t=1 → b.
    func kmMixCPU(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        WetKM.mix(a, b, t, basis: wetBasisD, mat: wetMat)
    }

    /// Sample the active layer at a canvas-pixel position as a STRAIGHT LINEAR color +
    /// alpha (1×1 getBytes on .shared storage — cheap, coherent for committed paint).
    /// Used by the wet brush to pick up the canvas color it crosses. Returns nil out of
    /// bounds. Recovery order (decode THEN un-premultiply) is load-bearing — see
    /// `WetKM.straightLinear` (the old divide-then-decode returned semi-transparent
    /// paint up to ~3× too light; fixed 2026-07-14).
    func sampleLayerColor(x: Int, y: Int) -> (color: SIMD3<Float>, alpha: Float)? {
        guard let tex = activeLayerTexture, x >= 0, y >= 0, x < canvasWidth, y < canvasHeight else { return nil }
        var bgra = [UInt8](repeating: 0, count: 4)
        bgra.withUnsafeMutableBytes { ptr in
            tex.getBytes(ptr.baseAddress!, bytesPerRow: 4,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        return WetKM.straightLinear(b: bgra[0], g: bgra[1], r: bgra[2], a: bgra[3])
    }

    /// Like `sampleLayerColor`, but averages a (2·radius+1)² neighborhood (clamped at the
    /// canvas edge) in the PREMULTIPLIED-LINEAR domain — decode each texel, sum premult +
    /// alpha, un-premultiply the sums — so semi-transparent texels contribute in proportion
    /// to their coverage instead of biasing the straight color. Used to seed the smudge
    /// load: a single texel makes the seed jittery on noisy/textured paint, while the GPU
    /// deposit sees a soft-coverage footprint.
    func sampleLayerColorAveraged(x: Int, y: Int, radius: Int = 1) -> (color: SIMD3<Float>, alpha: Float)? {
        guard let tex = activeLayerTexture, x >= 0, y >= 0, x < canvasWidth, y < canvasHeight else { return nil }
        let x0 = max(0, x - radius), x1 = min(canvasWidth - 1, x + radius)
        let y0 = max(0, y - radius), y1 = min(canvasHeight - 1, y + radius)
        let w = x1 - x0 + 1, h = y1 - y0 + 1
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { ptr in
            tex.getBytes(ptr.baseAddress!, bytesPerRow: w * 4,
                         from: MTLRegionMake2D(x0, y0, w, h), mipmapLevel: 0)
        }
        var sumPremult = SIMD3<Float>.zero
        var sumA: Float = 0
        for i in 0..<(w * h) {
            let o = i * 4
            sumPremult += SIMD3<Float>(WetKM.s2l(Float(bytes[o + 2]) / 255.0),
                                       WetKM.s2l(Float(bytes[o + 1]) / 255.0),
                                       WetKM.s2l(Float(bytes[o]) / 255.0))
            sumA += Float(bytes[o + 3]) / 255.0
        }
        guard sumA > 1e-4 else { return (SIMD3<Float>(0, 0, 0), 0) }
        let straight = simd_clamp(sumPremult / sumA, SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
        return (straight, sumA / Float(w * h))
    }

    /// Render a batch of brush stamps directly into the canvas texture (source-over).
    /// Used for stroke replay during persistence restore — each saved stroke is
    /// regenerated as stamps and committed in one pass. `strokeOpacity` is the
    /// per-stroke ceiling applied at flatten (stamp alpha carries the brush's flow).
    func commitStampsToCanvas(_ stamps: [StampInstance], strokeOpacity: Float = 1.0, shapeTexture: MTLTexture? = nil,
                              grain: GrainSettings? = nil,
                              lightness: (params: SIMD4<Float>, recenter: SIMD4<Float>)? = nil,
                              flip: SIMD2<Float> = .zero,
                              wetInk: Bool = false) {
        guard let canvas = activeLayerTexture, !stamps.isEmpty else { return }
        guard let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // 1. Clear scratch and render stamps into it.
        let scratchRPD = MTLRenderPassDescriptor()
        scratchRPD.colorAttachments[0].texture = scratch
        scratchRPD.colorAttachments[0].loadAction = .clear
        scratchRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        scratchRPD.colorAttachments[0].storeAction = .store

        let byteCount = stamps.count * MemoryLayout<StampInstance>.stride
        guard let stampBuf = stamps.withUnsafeBytes({ ptr -> MTLBuffer? in
            guard let base = ptr.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: byteCount, options: .storageModeShared)
        }) else { return }

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: scratchRPD) {
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(stampBuf, offset: 0, index: 1)
            var canvasSizeFlip = SIMD4<Float>(Float(canvasWidth), Float(canvasHeight), flip.x, flip.y)
            enc.setVertexBytes(&canvasSizeFlip, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            bindMovingGrain(enc, grain)
            if wetInk, let wetPSO = wetInkScratchPSO, let basisBuf = wetBasisBuffer, let matBuf = wetMatBuffer {
                enc.setRenderPipelineState(wetPSO)
                enc.setFragmentTexture(canvas, index: 0)
                enc.setFragmentBuffer(basisBuf, offset: 0, index: 0)
                enc.setFragmentBuffer(matBuf, offset: 0, index: 1)
                var doc = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
                enc.setFragmentBytes(&doc, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            } else if let shapeTexture {
                let movingOn = grain?.moving ?? false
                if let lm = lightness,
                   let pso = movingOn ? lightnessShapedStampMaxPSO : lightnessShapedStampPSO {
                    enc.setRenderPipelineState(pso)
                    enc.setFragmentTexture(shapeTexture, index: 0)
                    var p0 = lm.params
                    var p1 = lm.recenter
                    enc.setFragmentBytes(&p0, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                    enc.setFragmentBytes(&p1, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                } else if let shapedPSO = movingOn ? shapedStampMaxPSO : shapedBrushStampPSO {
                    enc.setRenderPipelineState(shapedPSO)
                    enc.setFragmentTexture(shapeTexture, index: 0)
                } else {
                    enc.setRenderPipelineState(brushStampPSO)
                    enc.setFragmentTexture(brushMaskTexture, index: 0)
                }
            } else if (grain?.moving ?? false), !wetInk, let maxPSO = brushStampMaxPSO {
                enc.setRenderPipelineState(maxPSO)
                enc.setFragmentTexture(brushMaskTexture, index: 0)
            } else {
                enc.setRenderPipelineState(brushStampPSO)
                enc.setFragmentTexture(brushMaskTexture, index: 0)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stamps.count)
            enc.endEncoding()
        }

        // 2. Flatten scratch into canvas (source-over).
        let flattenRPD = MTLRenderPassDescriptor()
        flattenRPD.colorAttachments[0].texture = canvas
        flattenRPD.colorAttachments[0].loadAction = .load
        flattenRPD.colorAttachments[0].storeAction = .store

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: flattenRPD) {
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            drawScratch(enc, scratch: scratch, opacity: strokeOpacity, grain: grain)
            enc.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()  // OK — runs once per stroke during load, not interactive
    }

    /// Snapshot a specific layer's texture into CPU-side Data for undo.
    func snapshotLayer(at index: Int) -> Data? {
        guard index >= 0, index < layers.count else { return nil }
        let texture = layers[index].texture
        let bytesPerRow = canvasWidth * 4
        let byteCount = bytesPerRow * canvasHeight
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, canvasWidth, canvasHeight),
                             mipmapLevel: 0)
        }
        return data
    }

    /// Snapshot the active layer (convenience wrapper).
    func snapshotCanvas() -> Data? {
        snapshotLayer(at: activeLayerIndex)
    }

    /// Restore a specific layer's texture from a CPU-side undo snapshot.
    func restoreLayer(at index: Int, from data: Data) {
        guard index >= 0, index < layers.count,
              data.count == canvasWidth * canvasHeight * 4 else { return }
        let texture = layers[index].texture
        let bytesPerRow = canvasWidth * 4
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, canvasWidth, canvasHeight),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }
    }

    /// Restore the active layer (convenience wrapper).
    func restoreCanvas(from data: Data) {
        restoreLayer(at: activeLayerIndex, from: data)
    }

    /// Read a specific layer texture into a CGImage for per-layer persistence.
    func layerToCGImage(at index: Int) -> CGImage? {
        guard index >= 0, index < layers.count else { return nil }
        return textureToCGImage(layers[index].texture)
    }

    /// Encode a specific layer as PNG without routing transparent pixels through
    /// UIKit/CoreGraphics premultiplication.
    func layerPNGData(at index: Int) -> Data? {
        guard index >= 0, index < layers.count else { return nil }
        return textureToPNGData(layers[index].texture)
    }

    /// Read the flattened (all visible layers composited) canvas into a CGImage
    /// for stream capture, thumbnails, and single-image export. Includes the
    /// active stroke (scratch texture) so in-progress drawing is captured.
    /// `strokeOpacity` is the per-stroke ceiling applied to the in-progress scratch
    /// (passed explicitly so the snapshot doesn't depend on mutable renderer state).
    func flattenedCGImage(strokeOpacity: Float = 1.0) -> CGImage? {
        guard !layers.isEmpty else { return nil }

        // Render all visible layers into a temporary texture, interleaving
        // the scratch texture at the active layer's z-position (same logic
        // as compositeToDrawable) so the in-progress stroke is included.
        let desc = makeLayerDescriptor()
        guard let tempTexture = device.makeTexture(descriptor: desc) else { return nil }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tempTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(compositorPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        var opacity: Float = 1.0

        for i in 0..<layers.count {
            guard layers[i].isVisible else { continue }
            drawLayerComposite(enc, layers[i])

            // Include in-progress stroke on the active layer (capped at stroke opacity).
            if i == activeLayerIndex, stampCount > 0, let scratch = scratchTexture {
                drawScratch(enc, scratch: scratch, opacity: strokeOpacity, grain: activeGrain)
            }
        }

        // Draw floating selection (if lasso is active) at current transform.
        if let selTex = selectionTexture, let selVB = selectionVertexBuffer {
            enc.setFragmentTexture(selTex, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.setVertexBuffer(selVB, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        }

        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()  // OK — runs once per capture, not per frame

        return textureToCGImage(tempTexture)
    }

    /// Read the flattened canvas composited over an opaque background. This is
    /// used for gallery thumbnails and stream snapshots, where matching the
    /// Metal canvas' linear source-over blend matters more than preserving alpha.
    func flattenedOpaqueCGImage(backgroundImage: CGImage?, maxPixelDimension: Int? = nil,
                                strokeOpacity: Float = 1.0) -> CGImage? {
        guard !layers.isEmpty else { return nil }
        guard let targetSize = snapshotTextureSize(maxPixelDimension: maxPixelDimension) else { return nil }
        guard let tempTexture = makeSnapshotTexture(width: targetSize.width, height: targetSize.height) else {
            return nil
        }

        var backgroundTexture: MTLTexture?
        if let backgroundImage {
            backgroundTexture = makeSnapshotTexture(width: targetSize.width, height: targetSize.height)
            if let backgroundTexture {
                clearTexture(backgroundTexture)
                let ciImage = CIImage(cgImage: backgroundImage, options: [.colorSpace: sRGBColorSpace])
                renderCIImage(ciImage, to: backgroundTexture)
            }
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return nil }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = tempTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return nil }
        enc.setRenderPipelineState(compositorPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        var opacity: Float = 1.0

        if let backgroundTexture {
            enc.setFragmentTexture(backgroundTexture, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }

        for i in 0..<layers.count {
            guard layers[i].isVisible else { continue }
            drawLayerComposite(enc, layers[i])

            if i == activeLayerIndex, stampCount > 0, let scratch = scratchTexture {
                drawScratch(enc, scratch: scratch, opacity: strokeOpacity, grain: activeGrain)
            }
        }

        if let selTex = selectionTexture, let selVB = selectionVertexBuffer {
            enc.setFragmentTexture(selTex, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.setVertexBuffer(selVB, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        }

        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()

        return textureToCGImage(tempTexture)
    }

    /// Convert any Metal texture to CGImage via CIImage (correct sRGB + premultiplied alpha).
    private func textureToCGImage(_ texture: MTLTexture) -> CGImage? {
        guard let ciImage = textureToCIImage(texture) else { return nil }
        return ciContext.createCGImage(ciImage, from: ciImage.extent,
                                       format: .BGRA8, colorSpace: sRGBColorSpace)
    }

    /// Encode any Metal texture as PNG through Core Image. This avoids
    /// UIImage.pngData(), which can re-premultiply transparent pixels in the
    /// wrong color space before persistence.
    private func textureToPNGData(_ texture: MTLTexture) -> Data? {
        guard let ciImage = textureToCIImage(texture) else { return nil }
        return ciContext.pngRepresentation(of: ciImage, format: .RGBA8, colorSpace: sRGBColorSpace)
    }

    private func textureToCIImage(_ texture: MTLTexture) -> CIImage? {
        // linearSRGB — the texture is .bgra8Unorm_srgb, so Metal's sampler applies
        // sRGB→linear DECODE on read; Core Image therefore receives already-linear
        // values. Labelling them sRGB here makes CIImage apply the decode a SECOND
        // time → every read darkens (and over-saturates) the image. Because the save
        // path (layerPNGData) and snapshots both funnel through here, that extra
        // decode bakes into stored PNGs and compounds on each save/reopen, marching
        // any color toward black. This is the exact inverse of the write path
        // (`renderCIImage`), which passes linearSRGB for the same reason: let Metal —
        // not Core Image — own the sRGB↔linear conversion for `_srgb` textures.
        guard var ciImage = CIImage(mtlTexture: texture, options: [
            .colorSpace: linearSRGBColorSpace
        ]) else { return nil }
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ciImage.extent.height))
        return ciImage
    }

    /// Load a CGImage into a specific layer texture, stretched to fill the canvas.
    func loadImageIntoLayer(at index: Int, _ image: CGImage) {
        guard index >= 0, index < layers.count else { return }
        let ciImage = CIImage(cgImage: image, options: [.colorSpace: sRGBColorSpace])
        renderCIImageIntoLayer(at: index, ciImage)
    }

    /// Load encoded image data directly into a layer via Core Image, bypassing
    /// UIImage/CoreGraphics decode paths for saved transparent canvas PNGs.
    @discardableResult
    func loadImageDataIntoLayer(at index: Int, _ data: Data) -> Bool {
        guard index >= 0, index < layers.count,
              let ciImage = CIImage(data: data, options: [.colorSpace: sRGBColorSpace]) else {
            return false
        }
        renderCIImageIntoLayer(at: index, ciImage)
        return true
    }

    /// Load encoded image data into the active layer (convenience wrapper).
    @discardableResult
    func loadImageDataIntoCanvas(_ data: Data) -> Bool {
        loadImageDataIntoLayer(at: activeLayerIndex, data)
    }

    private func renderCIImageIntoLayer(at index: Int, _ ciImage: CIImage) {
        guard index >= 0, index < layers.count else { return }
        renderCIImage(ciImage, to: layers[index].texture)
    }

    private func renderCIImage(_ source: CIImage, to texture: MTLTexture) {
        var ciImage = source
        let imgW = ciImage.extent.width
        let imgH = ciImage.extent.height
        guard imgW > 0, imgH > 0 else { return }
        let sx = CGFloat(texture.width) / imgW
        let sy = CGFloat(texture.height) / imgH
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: -sy)
            .translatedBy(x: 0, y: -imgH))
        let bounds = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        // linearSRGB — texture is .bgra8Unorm_srgb, so Metal's render pipeline applies
        // linear→sRGB encoding on store. Passing sRGB here would double-encode (gamma
        // applied twice → washed-out midtones, e.g. dark grays lifting to mid-gray).
        // We tell CIContext to output linear values; Metal handles the sRGB encoding.
        //
        // BUT: on some OS/runtime combinations CIContext.render(to: MTLTexture)
        // silently writes NOTHING (verified 2026-08-22 on the iOS 18.3.1 simulator;
        // reported by Donald as reopen-blank data loss on iPadOS 26 hardware too).
        // Every saved drawing then reopened blank, and the next autosave persisted
        // the blank layers. `directCIRenderToTextureWorks` probes the path once per
        // renderer; when broken we use the CPU route, which is exact (see below).
        if directCIRenderToTextureWorks {
            ciContext.render(ciImage, to: texture, commandBuffer: nil,
                             bounds: bounds, colorSpace: linearSRGBColorSpace)
        } else {
            renderCIImageViaCPU(ciImage, to: texture, bounds: bounds)
        }
    }

    /// One-time probe: does CIContext.render(to: MTLTexture) actually write?
    /// Renders solid red into a tiny bgra8Unorm_srgb texture and reads it back.
    /// Broken (all-zero) on the iOS simulator since ≥Jul 2026 and on iPadOS 26
    /// devices; self-healing here beats a compile-time platform split.
    fileprivate lazy var directCIRenderToTextureWorks: Bool = {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: 4, height: 4, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        guard let probe = device.makeTexture(descriptor: desc) else { return false }
        let bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1)).cropped(to: bounds)
        ciContext.render(red, to: probe, commandBuffer: nil,
                         bounds: bounds, colorSpace: linearSRGBColorSpace)
        var bytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        probe.getBytes(&bytes, bytesPerRow: 16, from: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0)
        let works = bytes.contains { $0 != 0 }
        if !works {
            NSLog("CanvasRenderer: CIContext.render(to:texture) is a no-op on this runtime — using CPU image-load fallback")
        }
        return works
    }()

    /// Exact CPU fallback for loading images into `_srgb` textures: CI renders to
    /// a CPU bitmap in LINEAR half-float (premultiplication stays in linear space —
    /// CI's 8-bit bitmap output premultiplies in the ENCODED space, measured 128
    /// for ½-alpha white, which is the CGContext gamma trap the module doc bans),
    /// uploads to a temp rgba16Float texture, and one compositor draw stores it
    /// into the `_srgb` target — Metal's hardware does the exact linear→sRGB encode.
    /// Cold path (drawing load only).
    private func renderCIImageViaCPU(_ ciImage: CIImage, to texture: MTLTexture, bounds: CGRect) {
        let w = Int(bounds.width), h = Int(bounds.height)
        guard w > 0, h > 0 else { return }
        // The caller pre-flips the image for Metal's top-left origin, but
        // toBitmap already writes row 0 = top (CG layout) — flip back, or the
        // loaded canvas comes out mirrored vertically (verified via thumbnail).
        let upright = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -bounds.height))
        let rowBytes = w * 8 // RGBA × 16-bit half
        var buf = [UInt8](repeating: 0, count: rowBytes * h)
        buf.withUnsafeMutableBytes { raw in
            ciContext.render(upright, toBitmap: raw.baseAddress!, rowBytes: rowBytes,
                             bounds: bounds, format: .RGBAh, colorSpace: linearSRGBColorSpace)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let temp = device.makeTexture(descriptor: desc) else { return }
        buf.withUnsafeBytes { raw in
            temp.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                         withBytes: raw.baseAddress!, bytesPerRow: rowBytes)
        }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear // replace semantics, like CI render
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        var opacity: Float = 1.0
        enc.setRenderPipelineState(compositorPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        enc.setFragmentTexture(temp, index: 0)
        enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted() // cold path (drawing load), CPU reads follow
    }

    /// Load a CGImage into the active layer (convenience wrapper).
    func loadImageIntoCanvas(_ image: CGImage) {
        loadImageIntoLayer(at: activeLayerIndex, image)
    }

    private func snapshotTextureSize(maxPixelDimension: Int?) -> (width: Int, height: Int)? {
        guard canvasWidth > 0, canvasHeight > 0 else { return nil }
        guard let maxPixelDimension, maxPixelDimension > 0 else {
            return (canvasWidth, canvasHeight)
        }
        let scale = min(
            CGFloat(maxPixelDimension) / CGFloat(canvasWidth),
            CGFloat(maxPixelDimension) / CGFloat(canvasHeight),
            1
        )
        return (
            max(1, Int((CGFloat(canvasWidth) * scale).rounded())),
            max(1, Int((CGFloat(canvasHeight) * scale).rounded()))
        )
    }

    private func makeSnapshotTexture(width: Int, height: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared
        return device.makeTexture(descriptor: desc)
    }

    // MARK: - Lasso Selection (Metal-native)

    /// Extract pixels inside the lasso path from the canvas into a selection texture,
    /// and clear those pixels from the canvas. Both operations happen entirely in Metal.
    func extractSelection(canvasPath: CGPath, bounds: CGRect, canvasScale: CGFloat) {
        guard let canvas = activeLayerTexture, let maskedPSO = maskedCopyPSO else { return }

        // Convert bounds from view-points to canvas-pixels.
        let pxBounds = CGRect(
            x: bounds.origin.x * canvasScale,
            y: bounds.origin.y * canvasScale,
            width: bounds.width * canvasScale,
            height: bounds.height * canvasScale
        )
        let selW = max(1, Int(pxBounds.width.rounded()))
        let selH = max(1, Int(pxBounds.height.rounded()))

        // 1. Rasterize the lasso path into an R8 mask (canvas-pixel resolution).
        //    CGContext is fine here — it's a single-channel mask, no color issues.
        let maskW = canvasWidth
        let maskH = canvasHeight
        var maskPixels = [UInt8](repeating: 0, count: maskW * maskH)
        maskPixels.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            let colorSpace = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(data: base, width: maskW, height: maskH,
                                      bitsPerComponent: 8, bytesPerRow: maskW,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            // Flip Y: CGContext origin is bottom-left, Metal texture origin is top-left.
            // Without this flip, the mask is upside-down and the lasso clips the wrong region.
            ctx.translateBy(x: 0, y: CGFloat(maskH))
            ctx.scaleBy(x: canvasScale, y: -canvasScale)
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addPath(canvasPath)
            // Even-odd so multi-subpath selection paths (unified selection:
            // disjoint objects + negative-refinement holes) extract correctly.
            // Identical to winding for simple lasso loops.
            ctx.fillPath(using: .evenOdd)
        }

        let maskDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: maskW, height: maskH, mipmapped: false)
        maskDesc.usage = .shaderRead
        maskDesc.storageMode = .shared
        guard let maskTexture = device.makeTexture(descriptor: maskDesc) else { return }
        maskTexture.replace(region: MTLRegionMake2D(0, 0, maskW, maskH),
                            mipmapLevel: 0, withBytes: maskPixels, bytesPerRow: maskW)

        // 2. Create selection texture (cropped to bounding box).
        let selDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: selW, height: selH, mipmapped: false)
        selDesc.usage = [.shaderRead, .renderTarget]
        selDesc.storageMode = .shared
        guard let selTex = device.makeTexture(descriptor: selDesc) else { return }

        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // 3. Render pass A — copy canvas pixels masked by path into selection texture.
        //    The fragment shader samples canvas + mask; outputs canvas * mask.alpha.
        //    We use a viewport/texcoord mapping so the selection texture covers just the bounding box.
        let copyRPD = MTLRenderPassDescriptor()
        copyRPD.colorAttachments[0].texture = selTex
        copyRPD.colorAttachments[0].loadAction = .clear
        copyRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        copyRPD.colorAttachments[0].storeAction = .store

        // Build vertex data that maps the crop region of the canvas to the full selection texture.
        // Texcoords sample the crop region of the canvas (pxBounds / canvasSize).
        let u0 = Float(pxBounds.minX) / Float(canvasWidth)
        let v0 = Float(pxBounds.minY) / Float(canvasHeight)
        let u1 = Float(pxBounds.maxX) / Float(canvasWidth)
        let v1 = Float(pxBounds.maxY) / Float(canvasHeight)
        let cropVerts: [Float] = [
            -1, -1, u0, v1,
             1, -1, u1, v1,
            -1,  1, u0, v0,
            -1,  1, u0, v0,
             1, -1, u1, v1,
             1,  1, u1, v0,
        ]
        guard let cropBuf = device.makeBuffer(bytes: cropVerts, length: cropVerts.count * 4, options: .storageModeShared) else { return }

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: copyRPD) {
            enc.setRenderPipelineState(maskedPSO)
            enc.setVertexBuffer(cropBuf, offset: 0, index: 0)
            enc.setFragmentTexture(canvas, index: 0)
            enc.setFragmentTexture(maskTexture, index: 1)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        // 4. Render pass B — clear canvas pixels inside the mask (destination-out).
        let clearRPD = MTLRenderPassDescriptor()
        clearRPD.colorAttachments[0].texture = canvas
        clearRPD.colorAttachments[0].loadAction = .load
        clearRPD.colorAttachments[0].storeAction = .store

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: clearRPD),
           let clearPSO = maskedClearPSO {
            // maskedClearFragment outputs alpha = mask.r; destination-out multiplies
            // canvas by (1 - alpha). Inside mask: cleared. Outside: preserved.
            enc.setRenderPipelineState(clearPSO)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.setFragmentTexture(maskTexture, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()  // OK — runs once per lasso, not per frame

        selectionTexture = selTex
        selectionBounds = pxBounds
        updateSelectionVertices(translation: .zero, scale: 1, rotation: 0)
    }

    /// Update the selection quad vertices from gesture state. Called each gesture update.
    func updateSelectionVertices(translation: CGPoint, scale: CGFloat, rotation: CGFloat) {
        guard selectionTexture != nil else { return }

        // Selection bounds center in canvas pixels.
        let cx = Float(selectionBounds.midX)
        let cy = Float(selectionBounds.midY)
        let hw = Float(selectionBounds.width) * 0.5
        let hh = Float(selectionBounds.height) * 0.5

        // Convert gesture translation from view-points to canvas-pixels using
        // the stored canvas scale (canvasPixels / viewPoints). Previously used
        // UIScreen.main.bounds which broke in split-screen or non-fullscreen layouts.
        let tx = Float(translation.x * canvasScale)
        let ty = Float(translation.y * canvasScale)
        let s = Float(scale)
        let c = cosf(Float(rotation))
        let sn = sinf(Float(rotation))

        // Four corners in canvas-pixel space, pre-transformed.
        func transformCorner(lx: Float, ly: Float) -> SIMD2<Float> {
            // Local offset from center
            let rx = lx * s
            let ry = ly * s
            // Rotate
            let rotX = rx * c - ry * sn
            let rotY = rx * sn + ry * c
            // Translate to canvas-pixel position
            let px = cx + tx + rotX
            let py = cy + ty + rotY
            // Convert to NDC
            let ndcX = (px / Float(canvasWidth)) * 2 - 1
            let ndcY = 1 - (py / Float(canvasHeight)) * 2
            return SIMD2<Float>(ndcX, ndcY)
        }

        let tl = transformCorner(lx: -hw, ly: -hh)
        let tr = transformCorner(lx:  hw, ly: -hh)
        let bl = transformCorner(lx: -hw, ly:  hh)
        let br = transformCorner(lx:  hw, ly:  hh)

        // 6 vertices (2 triangles), each with (posX, posY, texU, texV)
        let verts: [Float] = [
            bl.x, bl.y, 0, 1,
            br.x, br.y, 1, 1,
            tl.x, tl.y, 0, 0,
            tl.x, tl.y, 0, 0,
            br.x, br.y, 1, 1,
            tr.x, tr.y, 1, 0,
        ]

        if let buf = selectionVertexBuffer, buf.length >= verts.count * 4 {
            memcpy(buf.contents(), verts, verts.count * 4)
        } else {
            selectionVertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * 4, options: .storageModeShared)
        }
    }

    /// Composite the selection texture onto the canvas at its current transform.
    func commitSelection() {
        guard let selTex = selectionTexture, let canvas = activeLayerTexture,
              let vertBuf = selectionVertexBuffer else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        if let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) {
            enc.setRenderPipelineState(compositorPSO)  // source-over
            enc.setVertexBuffer(vertBuf, offset: 0, index: 0)
            enc.setFragmentTexture(selTex, index: 0)
            var opacity: Float = 1.0
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()  // OK — runs once on commit

        discardSelection()
    }

    /// Free the selection texture and reset state.
    func discardSelection() {
        selectionTexture = nil
        selectionBounds = .zero
        selectionVertexBuffer = nil
    }

    /// Load an image (with alpha) as the floating selection — the paste flow's
    /// entry. `rect` is in canvas pixels. Unlike `extractSelection`, nothing is
    /// cut from any layer; the float is pure new content until committed.
    /// Returns false when a texture can't be created.
    @discardableResult
    func setSelectionFromImage(_ image: CGImage, rect: CGRect) -> Bool {
        let w = max(1, Int(rect.width.rounded()))
        let h = max(1, Int(rect.height.rounded()))
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .renderTarget]
        desc.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: desc) else { return false }
        // Same CI path as layer loads: sRGB-tagged input, linear at the Metal
        // boundary, Y-flip + scale-to-fill handled inside renderCIImage.
        renderCIImage(CIImage(cgImage: image, options: [.colorSpace: sRGBColorSpace]), to: tex)
        selectionTexture = tex
        selectionBounds = rect
        updateSelectionVertices(translation: .zero, scale: 1, rotation: 0)
        return true
    }

    // MARK: - Private Render Passes

    private func renderStampsIntoScratch(commandBuffer: MTLCommandBuffer, scratch: MTLTexture, isEraser: Bool) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = scratch
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store  // needed for compositing pass

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        if stampCount > 0 {
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(stampBuffer, offset: 0, index: 1)
            var canvasSizeFlip = SIMD4<Float>(Float(canvasWidth), Float(canvasHeight),
                                              isEraser ? 0 : activeFlip.x, isEraser ? 0 : activeFlip.y)
            enc.setVertexBytes(&canvasSizeFlip, length: MemoryLayout<SIMD4<Float>>.size, index: 2)
            bindMovingGrain(enc, activeGrain)
            let movingOn = !isEraser && (activeGrain?.moving ?? false)
            // Wet INK (P7 core): KM against the pristine canvas texture, source-over into
            // the scratch. Takes priority over every dry PSO; smudge never routes here.
            if !isEraser, activeWetInk, let wetPSO = wetInkScratchPSO,
               let canvas = activeLayerTexture, let basisBuf = wetBasisBuffer, let matBuf = wetMatBuffer {
                enc.setRenderPipelineState(wetPSO)
                enc.setFragmentTexture(canvas, index: 0)
                enc.setFragmentBuffer(basisBuf, offset: 0, index: 0)
                enc.setFragmentBuffer(matBuf, offset: 0, index: 1)
                var doc = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
                enc.setFragmentBytes(&doc, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            } else
            // Textured shape (Phase 3) takes priority for the brush; eraser + round brush
            // keep the procedural path. (Grain applies at scratch-COMPOSITE time, not per
            // dab — per-dab carving is refilled by overlapping stamps; see grainCompositor.)
            if !isEraser, let shapeTex = activeShapeTexture {
                if let lm = activeLightness,
                   let pso = movingOn ? lightnessShapedStampMaxPSO : lightnessShapedStampPSO {
                    enc.setRenderPipelineState(pso)
                    enc.setFragmentTexture(shapeTex, index: 0)
                    var p0 = lm.params
                    var p1 = lm.recenter
                    enc.setFragmentBytes(&p0, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
                    enc.setFragmentBytes(&p1, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
                } else if let shapedPSO = movingOn ? shapedStampMaxPSO : shapedBrushStampPSO {
                    enc.setRenderPipelineState(shapedPSO)
                    enc.setFragmentTexture(shapeTex, index: 0)
                } else {
                    enc.setRenderPipelineState(brushStampPSO)
                    enc.setFragmentTexture(brushMaskTexture, index: 0)
                }
            } else if !isEraser, movingOn, let maxPSO = brushStampMaxPSO {
                enc.setRenderPipelineState(maxPSO)
                enc.setFragmentTexture(brushMaskTexture, index: 0)
            } else {
                enc.setRenderPipelineState(isEraser ? eraserStampPSO : brushStampPSO)
                enc.setFragmentTexture(brushMaskTexture, index: 0)
            }
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: stampCount)
        }

        enc.endEncoding()
    }

    private func compositeToDrawable(commandBuffer: MTLCommandBuffer, drawable: CAMetalDrawable,
                                     scratch: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(compositorPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        var opacity: Float = 1.0

        // Draw all visible layers bottom-to-top, interleaving the scratch texture
        // at the active layer's z-position so the active stroke preview appears
        // at the correct depth.
        for i in 0..<layers.count {
            guard layers[i].isVisible else { continue }

            drawLayerComposite(enc, layers[i])

            // Draw scratch (active stroke) on top of the active layer, capped at the
            // per-stroke opacity ceiling (stamp alpha carries flow); grain-aware (P8).
            if i == activeLayerIndex && stampCount > 0 {
                drawScratch(enc, scratch: scratch, opacity: activeStrokeOpacity, grain: activeGrain)
            }
        }

        // Draw floating selection (if lasso is active).
        if let selTex = selectionTexture, let selVB = selectionVertexBuffer {
            enc.setFragmentTexture(selTex, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.setVertexBuffer(selVB, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        }

        enc.endEncoding()
    }

    // MARK: - Texture Utilities

    /// Clear every document layer back to transparent. Used by BrushPreviewRenderer,
    /// which re-renders into one long-lived document — never on the drawing hot path.
    func clearAllLayers() {
        for layer in layers { clearTexture(layer.texture) }
    }

    fileprivate func clearTexture(_ texture: MTLTexture) {
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        cmdBuf.commit()
        // waitUntilCompleted is acceptable here — clearTexture runs on cold
        // paths only (document allocation, layer add/reset/restore, overlay
        // texture creation, opaque-snapshot background prep), never on the
        // per-frame hot path.
        cmdBuf.waitUntilCompleted()
    }

    // MARK: - Pipeline State Builders

    private static func makeBrushStampPSO(device: MTLDevice, library: MTLLibrary, eraser: Bool) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "brushStampVertex")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let ca = desc.colorAttachments[0]!

        if eraser {
            // Programmable blend: eraserStampFragment reads [[color(0)]], computes
            // dst * (1 - mask), and snaps near-clear results to exact zero. Fixed-
            // function blending is off — the shader returns the final pixel value.
            desc.fragmentFunction = library.makeFunction(name: "eraserStampFragment")
            ca.isBlendingEnabled = false
            if let pso = try? device.makeRenderPipelineState(descriptor: desc) {
                return pso
            }
            // Simulator fallback: rendertarget reads are unsupported there
            // ("reading from a rendertarget is not supported"), which would
            // nil the whole renderer. Approximate with fixed-function
            // destination-out (dst *= 1 - mask.alpha) — same erase, minus the
            // snap-near-clear-to-zero nicety. Device builds never take this
            // path: the programmable PSO above compiles on real hardware.
            desc.fragmentFunction = library.makeFunction(name: "brushStampFragment")
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .zero
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .zero
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            // Source-over (premultiplied): dst = src + dst * (1 - src.alpha).
            desc.fragmentFunction = library.makeFunction(name: "brushStampFragment")
            ca.isBlendingEnabled = true
            ca.rgbBlendOperation = .add
            ca.alphaBlendOperation = .add
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Textured-shape brush PSO (pro-brush Phase 3): samples a grayscale stamp mask via
    /// `shapedStampFragment`. Same premultiplied source-over blend as the round brush.
    private static func makeShapedBrushStampPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "brushStampVertex")
        desc.fragmentFunction = library.makeFunction(name: "shapedStampFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Wet-mix PSO: programmable framebuffer read (wetStampFragment reads [[color(0)]],
    /// mixes, returns the final pixel). Fixed-function blending off. Returns nil where
    /// framebuffer fetch is unsupported (Simulator) so the wet tool can degrade gracefully.
    /// Max-blend variants of the dry stamp PSOs, used when MOVING grain is active:
    /// coverage composes as MAX instead of accumulating, so the per-dab carve can't
    /// beat against the overlap count (the rhythmic banding in the first dry-18
    /// renders — 3-vs-4-dabs-deep oscillation showed through wherever per-dab alpha
    /// dipped below 1). Within-stroke build-up doesn't exist for moving-grain media
    /// (dry crayon/lead), so MAX is the right composition there.
    private static func makeMaxBlendStampPSO(device: MTLDevice, library: MTLLibrary,
                                             fragment: String) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "brushStampVertex")
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .max
        ca.alphaBlendOperation = .max
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .one
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .one
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Wet-ink scratch PSO: plain source-over into the scratch; the KM under-color is a
    /// TEXTURE sample of the pristine canvas (no framebuffer fetch → Simulator-safe).
    private static func makeWetInkScratchPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "brushStampVertex")
        desc.fragmentFunction = library.makeFunction(name: "wetInkScratchFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeWetStampPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "brushStampVertex")
        desc.fragmentFunction = library.makeFunction(name: "wetStampFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeCompositorPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositorVertex")
        desc.fragmentFunction = library.makeFunction(name: "compositorFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Per-layer blend parameters for `blendCompositorFragment` — layout must
    /// match the MSL `BlendParams` struct.
    private struct BlendParams {
        var opacity: Float
        var mode: UInt32
    }

    /// Framebuffer-fetch blend compositor (reads `[[color(0)]]`). Device only:
    /// the iOS SIMULATOR cannot read the render target (same limitation as the
    /// wet/eraser PSOs) — nil there, so non-Normal blend modes draw as Normal
    /// on the sim. Layer OPACITY still applies everywhere (fixed-function path).
    private lazy var blendCompositorPSO: MTLRenderPipelineState? =
        Self.makeBlendCompositorPSO(device: device, library: library)

    /// Draw one layer quad honoring its blend mode + opacity. Leaves the
    /// encoder on `compositorPSO` so surrounding draws are unaffected.
    /// Assumes the quad vertex buffer is already bound at index 0.
    private func drawLayerComposite(_ enc: MTLRenderCommandEncoder, _ layer: Layer) {
        if layer.blendMode != .normal, let blendPSO = blendCompositorPSO {
            var params = BlendParams(opacity: layer.opacity, mode: layer.blendMode.shaderIndex)
            enc.setRenderPipelineState(blendPSO)
            enc.setFragmentTexture(layer.texture, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<BlendParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.setRenderPipelineState(compositorPSO)
        } else {
            var op = layer.opacity
            enc.setFragmentTexture(layer.texture, index: 0)
            enc.setFragmentBytes(&op, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
    }

    /// Alpha-locked flatten: source-over for color, but the destination's
    /// alpha channel is preserved bit-exactly.
    ///   rgb: src.rgb·dst.a + dst.rgb·(1 − src.a)  (src premultiplied — new
    ///        paint is scaled by the existing coverage, so transparent areas
    ///        stay empty and feathered edges scale proportionally)
    ///   a:   src.a·dst.a + dst.a·(1 − src.a) = dst.a
    private static func makeAlphaLockCompositorPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositorVertex")
        desc.fragmentFunction = library.makeFunction(name: "compositorFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .destinationAlpha
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .destinationAlpha
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Blend-mode compositor: programmable blending (fragment reads the
    /// destination via [[color(0)]] and computes the full W3C blend equation
    /// itself), so fixed-function blending is DISABLED. Fails on the simulator
    /// ("reading from a rendertarget is not supported") → callers treat nil as
    /// "draw Normal instead".
    private static func makeBlendCompositorPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositorVertex")
        desc.fragmentFunction = library.makeFunction(name: "blendCompositorFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        desc.colorAttachments[0].isBlendingEnabled = false
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeMaskedCopyPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositorVertex")
        desc.fragmentFunction = library.makeFunction(name: "maskedCopyFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        // No blending — replace (copy).
        desc.colorAttachments[0].isBlendingEnabled = false
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    private static func makeMaskedClearPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositorVertex")
        desc.fragmentFunction = library.makeFunction(name: "maskedClearFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        // Destination-out: dst = dst * (1 - src.alpha). maskedClearFragment outputs
        // alpha = mask.r, so pixels inside the mask are cleared.
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .zero
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .zero
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - Brush Mask Generation

    private static func generateBrushMask(device: MTLDevice, size: Int) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: size,
            height: size,
            mipmapped: false
        )
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        var pixels = [UInt8](repeating: 0, count: size * size)
        let center = Float(size) / 2.0
        let r2 = center * center
        for y in 0..<size {
            for x in 0..<size {
                let dx = Float(x) + 0.5 - center
                let dy = Float(y) + 0.5 - center
                let d2 = dx * dx + dy * dy
                if d2 >= r2 { continue }
                let norm2 = d2 / r2
                let falloff = (1 - norm2) * (1 - norm2) // (1 - r²)²
                pixels[y * size + x] = UInt8(max(0, min(255, Int((falloff * 255).rounded()))))
            }
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size),
                        mipmapLevel: 0, withBytes: pixels, bytesPerRow: size)
        return texture
    }

    // MARK: - Brush Shape Stamps (Phase 3)

    /// Texture for a given shape id, or nil for the procedural round brush / unknown id.
    /// Bind the grain texture + params for the grain compositor. Grain texture at
    /// texture(1) (the scratch keeps 0); params (depth, uvScaleX, uvScaleY, 0) at
    /// fragment buffer(1) — buffer(0) stays the compositor's opacity. The UV scale maps
    /// the unit quad to document pixels × invScale so grain tiles in DOCUMENT space.
    private func bindGrainCompositor(_ enc: MTLRenderCommandEncoder, _ grain: GrainSettings) {
        enc.setFragmentTexture(grain.texture, index: 1)
        // t0 = (depth, sx, sy, 0); t1 = (brightness, contrastMul, 0, 0).
        var params = [SIMD4<Float>(grain.depth,
                                   Float(canvasWidth) * grain.invScale,
                                   Float(canvasHeight) * grain.invScale, 0),
                      SIMD4<Float>(grain.brightness, grain.contrastMul, 0, 0)]
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size * 2, index: 1)
    }

    /// Generate the procedural grain library: 256² R8, TILEABLE (periodic value-noise
    /// lattice), deterministic (fixed seeds — replay/harness identical). Kept in the
    /// COARSE value-grain band per the P8 plan (fine tooth is resynthesized by klein).
    private static func makeGrainTextures(device: MTLDevice, queue: MTLCommandQueue) -> [String: MTLTexture] {
        let size = 256
        func hash(_ x: Int, _ y: Int, _ seed: UInt64) -> Double {
            var h = seed &+ 0x9E37_79B9_7F4A_7C15
            h = (h ^ UInt64(bitPattern: Int64(x)) &* 0xBF58_476D_1CE4_E5B9)
            h = (h ^ UInt64(bitPattern: Int64(y)) &* 0x94D0_49BB_1331_11EB)
            h ^= h >> 31; h = h &* 0xD6E8_FEB8_6659_FD93; h ^= h >> 27
            return Double(h % 1_000_000) / 1_000_000.0
        }
        /// Periodic value noise: lattice of `cells` per tile edge, smoothstep-interpolated,
        /// indices wrapped so the 256px tile repeats seamlessly.
        func vnoise(_ px: Int, _ py: Int, cells: Int, seed: UInt64) -> Double {
            let cellSize = Double(size) / Double(cells)
            let fx = Double(px) / cellSize, fy = Double(py) / cellSize
            let x0 = Int(fx) % cells, y0 = Int(fy) % cells
            let x1 = (x0 + 1) % cells, y1 = (y0 + 1) % cells
            var tx = fx - Double(Int(fx)), ty = fy - Double(Int(fy))
            tx = tx * tx * (3 - 2 * tx); ty = ty * ty * (3 - 2 * ty)
            let a = hash(x0, y0, seed), b = hash(x1, y0, seed)
            let c = hash(x0, y1, seed), d = hash(x1, y1, seed)
            return (a + (b - a) * tx) + ((c + (d - c) * tx) - (a + (b - a) * tx)) * ty
        }
        func makeTexture(_ value: (Int, Int) -> Double) -> MTLTexture? {
            var bytes = [UInt8](repeating: 0, count: size * size)
            for y in 0..<size {
                for x in 0..<size {
                    bytes[y * size + x] = UInt8(max(0, min(255, value(x, y) * 255)))
                }
            }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                width: size, height: size, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            bytes.withUnsafeBytes { ptr in
                tex.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0,
                            withBytes: ptr.baseAddress!, bytesPerRow: size)
            }
            return tex
        }
        var out: [String: MTLTexture] = [:]
        // Paper: 3 octaves of mid-frequency tooth.
        out["paper"] = makeTexture { x, y in
            let v = 0.5 * vnoise(x, y, cells: 12, seed: 11)
                  + 0.3 * vnoise(x, y, cells: 24, seed: 22)
                  + 0.2 * vnoise(x, y, cells: 48, seed: 33)
            return v
        }
        // Canvas: woven directional structure + noise breakup.
        out["canvasWeave"] = makeTexture { x, y in
            let wx = 0.5 + 0.5 * sin(Double(x) * .pi * 16.0 / 256.0)
            let wy = 0.5 + 0.5 * sin(Double(y) * .pi * 16.0 / 256.0)
            let weave = max(wx, wy) * 0.65
            return min(1, weave + 0.35 * vnoise(x, y, cells: 20, seed: 44))
        }
        // Speckle: coarse-ish octave pair with a moderate contrast push (dry-media
        // break-up; tuned in dry-08 — a single 16-cell octave at ×2.2 contrast wiped
        // whole chunks of the stroke).
        out["speckle"] = makeTexture { x, y in
            let v = 0.65 * vnoise(x, y, cells: 24, seed: 55) + 0.35 * vnoise(x, y, cells: 48, seed: 66)
            return min(1, max(0, (v - 0.25) * 1.6))
        }
        // Image-based grains (cloned Procreate textures): grayscale PNGs from
        // Resources/BrushGrains, tiling at their own pixel size (grainSettings uses
        // texture.width as the tile). Missing file → the id resolves to no grain.
        for descriptor in GrainCatalog.all {
            guard let resourceName = descriptor.resourceName,
                  let data = grainPNGData(resourceName: resourceName),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let w = cgImage.width, h = cgImage.height
            var bytes = [UInt8](repeating: 0, count: w * h)
            guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { continue }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            // MIPMAPPED: fine geometric grains (grid/hatching) alias away under
            // minification without mips — thin lines fall between samples (the Grid
            // Paper clone surfaced this; the grain samplers are trilinear now).
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                                width: w, height: h, mipmapped: true)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else { continue }
            bytes.withUnsafeBytes { ptr in
                tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                            withBytes: ptr.baseAddress!, bytesPerRow: w)
            }
            if tex.mipmapLevelCount > 1, let cmdBuf = queue.makeCommandBuffer(),
               let blit = cmdBuf.makeBlitCommandEncoder() {
                blit.generateMipmaps(for: tex)
                blit.endEncoding()
                cmdBuf.commit()
            }
            out[descriptor.id] = tex
        }
        return out
    }

    /// Bundle (app) / `BRUSH_GRAINS_DIR` env (harness) lookup for image-grain PNGs —
    /// mirrors `shapePNGData`.
    private static func grainPNGData(resourceName: String) -> Data? {
        #if BRUSH_HARNESS
        guard let dir = ProcessInfo.processInfo.environment["BRUSH_GRAINS_DIR"] else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(resourceName).png"))
        #else
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png",
                                          subdirectory: "BrushGrains") else { return nil }
        return try? Data(contentsOf: url)
        #endif
    }

    /// Grain-variant PSO (same source-over blend as the compositor).
    private static func makeGrainStampPSO(device: MTLDevice, library: MTLLibrary, fragment: String,
                                          vertex: String = "brushStampVertex") -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: vertex)
        desc.fragmentFunction = library.makeFunction(name: fragment)
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add
        ca.sourceRGBBlendFactor = .one
        ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: desc)
    }

    /// Resolve a brush's P4a lightness-map uniform, or nil when off / round tip.
    /// NOTE: uses the UNJITTERED brush color (per-stroke color jitter + lightness maps
    /// are both niche; combining them per-stroke is a follow-up).
    /// Flip X/Y flags for the stamp vertex UV mirror. Zero unless a shaped tip asks.
    func flipSettings(for brush: BrushConfig) -> SIMD2<Float> {
        guard brush.shapeID != nil else { return .zero }
        return SIMD2<Float>(brush.flipX ? 1 : 0, brush.flipY ? 1 : 0)
    }

    func lightnessSettings(for brush: BrushConfig) -> (params: SIMD4<Float>, recenter: SIMD4<Float>)? {
        guard brush.tipLightness > 0.005, let shapeID = brush.shapeID else { return nil }
        let hsl = LightnessMap.hsl(r: Double(brush.color.red), g: Double(brush.color.green), b: Double(brush.color.blue))
        let mean = shapeLumaMeans[shapeID] ?? userShapeLumaMeans[shapeID] ?? 0.75
        return (SIMD4<Float>(Float(hsl.h), Float(hsl.s), Float(hsl.l),
                             Float(min(max(brush.tipLightness, 0), 1))),
                SIMD4<Float>(mean, 1.6, 0, 0))
    }

    /// Resolve a brush's grain settings (P8): texture + depth + document-space UV scale.
    /// nil when the brush has no grain, depth ≈ 0, or the id is unknown.
    /// `widthPx` is the brush's nominal stamp diameter in CANVAS pixels (baseWidth ×
    /// canvasScale on the live path; harness/persistence widths are already canvas px,
    /// so the default falls back to baseWidth). Only the moving-mode Zoom uses it.
    /// `strokeID` seeds the per-stroke Offset Jitter (nil → no offset).
    func grainSettings(for brush: BrushConfig, widthPx: CGFloat = 0, strokeID: UUID? = nil) -> GrainSettings? {
        guard brush.grainDepth > 0.005, let grainID = brush.grainID else { return nil }
        let depth = Float(min(max(brush.grainDepth, 0), 1))
        let tex: MTLTexture
        var nativeScale = 1.0
        if let desc = GrainCatalog.descriptor(for: grainID), let t = grainTextures[desc.id] {
            tex = t
            nativeScale = Double(desc.nativeScale)
        } else if let user = userGrain(for: grainID) {
            tex = user.texture
        } else {
            return nil
        }
        let gscale = Double(max(brush.grainScale, 0.05))
        // Cropped tile: the texture's own pixel size × scales (texturized always uses
        // this — document-anchored, brush-size-invariant).
        let fixedTile = Double(tex.width) * nativeScale * gscale
        var tilePx = fixedTile
        if brush.grainMoving {
            // Procreate Grain "Zoom": Follow size (0) → tile ∝ brush size, so the grain
            // grows/shrinks with the brush; Cropped (1) → fixed tile. K = 2: at
            // Scale 100% the tile spans ~2× the brush width.
            let w = Double(widthPx > 0 ? widthPx : brush.baseWidth)
            let followTile = max(8.0, w * gscale * 2.0)
            let zoom = Double(min(max(brush.grainZoom, 0), 1))
            tilePx = followTile + (fixedTile - followTile) * zoom
        }
        // Procreate Grain "Movement" (moving mode): 0 = smear/drag (the legacy streak
        // anisotropy — lateral ×3.5, along ×0.45), 1 = Rolling (isotropic — the texture
        // rolls under the brush undistorted).
        let movement = Float(min(max(brush.grainMovement, 0), 1))
        let alongMul = 0.45 + (1.0 - 0.45) * movement
        let latMul = 3.5 + (1.0 - 3.5) * movement
        // Offset Jitter (moving-only): one random tile offset per stroke, so repeated
        // strokes don't sample the same grain phase. Deterministic per stroke id.
        var offU: Float = 0, offV: Float = 0
        if brush.grainMoving, brush.grainOffsetJitter, let id = strokeID {
            let seed = StrokeStampGenerator.strokeSeed(id)
            offU = Float(brushHash01(seed, 0, 0x6F01) * tilePx)
            offV = Float(brushHash01(seed, 0, 0x6F02) * tilePx)
        }
        // Rotation (moving-only): grain angle vs the stroke direction, ±100% ≙ ±180°.
        let theta = Float(min(max(brush.grainRotation, -1), 1)) * .pi
        // Brightness/Contrast (both modes): shader applies src' = (src−.5)·mul + .5 + b.
        let contrastMul = Float(pow(3.0, Double(min(max(brush.grainContrast, -1), 1))))
        return GrainSettings(texture: tex,
                             moving: brush.grainMoving,
                             depth: depth,
                             invScale: Float(1.0 / tilePx),
                             alongMul: alongMul,
                             latMul: latMul,
                             offU: offU,
                             offV: offV,
                             cosR: cos(theta),
                             sinR: sin(theta),
                             brightness: Float(min(max(brush.grainBrightness, -1), 1)),
                             contrastMul: contrastMul,
                             depthMin: Float(min(max(brush.grainDepthMinimum, 0), 1)))
    }

    /// Bind the moving-grain slot (texture(1) + fragment buffer(3)) for a dry stamp
    /// pass: the grain when it's MOVING mode, else the disabled dummy. Every dry stamp
    /// fragment declares the slot, so it must always be bound.
    private func bindMovingGrain(_ enc: MTLRenderCommandEncoder,
                                 _ grain: GrainSettings?) {
        // Packing (3×float4): g0 = (depth, invScale, latMul, alongMul);
        // g1 = (offU, offV, cosR, sinR); g2 = (brightness, contrastMul, depthMin, 0).
        // depth == 0 disables the carve, so the dummy binding needs no enabled flag.
        var params: [SIMD4<Float>]
        if let grain, grain.moving {
            enc.setFragmentTexture(grain.texture, index: 1)
            params = [SIMD4<Float>(grain.depth, grain.invScale, grain.latMul, grain.alongMul),
                      SIMD4<Float>(grain.offU, grain.offV, grain.cosR, grain.sinR),
                      SIMD4<Float>(grain.brightness, grain.contrastMul, grain.depthMin, 0)]
        } else {
            enc.setFragmentTexture(blackDummyTexture, index: 1)
            params = [SIMD4<Float>(0, 0, 1, 1), SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 1, 0, 0)]
        }
        enc.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.size * 3, index: 3)
    }

    /// `MetalCanvasView` resolves this when a stroke starts and assigns `activeShapeTexture`.
    func shapeTexture(for id: String?) -> MTLTexture? {
        guard let id, id != BrushShapeCatalog.roundID else { return nil }
        if let builtIn = shapeTextures[id] { return builtIn }
        return userShapeTexture(for: id)
    }

    /// Lazily load a user-imported tip (BrushAssetStore.directory/shapes/<id>.png) into
    /// the runtime cache. Same mask pipeline as the catalog tips (mipmapped R8, luma =
    /// coverage). nil (→ procedural round fallback) when the file is missing.
    private func userShapeTexture(for id: String) -> MTLTexture? {
        if let cached = userShapeTextures[id] { return cached }
        guard let dir = BrushAssetStore.directory else { return nil }
        let url = dir.appendingPathComponent("shapes/\(id).png")
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let texture = Self.makeGrayscaleMaskTexture(device: device, queue: commandQueue, cgImage: cgImage) else {
            return nil
        }
        userShapeTextures[id] = texture
        userShapeLumaMeans[id] = Self.shapeMeanLuma(cgImage)
        return texture
    }

    /// Lazily load a user-imported grain (grains/<id>.png). Grayscale, tile = the
    /// image's own pixel size (Procreate-style: the source repeats at native scale,
    /// then `BrushConfig.grainScale` multiplies).
    private func userGrain(for id: String) -> (texture: MTLTexture, tilePx: Double)? {
        if let cached = userGrainTextures[id] { return cached }
        guard let dir = BrushAssetStore.directory else { return nil }
        let url = dir.appendingPathComponent("grains/\(id).png")
        guard let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let texture = Self.makeGrayscaleMaskTexture(device: device, queue: commandQueue, cgImage: cgImage) else {
            return nil
        }
        let entry = (texture: texture, tilePx: Double(cgImage.width))
        userGrainTextures[id] = entry
        return entry
    }

    /// Load every catalog shape that has a PNG resource into a mipmapped R8Unorm mask
    /// texture (luminance = coverage). Mipmaps avoid minification shimmer when a large
    /// (2048²) stamp is scaled down to a small brush radius.
    private static func loadShapeTextures(device: MTLDevice, queue: MTLCommandQueue) -> (textures: [String: MTLTexture], lumaMeans: [String: Float]) {
        var out: [String: MTLTexture] = [:]
        var means: [String: Float] = [:]
        for descriptor in BrushShapeCatalog.all {
            guard let resourceName = descriptor.resourceName,
                  let data = shapePNGData(resourceName: resourceName),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let texture = makeGrayscaleMaskTexture(device: device, queue: queue, cgImage: cgImage) else {
                continue
            }
            out[descriptor.id] = texture
            means[descriptor.id] = shapeMeanLuma(cgImage)
        }
        return (out, means)
    }

    /// Mean in-shape luma of a tip (pixels above a small threshold) — the P4a lightness
    /// map recenters tip luma around this so coverage-authored art (luma = coverage,
    /// clustered bright) maps its MEAN to "exact brush color" instead of washing white.
    private static func shapeMeanLuma(_ image: CGImage) -> Float {
        let w = min(image.width, 128), h = min(image.height, 128)
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0.75 }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = 0.0
        var n = 0
        for b in bytes where b > 12 { sum += Double(b) / 255.0; n += 1 }
        return n > 0 ? Float(sum / Double(n)) : 0.75
    }

    /// Shape-PNG bytes. SwiftPM builds read from the module resource bundle; the
    /// standalone BrushHarness build (swiftc, no generated `Bundle.module`) reads from
    /// the directory in the `BRUSH_SHAPES_DIR` env var instead (no textures → shaped
    /// brushes fall back to the procedural round tip, same as a missing resource).
    private static func shapePNGData(resourceName: String) -> Data? {
        #if BRUSH_HARNESS
        guard let dir = ProcessInfo.processInfo.environment["BRUSH_SHAPES_DIR"] else { return nil }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("\(resourceName).png")
        return try? Data(contentsOf: url)
        #else
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png",
                                          subdirectory: "BrushShapes") else { return nil }
        return try? Data(contentsOf: url)
        #endif
    }

    /// Rasterize a (grayscale) PNG into a mipmapped single-channel R8Unorm mask. The
    /// luminance is read straight as coverage; a dedicated DeviceGray context keeps this
    /// off the sRGB/P3 color path (a mask isn't a color — see CanvasModule CLAUDE.md).
    private static func makeGrayscaleMaskTexture(device: MTLDevice, queue: MTLCommandQueue, cgImage: CGImage) -> MTLTexture? {
        let w = cgImage.width, h = cgImage.height
        guard w > 0, h > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: true
        )
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: &bytes, bytesPerRow: w)

        if texture.mipmapLevelCount > 1,
           let cmdBuf = queue.makeCommandBuffer(),
           let blit = cmdBuf.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            cmdBuf.commit()
            cmdBuf.waitUntilCompleted()  // one-time at init, not interactive
        }
        return texture
    }

    // MARK: - Embedded Shader Source

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    // ── Brush Stamp ──────────────────────────────────────────────────────

    struct QuadVertex {
        float2 position;
        float2 texCoord;
    };

    struct StampInstance {
        float2 center;
        float  radius;
        float  rotation;
        float4 color;
        float  hardness;
        float  aspect;         // P4b: local-Y quad scale (pre-rotation); 1 = round
        float  wetTargetAlpha; // smudge alpha-carry; -1 = legacy coverage mode
        float  arcU;           // moving grain: arc position along the stroke (canvas px)
        float  grainMul;       // per-dab grain-depth multiplier (grain CurveOption)
        // Swift stride is 64 (SIMD4 alignment). SCALAR pads only — an MSL float3 is
        // itself 16-aligned and would inflate the GPU struct to 80 bytes, walking the
        // instanced fetch off-stride into garbage (stray-geometry bug, dry-19 iter 1).
        float  edgeFlat;       // 1 = stroke-aligned superellipse interior dab
        float  _pad0;
        float  _pad1;
    };

    struct StampVaryings {
        float4 position [[position]];
        float2 texCoord;
        float4 color;
        float  hardness;
        float  wetTargetAlpha; // consumed by wetStampFragment only
        float  strokeAlong;    // moving grain: this POINT's arc position along the stroke (canvas px)
        float  strokeLat;      // moving grain: this POINT's lateral offset from the stroke spine (canvas px)
        float  grainMul;       // per-dab grain-depth multiplier
        float  edgeFlat;       // 1 = superellipse (flat-sided) procedural dab
    };

    vertex StampVaryings brushStampVertex(
        uint vertexId [[vertex_id]],
        uint instanceId [[instance_id]],
        const device QuadVertex* quads [[buffer(0)]],
        const device StampInstance* instances [[buffer(1)]],
        constant float4& canvasSizeFlip [[buffer(2)]]  // (w, h, flipX, flipY)
    ) {
        QuadVertex q = quads[vertexId];
        StampInstance inst = instances[instanceId];

        // P4b anisotropy: squash the quad's local Y BEFORE rotation (aspect 1 = round).
        // texCoord is untouched, so every fragment (procedural falloff, shape mask, wet
        // KM) sees its usual unit space and simply lands on an elliptical footprint.
        float2 local = float2(q.position.x, q.position.y * max(inst.aspect, 0.05));

        // Rotate quad corner by pencil azimuth.
        float c = cos(inst.rotation);
        float s = sin(inst.rotation);
        float2 rotated = float2(
            local.x * c - local.y * s,
            local.x * s + local.y * c
        );

        // Scale by radius and translate to stamp center (in canvas pixels).
        float2 canvasPos = inst.center + rotated * inst.radius;

        // Canvas pixels → NDC. Metal NDC: x ∈ [-1,1] left→right, y ∈ [-1,1] bottom→top.
        // Canvas y=0 is top → NDC y=+1. So we flip.
        float2 ndc;
        ndc.x = (canvasPos.x / canvasSizeFlip.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (canvasPos.y / canvasSizeFlip.y) * 2.0;

        // Flip X/Y (Procreate Shape): per-brush UV mirror of the tip art. zw are 0/1
        // flags; no-op for the symmetric procedural round tip.
        float2 uv = q.texCoord;
        if (canvasSizeFlip.z > 0.5) { uv.x = 1.0 - uv.x; }
        if (canvasSizeFlip.w > 0.5) { uv.y = 1.0 - uv.y; }

        StampVaryings out;
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = uv;
        out.color = inst.color;
        out.hardness = inst.hardness;
        out.wetTargetAlpha = inst.wetTargetAlpha;
        // Moving grain: the POINT's stroke-frame coordinates, computed per VERTEX from
        // canvas position (affine → exact under interpolation). Projecting the canvas
        // offset onto the dab's travel direction makes the coordinates independent of
        // the dab's own diameter — overlapping dabs of DIFFERENT widths agree exactly
        // on the grain value at a shared canvas point. (The first per-dab texCoord
        // formulation normalized by each dab's diameter, so a varying-width stroke
        // sampled different grain per dab and max-blend exposed every circle boundary
        // — the "overlapping circles" report on dry-19.)
        float2 alongDir = float2(-s, c);   // local +y (travel) after rotation
        float2 latDir = float2(c, s);      // local +x (lateral) after rotation
        float2 rel = canvasPos - inst.center;
        out.strokeAlong = inst.arcU + dot(rel, alongDir);
        out.strokeLat = dot(rel, latDir);
        out.grainMul = inst.grainMul;
        out.edgeFlat = inst.edgeFlat;
        return out;
    }

    // Moving grain (2026-07-16): carve the dab's coverage by the grain sampled in a
    // STROKE-ANCHORED frame — u along the stroke (arcU + local-Y), v lateral (local-X)
    // — so the tooth travels with the stroke (streaky dry media). The quad is oriented
    // to the travel direction whenever moving grain is on (round tips are symmetric, so
    // forcing orientation costs nothing). Same soft-HEIGHT carve as the document-space
    // compositor. gp = (depth, invScale, latMul, alongMul); depth = 0 (dummy binding)
    // makes it an exact identity when off.
    static inline float movingGrainCarve(float cov, StampVaryings in,
                                         texture2d<float> grainTex,
                                         float4 gp, float4 g1, float4 g2) {
        if (gp.x <= 0.0) { return cov; }
        constexpr sampler g(filter::linear, mip_filter::linear, address::repeat);
        // Stroke-frame UV with per-axis Movement factors (gp.z = lateral, gp.w = along).
        // Movement 0 (smear): lateral ×3.5 / along ×0.45 — features stretch into streaks
        // running WITH the stroke (the crayon/lead look). Movement 1 (Rolling): ×1/×1 —
        // the texture rolls under the brush undistorted (grids stay square). Then the
        // Rotation matrix (g1.zw) turns the frame vs the stroke direction, and the
        // per-stroke Offset Jitter (g1.xy, canvas px) dephases repeated strokes.
        // Coordinates are the POINT's stroke-frame position (see brushStampVertex) —
        // dab-size-independent, so overlapping dabs agree and the interior is seamless.
        float2 p = float2(in.strokeLat * gp.z, in.strokeAlong * gp.w);
        p = float2(p.x * g1.z - p.y * g1.w, p.x * g1.w + p.y * g1.z);
        float2 guv = (p + g1.xy) * gp.y;
        // Brightness/Contrast pre-adjust (branched: (x−.5)·1+.5 costs float LSBs vs x,
        // and battery byte-diffs must stay exact at identity), then the smoothstep.
        float raw = grainTex.sample(g, guv).r;
        if (g2.y != 1.0 || g2.x != 0.0) {
            raw = clamp((raw - 0.5) * g2.y + 0.5 + g2.x, 0.0, 1.0);
        }
        float src = smoothstep(0.25, 0.85, raw);
        // Depth Minimum: floor for the MODULATED depth (dynamics grain curve + Depth
        // Jitter ride in grainMul) — full modulation still reaches Depth.
        float d = clamp(g2.z + (gp.x - g2.z) * in.grainMul, 0.0, 1.0);
        // MULTIPLICATIVE tooth, no compensation boost: the boost form (used once at
        // composite time by the document-grain path) inflates when applied per dab and
        // the stacking drowned the texture entirely (first dry-18 render — solid dark
        // caterpillar). Per-dab multiplicative carving survives overlap because the
        // moving UVs are CORRELATED across neighboring dabs (shared stroke frame), and
        // the max-blend PSOs keep the overlap COUNT out of the density.
        return cov * clamp(1.0 - d * src, 0.0, 1.0);
    }

    // Procedural soft-circle with adjustable hardness. Distance is computed from the
    // quad texCoord (center 0.5, circle edge at d=1) rather than sampling a mask, so a
    // single brush serves the full soft↔hard range. The falloff runs from `start` to the
    // edge (d=1). At hardness=1, start≈1 → a crisp edge with a ~1px fwidth AA rim. As
    // hardness drops, `start` is pushed inward — and below 0 at very low hardness — so the
    // feather begins near (or before) the center for a genuinely soft, airbrush-like dab
    // rather than a solid core with a thin rim. The quadratic (soft²) term keeps the
    // mid/high range close to a plain inner-radius falloff and concentrates the extra
    // softening at the low end.
    fragment float4 brushStampFragment(
        StampVaryings in [[stage_in]],
        texture2d<float> movingGrainTex [[texture(1)]],
        constant float4* movingGrainParams [[buffer(3)]]
    ) {
        // Distance metric: circle for visible/cap dabs; stroke-aligned SUPERELLIPSE
        // (x⁴+y⁴)^¼ for smooth-intent interior dabs — flat sides slide into a
        // mathematically flat stroke edge (no scallop), rounded corners keep curves
        // graceful. The quad is already rotated to the travel direction when edgeFlat
        // is set.
        float2 q = (in.texCoord - 0.5) * 2.0;
        float d;
        if (in.edgeFlat > 0.5) {
            float2 q2 = q * q;
            d = pow(dot(q2, q2), 0.25);
        } else {
            d = length(q);
        }
        float aa = max(fwidth(d), 1e-4);
        float soft = 1.0 - in.hardness;
        float start = min(in.hardness, 1.0 - aa) - soft * soft * 0.85;
        float alpha = 1.0 - smoothstep(start, 1.0, d);
        alpha = movingGrainCarve(alpha, in, movingGrainTex, movingGrainParams[0], movingGrainParams[1], movingGrainParams[2]);
        return in.color * alpha;
    }

    // P4a lightness-map tip (Krita PreserveLightness / Schatz quadratic; oracle:
    // LightnessMap.swift + OfflineTests). The tip's grayscale becomes a VALUE map:
    // f(x)=(2-4z)x² +(4z-1)x with z = brush HSL lightness (f(0)=0, f(1)=1, f(0.5)=z →
    // mid-gray tip pixels reproduce the brush color exactly). ALL of this runs in
    // sRGB-ENCODED space (the gamma landmine): the uniform carries the brush color as
    // sRGB HSL (precomputed CPU-side), and only the final result converts to linear
    // for the premultiplied _srgb store. Coverage stays the shaped-tip rule.
    static inline float lmHue2rgb(float p, float q, float t0) {
        float t = t0;
        if (t < 0.0) t += 1.0;
        if (t > 1.0) t -= 1.0;
        if (t < 1.0/6.0) return p + (q - p) * 6.0 * t;
        if (t < 1.0/2.0) return q;
        if (t < 2.0/3.0) return p + (q - p) * (2.0/3.0 - t) * 6.0;
        return p;
    }

    static inline float3 lmHSL2RGB(float h, float s, float l) {
        if (s < 1e-6) return float3(l, l, l);
        float q = l < 0.5 ? l * (1.0 + s) : l + s - l * s;
        float p = 2.0 * l - q;
        return float3(lmHue2rgb(p, q, h + 1.0/3.0), lmHue2rgb(p, q, h), lmHue2rgb(p, q, h - 1.0/3.0));
    }

    static inline float3 lmS2L(float3 c) {
        return float3(
            c.r <= 0.04045 ? c.r / 12.92 : pow((c.r + 0.055) / 1.055, 2.4),
            c.g <= 0.04045 ? c.g / 12.92 : pow((c.g + 0.055) / 1.055, 2.4),
            c.b <= 0.04045 ? c.b / 12.92 : pow((c.b + 0.055) / 1.055, 2.4));
    }

    static inline float lmL2S1(float x) {
        return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1.0 / 2.4) - 0.055;
    }

    static inline float3 lmL2S(float3 c) {
        return float3(lmL2S1(c.r), lmL2S1(c.g), lmL2S1(c.b));
    }

    // sRGB → HSL (matches LightnessMap.hsl on the CPU).
    static inline float3 lmRGB2HSL(float3 c) {
        float mx = max(c.r, max(c.g, c.b));
        float mn = min(c.r, min(c.g, c.b));
        float l = (mx + mn) * 0.5;
        float d = mx - mn;
        if (d < 1e-6) return float3(0.0, 0.0, l);
        float sat = l > 0.5 ? d / (2.0 - mx - mn) : d / (mx + mn);
        float h;
        if (mx == c.r)      h = (c.g - c.b) / d + (c.g < c.b ? 6.0 : 0.0);
        else if (mx == c.g) h = (c.b - c.r) / d + 2.0;
        else                h = (c.r - c.g) / d + 4.0;
        return float3(h / 6.0, sat, l);
    }

    fragment float4 lightnessShapedStampFragment(
        StampVaryings in [[stage_in]],
        texture2d<float> shapeTex [[texture(0)]],
        constant float4& lm [[buffer(0)]],  // (h, s, z, strength) — h/s/z now a FALLBACK; see below
        constant float4& rc [[buffer(1)]],  // (meanLuma, gain, 0, 0) — coverage-art recentering
        texture2d<float> movingGrainTex [[texture(1)]],
        constant float4* movingGrainParams [[buffer(3)]]
    ) {
        constexpr sampler shapeSampler(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float m = shapeTex.sample(shapeSampler, in.texCoord).r;
        float gamma = mix(1.8, 0.55, clamp(in.hardness, 0.0, 1.0));
        float cov = pow(max(m, 0.0), gamma);
        // The working HSL comes from the DAB's own color (un-premultiply the linear
        // in.color, encode to sRGB, RGB→HSL) — not from the per-stroke uniform — so
        // per-stroke AND per-dab color dynamics (P6 jitter) survive the lightness map.
        // The uniform's (h,s,z) is only the a==0 fallback. Deriving z per dab keeps the
        // oracle invariant per dab: mid-gray tip texel == that dab's exact color.
        float3 hsl;
        if (in.color.a > 1e-5) {
            hsl = lmRGB2HSL(lmL2S(in.color.rgb / in.color.a));
        } else {
            hsl = lm.xyz;
        }
        // Recenter coverage-authored luma so the tip's MEAN maps to the brush color,
        // damping the value swing by the NEIGHBORHOOD coverage (coarse-mip sample):
        // boundary texels fade with the brush color (no dark halo) while interior
        // speckle keeps its swing (mirrors LightnessMap.recenter — per-texel damping
        // cannot separate the two, same m in both zones).
        float mB = shapeTex.sample(shapeSampler, in.texCoord, level(4.0)).r;
        float damp = smoothstep(0.5, 0.9, mB);
        float mc = clamp(0.5 + (m - rc.x) * rc.y * damp, 0.0, 1.0);
        float z = hsl.z;
        float f = clamp((2.0 - 4.0 * z) * mc * mc + (4.0 * z - 1.0) * mc, 0.0, 1.0);
        float L = z + (f - z) * lm.w;
        float3 lin = lmS2L(lmHSL2RGB(hsl.x, hsl.y, L));
        cov = movingGrainCarve(cov, in, movingGrainTex, movingGrainParams[0], movingGrainParams[1], movingGrainParams[2]);
        float a = in.color.a * cov;   // flow × coverage, premultiplied out
        return float4(lin * a, a);
    }

    // Textured-shape brush (pro-brush Phase 3). Samples a grayscale stamp mask (luminance
    // = coverage) over the quad's texCoord instead of computing a procedural circle, so
    // chalk/charcoal/bristle/etc. dabs carry real edge + interior texture. Hardness acts
    // as a coverage gamma centered near neutral at 0.5: lower → lighter/feathered (the
    // mask's mid-grays recede), higher → denser/punchier (mid-grays fill in), without
    // destroying the mask's internal variation. in.color is premultiplied (rgb*flow,
    // flow); scaling by coverage keeps it premultiplied for the source-over blend.
    fragment float4 shapedStampFragment(
        StampVaryings in [[stage_in]],
        texture2d<float> shapeTex [[texture(0)]],
        texture2d<float> movingGrainTex [[texture(1)]],
        constant float4* movingGrainParams [[buffer(3)]]
    ) {
        constexpr sampler shapeSampler(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float m = shapeTex.sample(shapeSampler, in.texCoord).r;
        float gamma = mix(1.8, 0.55, clamp(in.hardness, 0.0, 1.0));
        float cov = pow(max(m, 0.0), gamma);
        cov = movingGrainCarve(cov, in, movingGrainTex, movingGrainParams[0], movingGrainParams[1], movingGrainParams[2]);
        return in.color * cov;
    }

    // Programmable-blend eraser: reads current framebuffer value, applies
    // destination-out (dst *= 1 - mask) in-shader, and snaps near-clear pixels
    // to exact zero. Without the snap, the soft brush mask leaves partial-alpha
    // residue at the eraser's periphery — visually invisible but encodes as
    // a faint stroke-color ghost in the JPEG sent to the generator.
    //
    // The shared brushMask uses a (1-r²)² falloff that's right for paint build-up
    // but too gradual for erasing — at half-radius only ~50% of alpha is removed,
    // forcing several passes to clear a region. We remap the mask to a near-hard
    // disc (smoothstep over the very tail of the falloff) so a single pass fully
    // erases inside the stamp radius, with a thin AA rim to avoid jaggies.
    fragment float4 eraserStampFragment(
        StampVaryings in [[stage_in]],
        texture2d<float> brushMask [[texture(0)]],
        float4 dst [[color(0)]]
    ) {
        constexpr sampler maskSampler(filter::linear, address::clamp_to_zero);
        float mask = brushMask.sample(maskSampler, in.texCoord).r;
        mask = smoothstep(0.0, 0.02, mask);
        float4 result = dst * (1.0 - mask);
        return result.a < (4.0 / 255.0) ? float4(0.0) : result;
    }

    // Wet-mix brush (pro-brush Phase 4, Step 1). Reads the canvas pixel under the stamp
    // via framebuffer fetch and mixes it toward the stamp's color — wet-on-wet build-up,
    // not opaque coverage. in.color carries the STRAIGHT brush color in rgb and the
    // per-stamp deposit weight in alpha. Coverage uses the same procedural-hardness
    // falloff as the dry brush. Mixing is a LINEAR lerp for Step 1 (Kubelka-Munk pigment
    // mixing slots in here later). dst is premultiplied+linear (sRGB texture); we
    // un-premultiply, mix straight colors, then re-premultiply.
    // Wet-mix brush with spectral Kubelka-Munk pigment mixing (pro-brush Phase 4 Step 2).
    // Reads the canvas pixel under the stamp (framebuffer fetch), upsamples it to a
    // 36-band reflectance spectrum (Mallett-Yuksel 7-basis), KM-mixes per band toward the
    // per-stamp carried LOAD color (in.color.rgb, evolves along the stroke — Step 3 smear),
    // integrates back to linear RGB, and applies endpoint-exact residual correction so
    // unmixed colors stay faithful. Both the canvas color and the load color are upsampled
    // in-shader (the load varies per stamp, so it can't be a per-stroke uniform).
    // Tables: basis (7×36, k-major) buffer(0); spectrum→linRGB matrix (36×3) buffer(1).
    // Wet INK through the SCRATCH layer (P7 core, 2026-07-16). The old direct-RMW ink
    // path had a structural flaw: each dab KM-mixed the pixel toward the carried load,
    // and the fixed point of repeating that is PURE load — dozens of overlapping dabs
    // fully erased the under-color, then the opacity ceiling blended that pure load with
    // white paper ("opaque replacement fading to white", fixture-4). Here the KM under-
    // color comes from the PRISTINE pre-stroke canvas (bound as a texture — the render
    // target is the scratch), so the mix CANNOT compound: one stroke = one wet glaze of
    // KM(under → load, Mix), accumulated source-over in scratch and flattened at the
    // per-stroke opacity ceiling exactly like a dry stroke. No framebuffer fetch, so wet
    // ink also works on the Simulator. Smudge stays on the RMW path (wetStampFragment).
    fragment float4 wetInkScratchFragment(
        StampVaryings in [[stage_in]],
        texture2d<float> canvasTex [[texture(0)]],
        constant float* basis [[buffer(0)]],
        constant float* mat [[buffer(1)]],
        constant float2& docSize [[buffer(2)]]
    ) {
        constexpr int NB = 36;
        constexpr sampler canvasSampler(filter::nearest, address::clamp_to_edge);
        float d = length(in.texCoord - 0.5) * 2.0;
        float aa = max(fwidth(d), 1e-4);
        float soft = 1.0 - in.hardness;
        float start = min(in.hardness, 1.0 - aa) - soft * soft * 0.85;
        float cov = 1.0 - smoothstep(start, 1.0, d);
        if (cov <= 0.0) { return float4(0.0); }

        // Pre-stroke canvas at this fragment (scratch and document share pixel space).
        float4 base = canvasTex.sample(canvasSampler, in.position.xy / docSize);
        float3 brushLin = in.color.rgb;      // carried load (straight linear)
        float w = in.color.a;                // Mix — KM weight toward the load
        // The mix partner: what the eye sees (premult-linear over white paper), faded
        // toward the LOAD itself by paint presence — bare paper mixes with nothing, so
        // ink on paper stays full-strength ink; Mix only waters down against PAINT.
        float3 seen = base.rgb + (1.0 - base.a);
        float3 under = mix(brushLin, seen, base.a);

        float dstW[7], brW[7];
        { float3 c = max(under, 0.0); float mn = min(c.r, min(c.g, c.b));
          dstW[0]=mn; dstW[1]=0; dstW[2]=0; dstW[3]=0; dstW[4]=0; dstW[5]=0; dstW[6]=0;
          float rr=c.r-mn, gg=c.g-mn, bb=c.b-mn;
          if (rr<=gg && rr<=bb) { dstW[1]=min(gg,bb); if (gg>bb) dstW[5]=gg-bb; else dstW[6]=bb-gg; }
          else if (gg<=rr && gg<=bb) { dstW[2]=min(rr,bb); if (rr>bb) dstW[4]=rr-bb; else dstW[6]=bb-rr; }
          else { dstW[3]=min(rr,gg); if (rr>gg) dstW[4]=rr-gg; else dstW[5]=gg-rr; } }
        { float3 c = max(brushLin, 0.0); float mn = min(c.r, min(c.g, c.b));
          brW[0]=mn; brW[1]=0; brW[2]=0; brW[3]=0; brW[4]=0; brW[5]=0; brW[6]=0;
          float rr=c.r-mn, gg=c.g-mn, bb=c.b-mn;
          if (rr<=gg && rr<=bb) { brW[1]=min(gg,bb); if (gg>bb) brW[5]=gg-bb; else brW[6]=bb-gg; }
          else if (gg<=rr && gg<=bb) { brW[2]=min(rr,bb); if (rr>bb) brW[4]=rr-bb; else brW[6]=bb-rr; }
          else { brW[3]=min(rr,gg); if (rr>gg) brW[4]=rr-gg; else brW[5]=gg-rr; } }

        float3 mixLin = float3(0.0), dstRT = float3(0.0), brushRT = float3(0.0);
        for (int i = 0; i < NB; i++) {
            float sd = 0.0, sb = 0.0;
            for (int k = 0; k < 7; k++) { float bk = basis[k * NB + i]; sd += dstW[k]*bk; sb += brW[k]*bk; }
            sd = clamp(sd, 0.004, 1.0); sb = clamp(sb, 0.004, 1.0);
            float3 A = float3(mat[i*3+0], mat[i*3+1], mat[i*3+2]);
            dstRT += sd * A; brushRT += sb * A;
            float ksd = (1.0 - sd) * (1.0 - sd) / (2.0 * sd);
            float ksb = (1.0 - sb) * (1.0 - sb) / (2.0 * sb);
            float ksm = mix(ksd, ksb, w);
            float Rm = clamp(1.0 + ksm - sqrt(ksm * ksm + 2.0 * ksm), 0.0, 1.0);
            mixLin += Rm * A;
        }
        mixLin = clamp(mixLin, 0.0, 1.0);
        dstRT = clamp(dstRT, 0.0, 1.0);
        brushRT = clamp(brushRT, 0.0, 1.0);
        float3 corrected = clamp(mixLin + (1.0 - w) * (under - dstRT) + w * (brushLin - brushRT), 0.0, 1.0);

        // Deposit source-over into the scratch: coverage-alpha scaled by the CHARGE
        // reservoir level (wetTargetAlpha carries it for ink stamps — a drying brush
        // deposits a fainter glaze), KM-mixed color. Within-stroke overlaps saturate
        // toward the reservoir level; the OPACITY ceiling applies once, at the flatten —
        // same Glaze split as the dry brush.
        float a = cov * clamp(in.wetTargetAlpha, 0.0, 1.0);
        return float4(corrected * a, a);
    }

    fragment float4 wetStampFragment(
        StampVaryings in [[stage_in]],
        constant float* basis [[buffer(0)]],
        constant float* mat [[buffer(1)]],
        float4 dst [[color(0)]]
    ) {
        constexpr int NB = 36;
        float d = length(in.texCoord - 0.5) * 2.0;
        float aa = max(fwidth(d), 1e-4);
        float soft = 1.0 - in.hardness;
        float start = min(in.hardness, 1.0 - aa) - soft * soft * 0.85;
        float cov = 1.0 - smoothstep(start, 1.0, d);
        if (cov <= 0.0) { return dst; }
        float w = cov * in.color.a;                 // KM mix weight toward the carried load
        float3 brushLin = in.color.rgb;             // carried load color (linear), per stamp
        // Fade the mix target from the load color (no paint underneath) to the under-color
        // by how much paint is present (dst.a), so the transition tracks the under-color's
        // own edge softness (no hard step). Opaque cores (dst.a≈1) → full under-color.
        float3 under = dst.rgb / max(dst.a, 1e-4);
        float3 dstLin = mix(brushLin, under, dst.a);

        // Mallett-Yuksel sorted-channel upsample weights for an sRGB-linear color.
        float dstW[7], brW[7];
        { float3 c = max(dstLin, 0.0); float mn = min(c.r, min(c.g, c.b));
          dstW[0]=mn; dstW[1]=0; dstW[2]=0; dstW[3]=0; dstW[4]=0; dstW[5]=0; dstW[6]=0;
          float rr=c.r-mn, gg=c.g-mn, bb=c.b-mn;
          if (rr<=gg && rr<=bb) { dstW[1]=min(gg,bb); if (gg>bb) dstW[5]=gg-bb; else dstW[6]=bb-gg; }
          else if (gg<=rr && gg<=bb) { dstW[2]=min(rr,bb); if (rr>bb) dstW[4]=rr-bb; else dstW[6]=bb-rr; }
          else { dstW[3]=min(rr,gg); if (rr>gg) dstW[4]=rr-gg; else dstW[5]=gg-rr; } }
        { float3 c = max(brushLin, 0.0); float mn = min(c.r, min(c.g, c.b));
          brW[0]=mn; brW[1]=0; brW[2]=0; brW[3]=0; brW[4]=0; brW[5]=0; brW[6]=0;
          float rr=c.r-mn, gg=c.g-mn, bb=c.b-mn;
          if (rr<=gg && rr<=bb) { brW[1]=min(gg,bb); if (gg>bb) brW[5]=gg-bb; else brW[6]=bb-gg; }
          else if (gg<=rr && gg<=bb) { brW[2]=min(rr,bb); if (rr>bb) brW[4]=rr-bb; else brW[6]=bb-rr; }
          else { brW[3]=min(rr,gg); if (rr>gg) brW[4]=rr-gg; else brW[5]=gg-rr; } }

        float3 mixLin = float3(0.0), dstRT = float3(0.0), brushRT = float3(0.0);
        for (int i = 0; i < NB; i++) {
            float sd = 0.0, sb = 0.0;
            for (int k = 0; k < 7; k++) { float bk = basis[k * NB + i]; sd += dstW[k]*bk; sb += brW[k]*bk; }
            sd = clamp(sd, 0.004, 1.0); sb = clamp(sb, 0.004, 1.0);
            float3 A = float3(mat[i*3+0], mat[i*3+1], mat[i*3+2]);
            dstRT += sd * A; brushRT += sb * A;
            float ksd = (1.0 - sd) * (1.0 - sd) / (2.0 * sd);
            float ksb = (1.0 - sb) * (1.0 - sb) / (2.0 * sb);
            float ksm = mix(ksd, ksb, w);
            float Rm = clamp(1.0 + ksm - sqrt(ksm * ksm + 2.0 * ksm), 0.0, 1.0);
            mixLin += Rm * A;
        }
        // Clamp integrated linear RGB to [0,1] before the residual math (matches reference).
        mixLin = clamp(mixLin, 0.0, 1.0);
        dstRT = clamp(dstRT, 0.0, 1.0);
        brushRT = clamp(brushRT, 0.0, 1.0);
        // Endpoint-exact residual correction (linear): unmixed dst & full-deposit load stay faithful.
        float3 corrected = max(mixLin + (1.0 - w) * (dstLin - dstRT) + w * (brushLin - brushRT), 0.0);

        // Alpha semantics, two modes:
        //  • wetTargetAlpha < 0 (wet INK, legacy): builds by COVERAGE toward opaque
        //    (opaque wet paint; no translucent fringe → no white halo). Byte-identical
        //    to the pre-2026-07-15 behavior.
        //  • wetTargetAlpha ≥ 0 (SMUDGE alpha-carry): dst.a moves toward the CARRIED
        //    load's alpha at the deposit rate w — smudging 40%-opacity paint keeps it
        //    ~40% instead of hardening it opaque, dragging onto blank lays a translucent
        //    tail that thins as the load depletes, and dragging a thin load across dense
        //    paint genuinely thins it (real smudge displaces paint, not just color).
        float outA;
        if (in.wetTargetAlpha < 0.0) {
            // Coverage build with a CEILING at the stroke's opacity (packed in the -1..-2
            // sentinel range as -(1+opacity)): translucent wet ink stays translucent
            // (device finding, 2026-07-15 — the deposit-rate scaling alone converges to
            // opaque and reads as "opacity does nothing"). Existing denser paint is
            // never thinned (max with dst.a). Opacity 1 is byte-identical to the old rule.
            float ceilA = clamp(-in.wetTargetAlpha - 1.0, 0.0, 1.0);
            outA = max(dst.a, min(dst.a + cov * (1.0 - dst.a), max(dst.a, ceilA)));
        } else {
            outA = clamp(dst.a + (in.wetTargetAlpha - dst.a) * w, 0.0, 1.0);
        }
        return float4(corrected * outA, outA);
    }

    // ── Compositor (full-screen quad) ────────────────────────────────────

    struct CompositorVaryings {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex CompositorVaryings compositorVertex(
        uint vertexId [[vertex_id]],
        const device QuadVertex* quads [[buffer(0)]]
    ) {
        QuadVertex q = quads[vertexId];
        CompositorVaryings out;
        out.position = float4(q.position, 0.0, 1.0);
        out.texCoord = q.texCoord;
        return out;
    }

    fragment float4 compositorFragment(
        CompositorVaryings in [[stage_in]],
        texture2d<float> layerTexture [[texture(0)]],
        constant float& opacity [[buffer(0)]]
    ) {
        constexpr sampler texSampler(filter::linear, address::clamp_to_zero);
        float4 color = layerTexture.sample(texSampler, in.texCoord);
        return color * opacity;
    }

    // ── Blend-mode compositor (framebuffer fetch; device only) ───────────
    // Separable W3C blend formulas on UNPREMULTIPLIED linear channels; the
    // full compositing equation (spec: co = (1-ab)·cs + (1-as)·cb + as·ab·B)
    // runs here because fixed-function blending can't express these modes.
    // Indices must match LayerBlendMode.shaderIndex.

    struct BlendParams {
        float opacity;
        uint mode;
    };

    static float3 blendFormula(uint mode, float3 s, float3 d) {
        switch (mode) {
            case 1: return min(s, d);                                   // darken
            case 2: return s * d;                                       // multiply
            case 3: {                                                   // color burn
                float3 raw = 1.0 - min(float3(1.0), (1.0 - d) / max(s, float3(1e-5)));
                raw = select(raw, float3(0.0), s <= float3(1e-5));
                return select(raw, float3(1.0), d >= float3(1.0 - 1e-5));
            }
            case 4: return max(float3(0.0), s + d - 1.0);               // linear burn
            case 5: return max(s, d);                                   // lighten
            case 6: return s + d - s * d;                               // screen
            case 7: {                                                   // color dodge
                float3 raw = min(float3(1.0), d / max(1.0 - s, float3(1e-5)));
                raw = select(raw, float3(1.0), s >= float3(1.0 - 1e-5));
                return select(raw, float3(0.0), d <= float3(1e-5));
            }
            case 8: return min(float3(1.0), s + d);                     // add (linear dodge)
            case 9:                                                     // overlay = hardLight(d, s)
                return select(1.0 - 2.0 * (1.0 - d) * (1.0 - s),
                              2.0 * d * s,
                              d <= float3(0.5));
            case 10: {                                                  // soft light (W3C)
                float3 Dd = select(sqrt(d),
                                   ((16.0 * d - 12.0) * d + 4.0) * d,
                                   d <= float3(0.25));
                return select(d + (2.0 * s - 1.0) * (Dd - d),
                              d - (1.0 - 2.0 * s) * d * (1.0 - d),
                              s <= float3(0.5));
            }
            case 11:                                                    // hard light
                return select(1.0 - 2.0 * (1.0 - s) * (1.0 - d),
                              2.0 * s * d,
                              s <= float3(0.5));
            case 12: return abs(s - d);                                 // difference
            case 13: return s + d - 2.0 * s * d;                        // exclusion
            default: return s;                                          // normal
        }
    }

    fragment float4 blendCompositorFragment(
        CompositorVaryings in [[stage_in]],
        float4 dst [[color(0)]],
        texture2d<float> layerTexture [[texture(0)]],
        constant BlendParams& bp [[buffer(0)]]
    ) {
        constexpr sampler texSampler(filter::linear, address::clamp_to_zero);
        // Layer opacity scales the premultiplied source uniformly.
        float4 src = layerTexture.sample(texSampler, in.texCoord) * bp.opacity;
        float sa = src.a;
        float da = dst.a;
        float3 sc = sa > 1e-5 ? src.rgb / sa : float3(0.0);
        float3 dc = da > 1e-5 ? dst.rgb / da : float3(0.0);
        float3 B = blendFormula(bp.mode, sc, dc);
        float3 rgb = (1.0 - da) * src.rgb + (1.0 - sa) * dst.rgb + sa * da * B;
        float a = sa + da * (1.0 - sa);
        return float4(rgb, a);
    }

    // P8 grain compositor: composites the SCRATCH (the isolated in-flight stroke) while
    // carving its accumulated alpha with document-space paper tooth. src = grain height;
    // valleys (high src) eat the stroke's alpha: a' = clamp(a − src·depth, 0, 1), an
    // exact identity at depth 0. Applied at composite time so overlapping dabs cannot
    // refill the tooth. texCoord spans the full document, so grainUV = texCoord·uvScale
    // tiles in DOCUMENT space (tooth stays put; overlapping strokes share it).
    fragment float4 grainCompositorFragment(
        CompositorVaryings in [[stage_in]],
        texture2d<float> layerTexture [[texture(0)]],
        texture2d<float> grainTex [[texture(1)]],
        constant float& opacity [[buffer(0)]],
        constant float4* gpArr [[buffer(1)]]
    ) {
        constexpr sampler texSampler(filter::linear, address::clamp_to_zero);
        constexpr sampler grainSampler(filter::linear, mip_filter::linear, address::repeat);
        float4 gp = gpArr[0];   // (depth, sx, sy, 0)
        float4 t1 = gpArr[1];   // (brightness, contrastMul, 0, 0)
        float4 color = layerTexture.sample(texSampler, in.texCoord);
        float src = grainTex.sample(grainSampler, in.texCoord * gp.yz).r;
        if (t1.y != 1.0 || t1.x != 0.0) {
            src = clamp((src - 0.5) * t1.y + 0.5 + t1.x, 0.0, 1.0);
        }
        float a = color.a;
        float carved = clamp(a - src * gp.x, 0.0, 1.0);
        // Premultiplied: scale rgb with the same factor so straight color is preserved.
        float k = a > 1e-5 ? carved / a : 0.0;
        return color * k * opacity;
    }

    // ── Masked Copy (lasso extraction) ──────────────────────────────────

    /// Outputs mask.r as alpha for destination-out clear passes. R8Unorm textures
    /// return alpha=1 when sampled normally, so compositorFragment can't be used
    /// for masked clears — it would clear the entire canvas regardless of mask value.
    fragment float4 maskedClearFragment(
        CompositorVaryings in [[stage_in]],
        texture2d<float> mask [[texture(0)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_zero);
        float maskVal = mask.sample(s, in.texCoord).r;
        return float4(0.0, 0.0, 0.0, maskVal);
    }

    fragment float4 maskedCopyFragment(
        CompositorVaryings in [[stage_in]],
        texture2d<float> canvas [[texture(0)]],
        texture2d<float> mask [[texture(1)]]
    ) {
        constexpr sampler s(filter::linear, address::clamp_to_zero);
        float4 color = canvas.sample(s, in.texCoord);
        float maskAlpha = mask.sample(s, in.texCoord).r;
        return color * maskAlpha;
    }
    """
}

// MARK: - Load-path self-test

/// Physical-device self-test for the image-load pipeline, triggered by the
/// `-KikiCanvasLoadSelfTest 1` launch argument (read the verdict via
/// `ipad.sh logs`). Exists because CIContext.render(to: MTLTexture) silently
/// no-ops on some runtimes (iOS 18.3.1 simulator; suspected iPadOS 26 device),
/// which made every reopened drawing load blank — and the next autosave then
/// persisted the blank layers (real data loss, reported 2026-08-22).
/// Exercises, at renderer level, exactly what reopening a drawing does:
/// ground-truth pixels via raw texture bytes → layerPNGData (save) → clear →
/// loadImageDataIntoLayer (load, which self-selects direct vs CPU route) →
/// pixel compare.
public enum CanvasLoadSelfTest {
    public static func report() -> String {
        guard let renderer = CanvasRenderer() else { return "FAIL: renderer init" }
        let side = 256
        renderer.configureDocument(side: side, viewScale: 1)
        guard !renderer.layers.isEmpty else { return "FAIL: no layer after configure" }
        let texture = renderer.layers[0].texture

        // Ground truth: opaque red 64×64 block at (32,32), written as raw bytes
        // (BGRA sRGB-encoded premultiplied — exact for alpha 1). No CI involved.
        let block = 64
        var px = [UInt8](repeating: 0, count: block * block * 4)
        for i in 0..<(block * block) {
            px[i * 4 + 0] = 0    // B
            px[i * 4 + 1] = 0    // G
            px[i * 4 + 2] = 255  // R
            px[i * 4 + 3] = 255  // A
        }
        px.withUnsafeBytes { raw in
            texture.replace(region: MTLRegionMake2D(32, 32, block, block), mipmapLevel: 0,
                            withBytes: raw.baseAddress!, bytesPerRow: block * 4)
        }

        // Save side.
        guard let png = renderer.layerPNGData(at: 0) else { return "FAIL: layerPNGData nil" }

        // Direct-render probe verdict (also decides which route the load uses).
        let direct = renderer.directCIRenderToTextureWorks

        // Load side (fresh texture so stale bytes can't fake a pass).
        renderer.clearTexture(texture)
        guard renderer.loadImageDataIntoLayer(at: 0, png) else { return "FAIL: load returned false" }

        func pixel(_ x: Int, _ y: Int) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: 4)
            texture.getBytes(&b, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
            return b
        }
        let center = pixel(64, 64)   // inside the block
        let corner = pixel(200, 200) // outside — must stay transparent
        let centerOK = abs(Int(center[2]) - 255) <= 2 && Int(center[0]) <= 2
            && Int(center[1]) <= 2 && abs(Int(center[3]) - 255) <= 2
        let cornerOK = corner == [0, 0, 0, 0]
        let verdict = (centerOK && cornerOK) ? "PASS" : "FAIL"
        return "\(verdict): directCIRender=\(direct ? "works" : "BROKEN(no-op)") "
            + "pngBytes=\(png.count) centerBGRA=\(center) cornerBGRA=\(corner)"
    }
}

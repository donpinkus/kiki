import UIKit
import Metal
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
    private let eraserStampPSO: MTLRenderPipelineState
    /// Wet-mix brush: programmable framebuffer-read RMW into the layer (pro-brush
    /// Phase 4). nil if pipeline creation failed (e.g. on the Simulator, which doesn't
    /// support framebuffer fetch) — callers must guard on it.
    private let wetStampPSO: MTLRenderPipelineState?
    private let compositorPSO: MTLRenderPipelineState

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

    /// The stamp texture for the stroke currently being drawn/flattened, or nil for the
    /// procedural round brush. `MetalCanvasView` sets this when a stroke starts (alongside
    /// `activeStrokeOpacity`); the live + flatten render paths read it to pick the shaped
    /// PSO and bind the texture.
    var activeShapeTexture: MTLTexture?

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
    }

    /// Maximum stamps per frame. 240 Hz pencil × ~6 interpolated steps per touch
    /// × double-buffer safety = ~3000. Generous headroom.
    private static let maxStampsPerFrame = 4096
    private let stampBuffer: MTLBuffer
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
        // Wet PSO uses framebuffer fetch — unsupported on the Simulator, so this may
        // be nil there; the wet tool guards on it and no-ops if unavailable.
        self.wetStampPSO = Self.makeWetStampPSO(device: device, library: lib)
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
        let stampBufSize = Self.maxStampsPerFrame * MemoryLayout<StampInstance>.stride
        guard let sbuf = device.makeBuffer(length: stampBufSize, options: .storageModeShared) else { return nil }
        self.stampBuffer = sbuf

        // Brush mask texture (64×64 soft circle).
        guard let mask = Self.generateBrushMask(device: device, size: 64) else { return nil }
        self.brushMaskTexture = mask

        // Load textured brush-shape stamps (pro-brush Phase 3). Missing/failed assets are
        // skipped — that shape just falls back to the procedural round brush at draw time.
        self.shapeTextures = Self.loadShapeTextures(device: device, queue: queue)

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
        guard side != canvasWidth || side != canvasHeight else { return }

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
        guard stampCount < Self.maxStampsPerFrame else { return }
        let ptr = stampBuffer.contents().bindMemory(to: StampInstance.self, capacity: Self.maxStampsPerFrame)
        ptr[stampCount] = stamp
        stampCount += 1
    }

    // MARK: - Rendering

    /// Render one frame: clear scratch → draw stamps into scratch → composite
    /// all visible layers + scratch into the given drawable texture.
    func renderFrame(drawable: CAMetalDrawable, isErasing: Bool) {
        guard !layers.isEmpty, let scratch = scratchTexture else { return }
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
    func flattenScratchIntoCanvas() {
        guard let canvas = activeLayerTexture, let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(compositorPSO)
        enc.setFragmentTexture(scratch, index: 0)
        var opacity: Float = activeStrokeOpacity
        enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
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
        var canvasSize = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
        enc.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
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
        var canvasSize = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
        enc.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
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

    // MARK: - Wet Kubelka-Munk setup + CPU helpers (pro-brush Phase 4 Step 2)

    /// Build the spectral-mixing tables once: the 7 Mallett-Yuksel basis reflectance
    /// spectra (locked tuning) and the per-band spectrum→linear-RGB matrix (Wyman CMF
    /// approx + D65). Ported from the km_tune_final spike. CPU copies are kept for
    /// per-stroke brush upsampling; Float buffers are uploaded for the fragment shader.
    private func setupWetKMTables() {
        let NB = Self.wetNB
        let wl: [Double] = (0..<NB).map { 400.0 + Double($0) * (300.0 / Double(NB - 1)) }
        func g(_ x: Double, _ mu: Double, _ s1: Double, _ s2: Double) -> Double {
            let t = (x - mu) * (x < mu ? 1/s1 : 1/s2); return exp(-0.5 * t * t)
        }
        func xbar(_ l: Double) -> Double { 1.056*g(l,599.8,37.9,31.0) + 0.362*g(l,442.0,16.0,26.7) - 0.065*g(l,501.1,20.4,26.2) }
        func ybar(_ l: Double) -> Double { 0.821*g(l,568.8,46.9,40.5) + 0.286*g(l,530.9,16.3,31.1) }
        func zbar(_ l: Double) -> Double { 1.217*g(l,437.0,11.8,36.0) + 0.681*g(l,459.0,26.0,13.8) }
        func d65(_ l: Double) -> Double { 100.0*exp(-0.5*pow((l-470)/260,2)) + 12.0*exp(-0.5*pow((l-600)/90,2)) }
        let ill = wl.map(d65), xb = wl.map(xbar), yb = wl.map(ybar), zb = wl.map(zbar)
        var knorm = 0.0; for i in 0..<NB { knorm += ill[i]*yb[i] }

        var mat = [SIMD3<Double>](repeating: .zero, count: NB)
        for i in 0..<NB {
            let e = ill[i] / knorm
            let X = e*xb[i], Y = e*yb[i], Z = e*zb[i]
            mat[i] = SIMD3<Double>(
                 3.2406*X - 1.5372*Y - 0.4986*Z,
                -0.9689*X + 1.8758*Y + 0.0415*Z,
                 0.0557*X - 0.2040*Y + 1.0570*Z)
        }

        func clampS(_ v: Double) -> Double { max(0.004, min(1.0, v)) }
        func sig(_ x: Double) -> Double { 1/(1+exp(-x)) }
        func bump(_ l: Double, _ mu: Double, _ w: Double) -> Double { exp(-0.5*pow((l-mu)/w,2)) }
        let aS = 0.32, wS = 26.0, aR = 0.32   // locked blue-basis tuning
        func basis(_ k: Int, _ l: Double) -> Double {
            switch k {
            case 0: return clampS(0.985)                                              // white
            case 1: return clampS(0.02 + 0.96*sig((555 - l)/20))                      // cyan
            case 2: return clampS(0.02 + 0.96*(sig((465 - l)/18) + sig((l-595)/18)))  // magenta
            case 3: return clampS(0.02 + 0.96*sig((l - 520)/16))                      // yellow
            case 4: return clampS(0.02 + 0.96*sig((l - 595)/10))                      // red
            case 5: return clampS(0.02 + 0.96*bump(l,540,42))                         // green
            default: return clampS(0.02 + 0.96*(bump(l,458,32) + aS*bump(l,520,wS) + aR*bump(l,660,30)) * sig((l-415)/12)) // blue
            }
        }
        var basisD = [[Double]]()
        for k in 0..<7 { basisD.append(wl.map { basis(k, $0) }) }
        wetBasisD = basisD
        wetMat = mat

        var basisF = [Float](repeating: 0, count: 7*NB)
        for k in 0..<7 { for i in 0..<NB { basisF[k*NB+i] = Float(basisD[k][i]) } }
        var matF = [Float](repeating: 0, count: NB*3)
        for i in 0..<NB { matF[i*3+0] = Float(mat[i].x); matF[i*3+1] = Float(mat[i].y); matF[i*3+2] = Float(mat[i].z) }
        wetBasisBuffer = device.makeBuffer(bytes: basisF, length: basisF.count * MemoryLayout<Float>.size, options: .storageModeShared)
        wetMatBuffer = device.makeBuffer(bytes: matF, length: matF.count * MemoryLayout<Float>.size, options: .storageModeShared)
    }

    /// Mallett-Yuksel sorted-channel upsample: linear RGB → 36-band reflectance spectrum.
    private func wetUpsample(_ lin: SIMD3<Double>) -> [Double] {
        let NB = Self.wetNB
        let r = max(0, lin.x), gc = max(0, lin.y), b = max(0, lin.z)
        var w = [Double](repeating: 0, count: 7)   // white,cyan,magenta,yellow,red,green,blue
        let mn = min(r, min(gc, b)); w[0] = mn
        let rr = r - mn, gg = gc - mn, bb = b - mn
        if rr <= gg && rr <= bb { w[1] = min(gg, bb); if gg > bb { w[5] = gg - bb } else { w[6] = bb - gg } }
        else if gg <= rr && gg <= bb { w[2] = min(rr, bb); if rr > bb { w[4] = rr - bb } else { w[6] = bb - rr } }
        else { w[3] = min(rr, gg); if rr > gg { w[4] = rr - gg } else { w[5] = gg - rr } }
        var spec = [Double](repeating: 0, count: NB)
        for k in 0..<7 where w[k] > 0 { let bs = wetBasisD[k]; for i in 0..<NB { spec[i] += w[k]*bs[i] } }
        for i in 0..<NB { spec[i] = max(0.004, min(1.0, spec[i])) }
        return spec
    }

    private static func ksD(_ R: Double) -> Double { let r = max(1e-4, min(1.0-1e-6, R)); return (1-r)*(1-r)/(2*r) }
    private static func rFromKSD(_ ks: Double) -> Double { max(0, min(1, 1 + ks - sqrt(ks*ks + 2*ks))) }

    /// Spectral Kubelka-Munk mix of two linear-RGB colors on the CPU (same model as the
    /// wet shader). Used to evolve the brush's carried LOAD as it picks up canvas color
    /// (Step 3 smear). Endpoint-exact: t=0 → a, t=1 → b.
    func kmMixCPU(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float) -> SIMD3<Float> {
        let td = Double(t)
        let aD = SIMD3<Double>(Double(a.x), Double(a.y), Double(a.z))
        let bD = SIMD3<Double>(Double(b.x), Double(b.y), Double(b.z))
        let sa = wetUpsample(aD), sb = wetUpsample(bD)
        var mixLin = SIMD3<Double>.zero, aRT = SIMD3<Double>.zero, bRT = SIMD3<Double>.zero
        for i in 0..<Self.wetNB {
            let A = wetMat[i]
            aRT += sa[i] * A; bRT += sb[i] * A
            let ksm = Self.ksD(sa[i]) * (1 - td) + Self.ksD(sb[i]) * td
            mixLin += Self.rFromKSD(ksm) * A
        }
        func cl(_ v: SIMD3<Double>) -> SIMD3<Double> { SIMD3(max(0,min(1,v.x)), max(0,min(1,v.y)), max(0,min(1,v.z))) }
        let m = cl(mixLin), ar = cl(aRT), br = cl(bRT)
        let out = m + (1 - td) * (aD - ar) + td * (bD - br)
        return SIMD3<Float>(Float(max(0, min(1, out.x))), Float(max(0, min(1, out.y))), Float(max(0, min(1, out.z))))
    }

    /// Sample the active layer at a canvas-pixel position as a STRAIGHT LINEAR color +
    /// alpha (1×1 getBytes on .shared storage — cheap, coherent for committed paint).
    /// Used by the wet brush to pick up the canvas color it crosses. Returns nil out of bounds.
    func sampleLayerColor(x: Int, y: Int) -> (color: SIMD3<Float>, alpha: Float)? {
        guard let tex = activeLayerTexture, x >= 0, y >= 0, x < canvasWidth, y < canvasHeight else { return nil }
        var bgra = [UInt8](repeating: 0, count: 4)
        bgra.withUnsafeMutableBytes { ptr in
            tex.getBytes(ptr.baseAddress!, bytesPerRow: 4,
                         from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        let a = Float(bgra[3]) / 255.0
        guard a > 1e-4 else { return (SIMD3<Float>(0, 0, 0), 0) }
        // BGRA, sRGB-encoded, premultiplied → straight sRGB → linear.
        func s2l(_ c: Float) -> Float { c <= 0.04045 ? c/12.92 : pow((c+0.055)/1.055, 2.4) }
        let b = Float(bgra[0]) / 255.0 / a
        let g = Float(bgra[1]) / 255.0 / a
        let r = Float(bgra[2]) / 255.0 / a
        return (SIMD3<Float>(s2l(min(r,1)), s2l(min(g,1)), s2l(min(b,1))), a)
    }

    /// Render a batch of brush stamps directly into the canvas texture (source-over).
    /// Used for stroke replay during persistence restore — each saved stroke is
    /// regenerated as stamps and committed in one pass. `strokeOpacity` is the
    /// per-stroke ceiling applied at flatten (stamp alpha carries the brush's flow).
    func commitStampsToCanvas(_ stamps: [StampInstance], strokeOpacity: Float = 1.0, shapeTexture: MTLTexture? = nil) {
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
            var canvasSize = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
            enc.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            if let shapeTexture, let shapedPSO = shapedBrushStampPSO {
                enc.setRenderPipelineState(shapedPSO)
                enc.setFragmentTexture(shapeTexture, index: 0)
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
            enc.setRenderPipelineState(compositorPSO)
            enc.setFragmentTexture(scratch, index: 0)
            var opacity: Float = strokeOpacity
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
            enc.setFragmentTexture(layers[i].texture, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Include in-progress stroke on the active layer (capped at stroke opacity).
            if i == activeLayerIndex, stampCount > 0, let scratch = scratchTexture {
                enc.setFragmentTexture(scratch, index: 0)
                var scratchOpacity: Float = strokeOpacity
                enc.setFragmentBytes(&scratchOpacity, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
            enc.setFragmentTexture(layers[i].texture, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            if i == activeLayerIndex, stampCount > 0, let scratch = scratchTexture {
                enc.setFragmentTexture(scratch, index: 0)
                var scratchOpacity: Float = strokeOpacity
                enc.setFragmentBytes(&scratchOpacity, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
        ciContext.render(ciImage, to: texture, commandBuffer: nil,
                         bounds: bounds, colorSpace: linearSRGBColorSpace)
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
            ctx.fillPath()
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
            var canvasSize = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
            enc.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            // Textured shape (Phase 3) takes priority for the brush; eraser + round brush
            // keep the procedural path.
            if !isEraser, let shapeTex = activeShapeTexture, let shapedPSO = shapedBrushStampPSO {
                enc.setRenderPipelineState(shapedPSO)
                enc.setFragmentTexture(shapeTex, index: 0)
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

            enc.setFragmentTexture(layers[i].texture, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Draw scratch (active stroke) on top of the active layer, capped at the
            // per-stroke opacity ceiling (stamp alpha carries flow).
            if i == activeLayerIndex && stampCount > 0 {
                enc.setFragmentTexture(scratch, index: 0)
                var scratchOpacity: Float = activeStrokeOpacity
                enc.setFragmentBytes(&scratchOpacity, length: MemoryLayout<Float>.size, index: 0)
                enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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

    private func clearTexture(_ texture: MTLTexture) {
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store
        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.endEncoding()
        cmdBuf.commit()
        // waitUntilCompleted is acceptable here — clearTexture runs once during
        // canvas resize, not on the per-frame hot path.
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
    /// `MetalCanvasView` resolves this when a stroke starts and assigns `activeShapeTexture`.
    func shapeTexture(for id: String?) -> MTLTexture? {
        guard let id, id != BrushShapeCatalog.roundID else { return nil }
        return shapeTextures[id]
    }

    /// Load every catalog shape that has a PNG resource into a mipmapped R8Unorm mask
    /// texture (luminance = coverage). Mipmaps avoid minification shimmer when a large
    /// (2048²) stamp is scaled down to a small brush radius.
    private static func loadShapeTextures(device: MTLDevice, queue: MTLCommandQueue) -> [String: MTLTexture] {
        var out: [String: MTLTexture] = [:]
        for descriptor in BrushShapeCatalog.all {
            guard let resourceName = descriptor.resourceName,
                  let url = Bundle.module.url(forResource: resourceName, withExtension: "png", subdirectory: "BrushShapes"),
                  let data = try? Data(contentsOf: url),
                  let cgImage = UIImage(data: data)?.cgImage,
                  let texture = makeGrayscaleMaskTexture(device: device, queue: queue, cgImage: cgImage) else {
                continue
            }
            out[descriptor.id] = texture
        }
        return out
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
    };

    struct StampVaryings {
        float4 position [[position]];
        float2 texCoord;
        float4 color;
        float  hardness;
    };

    vertex StampVaryings brushStampVertex(
        uint vertexId [[vertex_id]],
        uint instanceId [[instance_id]],
        const device QuadVertex* quads [[buffer(0)]],
        const device StampInstance* instances [[buffer(1)]],
        constant float2& canvasSize [[buffer(2)]]
    ) {
        QuadVertex q = quads[vertexId];
        StampInstance inst = instances[instanceId];

        // Rotate quad corner by pencil azimuth.
        float c = cos(inst.rotation);
        float s = sin(inst.rotation);
        float2 rotated = float2(
            q.position.x * c - q.position.y * s,
            q.position.x * s + q.position.y * c
        );

        // Scale by radius and translate to stamp center (in canvas pixels).
        float2 canvasPos = inst.center + rotated * inst.radius;

        // Canvas pixels → NDC. Metal NDC: x ∈ [-1,1] left→right, y ∈ [-1,1] bottom→top.
        // Canvas y=0 is top → NDC y=+1. So we flip.
        float2 ndc;
        ndc.x = (canvasPos.x / canvasSize.x) * 2.0 - 1.0;
        ndc.y = 1.0 - (canvasPos.y / canvasSize.y) * 2.0;

        StampVaryings out;
        out.position = float4(ndc, 0.0, 1.0);
        out.texCoord = q.texCoord;
        out.color = inst.color;
        out.hardness = inst.hardness;
        return out;
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
        StampVaryings in [[stage_in]]
    ) {
        float d = length(in.texCoord - 0.5) * 2.0;
        float aa = max(fwidth(d), 1e-4);
        float soft = 1.0 - in.hardness;
        float start = min(in.hardness, 1.0 - aa) - soft * soft * 0.85;
        float alpha = 1.0 - smoothstep(start, 1.0, d);
        return in.color * alpha;
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
        texture2d<float> shapeTex [[texture(0)]]
    ) {
        constexpr sampler shapeSampler(filter::linear, mip_filter::linear, address::clamp_to_zero);
        float m = shapeTex.sample(shapeSampler, in.texCoord).r;
        float gamma = mix(1.8, 0.55, clamp(in.hardness, 0.0, 1.0));
        float cov = pow(max(m, 0.0), gamma);
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

        // Alpha builds by COVERAGE (opaque wet paint; no translucent fringe → no white halo).
        float outA = dst.a + cov * (1.0 - dst.a);
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

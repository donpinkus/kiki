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
    private let eraserStampPSO: MTLRenderPipelineState
    private let compositorPSO: MTLRenderPipelineState
    private let flattenPSO: MTLRenderPipelineState

    /// Cached CIContext for texture→CGImage conversion. CIImage handles sRGB
    /// conversion and premultiplied alpha correctly, avoiding the color artifacts
    /// from manual getBytes + CGDataProvider construction.
    private let ciContext: CIContext

    // MARK: - Textures

    /// Per-layer persistent textures. Index 0 = bottom layer. All completed
    /// strokes on a given layer live in `layerTextures[layerIndex]`.
    private(set) var layerTextures: [MTLTexture] = []

    /// Per-layer visibility flags, parallel to `layerTextures`.
    var layerVisibility: [Bool] = []

    /// Which layer receives brush/eraser/lasso operations.
    var activeLayerIndex: Int = 0

    /// Convenience: the texture for the currently active layer.
    var activeLayerTexture: MTLTexture? {
        guard activeLayerIndex >= 0, activeLayerIndex < layerTextures.count else { return nil }
        return layerTextures[activeLayerIndex]
    }

    /// Scratch texture for the active (in-progress) stroke. Rebuilt each frame
    /// from stamp instances; conceptually memoryless between frames.
    private(set) var scratchTexture: MTLTexture?

    /// Soft-circle brush mask (single-channel, R8Unorm). Quadratic falloff:
    /// α(r) = (1 − (r/R)²)², matching the plan's 5-stop gradient.
    private let brushMaskTexture: MTLTexture

    /// Quad vertex buffer: 6 vertices for two triangles covering [-1,1]² with
    /// texcoords [0,1]². Shared by brush stamps and compositor.
    private let quadVertexBuffer: MTLBuffer

    // MARK: - Canvas State

    private(set) var canvasWidth: Int = 0
    private(set) var canvasHeight: Int = 0
    /// Ratio of canvas pixels to view points (retina scale). Set by resizeCanvas.
    private(set) var canvasScale: CGFloat = 1

    var hasCanvas: Bool { !layerTextures.isEmpty }

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
              let compPSO = Self.makeCompositorPSO(device: device, library: lib),
              let flatPSO = Self.makeFlattenPSO(device: device, library: lib) else {
            return nil
        }
        self.brushStampPSO = brushPSO
        self.eraserStampPSO = erasePSO
        self.compositorPSO = compPSO
        self.flattenPSO = flatPSO
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

    /// (Re)allocate layer textures and scratch texture to match the given pixel size.
    /// On first call, creates a single layer (index 0). On resize, existing layers
    /// are discarded (caller should save/restore if needed).
    func resizeCanvas(width: Int, height: Int, viewScale: CGFloat = 0) {
        guard width > 0, height > 0 else { return }
        guard width != canvasWidth || height != canvasHeight else { return }

        canvasWidth = width
        canvasHeight = height
        if viewScale > 0 { canvasScale = viewScale }

        let desc = makeLayerDescriptor()

        // Create initial single layer if none exist, otherwise recreate all layers.
        if layerTextures.isEmpty {
            guard let layer0 = device.makeTexture(descriptor: desc) else { return }
            clearTexture(layer0)
            layerTextures = [layer0]
            layerVisibility = [true]
            activeLayerIndex = 0
        } else {
            var newTextures: [MTLTexture] = []
            for _ in 0..<layerTextures.count {
                guard let tex = device.makeTexture(descriptor: desc) else { return }
                clearTexture(tex)
                newTextures.append(tex)
            }
            layerTextures = newTextures
        }

        scratchTexture = device.makeTexture(descriptor: desc)
    }

    // MARK: - Layer Management

    /// Add a new empty layer on top. Returns the index of the new layer.
    @discardableResult
    func addLayer() -> Int {
        guard layerTextures.count < Self.maxLayerCount else { return activeLayerIndex }
        let desc = makeLayerDescriptor()
        guard let texture = device.makeTexture(descriptor: desc) else { return activeLayerIndex }
        clearTexture(texture)
        layerTextures.append(texture)
        layerVisibility.append(true)
        return layerTextures.count - 1
    }

    /// Remove a layer. Must keep at least 1 layer.
    func removeLayer(at index: Int) {
        guard layerTextures.count > 1, index >= 0, index < layerTextures.count else { return }
        layerTextures.remove(at: index)
        layerVisibility.remove(at: index)
        if activeLayerIndex >= layerTextures.count {
            activeLayerIndex = layerTextures.count - 1
        } else if activeLayerIndex > index {
            activeLayerIndex -= 1
        }
    }

    /// Set the active layer index.
    func setActiveLayer(_ index: Int) {
        guard index >= 0, index < layerTextures.count else { return }
        activeLayerIndex = index
    }

    /// Reorder a layer from one position to another.
    func moveLayer(from source: Int, to destination: Int) {
        guard source >= 0, source < layerTextures.count,
              destination >= 0, destination < layerTextures.count,
              source != destination else { return }
        let tex = layerTextures.remove(at: source)
        let vis = layerVisibility.remove(at: source)
        layerTextures.insert(tex, at: destination)
        layerVisibility.insert(vis, at: destination)

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
        guard let layer0 = device.makeTexture(descriptor: desc) else { return }
        clearTexture(layer0)
        layerTextures = [layer0]
        layerVisibility = [true]
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
        guard !layerTextures.isEmpty, let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Clear scratch + render stamps into it.
        renderStampsIntoScratch(commandBuffer: cmdBuf, scratch: scratch, isEraser: isErasing)

        // Pass 2: Composite all visible layers + scratch into the drawable.
        compositeToDrawable(commandBuffer: cmdBuf, drawable: drawable, scratch: scratch)

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Flatten the scratch texture into the active layer (stroke completion).
    /// Uses source-over for brush, or a custom "erase" pass for eraser.
    func flattenScratchIntoCanvas(isEraser: Bool) {
        guard let canvas = activeLayerTexture, let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = canvas
        rpd.colorAttachments[0].loadAction = .load
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        if isEraser {
            // Eraser: destination-out blend (clear pixels under the stamp mask).
            enc.setRenderPipelineState(flattenPSO)
        } else {
            // Brush: source-over blend.
            enc.setRenderPipelineState(compositorPSO)
        }

        enc.setFragmentTexture(scratch, index: 0)
        var opacity: Float = 1.0
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

    /// Render a batch of brush stamps directly into the canvas texture (source-over).
    /// Used for stroke replay during persistence restore — each saved stroke is
    /// regenerated as stamps and committed in one pass.
    func commitStampsToCanvas(_ stamps: [StampInstance]) {
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
            enc.setRenderPipelineState(brushStampPSO)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(stampBuf, offset: 0, index: 1)
            var canvasSize = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
            enc.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            enc.setFragmentTexture(brushMaskTexture, index: 0)
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
            var opacity: Float = 1.0
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
        guard index >= 0, index < layerTextures.count else { return nil }
        let texture = layerTextures[index]
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
        guard index >= 0, index < layerTextures.count,
              data.count == canvasWidth * canvasHeight * 4 else { return }
        let texture = layerTextures[index]
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
        guard index >= 0, index < layerTextures.count else { return nil }
        return textureToCGImage(layerTextures[index])
    }

    /// Read the flattened (all visible layers composited) canvas into a CGImage
    /// for stream capture, thumbnails, and single-image export.
    func flattenedCGImage() -> CGImage? {
        guard !layerTextures.isEmpty else { return nil }

        // Render all visible layers into a temporary texture.
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

        for i in 0..<layerTextures.count {
            guard layerVisibility[i] else { continue }
            enc.setFragmentTexture(layerTextures[i], index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        enc.endEncoding()

        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()  // OK — runs once per capture, not per frame

        return textureToCGImage(tempTexture)
    }

    /// Convenience: flattened CGImage (used by existing callers that expected canvasToCGImage).
    func canvasToCGImage() -> CGImage? {
        flattenedCGImage()
    }

    /// Convert any Metal texture to CGImage via CIImage (correct sRGB + premultiplied alpha).
    private func textureToCGImage(_ texture: MTLTexture) -> CGImage? {
        guard var ciImage = CIImage(mtlTexture: texture, options: [
            .colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        ]) else { return nil }
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ciImage.extent.height))
        return ciContext.createCGImage(ciImage, from: ciImage.extent,
                                       format: .BGRA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Load a CGImage into a specific layer texture.
    func loadImageIntoLayer(at index: Int, _ image: CGImage) {
        guard index >= 0, index < layerTextures.count else { return }
        let texture = layerTextures[index]
        var ciImage = CIImage(cgImage: image)
        ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1)
            .translatedBy(x: 0, y: -ciImage.extent.height))
        let bounds = CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
        ciContext.render(ciImage, to: texture, commandBuffer: nil,
                         bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
    }

    /// Load a CGImage into the active layer (convenience wrapper).
    func loadImageIntoCanvas(_ image: CGImage) {
        loadImageIntoLayer(at: activeLayerIndex, image)
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
            enc.setRenderPipelineState(isEraser ? eraserStampPSO : brushStampPSO)
            enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)
            enc.setVertexBuffer(stampBuffer, offset: 0, index: 1)
            var canvasSize = SIMD2<Float>(Float(canvasWidth), Float(canvasHeight))
            enc.setVertexBytes(&canvasSize, length: MemoryLayout<SIMD2<Float>>.size, index: 2)
            enc.setFragmentTexture(brushMaskTexture, index: 0)
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
        for i in 0..<layerTextures.count {
            guard layerVisibility[i] else { continue }

            enc.setFragmentTexture(layerTextures[i], index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

            // Draw scratch (active stroke) on top of the active layer.
            if i == activeLayerIndex && stampCount > 0 {
                enc.setFragmentTexture(scratch, index: 0)
                enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
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
        desc.fragmentFunction = library.makeFunction(name: "brushStampFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        let ca = desc.colorAttachments[0]!
        ca.isBlendingEnabled = true
        ca.rgbBlendOperation = .add
        ca.alphaBlendOperation = .add

        if eraser {
            // Destination-out: dst = dst * (1 - src.alpha). Erases canvas under the stamp.
            ca.sourceRGBBlendFactor = .zero
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .zero
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        } else {
            // Source-over (premultiplied): dst = src + dst * (1 - src.alpha).
            ca.sourceRGBBlendFactor = .one
            ca.destinationRGBBlendFactor = .oneMinusSourceAlpha
            ca.sourceAlphaBlendFactor = .one
            ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

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

    private static func makeFlattenPSO(device: MTLDevice, library: MTLLibrary) -> MTLRenderPipelineState? {
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "compositorVertex")
        desc.fragmentFunction = library.makeFunction(name: "compositorFragment")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb

        // Destination-out blend for eraser flattening.
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
    };

    struct StampVaryings {
        float4 position [[position]];
        float2 texCoord;
        float4 color;
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
        return out;
    }

    fragment float4 brushStampFragment(
        StampVaryings in [[stage_in]],
        texture2d<float> brushMask [[texture(0)]]
    ) {
        constexpr sampler maskSampler(filter::linear, address::clamp_to_zero);
        float mask = brushMask.sample(maskSampler, in.texCoord).r;
        return in.color * mask;
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

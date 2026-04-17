import UIKit
import Metal
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

    // MARK: - Textures

    /// The persistent canvas layer. All completed strokes live here.
    private(set) var canvasTexture: MTLTexture?

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

    var hasCanvas: Bool { canvasTexture != nil }

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

    /// (Re)allocate canvas and scratch textures to match the given pixel size.
    func resizeCanvas(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard width != canvasWidth || height != canvasHeight else { return }

        canvasWidth = width
        canvasHeight = height

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm_srgb,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
        desc.storageMode = .shared

        canvasTexture = device.makeTexture(descriptor: desc)
        scratchTexture = device.makeTexture(descriptor: desc)

        // Clear canvas to transparent.
        if let canvas = canvasTexture {
            clearTexture(canvas)
        }
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
    /// canvas + scratch into the given drawable texture.
    func renderFrame(drawable: CAMetalDrawable, isErasing: Bool) {
        guard let canvas = canvasTexture, let scratch = scratchTexture else { return }
        guard let cmdBuf = commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Clear scratch + render stamps into it.
        renderStampsIntoScratch(commandBuffer: cmdBuf, scratch: scratch, isEraser: isErasing)

        // Pass 2: Composite canvas + scratch into the drawable.
        compositeToDrawable(commandBuffer: cmdBuf, drawable: drawable, canvas: canvas, scratch: scratch)

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    /// Flatten the scratch texture into the canvas (stroke completion).
    /// Uses source-over for brush, or a custom "erase" pass for eraser.
    func flattenScratchIntoCanvas(isEraser: Bool) {
        guard let canvas = canvasTexture, let scratch = scratchTexture else { return }
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
        guard let canvas = canvasTexture, !stamps.isEmpty else { return }

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
        guard let canvas = canvasTexture, !stamps.isEmpty else { return }
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

    /// Snapshot the canvas texture into CPU-side Data for undo.
    func snapshotCanvas() -> Data? {
        guard let texture = canvasTexture else { return nil }
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

    /// Restore canvas texture from a CPU-side undo snapshot.
    func restoreCanvas(from data: Data) {
        guard let texture = canvasTexture, data.count == canvasWidth * canvasHeight * 4 else { return }
        let bytesPerRow = canvasWidth * 4
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, canvasWidth, canvasHeight),
                            mipmapLevel: 0, withBytes: base, bytesPerRow: bytesPerRow)
        }
    }

    /// Read the canvas texture into a CGImage for persistence / stream capture.
    func canvasToCGImage() -> CGImage? {
        guard let data = snapshotCanvas() else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        )
        return data.withUnsafeBytes { ptr -> CGImage? in
            guard let base = ptr.baseAddress else { return nil }
            guard let provider = CGDataProvider(dataInfo: nil, data: base, size: data.count,
                                                releaseData: { _, _, _ in }) else { return nil }
            return CGImage(width: canvasWidth, height: canvasHeight,
                           bitsPerComponent: 8, bitsPerPixel: 32,
                           bytesPerRow: canvasWidth * 4,
                           space: colorSpace, bitmapInfo: bitmapInfo,
                           provider: provider, decode: nil,
                           shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    /// Load a CGImage into the canvas texture (for restoring saved drawings or
    /// baking images).
    func loadImageIntoCanvas(_ image: CGImage) {
        guard canvasTexture != nil else { return }
        let w = canvasWidth
        let h = canvasHeight
        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: colorSpace,
                                  bitmapInfo: bitmapInfo) else { return }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let pixels = ctx.data else { return }
        canvasTexture!.replace(region: MTLRegionMake2D(0, 0, w, h),
                               mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
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
                                     canvas: MTLTexture, scratch: MTLTexture) {
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rpd.colorAttachments[0].storeAction = .store

        guard let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        enc.setRenderPipelineState(compositorPSO)
        enc.setVertexBuffer(quadVertexBuffer, offset: 0, index: 0)

        // Draw canvas layer.
        var opacity: Float = 1.0
        enc.setFragmentTexture(canvas, index: 0)
        enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // Draw scratch (active stroke) on top.
        if stampCount > 0 {
            enc.setFragmentTexture(scratch, index: 0)
            enc.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
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
    """
}

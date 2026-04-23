# CanvasModule — Metal Drawing Engine

## Critical Rules (NEVER violate)

### sRGB Premultiplied Alpha — The Bidirectional CIImage Rule

The canvas uses `.bgra8Unorm_srgb` Metal textures. The `_srgb` suffix means Metal's blend pipeline works in **linear** space: it decodes sRGB→linear on read, blends, then encodes linear→sRGB on write. The stored premultiplied values are `sRGB_encode(linear_R × alpha)`.

**CGContext premultiplies in sRGB space** (`sRGB_R × alpha`), which is mathematically different. Any CGImage↔Metal round-trip through CGContext darkens semi-transparent pixels because `sRGB(R_linear × α) ≠ sRGB(R_linear) × α`. The darkening is **cumulative** — each round-trip makes it worse.

**ALWAYS use CIImage + CIContext for BOTH directions:**

| Direction | Correct | WRONG (causes darkening) |
|---|---|---|
| Metal→CGImage | `CIImage(mtlTexture:)` → `CIContext.createCGImage()` | `texture.getBytes()` → `CGDataProvider` → `CGImage(...)` |
| CGImage→Metal | `CIImage(cgImage:)` → `CIContext.render(_:to:commandBuffer:bounds:colorSpace:)` | `CGContext.draw(image)` → `texture.replace(region:withBytes:)` |

CIContext is cached on `CanvasRenderer` (created once at init, backed by the same MTLDevice). Both CIImage paths handle sRGB↔linear conversion and premultiplied alpha correctly.

**Y-flip:** CIImage uses bottom-left origin; Metal textures use top-left. Apply `CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -extent.height)` when converting in either direction.

### Color Space — Always Explicit sRGB

**NEVER use `CGColorSpaceCreateDeviceRGB()`** — on modern iPads it returns Display P3 (wider gamut). The canvas texture is `.bgra8Unorm_srgb` (sRGB). If CIContext/CGImage operations use P3 while the data is sRGB, colors appear more saturated in UIKit views (UIImageView, UIGraphicsImageRenderer) vs the Metal canvas (which correctly presents as sRGB via CAMetalLayer).

**ALWAYS use `CGColorSpace(name: CGColorSpace.sRGB)!`** for:
- `CIContext` working color space
- `CIImage(mtlTexture:, options: [.colorSpace: ...])` 
- `CIContext.createCGImage(..., colorSpace: ...)`
- `CIContext.render(..., colorSpace: ...)`

### UIGraphicsImageRenderer — Always Force sRGB

`UIGraphicsImageRenderer(size:)` defaults to the display's color space — **Display P3** on modern iPads. Any image produced by a default renderer will be P3-tagged, causing a saturation mismatch when displayed alongside the sRGB Metal canvas (via CAMetalLayer).

**ALWAYS create renderers with explicit sRGB format:**
```swift
let format = UIGraphicsImageRendererFormat()
format.preferredRange = .standard  // sRGB
let renderer = UIGraphicsImageRenderer(size: size, format: format)
```

This applies to: lasso extraction, lasso clear, selection composite, thumbnail generation, and any future CG-based image operations on canvas content.

### Performance — Main Thread Budget

Target: <8ms per frame at 120 Hz. Three rules:

1. **NEVER `drawHierarchy(afterScreenUpdates: true)`** on MetalCanvasView. Forces synchronous GPU pipeline drain (10-50ms). Use `texture.getBytes()` on `.shared` textures or CIImage for CPU reads.

2. **NEVER `waitUntilCompleted()`** on per-frame or per-touch command buffers. Blocks main thread. Commit async; rely on Metal same-queue ordering. Only acceptable at stroke-end (`flattenScratchIntoCanvas`) or canvas-resize (`clearTexture`).

3. **Use `.shared` storage** for canvas textures on Apple Silicon. Unified memory = CPU and GPU share physical memory. `getBytes()`/`replace()` are coherent with no staging buffers. `.private` causes assertion failures on CPU access.

### Pixel Format

Always `.bgra8Unorm_srgb` for canvas textures. iOS's native compositor format is BGRA little-endian. Using RGBA or big-endian forces a CPU byte-swap on every composite → <1 fps.

For CGBitmapContext (undo snapshots only — raw bytes, no color interpretation): `premultipliedFirst | byteOrder32Little` = BGRA in memory. This matches the texture's raw byte layout, so `snapshotCanvas()`/`restoreCanvas()` are lossless round-trips (no CIImage needed for raw byte undo).

### CGContext → Metal Texture Y-Flip

CGBitmapContext has **bottom-left** origin. Metal textures have **top-left** origin (row 0 = top). When rasterizing a CGPath into a mask texture via CGContext, always flip Y:
```swift
ctx.translateBy(x: 0, y: CGFloat(textureHeight))
ctx.scaleBy(x: scale, y: -scale)
```
Without this flip, the mask is upside-down and operations (lasso, clip) hit the wrong region.

### R8Unorm Textures — Alpha Is Always 1

Metal's R8Unorm format returns `(R, 0, 0, 1.0)` when sampled — `.a` is always 1 regardless of the R value. If you use an R8 texture as a mask with a destination-out blend (`dst *= 1 - src.alpha`), it clears the **entire** target because alpha is always 1.

**Fix:** Write a dedicated fragment shader that outputs the R channel as alpha: `return float4(0, 0, 0, mask.sample(uv).r)`. See `maskedClearFragment` in `CanvasRenderer.swift`.

## Architecture

```
MetalCanvasView (UIView, CAMetalLayer)
├── CanvasRenderer (Metal state: device, pipelines, textures, shaders)
│   ├── layers: [Layer] — unified array (texture + name + visibility per layer)
│   ├── scratchTexture — active stroke preview (cleared each frame)
│   ├── selectionTexture — floating lasso selection (Metal-rendered, no UIImageView)
│   ├── brushMaskTexture (R8Unorm, 64×64 soft circle)
│   ├── brushStampPSO — instanced quads, source-over blend
│   ├── eraserStampPSO — instanced quads, programmable blend (dst *= 1-mask, snap near-clear to zero)
│   ├── compositorPSO — fullscreen quad, source-over (layer compositing + selection display)
│   ├── maskedCopyPSO — fullscreen quad, no blend (lasso extraction: canvas × mask → selection)
│   └── maskedClearPSO — fullscreen quad, destination-out (lasso clear: uses maskedClearFragment)
├── Stamp generation (CPU: arc-length resample, adaptive spacing)
├── Touch handling (coalesced touches, per-tool dispatch)
├── Undo (per-layer raw byte snapshots via getBytes/replace, depth 30)
└── Lasso (CAShapeLayer preview, Metal extraction/display/commit, CPU clip mask)
```

### Layer state — single source of truth

`CanvasRenderer` owns the authoritative layer state via `layers: [Layer]`. Each `Layer` struct holds the `MTLTexture`, `name`, `isVisible`, and `id`. MetalCanvasView reads from the renderer via computed properties. CanvasViewModel caches copies for SwiftUI `@Observable` reactivity, synced via the `onStateChanged` callback.

### Multi-layer compositing
1. Compositor iterates `layers` bottom-to-top (index 0 = bottom)
2. Skips layers where `isVisible == false`
3. Draws scratch texture (active stroke) interleaved at the active layer's z-position
4. Draws floating selection (lasso) on top of all layers

### Brush rendering flow
1. Touch points → `StrokePoint` array (pressure, altitude, position)
2. Arc-length resample with **adaptive spacing** (`max(effectiveWidth × 0.3, 0.5)`)
3. Per-stamp: `StampInstance` (center, radius, rotation, premultiplied color)
4. All stamps → shared `MTLBuffer` → single instanced draw call into scratch texture
5. On touchesEnded: flatten scratch into active layer (source-over)

### Eraser flow (different from brush)
- Stamps applied **directly to active layer texture** per touchesMoved (not via scratch)
- Uses temporary `MTLBuffer` per batch — no shared-buffer races
- Commits **without** `waitUntilCompleted` — async, same-queue ordering
- Undo snapshot pushed at touchesBegan (before any erasing), popped on cancel

### Persistence
- Canvas saved as **layered JSON envelope** with per-layer PNGs
- Backward compatible: old single-PNG format auto-detected and loaded as layer 0
- Legacy stroke JSON replayed as final fallback

### Lasso flow (entirely Metal — no CG color pipeline)
- Path preview: two `CAShapeLayer`s (white + black offset dashes)
- Extraction: rasterize CGPath → R8 mask texture, then Metal maskedCopy + maskedClear passes
- Clip mask: `setClipPath()` persists the path across tool switches. Stamps outside the path are discarded (CPU-side via `CGPath.contains()`)
- Commit: Metal render pass composites selection texture onto active layer (source-over)
- Cancel: discard selection texture + undo to pre-lasso snapshot

## Files

| File | Role |
|------|------|
| `MetalCanvasView.swift` | UIView, touch handling, CADisplayLink render loop, stamp generation, undo, lasso |
| `CanvasRenderer.swift` | Metal device/queue/pipelines, Layer struct, texture management, render passes, CIContext, shaders (embedded MSL) |
| `CanvasViewModel.swift` | @Observable bridge between AppCoordinator and MetalCanvasView, snapshot/thumbnail compositing |
| `CanvasView.swift` | UIViewRepresentable wrapper, callback wiring |
| `RotatableCanvasContainer.swift` | Gesture handling (zoom/rotate/pan), cursor overlay, background image, lasso selection view |
| `LassoSelectionView.swift` | Gesture-only view for lasso transform (pan/pinch/rotate), marching ants |
| `DrawingEngine.swift` | Stroke/StrokePoint/BrushConfig/ToolState/LayerInfo/LayeredDrawing types |

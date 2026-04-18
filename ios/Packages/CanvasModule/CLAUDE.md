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
│   ├── canvasTexture (.bgra8Unorm_srgb, .shared) — persistent drawing surface
│   ├── scratchTexture — active stroke preview (cleared each frame)
│   ├── selectionTexture — floating lasso selection (Metal-rendered, no UIImageView)
│   ├── brushMaskTexture (R8Unorm, 64×64 soft circle)
│   ├── brushStampPSO — instanced quads, source-over blend
│   ├── eraserStampPSO — instanced quads, destination-out blend
│   ├── compositorPSO — fullscreen quad, source-over (layer compositing + selection display)
│   ├── flattenPSO — fullscreen quad, destination-out (eraser flatten)
│   ├── maskedCopyPSO — fullscreen quad, no blend (lasso extraction: canvas × mask → selection)
│   └── maskedClearPSO — fullscreen quad, destination-out (lasso clear: uses maskedClearFragment)
├── Stamp generation (CPU: arc-length resample, adaptive spacing)
├── Touch handling (coalesced touches, per-tool dispatch)
├── Undo (raw byte snapshots via getBytes/replace, depth 30)
└── Lasso (CAShapeLayer preview, Metal extraction/display/commit)
```

### Brush rendering flow
1. Touch points → `StrokePoint` array (pressure, altitude, position)
2. Arc-length resample with **adaptive spacing** (`max(effectiveWidth × 0.3, 0.5)`) — tighter at low pressure so light strokes don't scatter into dots
3. Per-stamp: `StampInstance` (center, radius, rotation, premultiplied color)
4. All stamps → shared `MTLBuffer` → single instanced draw call into scratch texture
5. Compositor pass: canvas + scratch → drawable
6. On touchesEnded: flatten scratch into canvas (source-over for brush, destination-out for eraser)

### Eraser flow (different from brush)
- Stamps applied **directly to canvas texture** per touchesMoved (not via scratch)
- Uses temporary `MTLBuffer` per batch (`device.makeBuffer(bytes:)`) — no shared-buffer races
- Commits **without** `waitUntilCompleted` — async, same-queue ordering
- Undo snapshot pushed at touchesBegan (before any erasing), popped on cancel

### Persistence
- Canvas saved as **PNG bitmap** (via `canvasToCGImage()` → `pngData()`), not stroke JSON
- Restored via `loadDrawingData()` → `loadImageIntoCanvas()` (CIContext.render path)
- Legacy stroke JSON is auto-detected and replayed as fallback
- Stroke data kept in memory for potential future use (time-lapse, editing)

### Lasso flow (entirely Metal — no CG color pipeline)
- Path preview: two `CAShapeLayer`s (white + black offset dashes) — Core Animation, off Metal hot path
- Extraction: rasterize CGPath → R8 mask texture (CGContext, grayscale only — Y-flipped!), then two Metal render passes:
  - **maskedCopy**: canvas × mask → selection texture (crop region only)
  - **maskedClear**: clear canvas inside mask (maskedClearFragment outputs mask.r as alpha for destination-out)
- Display: Metal compositor draws selection texture as a transformed quad each frame (vertex positions computed from gesture state on CPU). LassoSelectionView is gesture-only (no UIImageView) with marching ants (CAShapeLayer).
- Commit: Metal render pass composites selection texture onto canvas at current transform (source-over)
- Cancel: discard selection texture + undo to pre-lasso snapshot

## Files

| File | Role |
|------|------|
| `MetalCanvasView.swift` | UIView, touch handling, CADisplayLink render loop, stamp generation, undo, lasso |
| `CanvasRenderer.swift` | Metal device/queue/pipelines, texture management, render passes, CIContext, shaders (embedded MSL) |
| `CanvasViewModel.swift` | Public API bridge between AppCoordinator and MetalCanvasView |
| `RotatableCanvasContainer.swift` | Gesture handling (zoom/rotate/pan), cursor overlay, background image, lasso selection view |
| `DrawingCanvasView.swift` | **LEGACY** — old CGBitmapContext engine, kept for reference. Not used at runtime. |
| `DrawingEngine.swift` | Stroke/StrokePoint/BrushConfig/ToolState types (shared by old and new engines) |
| `StrokeSmoother.swift` | CPU stroke smoothing (Catmull-Rom + EMA) |
| `StrokeTessellator.swift` | CPU tessellation for variable-width stroke contours |

# Metal Canvas Rewrite — Full Architecture Plan

## Context

Kiki's drawing canvas is backed by `CGBitmapContext` + `UIView.draw(rect:)`. Every frame, the full retina-resolution canvas (~20–30 MB) must be re-read from CPU RAM into the view's backing store. This is fundamentally too slow for interactive painting tools — smudge hit <1 fps, and even brush/eraser pay an unnecessary per-frame tax.

WebGL liquid simulations feel instant because data lives on the GPU and never crosses to the CPU. The fix is the same: move the canvas into an `MTLTexture`, do all painting in Metal shaders, and display via `CAMetalLayer` — zero CPU↔GPU pixel traffic per frame.

This plan replaces the entire `DrawingCanvasView` engine with a Metal-backed architecture. It includes multi-layer support (user's requirement), predicted touches for low latency, and a clean foundation for smudge to be added later as a fragment-shader pass. Smudge is reverted in this rewrite (the UI button is removed); brush, eraser, and lasso ship first on the Metal engine.

## Architecture Overview

```
┌─ RotatableCanvasContainer (UIView, unchanged) ─────────────────────┐
│  ┌─ transformView ───────────────────────────────────────────────┐  │
│  │  backgroundImageView (UIImageView, white/lineart, unchanged) │  │
│  │  MetalCanvasView (new — CAMetalLayer + CADisplayLink)        │  │
│  │  cursorView (CursorOverlayView, unchanged)                   │  │
│  │  lassoSelectionView (LassoSelectionView, unchanged)          │  │
│  └──────────────────────────────────────────────────────────────┘  │
│  ringView (ColorPickerRingView, screen-space, unchanged)          │
└───────────────────────────────────────────────────────────────────┘
```

**MetalCanvasView** replaces `DrawingCanvasView`. Everything around it (gestures, cursor, lasso floating selection, eyedropper ring, background image) is UIView-based and stays unchanged.

### Display pipeline

- `CAMetalLayer` backing the view, `.bgra8Unorm_srgb` pixel format, `maximumDrawableCount = 2` (double buffering for minimum latency).
- `CADisplayLink` at 120 Hz (ProMotion). Only encodes a render pass when dirty (touch event, animation, or layer change). When idle, no GPU work.
- Each frame renders a single compositing pass: background color → layer stack bottom-to-top → active-stroke overlay → present drawable.

### Canvas textures

Each drawing layer is one `MTLTexture` at view-bounds × retina-scale resolution (~2700×2100, `.bgra8Unorm_srgb`). At ~20 MB per layer, a 10-layer drawing uses ~200 MB GPU memory — well within iPad budgets.

Active stroke is rendered into a separate scratch texture, composited live onto the active layer during display. On stroke completion, the scratch texture is flattened into the active layer via a blit.

**TBDR-aware render pass config** (from Apple TBDR guidance, validated by external deep-research report):
- Scratch texture: `storageMode = .memoryless` if available (A11+), `loadAction = .clear`, `storeAction = .dontCare` after compositing into the frame. This keeps the scratch in on-chip tile memory only — zero system memory bandwidth for it.
- Canvas layer textures: `loadAction = .load` (preserve existing content), `storeAction = .store` (persist brush/erase writes).
- PSO precompilation: build `MTLRenderPipelineState` objects for brush, eraser, and compositor blend modes at `MetalCanvasView` init time. Avoids first-stroke shader compilation hitch.

### Brush rendering — instanced stamp quads

Each stroke is arc-length resampled into stamp positions (spacing = `radius × 0.15`, tunable). Each stamp is a small textured quad rendered via an instanced draw call into the scratch texture.

Per-stamp instance data (passed as a structured buffer):
```
struct StampInstance {
    float2 position;    // canvas pixel coords
    float  radius;      // pressure-modulated
    float  rotation;    // from pencil azimuth
    float4 color;       // premultiplied, opacity pre-applied
};
```

Fragment shader samples a single-channel brush-mask texture (soft circle for solid brushes, more complex textures later), multiplies by the instance color, and outputs premultiplied RGBA. Blend state on the pipeline: standard source-over (`.sourceAlpha, .oneMinusSourceAlpha`).

Pressure, tilt, velocity are resolved CPU-side per stamp (same as current `StrokeTessellator` math) and baked into the instance attributes. The shader is simple — just texture sample × color.

### Eraser

Same stamp-based rendering, but the scratch texture is composited into the active layer with a "destination-out" blend (erases pixels under the stamp).

### Lasso

The existing lasso flow (Phase A floating selection / Phase B clip mask) stays. `LassoSelectionView` is a separate UIView. What changes:

- **Extract selection:** read pixels from the active layer's MTLTexture → CGImage → UIImage for the floating selection. Use `texture.getBytes()`.
- **Commit selection:** composite the UIImage back into the active layer's MTLTexture via `texture.replace(region:...)`.
- **Clip mask:** stencil buffer on the Metal render pipeline, or rasterize the lasso path into a mask texture and apply in the fragment shader when rendering stamps.

### Zoom / rotation

Unchanged. UIView transform on `transformView` in `RotatableCanvasContainer`. Metal rendering is at full resolution; zoom is a view-layer scaling. Touch coordinates are converted to canvas-local via `touch.location(in: canvasView)` as today.

### Predicted touches — preview / committed stroke split

Pen-to-photon latency target: <12 ms. The key technique (confirmed by both Apple docs and Procreate's behavior):

```swift
// In touchesMoved:
let coalesced = event?.coalescedTouches(for: touch) ?? [touch]   // real high-fidelity samples
let predicted = event?.predictedTouches(for: touch) ?? []         // speculative ~16ms-ahead estimates
```

Two-buffer approach:
- **Committed path**: coalesced touches → stamp instances → rendered into the **canvas layer texture** (persistent, undo-tracked). This may lag by 1–2 frames.
- **Preview path**: committed + predicted touches → stamp instances → rendered into the **scratch texture** (memoryless, ephemeral). This is what the user sees under the pencil tip.

Each frame: clear the scratch texture, re-render the entire active stroke (committed + predicted) into it, composite onto the canvas. When the next touchesMoved arrives, the scratch is rebuilt with the latest data — the predicted portion is overwritten by the new real+predicted points.

This separation costs almost nothing (scratch is memoryless, instanced draw is fast) and cuts perceived latency by 8–16 ms.

### Color management

`.bgra8Unorm_srgb` storage with manual linear-space blending in the fragment shader:
```metal
// In brush stamp fragment shader:
float4 canvasColor = canvasTexture.sample(sampler, uv);
float3 linearCanvas = pow(canvasColor.rgb, 2.2);
float3 linearBrush = pow(brushColor.rgb, 2.2);
float3 blended = mix(linearCanvas, linearBrush, alpha);
return float4(pow(blended, 1.0/2.2), resultAlpha);
```

This avoids the "muddy midtones" artifact of gamma-space blending (Procreate and Photoshop iPad both blend in linear space).

## Multi-Layer Architecture

### Layer model

```swift
public struct DrawingLayer: Identifiable {
    public let id: UUID
    public var name: String
    public var isVisible: Bool = true
    public var opacity: Float = 1.0
    public var blendMode: LayerBlendMode = .normal
    // The MTLTexture is managed by the renderer, keyed by layer.id
}

public enum LayerBlendMode: String, Codable, CaseIterable {
    case normal, multiply, screen, overlay
}
```

### Compositor

Single render pass per frame. For each visible layer (bottom to top):
1. Render a full-screen quad sampling the layer's texture.
2. Fragment shader applies the layer's blend mode and opacity.
3. Pipeline blend state set per-layer (normal = source-over, multiply/screen/overlay = custom shader math).

Active layer's display also includes the scratch texture composited on top (live stroke preview).

### Layer UI (not in scope for this plan — addressed separately)

Layer panel (add, delete, reorder, rename, toggle visibility, adjust opacity, change blend mode) is a SwiftUI overlay. It interacts with `AppCoordinator` which talks to `CanvasViewModel`. The Metal engine exposes layer operations; the UI is a separate workstream.

## Undo / Redo

Full-texture snapshot per undoable action, stored as CPU-side `Data` (pixel bytes from `texture.getBytes()`). Depth capped at 30.

```swift
struct UndoSnapshot {
    let layerID: UUID
    let pixelData: Data        // width × height × 4 bytes, BGRA
    let width: Int
    let height: Int
}
```

On undo: `texture.replace(region:..., withBytes: snapshot.pixelData)`. On redo: same with the post-action snapshot.

Memory budget: ~20 MB per snapshot × 30 depth = ~600 MB. Acceptable on 8+ GB iPads. Revisit with compression or stroke-replay if this proves tight.

Actions that produce snapshots: stroke completion, erase, lasso commit, clear, lineart swap, layer merge. During a stroke, no snapshots are taken (the stroke-in-progress is speculative).

## Stream Capture

Current: `captureSnapshot()` calls `canvasView.drawHierarchy(in:afterScreenUpdates:)` at ~2 fps, encodes JPEG at 768×768.

New: read the compositor's output (or a dedicated downscaled render target) into CPU bytes via `texture.getBytes()` on a completed command buffer. Encode JPEG on a background queue. No `drawHierarchy` needed — the Metal pipeline already has the composited result.

```swift
func captureForStream() -> UIImage? {
    guard let texture = renderer.compositedTexture else { return nil }
    var bytes = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(&bytes, bytesPerRow: texture.width * 4,
                     from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                     mipmapLevel: 0)
    // Build CGImage from bytes, scale to 768×768, encode JPEG
    ...
}
```

This runs at ~2–5 ms on M-series (bandwidth-limited, not compute-limited).

## Persistence

### Stroke data (unchanged)

`Stroke`, `StrokePoint`, `BrushConfig` remain Codable JSON. Strokes are stored per-drawing in SwiftData (`Drawing.drawingData`). The Metal engine replays strokes on load by re-rendering them into the canvas texture via the stamp pipeline.

### Layer data (new)

Each layer's pixel content is saved as compressed PNG data in SwiftData. Layer metadata (name, blend mode, opacity, order) is stored as a Codable struct alongside drawing data.

### Background image (unchanged)

Stored as PNG in `Drawing.backgroundImageData`. Loaded as a UIImage into the existing `backgroundImageView`.

### Thumbnail

Rendered from the compositor's output, downscaled to 256×256. Same `generateThumbnail` API, different internal path (Metal readback instead of `drawHierarchy`).

## File Plan

### New files (in `ios/Packages/CanvasModule/Sources/CanvasModule/`)

| File | Responsibility |
|------|----------------|
| `MetalCanvasView.swift` | UIView subclass. Owns `CAMetalLayer`, `CADisplayLink`, touch handling (dispatches to tools), dirty-flag management. Replaces `DrawingCanvasView`. |
| `CanvasRenderer.swift` | Metal pipeline setup (`MTLDevice`, `MTLCommandQueue`, `MTLRenderPipelineState` for brush, eraser, compositor). Encodes render passes. Manages textures (per-layer, scratch, composite output). |
| `BrushStampPipeline.swift` | Stamp instance buffer management. Arc-length resampling. Instanced draw call encoding. Pressure/tilt → instance attribute conversion. |
| `LayerStack.swift` | Layer model (`DrawingLayer`), ordering, active-layer tracking, add/remove/merge operations. |
| `CanvasUndoManager.swift` | Snapshot storage (`[UndoSnapshot]`), push/pop, redo stack. Replaces the generic `UndoStack<CanvasAction>` for the Metal engine. |
| `Shaders.metal` | MSL shaders: brush-stamp fragment, layer-composite fragment (with blend modes), eraser fragment. Future: smudge compute/fragment shader. |
| `BrushMaskGenerator.swift` | Generates soft-circle (and future textured) brush mask `MTLTexture`s. |

### Modified files

| File | Changes |
|------|---------|
| `CanvasView.swift` | `makeUIView` returns `RotatableCanvasContainer` wrapping `MetalCanvasView` instead of `DrawingCanvasView`. Callback wiring stays the same shape. |
| `CanvasViewModel.swift` | Internals adapt: `attach()` receives `MetalCanvasView` + container. `selectBrush/Eraser/Lasso` set tool state on MetalCanvasView. `captureSnapshot()` reads from Metal compositor. `exportDrawingData()` / `loadStrokes()` / thumbnail unchanged in API. |
| `RotatableCanvasContainer.swift` | Replace `DrawingCanvasView` property with `MetalCanvasView`. Gesture wiring, cursor, lasso selection overlay, color picker ring — all unchanged. |
| `DrawingEngine.swift` | Add `DrawingLayer`, `LayerBlendMode` types. Keep `Stroke`, `StrokePoint`, `BrushConfig`, `ToolState` (remove `.smudge` case). Keep `CanvasAction` (adapt cases for Metal undo). |

### Deleted files

| File | Reason |
|------|--------|
| `DrawingCanvasView.swift` | Replaced by `MetalCanvasView` + `CanvasRenderer`. |

### Unchanged files (no modifications needed)

| File | Why |
|------|-----|
| `CursorOverlayView.swift` | UIView overlay, unaffected. |
| `LassoSelectionView.swift` | UIView overlay, unaffected. |
| `ColorPickerRingView.swift` | UIView overlay, unaffected. |
| `StrokeSmoother.swift` | CPU-side stroke smoothing, reused by BrushStampPipeline. |
| `StrokeTessellator.swift` | CPU-side tessellation, reused for stroke contour generation. |
| `UIImage+PixelColor.swift` | Utility, unaffected. |
| `TouchTrackingGestureRecognizer.swift` | Gesture, unaffected. |
| `UndoStack.swift` | Generic data structure; new `CanvasUndoManager` may wrap or replace it. |
| `SketchSnapshot.swift` | Data type, unaffected. |

### App-level files (in `ios/Kiki/`)

| File | Changes |
|------|---------|
| `AppCoordinator.swift` | Remove `.smudge` from `DrawingTool` enum. Remove smudge-related per-tool state. Add layer management actions (addLayer, removeLayer, selectLayer, etc.). `applyTool()` drops the smudge case. |
| `DrawingTopBar.swift` | Remove smudge tool button. |
| `CanvasSidebar.swift` | Remove smudge-related opacity slider guard. |
| `DrawingView.swift` | Minor: may need to pass layer-related state to the canvas view. |

## Implementation Phases

### Phase 1: Core Metal engine + brush + eraser (~5–7 days)

**Goal:** Replace `DrawingCanvasView` with `MetalCanvasView` for basic drawing. Single-layer. Brush and eraser work at 120 Hz. No lasso, no multi-layer, no smudge.

1. `MetalCanvasView` + `CanvasRenderer`: CAMetalLayer setup, CADisplayLink, one canvas MTLTexture, render loop that composites background + canvas + active stroke.
2. `BrushStampPipeline`: instanced stamp rendering with soft-circle mask. Pressure-modulated size.
3. `Shaders.metal`: brush-stamp fragment shader (sample mask × color), source-over blend.
4. Eraser: same pipeline, destination-out blend.
5. Touch handling: coalescedTouches + predictedTouches → stamp instances. Active stroke in scratch texture, flattened on touchesEnded.
6. Wire into `CanvasViewModel` and `RotatableCanvasContainer`: tool selection, drawing-changed callbacks, basic undo (full-texture snapshots).
7. Revert smudge: remove `.smudge` from `DrawingTool`, `ToolState`; remove smudge UI button.
8. Build, test brush + eraser on simulator.

### Phase 2: Lasso + undo/redo + persistence (~3–4 days)

**Goal:** Feature parity with pre-smudge DrawingCanvasView (minus smudge).

1. Lasso: path drawing (existing touch flow), selection extraction via texture readback, clip mask via stencil or mask texture.
2. `CanvasUndoManager`: full-snapshot push/pop, integrated with stroke completion / erase / lasso commit / clear.
3. Persistence: export strokes as JSON (unchanged), load strokes on attach (replay through BrushStampPipeline), thumbnail generation via Metal readback.
4. Stream capture: `captureSnapshot()` from Metal compositor output.
5. "Send to canvas" / baked image: load UIImage → MTLTexture, composite into canvas.
6. Integration testing: save → close → reopen cycle, undo/redo, stream capture.

### Phase 3: Multi-layer support (~3–5 days)

**Goal:** N layers with blend modes, composited in a single render pass.

1. `LayerStack` model: add/remove/reorder/merge layers. Active-layer tracking.
2. `CanvasRenderer` compositor: per-layer quad with blend-mode fragment shader.
3. Per-layer undo: snapshots keyed by layer ID.
4. Persistence: save per-layer pixel data + metadata.
5. Layer UI hooks in `AppCoordinator` (the actual layer panel UI is a separate workstream).
6. `Drawing` model update: add layer data alongside existing drawingData.

### Phase 4: Polish + predicted touches + verification (~2–3 days)

**Goal:** Production-quality latency and correctness.

1. Predicted touches: render speculative stamps, overwrite on real touch arrival.
2. Linear-space blending in shaders (gamma expand → blend → gamma compress).
3. On-device profiling: signpost each render pass, measure end-to-end latency with Instruments.
4. Edge cases: empty canvas, single-pixel strokes, canvas rotation during stroke, app backgrounding during stroke, memory pressure handling.
5. Delete `DrawingCanvasView.swift` and any remaining dead code.

## Verification

### Build
```bash
cd ios && xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
```

### Functional tests (on-device, iPad Pro)

| # | Test | Expected |
|---|------|----------|
| 1 | Draw a stroke with varying pressure | Smooth, variable-width line with tapered ends. No stuttering. |
| 2 | Draw 50 strokes rapidly | All render at 120 Hz. No frame drops. |
| 3 | Erase through a stroke | Clean erasure following the eraser path. |
| 4 | Undo 10 strokes, redo 5 | Canvas state matches expectations at each step. |
| 5 | Lasso a region, move it, commit | Selection extracts, moves, commits back to canvas. |
| 6 | Save drawing, close, reopen | All strokes restored, background image intact. |
| 7 | Stream capture while drawing | FLUX.2 receives canvas updates at ~2 fps. |
| 8 | "Send to canvas" a generated image | Image appears on canvas, erasable, undoable. |
| 9 | Pinch-to-zoom + rotate + draw | Strokes land at correct positions regardless of transform. |
| 10 | Multi-layer: draw on layer 2, hide layer 1 | Layer 1 content hidden, layer 2 content visible. |
| 11 | Multi-layer: change blend mode to multiply | Layer composites correctly with multiply. |
| 12 | Memory: 10 layers + 30 undo states | No crash on 8 GB iPad. |

### Performance targets (on-device, iPad Pro M1+)

| Metric | Target |
|--------|--------|
| Brush stroke render latency | < 4 ms per frame |
| End-to-end pencil-to-screen | < 12 ms (with predicted touches) |
| Frame rate during continuous drawing | 120 fps sustained |
| Undo/redo | < 5 ms (texture replace) |
| Stream capture | < 10 ms per frame (background queue) |

## What was validated / added from the ChatGPT deep-research report

The report confirms the Metal direction and brush-stamp model. Useful details incorporated:
- **TBDR load/store actions**: scratch texture should be `memoryless` + `dontCare` store. Canvas textures use `load`/`store`. This keeps transient data in on-chip tile memory and eliminates bandwidth for ephemeral buffers.
- **PSO precompilation**: build pipeline states at init time, not on first brush stroke.
- **Preview / committed stroke split**: render predicted touches into a temporary overlay that's rebuilt each frame, commit real touches into the persistent canvas. This is the gold-standard pattern for sub-12ms perceived latency.
- **Tile-bucket batching**: even on a single texture, the report emphasizes batching GPU work by spatial locality. Our instanced draw call (one call per stroke batch) naturally does this.

**What we rejected as overengineered for Kiki's scope:**
- Virtual texturing / tiled paging / LRU residency manager / sparse textures (designed for 16K×8K canvases; our ~5.7 MP canvas fits in one texture).
- Scene graph compositor with mask/adjustment nodes (we need flat N-layer compositing).
- Journaling crash-safe persistence (SwiftData auto-save is sufficient for Phase 1).
- Effort estimates of 4–6 weeks with 2–4 engineers (our non-tiled, single-texture approach is much simpler).

## What's explicitly NOT in scope

- **Smudge tool** — reverted in this rewrite, re-added later as a ping-pong-texture fragment-shader pass on the proven Metal engine.
- **Layer panel UI** — separate workstream. This plan adds the engine support (LayerStack, compositor, undo per layer); the SwiftUI layer panel is designed + built separately.
- **Textured brushes** — the architecture supports them (brush mask texture is a parameter), but we ship with solid-color soft-circle brushes only. Textured brushes are an additive feature.
- **Tiled canvas / large artboard** — canvas is view-bounds × retina-scale (~5.7 MP). Sufficient for Kiki's sketch-to-AI workflow. Tiling is a future optimization if we want print-resolution canvases.
- **HDR / wide color** — `.bgra8Unorm_srgb` (8-bit) is sufficient. 16-bit float is a future upgrade for HDR displays.

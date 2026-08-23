# CanvasModule — Metal Drawing Engine

## Dev loop: BrushHarness (headless macOS rendering)

Brush/color-mixing work does NOT need an iPad round-trip: `BrushHarness/` compiles the
real engine (CanvasRenderer + StrokeStampGenerator + WetStrokeWalker) into a macOS CLI
that renders synthetic strokes and recorded fixtures to PNGs — **including the wet brush**
(Apple-silicon Macs have framebuffer fetch; the iOS Simulator does not). Run instructions:
`BrushHarness/README.md`. Recorded fixtures come from the app: Brush Studio → "Record
strokes" → share the JSON → `brushharness --fixtures <file>`. Device testing remains for
feel/latency/input only.

## Critical Rules (NEVER violate)

### Color pipeline — the one correct mental model (read this BEFORE touching color)

Our intuition here was wrong repeatedly and shipped real bugs: washed-out exports, an eyedropper that drifted on every sample, and save→reopen marching colors to black. **For each rule below, the "obvious" version is the trap.**

**The invariant:** a `.bgra8Unorm_srgb` texture stores `sRGB_encode(linear)` bytes, and **Metal's hardware owns the gamma at every texture boundary** — the sampler DECODES sRGB→linear on read, the render target ENCODES linear→sRGB on store. Therefore: anything that touches a texture directly must speak **linear**; anything that emits a standalone image/file for UIKit/SwiftUI must speak **sRGB**. Pick the wrong side and the sRGB gamma curve is applied twice — one direction lightens, the other darkens.

| Boundary | Dir | Use | If you use the "obvious" space instead |
|---|---|---|---|
| brush/stamp color → `_srgb` scratch (`premultipliedColor`, wet brush) | write | **linear** — `s2l(brush.color)` | sRGB → double-encode → strokes paint a shade too light |
| `CIContext.render(_:to: _srgb texture, colorSpace:)` (`renderCIImage`) | write | **linearSRGB** | sRGB → double-encode → washed-out midtones |
| `CIImage(mtlTexture: _srgb, options:[.colorSpace:])` (`textureToCIImage`) | read | **linearSRGB** | sRGB → re-decode → darkens; **compounds to black on save/reopen** |
| `createCGImage(..., colorSpace:)` / `pngRepresentation(..., colorSpace:)` | output | **sRGB** | the image/PNG leaves Metal; tag it sRGB so UIKit shows it right |
| `CIImage(cgImage:)` of a loaded PNG | input | sRGB (the file's own tag) | it's a genuine sRGB file |
| `CIContext` working color space | — | **sRGB** | |
| sampling a single canvas pixel (eyedropper) | read | Metal snapshot, then sample in **sRGB** | see below |

**Intuitions that are WRONG — each one of these shipped a bug (fixed 2026-06-08):**
- ❌ "The texture is `_srgb`, so read it back with `CIImage(mtlTexture:, colorSpace: .sRGB)`." → re-decodes already-linear texels → darkens every snapshot/thumbnail/save, compounding to black. ✅ **linearSRGB.**
- ❌ "`brush.color` is the sRGB color I picked, so pack it straight into the stamp." → the `_srgb` store re-encodes it → strokes land a shade too light (and eyedropper sample→repaint compounds *lighter*). ✅ **convert sRGB→linear (`s2l`) first.**
- ❌ "To read a canvas pixel, render the view/layer into a CGContext (`CALayer.render`/`drawHierarchy`)." → a `CAMetalLayer`'s pixels live in a GPU drawable; `CALayer.render` captures **nothing** (you read the white background). ✅ **read a Metal snapshot** (`opaqueImageSnapshot`/`flattenedCGImage`), then sample it.
- ⚠️ Retracted (2026-07-13): we previously listed "`CGColorSpaceCreateDeviceRGB()` is Display P3 on iPads" here as a shipped bug. **Empirically false** — in iOS bitmap contexts DeviceRGB is an sRGB pass-through (byte-identical in both directions; verified with a standalone CG binary in the iOS-runtime simulator). The 2026-06-08 eyedropper drift came from the other bugs fixed in the same commit (`968a454`): `CALayer.render` capturing nothing, a Y-flip, and the sRGB-vs-linearSRGB re-decode. Still prefer explicit `CGColorSpace(name: CGColorSpace.sRGB)!` — it states intent — but existing DeviceRGB call sites are not color bugs.
- ❌ "Both color paths looked fine, so the pipeline is fine." → a lighten bug and a darken bug **cancel out** until one side is touched. The eyedropper round-trip is what exposed both. ✅ **always test the full loop: pick → paint → eyedrop → repaint → save → reopen.** A single hop proves nothing.
- ❌ "To recover a straight color from a premultiplied `_srgb` texel, divide the byte by alpha, then decode." → premultiplication lives in **LINEAR** space (`stored = sRGB_encode(linear × α)`), and s2l is nonlinear, so the order is load-bearing. ✅ **decode FIRST, then un-premultiply** (`s2l(byte)/α`). The reverse order shipped in the wet brush's `sampleLayerColor` — the smear picked up semi-transparent paint up to ~3× too light (fixed 2026-07-14; see `WetKM.straightLinear` + the OfflineTests regression check). The GPU never had the bug: framebuffer fetch of an `_srgb` attachment is already linear.

The detailed rules below expand each of these.

### sRGB Premultiplied Alpha — The Bidirectional CIImage Rule

The canvas uses `.bgra8Unorm_srgb` Metal textures. The `_srgb` suffix means Metal's blend pipeline works in **linear** space: it decodes sRGB→linear on read, blends, then encodes linear→sRGB on write. The stored premultiplied values are `sRGB_encode(linear_R × alpha)`.

**CGContext premultiplies in sRGB space** (`sRGB_R × alpha`), which is mathematically different. Any CGImage↔Metal round-trip through CGContext darkens semi-transparent pixels because `sRGB(R_linear × α) ≠ sRGB(R_linear) × α`. The darkening is **cumulative** — each round-trip makes it worse.

**ALWAYS use CIImage + CIContext for BOTH directions:**

| Direction | Correct | WRONG (causes darkening) |
|---|---|---|
| Metal→CGImage | `CIImage(mtlTexture:, [.colorSpace: linearSRGB])` → `CIContext.createCGImage(colorSpace: sRGB)` | `texture.getBytes()` → `CGDataProvider` → `CGImage(...)`; **or** `CIImage(mtlTexture:, [.colorSpace: sRGB])` (re-decodes → darkens) |
| CGImage→Metal | `CIImage(cgImage:)` → `CIContext.render(_:to:commandBuffer:bounds:colorSpace: linearSRGB)` | `CGContext.draw(image)` → `texture.replace(region:withBytes:)`; **or** `colorSpace: sRGB` (re-encodes → washes out) |

CIContext is cached on `CanvasRenderer` (created once at init, backed by the same MTLDevice). The CIImage paths handle premultiplied alpha correctly — but **you** must pass the right color space at each Metal boundary (linearSRGB) vs. output (sRGB); see the mental-model table above. Using the cached CIContext does **not** absolve you of getting the gamma side right.

**`CIContext.render(to: MTLTexture)` silently writes NOTHING on current runtimes — sim AND device** (verified 2026-08-22: iOS 18.3.1 simulator by direct byte probes, iPadOS 26 hardware via the `-KikiCanvasLoadSelfTest 1` launch-arg self-test → `directCIRender=BROKEN(no-op)`; solid-red render → all-zero texture bytes on cached and fresh contexts, with and without an explicit command buffer — the READ direction, `CIImage(mtlTexture:)`, works fine). Consequence before the fix: **every saved drawing reopened blank, and the next autosave persisted the blank layers** — a silent production data-loss loop (present in the sim since at least Jul 19; date of the device regression unknown — the path was verified working in June, so likely an OS update), masked by overlay layout showing only the generated image. `renderCIImage` now probes the direct path once per renderer (`directCIRenderToTextureWorks`, 4×4 red render + readback) and self-heals onto `renderCIImageViaCPU` when broken: CI renders to a CPU bitmap in **RGBAh + linearSRGB** (keeping premultiplication in linear space — CI's 8-bit bitmap output premultiplies in the ENCODED space, measured 128 for ½-alpha white, i.e. the CGContext gamma trap above), uploads to a temp `rgba16Float` texture, and one compositor draw stores it into the `_srgb` layer so Metal's hardware does the exact linear→sRGB encode. Note `toBitmap` writes rows top-down, so the caller's Metal pre-flip must be undone there (loads came back vertically mirrored until it was). Regression check: launch with `-KikiCanvasLoadSelfTest 1` → PASS/FAIL line in syslog + a Sentry message (kiki-ios) for devices without USB log access.

**Y-flip:** CIImage uses bottom-left origin; Metal textures use top-left. Apply `CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -extent.height)` when converting in either direction.

### Color Space — Always Explicit sRGB

Use explicit sRGB, not `CGColorSpaceCreateDeviceRGB()`, so color intent is auditable at every call site. **Correction (2026-07-13):** this section used to claim DeviceRGB "returns Display P3 on modern iPads" — that is false. Verified empirically (standalone CG binary in the iOS-runtime simulator): drawing an sRGB-tagged image into a DeviceRGB bitmap context is byte-identical (no gamut conversion), and DeviceRGB-tagged sources are treated as sRGB; an explicit Display P3 context, by contrast, really converts (sRGB 255,0,0 → 234,51,35). So the existing DeviceRGB call sites (`DiskColorPicker.generateSBImage`, `EyedropperRing.sampleColor`, the `DrawingVideoRecorder` fallback) behave identically to sRGB — don't "fix" them expecting a visible change, and don't cite DeviceRGB as a root cause for color drift.

**ALWAYS use `CGColorSpace(name: CGColorSpace.sRGB)!`** for:
- `CIContext` working color space
- `CIContext.createCGImage(..., colorSpace: ...)` and `CIContext.pngRepresentation(..., colorSpace: ...)` — the OUTPUT tag of an image/file should be sRGB

**EXCEPTION — direct Metal-texture I/O for a `_srgb` format uses `CGColorSpace(name: CGColorSpace.linearSRGB)!`, NOT sRGB, in BOTH directions.** Metal's hardware does the sRGB↔linear conversion for `.bgra8Unorm_srgb` textures (decode on sampler read, encode on render store), so Core Image must deal in *linear* values at the Metal boundary and let Metal own the gamma. This is symmetric:
- **Writing** — `CIContext.render(_:to:bounds:colorSpace: linearSRGB)` into a `_srgb` texture. Passing sRGB makes CIContext *also* encode → gamma applied twice → midtones lift to mid-gray (washed out).
- **Reading** — `CIImage(mtlTexture:, options: [.colorSpace: linearSRGB])` from a `_srgb` texture. The sampler already decoded sRGB→linear, so the values CI receives are linear. Passing sRGB makes CIImage *re-decode* → every read darkens AND over-saturates. Because the save path (`layerPNGData`→`textureToPNGData`) and all snapshots/thumbnails/eyedropper funnel through `textureToCIImage`, that extra decode bakes into stored PNGs and **compounds on each save/reopen, marching any color toward black.** (Fixed 2026-06-08; the read side had wrongly used sRGB.)

The only sRGB tags in this round-trip are on CGImage/PNG *outputs* (a CGImage that leaves the Metal world should be sRGB-tagged so UIKit/SwiftUI display it correctly) and on a CGImage *input* being loaded (`CIImage(cgImage:)` of an sRGB PNG). The `_srgb`-texture endpoints are always linearSRGB.

### UIGraphicsImageRenderer — Force `.standard` Range (convention)

**Correction (2026-07-13):** this section used to claim the default renderer produces **Display P3**-tagged images. Unsupported — in the iOS-runtime simulator the default `preferredRange` is `.standard` (sRGB) and a rendered pixel round-trips losslessly; on wide-color hardware the default may resolve to `.extended`, which is *extended sRGB* — in-gamut sRGB values are preserved exactly, so no saturation mismatch either way. Forcing `.standard` costs nothing and pins the format explicitly (plus avoids extended-range surprises for out-of-gamut inputs), so keep the convention — just don't expect it to change colors.

**Create renderers with explicit sRGB format:**
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

**Per-layer blend modes + opacity (2026-08-23):** every layer draw goes through
`drawLayerComposite` — Normal mode uses the fixed-function `compositorPSO` with the
layer's `opacity` as the uniform; the 13 non-Normal modes (`LayerBlendMode`, separable
W3C formulas) use `blendCompositorPSO`, a framebuffer-fetch fragment
(`blendCompositorFragment` reads `[[color(0)]]`, un-premultiplies both sides, evaluates
the blend formula in LINEAR space, and applies the full compositing equation itself —
fixed-function blending disabled). **Simulator**: fbfetch unavailable → the PSO is nil and
non-Normal modes render as Normal there (opacity still applies); device/macOS render the
real formulas. All three composite paths (display, `flattenedCGImage` stream capture,
`flattenedOpaqueCGImage` thumbnails/snapshots) share the helper, so exports match the
screen. Verified headless via the BrushHarness pattern (all 14 modes + opacity-scaled
multiply, pixel-accurate vs CPU W3C reference, 2026-08-23). Blend/opacity are
composite-time only — never baked into layer textures — and persist via `LayeredDrawing`
(optional fields, old saves decode to Normal/1.0).

### Brush rendering flow
1. Touch points → `StrokePoint` array (pressure, altitude, position)
2. Arc-length resample with **adaptive spacing** (`max(effectiveWidth × 0.3, 0.5)`)
3. Per-stamp: `StampInstance` (center, radius, rotation, premultiplied color). **Stamp color is fed in LINEAR** — `brush.color` is sRGB, but stamps render into a `.bgra8Unorm_srgb` scratch whose store re-encodes linear→sRGB, so `premultipliedColor` (and the wet brush) apply sRGB→linear (`s2l`) first. Packing sRGB directly double-encodes → strokes paint a shade too light and eyedropper sample→repaint compounds lighter. **Stamp alpha = the brush's `flow`** (per-stamp deposit), NOT opacity — so overlapping stamps build up *within* a stroke.
4. All stamps → shared `MTLBuffer` → single instanced draw call into scratch texture (premultiplied source-over; the scratch holds the whole stroke in isolation, saturating toward alpha 1)
5. On touchesEnded: flatten scratch into active layer, scaling the whole scratch by the brush's **per-stroke `opacity` ceiling** (`compositorFragment` `color * opacity`). This two-stage flow/opacity split ("Glaze") is why a sub-100% stroke that crosses itself stays flat instead of stacking. Live preview (`compositeToDrawable`) and snapshot/export paths apply the same ceiling — the former via `CanvasRenderer.activeStrokeOpacity`, the latter via an explicit `strokeOpacity:` parameter. See `documents/plans/pro-brush-roadmap.md` Phase 0.

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
- Clip mask: `setClipPath()` persists the path across tool switches. Stamps outside the path are discarded (CPU-side via `CGPath.contains(_:using: .evenOdd)` — even-odd since 2026-07-19 so magic-wand masks with holes/disjoint subpaths clip correctly; identical to winding for simple lasso loops)
- Commit: Metal render pass composites selection texture onto active layer (source-over)
- Cancel: discard selection texture + undo to pre-lasso snapshot

### Unified Selection (2026-07-19, supersedes separate lasso/wand selections)

`SelectionController` (MagicWand/) owns ONE selection: a list of per-object 1024²
bitmaps (`.auto(points:)` SAM-authored / `.freehand` hand-drawn or carved), whose
union (+ selection-wide Expand via union distance field) publishes the clip path.
Key mechanics:
- **Tap routing** (reopen-on-tap): Add outside → new object (auto-commits current);
  any tap inside an auto object → reopen + joint refine; Remove on freehand →
  SAM-carve (single-point decode ∩ object, contiguous-guarded). No "New Object" UI.
- **Freehand loops**: `MetalCanvasView.onFreehandLoopClosed` (set ⇒ lasso capture
  becomes a mask author: no undo snapshot, no extraction) → `MaskContour.rasterize`
  (even-odd) → add object or `subtracting` bake (carved auto objects → freehand
  source, points discarded).
- **Move**: `beginMove` → `beginMoveExtraction(path:)` (renderer extraction, even-odd
  fill) + container float gestures → commit composites + `MaskContour.transform`
  moves every object bitmap/point by the same affine (rotate+scale about extraction-
  bounds center, then translate — must match `updateSelectionVertices`). Cancel =
  snapshot restore + canvas undo. Clip visuals hidden while floating.
- **Selection undo**: snapshot stack (arrays are COW → ~free). `sessionGeneration`
  guards discard in-flight decode/derive results after restore/clear.
- Legacy lasso Phase-A-from-touch is dead code behind `onFreehandLoopClosed == nil`.

### Magic wand flow (`MagicWand/`, 2026-07-19)
- **No Metal selection extraction** — the wand is Phase-B-only: it produces a clip path (`setClipPath`) + ants + point markers; nothing floats/moves.
- Tap (`MetalCanvasView` `.magicWand` touch case, ≤12 pt travel) → `onWandTap` → `MagicWandController.handleTap` → SAM point prompt over the accumulated object points → best-score 256² logits → bilinear upsample to 1024² (`vImageScale_PlanarF`), threshold >0 → union with committed object bitmaps → marching squares + Douglas-Peucker (`MaskContour.path`, normalized [0,1]² coords, even-odd) → scaled to view points → `setClipPath`.
- `SAM2Segmenter` (actor): Apple's coreml-sam2.1-small 3-model split — ImageEncoder (once per image), PromptEncoder + MaskDecoder (per tap). `.cpuAndGPU` on device; **`.cpuOnly` + fake-mask dev injection on the simulator — the sim's Core ML zeroes `low_res_masks` (scores fine) on every runtime/compute-unit combination tested (18.3.1, 26.5 × CPU, GPU) while the identical .mlmodelc is correct on macOS. Read masks via MLMultiArray subscripts, not `withUnsafeBufferPointer` (CPU backend can hand back a strided/lazy buffer that reads as zeros).**
- Wand markers (green/red dots + white outline) are CAShapeLayers re-hosted together with the lasso preview layers by `setLassoPreviewHost` (overlay mode parks them above the generated image).
- Object model: current object refined live (pos/neg points), `startNewObject()` freezes its bitmap (embedding can then re-encode if the canvas changed — committed bitmaps stay valid). Undo while wand active steps back points, then reopens the last committed object.
- **Params (post-processing on the cached decode — no model re-run):** `granularity` (Small/Auto/Large — picks among SAM's 3 candidate masks; the "tolerance" analog), `contiguous` (keep only the 4-connected component at the first positive point, `MaskContour.connectedComponent`), `expansion` (±20 mask-px morphological grow/shrink, `MaskContour.expand`, separable 1-D passes). All apply to the CURRENT object only; committed objects keep their frozen bitmaps. `SAM2Segmenter.maskCandidates` returns all 3 logit grids + scores + areas; `mask()` is the argmax convenience.
- **Unselected-region stripes:** while any clip is active (wand or lasso Phase B), `clipDimLayer` (CAShapeLayer, even-odd full-rect+clip path, diagonal-stripe `UIColor(patternImage:)` fill) washes everything OUTSIDE the selectable region; ants layers animate `lineDashPhase` ("march"). CALayers never hit-test, so wand taps pass through. Rebuilt in `setClipPath`/`layoutSubviews` (`updateClipDimPath`).
- Offline harness pattern (SAM + contour + clip-chain, macOS): see scratchpad `wandharness`/`cliptest` mains from the 2026-07-19 session — compile `MagicWand/*.swift` (UIKit-free) with the BrushHarness file list.

## Files

| File | Role |
|------|------|
| `MetalCanvasView.swift` | UIView, touch handling, CADisplayLink render loop, undo, lasso |
| `CanvasRenderer.swift` | Metal device/queue/pipelines, Layer struct, texture management, render passes, CIContext, shaders (embedded MSL). **UIKit-free** (compiles on macOS for BrushHarness) — keep it that way |
| `StrokeStampGenerator.swift` | The pure stroke→stamps dab pipeline (dynamics, jitter, scatter, taper). Extracted from MetalCanvasView so BrushHarness runs the identical shipped code headless |
| `WetStrokeWalker.swift` | The wet brush's incremental stroke walk + carried-load smear (pure; canvas access injected as closures) |
| `WetKM.swift` | Spectral KM tables/mix + premult-`_srgb`-texel recovery (pure; asserted by OfflineTests) |
| `BrushFixture.swift` | Recorded-stroke JSON contract between the iPad recorder (Brush Studio) and BrushHarness |
| `CanvasViewModel.swift` | @Observable bridge between AppCoordinator and MetalCanvasView, snapshot/thumbnail compositing |
| `CanvasView.swift` | UIViewRepresentable wrapper, callback wiring |
| `RotatableCanvasContainer.swift` | Gesture handling (zoom/rotate/pan), cursor overlay, background image, lasso selection view. Also hosts app-overlay hooks: `externalTransformRegionProvider`/`onExternalTransform` (forward a two-finger gesture that starts over a registered rect — e.g. the fullscreen result panel — instead of transforming the canvas) and `onContactPointChanged` (reports the live single-touch contact point + brush diameter in pane space for the panel transparency-hole effect). |
| `LassoSelectionView.swift` | Gesture-only view for lasso transform (pan/pinch/rotate), marching ants |
| `MagicWand/SAM2Segmenter.swift` | On-device SAM 2.1 Core ML wrapper (actor; encode-once / decode-per-tap). UIKit-free |
| `MagicWand/MaskContour.swift` | Logits→binary upsample, mask union, marching-squares→CGPath, RDP simplify. UIKit-free |
| `MagicWand/MagicWandController.swift` | Wand session state (objects/points/masks, add-subtract mode), publishes clip path + markers |
| `MagicWand/SAM2Bundle.swift` | `Bundle.module` loader for the committed `Resources/SAM2/*.mlmodelc` |
| `DrawingEngine.swift` | Stroke/StrokePoint/BrushConfig/ToolState/LayerInfo/LayeredDrawing types |

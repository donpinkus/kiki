# Overlay Drawing Mode — Implementation Spec

**Status:** in development (5 parallel independent implementations, 2026-06-21)
**Owner:** Donald

## What we're building

A third drawing-mode **layout** for the Kiki iPad app in which the AI-generated image is
overlaid *exactly* on top of the drawing canvas — same position, size, rotation, and zoom —
instead of floating in a separate panel (fullscreen) or sitting in a side pane (split-screen).

Behavior, precisely:

1. **Generated image is locked to the canvas.** It covers the canvas drawing surface 1:1 and
   moves/zooms/rotates *with* the canvas (two-finger pan/pinch/rotate transforms both together).
   There is no separate floating panel to drag.
2. **No pass-through hole.** Unlike fullscreen's `FloatingResultPanel` (which punches a soft
   transparency hole under the pencil so you see the raw canvas while drawing), overlay mode keeps
   the generated image **fully opaque** — you are *always* looking at the generated result, never
   the raw canvas underneath.
3. **Fresh strokes show on a second, visual-only canvas above the generated image.** When you
   draw, your strokes render on a lightweight overlay-stroke surface that sits **above** the opaque
   generated image, so you can see what you just drew. These strokes are **purely visual** — they
   do **not** feed generation (the real Metal canvas underneath does that, exactly as today).
4. **Overlay strokes clear on every returned generation frame.** Each time a new generated frame
   arrives from the backend (~2 FPS), the visual-only overlay-stroke surface is wiped. Net effect:
   your raw strokes flash briefly, then the generated image (which now reflects them via fal's
   img2img feedback loop) takes over.

## Locked product decisions (do not re-litigate)

| Decision | Choice |
|---|---|
| Mode entry | New **third `DrawingLayout` case `.overlay`**, additive, selectable in Settings → Display (segmented picker gains a 3rd segment). Split-screen + fullscreen untouched. |
| Overlay-stroke clear timing | **Clear all overlay strokes on every returned generation frame** (still frames AND video frames). Literal, simplest. |
| Video idle-state animation | **Overlays in place** — the LTX animation renders locked to the canvas, same position as the still. |
| Transform lock | Overlay is **rigidly locked** to the canvas pan/zoom/rotate (they move together). |
| Cold start / between frames | **Show the last successful image** (never blank — honor "never clear the right pane"). Bind to `resultState.displayImage`. |

## Critical constraints (from CLAUDE.md — NEVER violate)

- **Canvas responsiveness is sacred.** The overlay-stroke surface must not add `waitUntilCompleted`
  or `drawHierarchy` to the drawing hot path. Reuse the existing `.shared`-storage + async-commit
  pattern. Target <8ms stroke latency at 120 Hz preserved.
- **Never clear the right pane / generated image.** Always keep the last successful image visible.
- **Color correctness.** Stamps render into `.bgra8Unorm_srgb` textures — the brush color must be
  fed **linear** (`s2l()` premultiplied) exactly as the existing `premultipliedColor()` does. If you
  stand up a second stroke texture, it must be `.bgra8Unorm_srgb` too and use the identical pipeline.
  See `ios/Packages/CanvasModule/CLAUDE.md` color section. Verify shader/color math offline before
  device testing.
- **No secrets on client.** (Not relevant here, but don't regress.)
- The overlay-stroke surface has **no undo, no layers, no persistence** — it's ephemeral and visual.

## Code map (verified 2026-06-21)

### Layout selection
- `ios/Kiki/App/AppCoordinator.swift:32-34` — `enum DrawingLayout: String, CaseIterable { case splitScreen, fullscreen }`. **Add `case overlay`.**
- `ios/Kiki/App/AppCoordinator.swift:318-325` — `var drawingLayout` (persists to UserDefaults; resets `panelHole`).
- `ios/Kiki/App/AppCoordinator.swift:499-502` — restore from UserDefaults at init.

**8 read sites** (most already fall through correctly for `.overlay` — verify each):
1. `AppCoordinator.swift:294` `updatePanelHole()` — `guard drawingLayout == .fullscreen`. Overlay has **no** hole → leave fullscreen-only (overlay excluded ✓).
2. `DrawingView.swift:55-57` canvas pane width — `== .splitScreen ? half : full`. Overlay → full ✓.
3. `DrawingView.swift:73` `externalTransformRegionProvider` — `== .fullscreen` returns floating-panel rect. Overlay has **no** draggable panel → leave fullscreen-only so two-finger gestures drive the **canvas** transform (which is what locks the overlay) ✓.
4. `DrawingView.swift:109` canvas alignment — `== .splitScreen ? .trailing : .center`. Overlay → center ✓.
5. `DrawingView.swift:132` lasso button alignment — same rule ✓.
6. `DrawingView.swift:160-180` **result-pane branch — THE place that needs new `.overlay` handling.** Currently: `if splitScreen { splitScreenResultPane } else if let image = displayImage { FloatingResultPanel(...) }`. For `.overlay`, the generated image + overlay strokes render **inside the canvas container** (see architecture), so this branch should NOT add a FloatingResultPanel for overlay. Add an explicit `.overlay` arm (likely render nothing here, or just an overlay-mode affordance).
7. `DrawingTopBar.swift:77` — `if drawingLayout != .splitScreen { inline style+prompt }`. Overlay → inline UI shown (same as fullscreen) ✓.
8. `SettingsPanel.swift:25` — reset-to-defaults sets `.splitScreen`. Leave as-is.

### Settings picker
- `ios/Kiki/Views/SettingsPanel.swift:42-52` — segmented `Picker("Layout", selection: $coordinator.drawingLayout)` with `.tag(DrawingLayout.splitScreen)` / `.fullscreen`. **Add a third `Text("Overlay").tag(DrawingLayout.overlay)`.**

### Drawing view render tree
- `ios/Kiki/Views/DrawingView.swift:13-201` — `VStack { DrawingTopBar; errorBanner; GeometryReader { ZStack(.topLeading) { CanvasView; CanvasSidebar; clearLassoButton; quickShapeTooltip; <result-pane branch 160-180>; grayBackground } } }`.
- `ios/Kiki/Views/FloatingResultPanel.swift` — fullscreen floating panel (visual-only, `allowsHitTesting(false)`, `panelHole` mask, `panelOffset`/`panelScale` transforms, `PanelLayout.rect`). **Reference only** — overlay mode does NOT reuse the floating panel; it locks to the canvas instead. The `panelHole` machinery is explicitly NOT wanted in overlay mode.

### Generated result delivery
- `ios/Packages/ResultModule/Sources/ResultModule/ResultState.swift:38-109` — `ResultState` enum; `displayImage` computed returns the current image for every state (`.streaming`→image, `.preview`→image, `.provisioning/.error/.idleTimeout`→previousImage, `.videoStreaming`→latestFrame, `.videoLooping`→fallback). **Bind the overlay image to `coordinator.resultState.displayImage` → "show last image, never blank" for free.**
- `ios/Kiki/App/AppCoordinator.swift:262` — `var resultState: ResultState = .empty` (the @Observable source of truth).
- `ios/Kiki/App/AppCoordinator.swift:465` — `private var lastSuccessfulImage: UIImage?`.

### Frame-arrival chokepoints (where to clear overlay strokes)
- **Still frames:** `ios/Kiki/App/AppCoordinator.swift:1175-1216` `session.onImageReceived` — sets `lastSuccessfulImage` + `resultState = .streaming(...)`. **Call `clearOverlayStrokes()` here** (e.g. right after `lastSuccessfulImage = image`, ~:1178).
- **Video frames:** `ios/Kiki/App/AppCoordinator.swift:1429-1483` `handleVideoEvent()` — `.frame` case (~:1438) sets `resultState = .videoStreaming(...)`. **Call `clearOverlayStrokes()` in the `.frame` case** so overlay strokes also clear during animation.
- Clearing when not in `.overlay` layout must be a harmless no-op (the overlay surface simply doesn't exist / isn't shown).
- Upstream plumbing: WS decode `StreamWebSocketClient` (`receivedFrames`/`videoEvents` AsyncStreams) → `StreamSession.onImageReceived`/`onVideoEvent` → AppCoordinator. You only need to hook the AppCoordinator chokepoints.

### Canvas engine (CanvasModule package)
- `ios/Packages/CanvasModule/Sources/CanvasModule/CanvasView.swift:1-86` — `UIViewRepresentable` wrapping `RotatableCanvasContainer`. Init takes closures `externalTransformRegionProvider`, `onExternalTransform`, `onContactPointChanged`. **This is where you add new params** to drive overlay mode (e.g. `overlayImage: UIImage?`, `overlayActive: Bool`, and a binding/handle to call `clearOverlayStrokes()`).
- `ios/Packages/CanvasModule/Sources/CanvasModule/RotatableCanvasContainer.swift`:
  - `:7` `public let canvasView = MetalCanvasView()`.
  - `:8-10` `public private(set) var rotation/scale/translation`.
  - `:98-120` view hierarchy: `transformView` (gets the `CGAffineTransform`) hosts `backgroundImageView`, `canvasView`, `cursorView`. **The generated-image overlay + overlay-stroke surface should be added inside `transformView`, above `canvasView`, so they inherit the exact transform.**
  - `:550-554` `applyTransform()` builds `CGAffineTransform(translation).rotated(rotation).scaledBy(scale)`.
- `ios/Packages/CanvasModule/Sources/CanvasModule/MetalCanvasView.swift`:
  - `:328` `layerClass = CAMetalLayer`; `:267-273` layer config (`.bgra8Unorm_srgb`, `isOpaque=false`).
  - `:335` `static let documentSide = 2048` (fixed document resolution).
  - `:2527-2532` `canvasScale = documentSide / bounds.width` (touch→texture mapping divisor).
  - Touch path: `touchesBegan :395`, `touchesMoved :554`, `touchesEnded :665`, `finishStroke :1012`.
  - Stamp gen: `generateStampsForStroke :2360-2460`; `premultipliedColor :2534-2555` (sRGB→linear `s2l`, premultiplied by flow).
- `ios/Packages/CanvasModule/Sources/CanvasModule/CanvasRenderer.swift`:
  - `:257-276` `configureDocument(side:viewScale:)` — allocates the 2048² layer + scratch textures (once).
  - `:232-243` `makeLayerDescriptor()` — `.bgra8Unorm_srgb`, `.shared`, `[.shaderRead,.shaderWrite,.renderTarget]`.
  - `:357-369` `renderFrame(drawable:isErasing:)` — Pass 1 stamps→scratch, Pass 2 composite layers+scratch→drawable, async commit.
  - `:374-395` `flattenScratchIntoCanvas()` — the one `waitUntilCompleted` on stroke-end.
  - `:717-768` `flattenedCGImage()` / `:840-870` Metal→CIImage (linearSRGB color space note).

## Recommended architecture (you may diverge on the overlay-stroke surface)

The robust way to get "locked exactly to the canvas" is to render both the generated image and the
overlay-stroke surface **inside `RotatableCanvasContainer.transformView`, above `canvasView`**, so
they inherit the canvas's `CGAffineTransform` automatically — no transform mirroring across the
SwiftUI/UIKit boundary.

Z-order inside `transformView` (bottom → top) when `.overlay` is active:
1. `backgroundImageView` (white / lineart) — existing.
2. `canvasView` (real Metal canvas; the actual drawing that feeds generation) — existing, now **visually occluded** by the generated image but still capturing touches.
3. **`generatedImageView`** — opaque `UIImageView` bound to `resultState.displayImage`, `userInteractionEnabled=false`, frame == canvas frame. (NEW)
4. **`OverlayStrokeView`** — visual-only stamp surface showing strokes since last generation; transparent except strokes; `userInteractionEnabled=false`. (NEW)

Touches still land on `canvasView` (the occluding views are non-interactive), so real drawing,
stroke capture, and generation are unchanged.

### The overlay-stroke surface
- A lightweight Metal surface (its own `CAMetalLayer` or a reused renderer path) holding **one
  accumulation texture** (`.bgra8Unorm_srgb`, `.shared`, 2048²) — **no undo, no layers, no scratch
  persistence beyond the active stroke**.
- It is fed the **same `StampInstance`s** the `MetalCanvasView` generates for the active stroke
  (identical `premultipliedColor`/`s2l` pipeline). The simplest wiring: `MetalCanvasView` forwards
  active-stroke stamps to the overlay surface each frame (live in-progress stroke visible), and on
  `finishStroke()` flattens them into the overlay accumulation texture.
- `clearOverlayStrokes()` wipes the accumulation texture (clear to transparent). Exposed up the
  chain: `RotatableCanvasContainer` → `CanvasView` → `CanvasViewModel` → so
  `AppCoordinator.onImageReceived` / `handleVideoEvent(.frame)` can call it.
- Only renders/clears when `.overlay` layout is active; inert otherwise.

### Generated image binding
- `CanvasView` (UIViewRepresentable) gains `overlayImage: UIImage?` (= `coordinator.resultState.displayImage` when `drawingLayout == .overlay`, else `nil`) and `overlayActive: Bool`. `updateUIView` pushes the image into the container's `generatedImageView` and toggles visibility.
- "Show last image, never blank" is automatic because `displayImage` already falls back to the last
  successful image across provisioning/error/idle states.

### Video in place
- When `resultState` is `.videoStreaming(latestFrame:)`, `displayImage` returns `latestFrame` → the
  `generatedImageView` shows it in place automatically (good enough for streaming frames).
- When `.videoLooping(mp4URL:fallback:)`, `displayImage` returns the **fallback still**, not the
  playing MP4. For true "video animation in place," render the looping MP4 in the locked overlay
  position too (an `AVPlayerLayer`/player view in the same `transformView` slot, swapped in when
  state is `.videoLooping`). **Minimum bar:** still + streaming frames locked in place. **Full bar:**
  the looping MP4 also plays locked to the transform. Reuse the existing split-screen video
  rendering logic where practical (see `ResultModule/ResultView.swift` videoLooping handling).

## Acceptance criteria

1. `swift build --package-path ios/Packages/CanvasModule` succeeds, and
   `xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build`
   succeeds.
2. Settings → Display shows a 3-way Split / Fullscreen / Overlay picker; selecting Overlay persists
   across relaunch.
3. In overlay mode: generated image is opaque, covers the canvas exactly, and two-finger
   pan/pinch/rotate moves image + strokes + canvas **together** with no drift/lag.
4. Drawing shows fresh strokes above the generated image; on each new generated frame the overlay
   strokes clear. Strokes are visual-only and do not alter generation behavior.
5. Before the first frame (and between frames), the last successful image stays visible — never
   blank after the first success.
6. Video idle-state animation appears in the locked overlay position (min bar: streaming frames;
   target: looping MP4 too).
7. Split-screen and fullscreen modes are visually and behaviorally unchanged.
8. No new `waitUntilCompleted`/`drawHierarchy` on the drawing hot path; 120 Hz stroke latency
   preserved. Color is correct (no washed-out / darkened strokes).

## Out of scope
- Changing what is sent to the backend / how generation is conditioned.
- Aspect-ratio reconciliation beyond uniform fit (generated images are square; canvas is square).
- Any backend / pod / model changes. **iOS-only.**

## Post-landing review (2026-06-21)

Four independent review agents (correctness, Metal/color/perf, simplification, integration) audited the
landed diff. **Color correctness, pixel registration, hot-path safety (dry brush), all 8 layout
branches, and never-blank were verified clean.** Fixes applied (build still green):

- **Async overlay clear** — `clearOverlayStrokes()` no longer routes through the blocking
  `clearTexture` (which `waitUntilCompleted`s); it now uses an async clear render pass. The clear runs
  on the main-thread ~2 FPS generation-frame cadence, so the blocking version was off-pattern per
  CanvasModule/CLAUDE.md (wait is reserved for stroke-end/resize). Flagged by 3 of 4 agents.
- **Allocation race fixed** — `MetalCanvasView.layoutSubviews` now re-tries
  `ensureOverlayStrokeTexture()` after `configureDocument`, so launching directly into overlay layout
  allocates the texture immediately instead of relying on a later `updateUIView` to self-heal.
- **Texture lifetime** — the ~16 MB overlay texture is now released on overlay deactivate
  (`releaseOverlayStrokeTexture()` from the `overlayStrokeLayer` didSet nil-branch); re-entry allocates
  a fresh, cleared texture, which also fixes stale strokes reappearing on overlay re-entry.
- **Naming** — `clearOverlayStroke` → `clearOverlayStrokes` through the whole chain.

**Open decision (NOT changed — product call):** eraser + wet-brush strokes don't render on the
visual-only overlay (they write direct-to-canvas, bypassing the scratch the overlay reads). The
correctness agent rated eraser High (you erase but the just-drawn overlay strokes linger up to one
frame interval); in the chosen "clear on every frame" continuous-streaming model the divergence
self-corrects in ~250–500 ms, so it was left as-is pending Donald's on-device judgment. Cheap fix if
wanted: clear the overlay on eraser/wet stroke-end (coarse) or render those tools into the overlay
(precise).

## Test / verify note
The iOS Simulator can't get past Sign in with Apple, so runtime verification of the visual behavior
is **device-only** (Donald's iPad). Implementations must at minimum **build cleanly**; offline
shader/color verification (standalone Swift asserting vs reference) is preferred over guessing.

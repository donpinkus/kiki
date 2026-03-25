# Decision Log

Record implementation decisions here as they are made. Newest first. This prevents re-debating the same choices across sessions.

## Format

```
### YYYY-MM-DD — Decision Title
**Context:** Why this decision was needed
**Decision:** What was decided
**Alternatives considered:** What else was evaluated
**Consequences:** What this means for the codebase
```

---

### 2026-03-25 — Gallery home page with SwiftData local persistence
**Context:** App was single-screen with no persistence. Drawings were lost on app close. Needed a way to save, browse, and resume multiple drawings.
**Decision:** Add a gallery home page as the app root (state-based navigation, no NavigationStack). Each drawing is a SwiftData `@Model` with `@Attribute(.externalStorage)` for all image blobs. Auto-save on change (debounced 1s for UI events, immediate after generation). CanvasViewModel uses a pending-state pattern for save/restore: `setPendingState()` queues data before navigation, `attach()` applies it before the PKCanvasView delegate is set to avoid spurious change events. Gallery uses `@Query` for automatic SwiftData observation. Empty drawings are cleaned up on gallery navigation.
**Alternatives considered:**
- NavigationStack — adds push/pop semantics but the drawing view is heavy and we don't want it in the back stack; state-switching is simpler
- File-based storage (PKDrawing files + metadata JSON) — more manual, SwiftData is mandated by architecture decisions
- Drawing model as source of truth (bind views directly to `@Model`) — would require restructuring AppCoordinator; deferred to v2
- Separate GalleryModule SPM package — unnecessary complexity for v1; gallery views live in main app target
**Consequences:**
- ContentView renamed to DrawingView; RootView added as navigation root
- AppCoordinator now accepts `ModelContext` in init; `KikiApp` creates `ModelContainer`
- Gallery button (top-left of DrawingView) and "New" button (top-right of GalleryView) for navigation
- Long-press delete mode on gallery tiles with X badge overlay
- Canvas thumbnail pre-rendered at save time (256px max) since PKDrawing can't be rendered without a live PKCanvasView
- Generated image loaded at full resolution in gallery tiles (SwiftUI handles downscaling)

---

### 2026-03-17 — Use drawHierarchy for canvas snapshot capture (not PKDrawing.image)
**Context:** Sketch images uploaded to ComfyUI were blank white despite PKDrawing containing valid strokes at valid coordinates within canvas bounds. Root cause: `PKDrawing.image(from:scale:)` returns a blank image when the PKCanvasView is inside a transformed parent view (RotatableCanvasContainer). This broke ControlNet sketch adherence entirely — generations were prompt-only with no sketch conditioning.
**Decision:** Use `canvasView.drawHierarchy(in:afterScreenUpdates:)` inside a `UIGraphicsImageRenderer` to capture the live rendered view content instead of re-rendering from PKDrawing data.
**Alternatives considered:**
- `PKDrawing.image(from:scale:)` — blank output, likely PencilKit bug with ancestor transforms
- Moving `PKDrawing.image()` outside the renderer block — not tested, drawHierarchy is more reliable
- `canvasView.snapshotView(afterScreenUpdates:)` — returns a UIView, not a UIImage
**Consequences:**
- Snapshot captures exactly what's on screen (WYSIWYG)
- Requires canvasView to be in the window hierarchy and visible (always true for our use case)
- Corrects the previous decision's note about switching TO `PKDrawing.image(from:scale:)` — that approach is broken

---

### 2026-03-17 — Canvas zoom and rotation via RotatableCanvasContainer
**Context:** Users need to zoom in for detail work and rotate the canvas to draw at comfortable angles.
**Decision:** Wrap PKCanvasView in a RotatableCanvasContainer with a three-level view hierarchy: container (SwiftUI-managed, no transform) → transformView (receives combined CGAffineTransform for scale + rotation) → PKCanvasView (drawing only). Zoom and rotation are handled by UIPinchGestureRecognizer and UIRotationGestureRecognizer on the container, applied as a single combined transform on the intermediate view. UIKit automatically translates touch coordinates through the parent's transform, so drawing works at any scale/rotation.
**Alternatives considered:**
- SwiftUI `.rotationEffect()` — breaks touch coordinate mapping for UIViewRepresentable
- Transform on the UIViewRepresentable root view — SwiftUI re-layouts fight the transform, squishing the canvas
- PKCanvasView's built-in UIScrollView zoom — zooms content inside a fixed frame with scroll bars, not the whole canvas visually
- CALayer transform3D — undocumented interaction with PencilKit touch handling
**Consequences:**
- ~~Snapshot capture switched from `drawHierarchy` to `PKDrawing.image(from:scale:)` to capture full drawing regardless of visual transform~~ **REVERTED** — `PKDrawing.image()` produces blank output with transformed ancestors; switched back to `drawHierarchy` (see 2026-03-17 decision above)
- New file: `RotatableCanvasContainer.swift` in CanvasModule
- Rotation snaps to 90° increments when released within ~8° threshold; scale clamped to 0.5x–5x
- Reset button appears in toolbar when canvas is zoomed or rotated

---

### 2026-03-15 — Replace fal.ai with ComfyUI (Qwen-Image) on RunPod
**Context:** fal-ai/scribble (SD 1.5 ControlNet) produced low-fidelity results with limited control. Needed higher quality generation with better sketch adherence and a model that supports more control types.
**Decision:** Switch to Qwen-Image 20B (FP8) + InstantX ControlNet Union running on ComfyUI, hosted on a RunPod H100 80GB SXM GPU pod. Use AnyLine Lineart preprocessor for soft edge control from PencilKit sketches. Lightning LoRA V2.0 for 8-step generation.
**Alternatives considered:**
- Union DiffSynth LoRA (supports lineart/softedge but is a LoRA hack, less stable)
- DiffSynth Model Patches (only canny/depth/inpaint, no lineart)
- Keeping fal.ai with different models (limited model selection)
**Consequences:**
- Generation latency increased from ~4s to ~6-8s (but quality is dramatically higher)
- Backend now depends on RunPod pod availability (no auto-scaling yet)
- Workflow params (strength, steps, models) changed via ComfyUI web UI + re-export of API format template
- Cost model changed from per-image API pricing to per-hour GPU rental ($2.69/hr H100 SXM)

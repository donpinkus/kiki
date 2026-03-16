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

### 2026-03-17 — Canvas zoom and rotation via RotatableCanvasContainer
**Context:** Users need to zoom in for detail work and rotate the canvas to draw at comfortable angles.
**Decision:** Wrap PKCanvasView in a RotatableCanvasContainer UIView. Zoom is handled by PKCanvasView's built-in UIScrollView (1x–5x). Rotation is handled by a UIRotationGestureRecognizer on the container, applying a CGAffineTransform to the parent while PKCanvasView's internal zoom transforms stay independent. UIKit automatically translates touch coordinates through the parent's transform, so drawing works at any rotation/zoom.
**Alternatives considered:**
- SwiftUI `.rotationEffect()` — breaks touch coordinate mapping for UIViewRepresentable
- Direct transform on PKCanvasView — conflicts with UIScrollView's internal zoom transforms
- CALayer transform3D — undocumented interaction with PencilKit touch handling
**Consequences:**
- Snapshot capture switched from `drawHierarchy` to `PKDrawing.image(from:scale:)` to capture full drawing regardless of zoom/scroll state
- New file: `RotatableCanvasContainer.swift` in CanvasModule
- Rotation snaps to 90° increments when released within ~8° threshold
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

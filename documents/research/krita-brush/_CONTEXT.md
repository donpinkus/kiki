# Shared Research Context — Krita Brush Deep-Dive

**Read this first.** Every research agent on this task shares this grounding. Do not re-derive it.

## The goal

Kiki is an iPad sketch-to-image app with a custom **Metal** brush engine. We want to greatly
improve our brush dynamics by **deeply understanding Krita's** (open source, OpenGL/CPU)
approach and grounding every recommendation in Krita's actual source code.

**North star (decided by the product owner):** **Krita-grade superset.** Treat Krita as the
ceiling — aim for the most capable brush dynamics possible, even where that *exceeds* Procreate.
Procreate parity is a floor, not the target. We already have a Procreate-parity plan
(`documents/plans/unified-brush-engine.md`); this research is about what Krita does *better or
differently* that we should absorb.

**Krita is OpenGL/CPU; we are Metal.** That is irrelevant to understanding their *logic,
math, and architecture*. Translate concepts, not APIs. When Krita does something on CPU that
we'd do in a Metal shader, say so and explain the translation.

## The organizing constraint — our canvas feeds an img2img model

Kiki's canvas is **not the final artifact**. It is a conditioning image for
`fal-ai/flux-2/klein/realtime`, captured as a flattened JPEG at 1–10 FPS and re-rendered every
~250ms. This reframes leverage:

- **High leverage (model consumes it):** large-scale value structure, hue, saturation, edge
  hardness, stroke shape/direction, thick-vs-thin paint, color *mixing*.
- **Low leverage (model discards/resynthesizes it):** fine grain, paper tooth, PBR micro-detail,
  single-pixel burnt edges.
- **Felt-by-the-hand regardless of output:** wet drag, color pull, taper, stabilization. Tactile
  handling is half of "feels pro."

Always note, per Krita feature, whether its value is **model-leverage** (changes what klein sees)
or **hand-feel** (the artist feels it even if the model eats it) or **low-leverage** (model
overwrites it). Krita-grade capability is the goal, but leverage informs *priority*.

## Our current engine — the facts

Source: `ios/Packages/CanvasModule/` (Metal). Read `ios/Packages/CanvasModule/CLAUDE.md` for the
color pipeline + perf invariants (they are sacred). Key facts:

**`BrushConfig`** (`ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:63`) — flat struct, fields:
`color, baseWidth, opacity (per-stroke ceiling / Glaze cap), flow (per-dab deposit),
pressureGamma (single scalar pressure→width curve), tiltSensitivity, streamline (one-scalar
exponential smoothing), hardness, spacing (fraction of width), taper, wetEnabled, wetStrength
(Mix), wetPickup (Smear), shapeID`. Per-point input = `StrokePoint { position, force(0–1),
altitude(radians), timestamp }` — **no azimuth/tilt-direction, no barrel-roll, no velocity field
(derived from timestamp), no rotation.**

**Rendering model** (`CanvasRenderer.swift`, `MetalCanvasView.swift`):
- Dabs are **instanced stamp quads**; arc-length resample with adaptive spacing `width*0.3`.
- Dry path: stamp into an isolated **scratch** texture each frame (Glaze: self-overlap stays flat),
  composited onto the layer once at `touchesEnded`, scaled by per-stroke `opacity` ceiling.
- `flow` = per-stamp alpha (within-stroke build-up). `opacity` = per-stroke ceiling.
- Wet path (device-only, framebuffer-fetch RMW): **spectral Kubelka-Munk** pigment mixing
  (Mallett-Yuksel 7-basis, 36-band) + a CPU **carried-load smear** (per-dab 1×1 `getBytes` of the
  layer). Controls: Mix (`wetStrength`), Smear (`wetPickup`).
- Brush tip = one procedural soft circle `(1-r²)²` (64×64 R8) OR a grayscale PNG
  (`BrushShapeCatalog`: chalk/charcoal/drybrush/pastel/spray). `rotation` field is plumbed but
  fed 0 on round brushes; textured shapes orient to stroke direction.
- Eraser = direct-to-layer destination-out stamps. Undo = full-texture CPU snapshots, depth 30.
- Textures `.bgra8Unorm_srgb` → blend math is **linear-space for free**.

**Perf invariants (sacred):** <8ms/frame @ 120Hz; NEVER `drawHierarchy` or `waitUntilCompleted`
on the hot path; `.shared` textures + async commits; the only sanctioned `waitUntilCompleted` is
the once-per-stroke flatten.

**Our committed target architecture** — `documents/plans/unified-brush-engine.md` (READ IT). It
already designs a Procreate-parity unified pipeline: one isolated Stroke Accumulation Buffer (SAB)
per stroke, bound-source reads (belowTex/sabPrev/reservoir), a single non-branching dab fragment,
per-stroke PSO selection for Glaze/Build-up/erase, a nested `BrushDescriptor` mirroring Procreate
Brush Studio panels. **Your job is to find where Krita's design teaches us something this plan
misses, gets wrong, or under-specifies** — and where Krita exceeds Procreate's surface entirely.

Also relevant: `documents/plans/pro-brush-roadmap.md` (the per-feature phasing, superseded by the
unified doc but useful for rationale).

## Krita source — location and map

Cloned at **`~/krita_src`** (i.e. `/Users/donald/krita_src`). Full tree (not shallow). Key areas:

**Core brush engine** — `libs/image/brushengine/`:
- `kis_paint_information.cc/.h` (704 lines) — **KisPaintInformation**, Krita's per-point data
  (their `StrokePoint`). The set of input axes lives here. Read this to enumerate every sensor input.
- `kis_paintop.cc/.h` — paintop base class (paintAt / paintLine).
- `kis_paintop_settings`, `kis_paintop_preset` — preset/config model.
- `KisPerStrokeRandomSource`, `kis_stroke_random_source` — **deterministic RNG** (our replay-determinism trap).
- `KisStrokeSpeedMeasurer` — velocity estimation.

**Shared option / sensor / curve machinery** — `plugins/paintops/libpaintop/`:
- `KisCurveOption.cpp/.h` (+ `KisCurveOptionData*`) — **THE core abstraction: every brush
  parameter is a response curve driven by sensors.** This is the heart of "brush dynamics."
- `sensors/KisDynamicSensor*.cpp` + `KisDynamicSensorFactory*` — the sensor types: pressure,
  tilt/drawing-angle, speed/distance, fade, time, fuzzy(random), rotation, etc. `KisDynamicSensorIds.h`
  enumerates them.
- `KisFlowOpacityOption`, `KisColorOption`, `KisColorSourceOption`, `KisAirbrushOption`,
  `KisTextureOption`/`KisTextureMaskInfo`/`KisTextureOptionData`, `KisDarkenOption`, `KisHSVOption`.
- `KisDabCacheUtils.cpp/.h` — **dab caching** (Krita caches generated dab masks; huge perf lesson).
- `KisAutoBrushModel` — procedural brush tip model.

**Brush tips / masks** — `libs/brush/` + `libs/image/kis_*mask_generator*`:
- `kis_mask_generator.h`, `kis_curve_circle_mask_generator`, `kis_curve_rect_mask_generator`,
  `kis_gauss_rect_mask_generator`, `kis_rect_mask_generator` — **procedural tip mask math**
  (soft/gauss/curve, circle vs rect, our `(1-r²)²` is one point in this space).
- `libs/brush/KisBrushModel`, `KisBrushServerProvider` — predefined brush resources (GBR/GIH/PNG/ABR),
  brush server.

**The paintops (brush families)** — `plugins/paintops/`:
- `defaultpaintops/brush/` — **the pixel brush** (`kis_brushop.cpp`, 407 lines) + `KisDabRenderingExecutor`/
  `KisDabRenderingQueue`/`KisDabRenderingJob` (multithreaded dab rendering).
- `colorsmudge/` — **the smudge/wet engine.** `KisColorSmudgeStrategy*` (Lightness/Mask/Stamp/Overlay
  variants), `KisColorSmudgeSource`, `KisColorRateOption`, `KisPaintThicknessOption`,
  `KisColorSmudgeInterstrokeData`, `KisGradientOption`. Compare hard against our KM wet path.
- `hairy/` (bristle/sumi-e), `sketch/` (connecting lines), `spray/`, `particle/`, `deform/`,
  `mypaint/` (MyPaint engine integration), `curvebrush/`, `gridbrush/`, `hatching/`, `roundmarker/`,
  `filterop/`, `tangentnormal/` — idea-mining for brush families beyond Procreate's surface.

**Stabilization / smoothing (TOOL layer, not paintop)** — `libs/ui/tool/`:
- `kis_smoothing_options.cpp/.h` — the smoothing *modes*: None, Basic, Weighted, Stabilizer.
- `kis_tool_freehand_helper.cpp/.h` — where smoothing is applied to the incoming event stream.
- `kis_stabilized_events_sampler.cpp/.h` — the stabilizer/airbrush event resampling.

## Output conventions

- Write findings to `documents/research/krita-brush/`. Filenames assigned per task.
- **Citation discipline (mandatory, per repo CLAUDE.md "code beats docs"):**
  - Cite Krita as `krita: <path-relative-to-~/krita_src>:<line>` for every non-obvious claim.
  - Cite our code as `<path>:<line>`.
  - Distinguish **verified** (read the code) from **inferred** (pattern-matched / from a comment).
    Use explicit hedges. Do not state an inference in the same confident voice as a verified fact.
  - When a Krita comment and the code disagree, the code wins; say so.
- Use real markdown tables and `file:line` references (clickable).
- Each findings doc: aim for **a page or more** of substance per topic. Depth over breadth of prose.
- Always include, per topic: (1) How Krita does it (grounded, with math), (2) How we do it today,
  (3) Gap analysis + what a Krita-grade superset would adopt, (4) img2img leverage call,
  (5) Metal translation notes (perf invariants), (6) Open questions / risks.

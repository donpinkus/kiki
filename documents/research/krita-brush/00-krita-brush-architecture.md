# 00 — Krita Brush Engine: Architectural Spine

**Purpose.** This is the shared map for the 12 downstream Krita brush-research topics. It traces
the engine from the entrypoint (a paint event) to the layer, names every class and its
responsibility, and gives each one a Kiki analogue. Read `_CONTEXT.md` first for goal/leverage
framing. Everything here is **verified against Krita source** unless explicitly marked *(inferred)*.
Citations are `krita: <path-rel-to-~/krita_src>:<line>`.

---

## 1. The one-paragraph spine

A freehand tool collects pointer events into **`KisPaintInformation`** (per-point input bundle) and
calls **`KisPaintOp::paintLine(pi1, pi2)`** between consecutive points. `paintLine` walks the
segment in spacing-sized steps, building an interpolated `KisPaintInformation` at each step and
calling the paintop's virtual **`paintAt(info)`**. For the pixel brush (**`KisBrushOp`**),
`paintAt` runs every enabled **option** (size, ratio, rotation, opacity/flow, scatter, softness…) —
each option being a **`KisCurveOption`** that maps **sensors** (pressure, tilt, speed, fade, fuzzy…)
through a **response curve** to a scalar — and packages the result into a **`DabRequestInfo`**. That
request is pushed onto a **multithreaded dab-rendering queue** (`KisDabRenderingExecutor` →
`KisDabRenderingQueue` → concurrent `KisDabRenderingJob`s). Each job generates the **dab** (a small
`KisFixedPaintDevice` mask, colorized) on a worker thread, with a **cache** that skips regeneration
when consecutive dab parameters are identical. A separate, throttled **`doAsynchronousUpdate`** pass
pulls finished dabs off the queue and `bltFixed`-composites them onto the layer in parallel
non-overlapping rectangles. So: **event → paintInfo → paintLine spacing walk → paintAt → options/
curves/sensors → DabRequestInfo → async render queue → cached dab mask → parallel blit to layer.**

---

## 2. Data model — the seven nouns

| Noun | Krita class | What it is | `krita:` |
|---|---|---|---|
| **PaintInfo** | `KisPaintInformation` | Per-point input bundle: pos, pressure, xTilt, yTilt, rotation, tangentialPressure, perspective, time, speed (+ derived drawingAngle, drawingDistance, totalStrokeLength via a registered `KisDistanceInformation`). | `libs/image/brushengine/kis_paint_information.cc:87` |
| **PaintOp** | `KisPaintOp` (base); `KisBrushOp` (pixel brush) | The brush *engine*. Owns options + the dab executor; exposes `paintAt`/`paintLine`. One per active stroke. | `libs/image/brushengine/kis_paintop.cc:53`; `plugins/paintops/defaultpaintops/brush/kis_brushop.cpp:47` |
| **Settings** | `KisPaintOpSettings` | Flat key→value config (the serialized brush params) read by every option's constructor. | `libs/image/brushengine/kis_paintop_settings.cpp` |
| **Preset** | `KisPaintOpPreset` | A resource = a paintop id + its `KisPaintOpSettings` (the on-disk `.kpp` brush). Creates the live paintop via the registry. | `libs/image/brushengine/kis_paintop_preset.cpp:160,545` |
| **Option** | `KisCurveOption` (+ typed `KisStandardOption<Data>` aliases like `KisSizeOption`) | One tunable brush parameter, driven by a curve + sensors. `apply(info)` → scalar multiplier/offset. | `plugins/paintops/libpaintop/KisCurveOption.cpp:91`; `plugins/paintops/libpaintop/KisStandardOptions.h:27,45` |
| **Sensor** | `KisDynamicSensor` (subclasses: Pressure, Speed, Rotation, XTilt, Fade, Fuzzy, Distance, Time…) | Reads one axis from `KisPaintInformation`, normalizes to `[0,1]`, runs it through that sensor's curve. | `plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:35`; `…/KisDynamicSensors.h:14` |
| **Dab** | `KisFixedPaintDevice` (the mask) wrapped in `KisRenderedDab` | One stamp: a small colorized alpha-mask buffer + its offset/opacity/flow. The atomic unit composited to the layer. | `plugins/paintops/libpaintop/KisDabCacheUtils.cpp:45`; `KisRenderedDab.h` |

**Curve** = `KisCubicCurve`, sampled to a 256-entry transfer LUT (`floatTransfer(256)`,
`krita: …/sensors/KisDynamicSensor.cpp:42`). The identity curve is detected and skipped
(`m_curve = std::nullopt`, line 22) — a perf shortcut.

---

## 3. Call flow in prose (entrypoint → layer)

**(a) Event ingestion + smoothing (TOOL layer, not paintop).**
`KisToolFreehandHelper` consumes tablet events, applies the *smoothing mode* (None/Basic/Weighted/
Stabilizer — out of scope here, see topic on stabilization), and emits `paintLine` /
`paintBezierSegment` / `paintAt` calls between successive `KisPaintInformation` points
(`krita: libs/ui/tool/kis_tool_freehand_helper.cpp:159,624,706`). **Key:** smoothing is *upstream*
of the paintop — the brush engine never sees raw events.

**(b) Segment → dabs: the spacing walk.**
`KisPaintOp::paintLine` delegates to `KisPaintOpUtils::paintLine`
(`krita: libs/image/brushengine/kis_paintop.cc:139`), which steps along the segment at intervals set
by the `KisSpacingInformation` returned from the *previous* `paintAt`, building an interpolated
`KisPaintInformation` per step (`KisPaintInformation::mix`, `kis_paint_information.cc:569`) and
calling `paintAt`. Bézier flattening (`paintBezierCurve`, `kis_paintop.cc:98`) recursively subdivides
curved segments to straight `paintLine`s below a 0.5px flatness threshold. **Spacing is adaptive and
fed back per dab** — not a fixed fraction computed once.

**(c) `paintAt` — option evaluation (`KisBrushOp::paintAt`, `kis_brushop.cpp:103`).** For one dab:
1. `scale = m_sizeOption.apply(info)` → multiply by LoD scale; bail if too small (lines 115–117).
2. `rotation = m_rotationOption.apply(info)`, `ratio = m_ratioOption.apply(info)` → build `KisDabShape(scale, ratio, rotation)` (lines 119–122).
3. `cursorPos = m_scatterOption.apply(...)` — random position jitter (lines 123–126).
4. `m_opacityOption.apply(info, &dabOpacity, &dabFlow)` — splits into *opacity* (stroke ceiling) and *flow* (per-dab deposit) (line 131).
5. Pack into `KisDabCacheUtils::DabRequestInfo` (color, pos, shape, info, softness, lightnessStrength) (lines 133–138).
6. **`m_dabExecutor->addDab(request, dabOpacity, dabFlow)`** — hand off to the render queue (line 140).
7. Return a fresh `KisSpacingInformation` (line 143) — this drives the *next* spacing step in (b).

**(d) How an option produces its scalar (`KisCurveOption::computeValueComponents`,
`KisCurveOption.cpp:102`).** For each active sensor: `value = sensor->parameter(info)`
(raw axis → normalize → sensor curve LUT). Sensors are then combined into three buckets:
- **scaling** sensors (default, e.g. pressure) → combined by `m_curveMode`: multiply (default), add, max, min, or difference (lines 124–151);
- **additive** sensors (rotation, tilt-direction — `isAdditive()`);
- **absoluteRotation** sensors.

`sizeLikeValue()` (line 78) collapses these to `constant * offset * scaling * additive`, clamped to
`[strengthMin, strengthMax]`. `rotationLikeValue()` (line 61) handles the angular wrap case. The
per-sensor normalization is the actual dynamics math, e.g. pressure is raw `info.pressure()`
(`KisDynamicSensors.h:43`), tilt is `1 - |xTilt|/60` (line 63), rotation is `info.rotation()/180`
and additive (line 33). **This curve+sensor machine is the heart of Krita's brush dynamics** and the
single biggest thing our flat `BrushConfig` lacks — see §6.

**(e) Dab generation (`KisDabCacheUtils::generateDab`, `KisDabCacheUtils.cpp:45`).** On a worker
thread, depending on brush application mode: `IMAGESTAMP` → `brush->paintDevice(...)` (full RGBA
stamp); solid color → `brush->mask(dab, paintColor, shape, info, subPixel, softness, lightnessStrength)`
(procedural mask painted with the paint color); else colorize a `colorSourceDevice` then `brush->mask`
with it (gradient/pattern sources). Then optional mirror. **Postprocess** (`postProcessDab`, line 93)
applies the sharpness threshold and the texture/pattern overlay *after* the mask exists.

**(f) Compositing to the layer (`KisBrushOp::doAsynchronousUpdate`, `kis_brushop.cpp:207`).**
A throttled pass (period 10–100ms, self-tuning from measured dab render time, lines 220–351) calls
`takeReadyDabs` to pull completed dabs, computes their bounding rects, **splits them into
non-overlapping rectangles** (`KisPaintOpUtils::splitDabsIntoRects`, line 286), then issues one
**concurrent** `painter->bltFixed(rc, dabsQueue)` job per rect (lines 297–303). Mirroring adds more
parallel jobs (lines 311–321). A final *sequential* job reports dirty rects, records the average
opacity, and updates the adaptive timing (lines 323–363). **This is the layer write** — alpha-over
compositing of the dab masks into the paint device.

---

## 4. The multithreaded dab-rendering queue (the part our model has no equivalent for)

This is Krita's signature perf architecture and the most important structural difference from us.

- **`KisDabRenderingExecutor`** (`KisDabRenderingExecutor.cpp:23`) owns a `KisDabRenderingQueue` + a
  `KisRunnableStrokeJobsInterface` (Krita's thread pool). `addDab` enqueues a job and, **if the job
  needs work**, schedules a `CONCURRENT` `KisDabRenderingJobRunner` (lines 46–56).
- **`KisDabRenderingQueue::addDab`** (`KisDabRenderingQueue.cpp:127`) assigns a monotonic `seqNo`,
  asks the cache whether this dab can be reused, and classifies the job into one of three types
  (lines 150–173):
  - **`Dab`** — must be fully generated (cache miss). Runs concurrently.
  - **`Copy`** — identical to the previous Dab → just alias its device, **zero render cost**
    (`avgExecutionTime(0)`, line 170). This is the cache hit.
  - **`Postprocess`** — same mask but needs its own sharpness/texture pass on a copy.
- **`KisDabRenderingJobRunner::run`** (`KisDabRenderingJob.cpp:131`) executes a job on a worker,
  then `notifyJobFinished` resolves any dependent Copy/Postprocess jobs that were waiting on it
  (binary-searched by `seqNo`, lines 193–248). Copies complete instantly; postprocess jobs spawn
  more concurrent runners. Ordering is preserved by `seqNo` even though execution is parallel.
- **Back-pressure / adaptivity.** `doAsynchronousUpdate` limits how many dabs it drains per pass by
  dividing the max update period by measured per-dab time (`kis_brushop.cpp:225`), and shrinks the
  update period when the queue is backed up (line 349). So a slow brush degrades to fewer, larger
  composite passes rather than stalling the input thread.
- **Resource pooling.** `DabRenderingResources` (the per-thread brush clone + color source) is pooled
  via `fetchResourcesFromCache`/`putResourcesToCache` (`KisDabRenderingQueue.cpp:398`), and dab
  devices use a `PooledMemoryAllocator` (line 51) to avoid per-dab heap churn.

**The dab cache validity test** (`kis_dab_cache_base.cpp:279`): `shouldUseCache = hasDabInCache &&
brush->supportsCaching() && solidColorFill && newParams.compare(lastSavedParams, precisionLevel)`.
I.e. reuse the last mask **only** if the brush supports it, the fill is a solid color, and the
quantized dab parameters (size/shape/subpixel/softness/color/mirror) match the previous dab within a
size-dependent precision tolerance. Procedural round brushes at constant pressure hit this every
dab; pressure-varying strokes miss and regenerate. **This is the lesson for us:** Krita caches the
*generated mask*, keyed on quantized parameters, so a constant-width segment reuses one mask buffer.

---

## 5. How this maps onto / differs from our Metal scratch-then-flatten model

| Krita | Kiki (Metal) | Note |
|---|---|---|
| `KisPaintInformation` (9 axes + derived angle/dist/speed) | `StrokePoint { position, force, altitude, timestamp }` | We have ~3 axes. No azimuth/tilt-direction, no rotation, no per-point speed (we'd derive from timestamp). `DrawingEngine.swift:63` |
| `KisBrushOp` + options | `BrushConfig` flat struct | Krita = behavior (live evaluator); ours = static config. We have **no per-dab option evaluation pipeline**. |
| `KisCurveOption` + sensors + `KisCubicCurve` LUT | single `pressureGamma` scalar | The biggest gap: every Krita param is a *curve over a chosen sensor*; ours is one hardcoded pressure→width gamma. |
| `paintLine` adaptive spacing walk (spacing fed back per dab) | arc-length resample at `width*0.3` | Similar idea; ours is a fixed fraction, Krita's is per-dab via `KisSpacingInformation`. |
| `generateDab` → `KisFixedPaintDevice` mask, **cached** by quantized params | per-frame instanced stamp quads, **no mask cache** | We regenerate every stamp on GPU each frame; Krita generates once and reuses (CPU). Our GPU path makes regen cheap, so the cache lesson is *conditional* — but the *parameter-quantization key* idea is still useful for the wet/expensive paths. |
| Async render queue + parallel `bltFixed` into the layer | scratch texture each frame, **flatten once** at `touchesEnded` | Inverted. Krita writes the layer continuously in throttled async passes; we isolate the whole stroke in a scratch buffer and composite once (this is what gives us flat Glaze self-overlap for free). |
| `opacity` (stroke ceiling) vs `flow` (per-dab deposit) split | identical `opacity`/`flow` split | **Direct match** — Krita's `KisFlowOpacityOption` semantics are exactly our per-stroke ceiling vs per-dab alpha (`KisFlowOpacityOption.cpp:43`; ours `DrawingEngine.swift`). |
| CPU worker-thread dab rendering, thread pool, back-pressure | GPU fragment shader, 120Hz display link | Krita parallelizes on CPU because each dab is expensive; we get parallelism free on the GPU. Their *queue/seqNo/back-pressure* machinery is largely moot for us — but their **adaptive spacing**, **curve+sensor evaluation**, and **mask-parameter caching** are pure logic we can port. |

**The structural inversion to internalize:** Krita = *continuous async writes to the layer with an
isolated-original cache*; Kiki = *isolated scratch buffer per stroke, single flatten*. Our model is
actually cleaner for build-up/Glaze semantics. What Krita has that we don't is **(1) the
curve+sensor dynamics layer** between input and dab, and **(2) adaptive per-dab spacing**. Those are
the portable wins; the threading queue is a CPU-cost artifact we don't need.

---

## 6. img2img leverage call (for prioritization)

- **Curve+sensor dynamics** = **high model-leverage + hand-feel.** Pressure/speed/tilt curves change
  stroke shape, width, edge hardness, and direction — all things klein *sees*. This is the top
  prize from Krita.
- **Adaptive spacing / spacing-as-feedback** = mostly **hand-feel** (avoids beading at high pressure;
  the model resynthesizes fine spacing anyway), but cheap to adopt.
- **Dab mask cache** = **pure perf**, no visual leverage; only worth it on expensive (wet) paths.
- **Async parallel blit queue** = **no leverage for us** (GPU already parallel). Do not port.

---

## 7. Open questions / risks for downstream topics

1. **Deterministic RNG** (`KisPerStrokeRandomSource`, fuzzy sensors) — fuzzy sensors make a brush
   non-pure; `isRandom()` (`KisCurveOption.cpp:197`) flags it. Replay determinism is a trap if we
   adopt scatter/fuzzy. (Topic: sensors/randomness.)
2. **`curveMode` combination semantics** (multiply/add/max/min/difference, `KisCurveOption.cpp:128`)
   — when multiple sensors drive one option, the combine mode matters and is non-obvious. Verify per
   option which mode each preset ships.
3. **`KisDabShape` rotation vs our stroke-direction auto-orient** — Krita's rotation is an explicit
   additive sensor output (device rotation + drawing-angle + fuzzy), not auto-derived. (Topic:
   rotation/shape.)
4. **Precision/LoD** (`precisionOption`, `KisLodTransform`) — Krita renders dabs at reduced precision
   for large brushes and at lower LoD during fast strokes; we have a fixed 2048² doc. May or may not
   matter. *(inferred from naming + line 274; not traced end-to-end.)*
5. The **cache validity** `solidColorFill` requirement means gradient/texture/smudge brushes never
   cache masks — relevant when comparing the smudge engine. (Topic: smudge/wet.)

---

### Glossary (Krita class → role → our analogue)

| Krita class | Role | Kiki analogue |
|---|---|---|
| `KisPaintInformation` | per-point input bundle | `StrokePoint` (fewer axes) |
| `KisDistanceInformation` | running stroke state (angle, dist, spacing) | implicit in our resampler |
| `KisPaintOp` / `KisBrushOp` | brush engine; `paintAt`/`paintLine` | our stroke renderer in `CanvasRenderer` |
| `KisPaintOpSettings` | flat serialized config | `BrushConfig` |
| `KisPaintOpPreset` | preset resource (id + settings) | (no resource model yet) `shapeID` is closest |
| `KisCurveOption` / `KisStandardOption<>` | one param = curve over sensors | single scalar fields (`pressureGamma`, etc.) |
| `KisDynamicSensor` (+ subclasses) | one input axis → normalized → curve | (none — we read `force`/`altitude` directly) |
| `KisCubicCurve` | response curve, 256-LUT | `pressureGamma` (one scalar) |
| `KisDabShape` | scale + ratio + rotation per dab | per-stamp size + (stubbed) rotation |
| `KisFixedPaintDevice` / `KisRenderedDab` | the dab mask + offset/opacity/flow | instanced `StampInstance` |
| `KisDabRenderingExecutor`/`Queue`/`Job` | multithreaded dab render + cache | (none — GPU fragment shader) |
| `KisDabRenderingQueueCache` / `kis_dab_cache_base` | mask cache keyed on quantized params | (none — regen per frame) |
| `KisFlowOpacityOption` | opacity (ceiling) vs flow (deposit) split | `opacity` / `flow` (direct match) |
| `KisToolFreehandHelper` | event ingest + smoothing, upstream of paintop | our touch handler + streamline |
| `doAsynchronousUpdate` + `bltFixed` | throttled parallel composite to layer | scratch-then-flatten at `touchesEnded` |

# Stabilization / Input Smoothing — Krita vs. Kiki

**Topic:** Input smoothing at the *tool layer* (upstream of paintop / stamp generation).
**Scope:** Krita's `KisSmoothingOptions` modes (None, Basic, Weighted, Stabilizer, Pixel-Perfect)
and the math behind each; how Kiki's single-scalar `streamline` compares; what a Krita-grade
superset adopts; img2img leverage; Metal/perf translation.

**Citation discipline:** `krita: <path-relative-to-~/krita_src>:<line>` for Krita,
`<path>:<line>` for ours. **Verified** = I read the code. **Inferred** = pattern-matched or
from a comment. Code wins over comments.

---

## 1. How Krita does it (grounded)

### 1.1 The architecture: smoothing is a *tool-layer* transform, not a paintop concern

Krita splits responsibility cleanly: the **paintop** (`KisBrushOp` etc.) consumes a stream of
`KisPaintInformation` points and renders dabs; the **tool** (`KisToolFreehandHelper`) is what
*conditions* the raw event stream into that point stream. All smoothing lives in the tool. The
paintop never knows whether the points it receives were smoothed (verified — smoothing is applied
entirely inside `KisToolFreehandHelper::paint`, which then calls `paintLine` / `paintBezierCurve`
into the stroke; `krita: libs/ui/tool/kis_tool_freehand_helper.cpp:492`).

Config is a flat set of fields on `KisSmoothingOptions` (verified —
`krita: libs/ui/tool/kis_smoothing_options.h:36`):

| Field | Default | Used by |
|---|---|---|
| `smoothingType` | `WEIGHTED_SMOOTHING` (=2) | mode selector |
| `smoothnessDistanceMin` | 50.0 | Weighted (σ), Stabilizer (sample count) |
| `smoothnessDistanceMax` | 50.0 | Weighted (σ), Stabilizer (sample count) |
| `smoothnessDistanceKeepAspectRatio` | true | distance scaling |
| `tailAggressiveness` | 0.15 | Weighted only (stroke-end pressure) |
| `smoothPressure` | false | Weighted only |
| `useScalableDistance` | true | zoom-invariance toggle |
| `delayDistance` | 50.0 | Stabilizer "dead zone" radius |
| `useDelayDistance` | true | Stabilizer dead-zone enable |
| `finishStabilizedCurve` | true | Stabilizer flush-on-lift |
| `stabilizeSensors` | true | Stabilizer: average pressure/tilt too |

Defaults verified at `krita: libs/ui/kis_config.cc:2194-2302`. Note **default mode is Weighted**
(`lineSmoothingType` default `1`; the enum is `NO=0, SIMPLE=1, WEIGHTED=2, STABILIZER=3,
PIXEL_PERFECT=4` — `krita: libs/ui/tool/kis_smoothing_options.h:20`). **Caveat (inferred):** the
config returns `1` but the enum value `1` is `SIMPLE_SMOOTHING`, so Krita's *factory default* is
actually **Basic/Simple**, not Weighted, despite Weighted being the popular choice. Code wins:
default is `SIMPLE_SMOOTHING`.

### 1.2 NO_SMOOTHING

Straight passthrough: `paintLine(previousPaintInformation, info)` — connect raw event to raw
event with a line (verified — `krita: libs/ui/tool/kis_tool_freehand_helper.cpp:640-642`). The
paintop's own `paintLine` does adaptive-spacing dab interpolation along that segment.

### 1.3 SIMPLE_SMOOTHING ("Basic") — Bézier tangent fitting, no positional averaging

Basic does **not** move any sample. It fits a **Catmull-Rom-style cubic Bézier** through the raw
samples so the *path between* samples is curved instead of a polyline. Mechanism (verified):

- Maintain `previousTangent`; compute `newTangent = (info.pos - olderPaintInformation.pos) / Δt`
  (`krita: libs/ui/tool/kis_tool_freehand_helper.cpp:619`). The tangent is a velocity vector
  (distance over time).
- `paintBezierSegment(older, previous, prevTangent, newTangent)` derives two control points from
  the tangents and emits a cubic Bézier (`krita: ...:626, :375`).
- Control-point placement is velocity-aware: `coeff = 0.8` base, reduced when the two tangents'
  speeds are *symmetric* to avoid corner-rounding artifacts; the faster side gets a longer control
  arm (verified — the `similarity = qMin(v1/v2, v2/v1)`, clamped ≥0.5, then
  `coeff *= 1 - max(0, similarity - 0.8)` block at `krita: ...:434-457`).

So Basic = **interpolation smoothing** (smooths the *curve between* points), zero lag, no input
displacement. It cannot fix jitter *in* the samples themselves.

### 1.4 WEIGHTED_SMOOTHING — Gaussian-over-arc-length positional average (the workhorse)

This is the one most artists mean by "stabilization slider." It is a **causal (backward-looking)
Gaussian-weighted average of recent sample positions**, weighted by **accumulated arc-length
distance**, not by time. The header comment says it's a modified GIMP/StreamLine algorithm; the
key deviation is distance-instead-of-velocity because "time measurements are too unstable in
realworld environment" (verified — `krita: libs/ui/tool/kis_tool_freehand_helper.cpp:494-512`).

The math (verified, `krita: ...:516-607`), per incoming `info`:

1. Append raw position to `history`; append the **distance from the previous sample** to a
   parallel `distanceHistory` (`...:530-534`).
2. Only engage once `history.size() > 3` (`...:539`).
3. `sigma = effectiveSmoothnessDistance(speed) / 3.0` — the distance slider is interpreted as the
   **3σ range** of a Gaussian (`...:540`). `effectiveSmoothnessDistance` lerps between max (slow)
   and min (fast): `(1-speed)·distMax + speed·distMin` (verified —
   `krita: ...:465-479`). So **the faster you draw, the smaller σ → less smoothing** — this is
   how fast strokes stay responsive and slow strokes get heavily steadied.
4. Walk `history` newest→oldest, accumulating `distanceSum`; each sample's weight is the Gaussian
   `gaussianWeight · exp(−distanceSum² / (2σ²))` (`...:570-573`). Position is the
   weight-normalized centroid: `x = Σ(rate·xᵢ)/Σrate` (`...:581-597`).
5. **Early-out:** if the running weight drops to <1% of the first sample's (`baseRate/rate > 100`),
   stop walking — the tail contributes nothing (`...:575-579`). This is what makes it
   *automatically bounded* — no fixed window size; the window self-sizes to ~3σ of arc length.
6. **Tail aggressiveness** (stroke-end taper): when pressure is *rising* between consecutive samples
   (`pressureGrad > 0`), inflate that sample's effective distance by
   `40·tailAggressiveness·(1−pressure)·3σ` (`...:562-567`). This pushes rising-pressure points
   *out* of the Gaussian window, so the smoothed position lags less at the start of a press —
   tightening stroke ends/tapers. Comment claims it controls "the end of the stroke"; the *code*
   keys on rising pressure gradient, which is the *start* of a press — verified, **code wins**: it's
   a pressure-onset bias, branded as tail control.
7. Optional `smoothPressure`: same Gaussian weights also average pressure (`...:585-587, 594`).

After computing the smoothed position it **rewrites `history.last()`** so the smoothing is
recursive over already-smoothed points (`...:604`). Then it falls through to the **same Bézier
tangent fit as Basic** (`...:609-638`) — Weighted = positional Gaussian *plus* Bézier interpolation.

**Key property:** lag is inherent — the centroid of the last ~3σ of travel trails the true cursor
by roughly σ of arc length. Bigger slider = steadier + laggier. This is the latency/smoothness
tradeoff made explicit in distance units.

### 1.5 STABILIZER — the "rope/string-pull" model

A fundamentally different mechanism: instead of weighting the *past samples*, it drags a
**fixed-length FIFO queue** behind the cursor and paints the **uniform average** of the queue.
This is the "rope" / "lazy mouse" / "pulled string" feel. Lifecycle (verified):

- **Start** (`stabilizerStart`, `krita: ...:776-802`): queue length =
  `qMax(3, round(effectiveSmoothnessDistance(speed)))` — here the distance slider is reinterpreted
  as a **sample count** (the comment even flags "this is no a 'distance' in any way",
  `...:779`). Prefill the deque with the first point repeated N times.
- **Per-event** (`paint`, `...:687-693`): push the raw event into a `KisStabilizedEventsSampler`
  (a time-resampler, see below). Do **not** paint here directly.
- **Poll-and-paint** on a timer (`stabilizerPollTimer`, interval = `stabilizerSampleSize` ms;
  default verified at `krita: libs/ui/kis_config.cc:2685-2694`). Each tick
  (`stabilizerPollAndPaint`, `...:852-912`):
  - Pull resampled events from the sampler.
  - **Delay distance / dead zone:** if `useDelayDistance`, a sampled point within radius
    `R = delayDistance / zoom` of the last painted point is **not painted** (`canPaint=false`) —
    the brush doesn't move until the cursor escapes a small circle. This kills micro-jitter while
    stationary and lets you "wind up" before a stroke. The dead-zone circle is even drawn in the
    outline (`...:864-879, :244-247`).
  - **Average:** `getStabilizedPaintInfo` builds the painted point as the **uniform mean of the
    whole deque** — `k = (i-1)/i` running-average coefficient (`...:832-846`). If
    `stabilizeSensors` is on it averages pressure/tilt/rotation too (`mixOtherWithoutTime`,
    `krita: libs/image/brushengine/kis_paint_information.cc:597`); otherwise only position
    (`mixOtherOnlyPosition`, `...:591`). Rotation is averaged via shortest-angular-distance, not
    naive lerp (`...:625-631`) — verified, matters for tilt/rotation brushes.
  - Then dequeue oldest, enqueue the new sample → the rope advances one link.
- **Deceleration / catch-up:** the `KisStabilizedEventsSampler` decouples input rate from paint
  rate. `range()` computes `elapsed = (timeSinceLastPaint)/sampleTime` and
  `alpha = realEvents.size()/elapsed`, then the iterator **resamples** real events to exactly
  `elapsed` output samples via `realEvents[floor(alpha·index)]` (verified —
  `krita: libs/ui/tool/kis_stabilized_events_sampler.cpp:68-85`). This produces a *constant
  paint cadence* regardless of how fast/slow events arrive — the rope decelerates smoothly into
  a stop instead of snapping.
- **Finish line** (`finishStabilizedCurve`, `stabilizerEnd`, `...:914-933`): on lift, if enabled,
  it injects a synthetic finishing event with a time-override equal to the deque size and polls
  again, **draining the queue** so the painted line catches all the way up to where you lifted.
  Without this the stroke would end short by the rope length.
- **Delayed paint helper** (`KisStabilizerDelayedPaintHelper`,
  `krita: libs/ui/tool/KisStabilizerDelayedPaintHelper.cpp`): an *optional* second stage
  (`stabilizerDelayedPaint` config) that buffers painted segments for a fixed 20 ms and replays
  them on a timer so the rendered line animates in smoothly behind the cursor rather than
  appearing in poll-sized chunks (verified — `fixedPaintTimerInterval = 20`, `...:9, :45-57`).
  This is purely a *render-smoothness* nicety, not a geometry change.

### 1.6 PIXEL_PERFECT — staircase removal (not relevant to us)

Holds a "tentative" pixel; if the next sample is within 1px (a diagonal jag), it stashes rather
than commits, then flushes once movement leaves the 1px neighborhood (verified —
`krita: ...:644-685`). This is a **pixel-art** mode (removes single-pixel staircase corners),
irrelevant to a 2048² antialiased img2img canvas.

### 1.7 Scalable distance & zoom-invariance

`useScalableDistance` divides the distance by `effectiveZoom` so "50px of smoothing" means 50
*document* px regardless of view zoom (verified — `effectiveSmoothnessDistance`,
`krita: ...:465-479`). The Stabilizer **inverts** the meaning (it counts samples, not distance)
and is **forced** to scalable-on (`krita: libs/ui/tool/kis_smoothing_options.cpp:123-136`, with a
`KIS_SAFE_ASSERT` guarding against turning it off — bug 421314).

### 1.8 Speed estimation (feeds Weighted's adaptive σ)

`drawingSpeed()` is precomputed per-point and read by Weighted (`...:540`). It is **not** raw Δpos/Δt:
`KisSpeedSmoother` ignores tablet timestamps (deemed unreliable), estimates the tablet's *sample
rate* via a filtered rolling mean of inter-event time, and divides accumulated distance over the
last ≥3 samples / ≥5px by that estimated cadence (verified —
`krita: libs/ui/tool/kis_speed_smoother.cpp:107-166`). The takeaway: **Krita treats event
timestamps as noise and derives velocity from a smoothed sample-rate model.** This is a direct,
load-bearing lesson for us (see §6).

---

## 2. How Kiki does it today

We have **one mode, one scalar**: `BrushConfig.streamline` (0–1)
(`ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:82`). It is a **lagged-anchor
exponential smoothing (EMA)** of position only:

```
factor   = max(1 - streamline·0.9, 0.08)         // 1 = follow exactly; small = heavy lag
smoothed = prev + (raw - prev)·factor
```

Verified — `ios/Packages/CanvasModule/Sources/CanvasModule/MetalCanvasView.swift:2587-2604`. The
cursor is seeded at touch start so the first point isn't lagged
(`MetalCanvasView.swift:503-504`). It is applied to **every coalesced touch** as points are
appended (`MetalCanvasView.swift:618-622`), and **only `position`** is smoothed — pressure,
altitude, timestamp pass through raw (verified — comment + code,
`MetalCanvasView.swift:2586, :2602`). The smoothed point is baked into the stored stroke so live
preview, replay, undo, and persistence agree (verified — `MetalCanvasView.swift:2584-2585`).

Downstream, the stamp generator arc-length resamples the (already-smoothed) polyline with adaptive
spacing `max(width·0.3, 0.5)` (per CanvasModule/CLAUDE.md; verified spacing constant in the
roadmap and module doc). **There is no curve interpolation** — we resample a polyline, so between
two smoothed anchors the path is straight. **There is no velocity field** (timestamp is carried but
unused for dynamics), no adaptive smoothing strength, no pressure smoothing, no dead-zone, no
catch-up-on-lift, no zoom-invariance term.

| Property | Kiki today | Krita |
|---|---|---|
| Modes | 1 (EMA) | 5 |
| Filter type | first-order EMA (IIR, infinite tail) | Gaussian-over-arc-length (FIR, self-bounded) + Bézier; or rope-average |
| Weighting domain | per-event (frame-rate dependent) | arc-length distance (frame-rate independent) |
| Adaptive to speed | no | yes (σ shrinks with speed) |
| Smooths pressure/tilt | no (position only) | optional (Weighted `smoothPressure`, Stabilizer `stabilizeSensors`) |
| Curve interpolation between anchors | no (polyline) | yes (velocity-aware cubic Bézier) |
| Dead-zone | no | yes (Stabilizer delayDistance) |
| Catch-up on lift | no | yes (finishStabilizedCurve) |
| Zoom-invariant | no | yes (scalableDistance) |

---

## 3. Gap analysis — what a Krita-grade superset adopts

Ranked by value (leverage × hand-feel), with the cheapest high-value wins first.

**A. Replace per-event EMA with arc-length-weighted smoothing (HIGH).** Our EMA is *frame-rate
dependent*: at 120 Hz with dense coalesced touches it smooths far harder than at 60 Hz, and a
fast flick and a slow crawl get the *same* `factor`. Krita's two innovations fix both: (1) weight
by **accumulated distance**, not events, so behavior is identical regardless of sample density;
(2) make σ **speed-adaptive** (`(1-speed)·max + speed·min`) so fast strokes stay responsive and
slow strokes get steadied. This is the single biggest correctness gap and it's pure CPU upstream.

**B. Add Bézier interpolation between anchors (MEDIUM-HIGH, img2img-relevant).** We feed a polyline
to the stamp resampler; corners are faceted. Krita's velocity-aware cubic Bézier
(`paintBezierSegment`) gives genuinely curved paths between anchors. Because klein *sees stroke
shape* (edges, curvature), faceted vs. smooth curves change the conditioning image. This is the
clearest model-leverage item in this topic.

**C. Add a Stabilizer ("rope") mode (MEDIUM, hand-feel).** Distinct from Weighted: the
fixed-length-queue average + dead-zone gives the heavy "lazy-mouse" feel pros use for inking long
confident curves. It's a different tool, not a stronger slider. Worth it for the superset, but
lower priority than A/B because the *output* differs little from heavy Weighted — its value is
hand-feel.

**D. Optionally smooth pressure/tilt, not just position (MEDIUM, img2img-relevant via width).**
Krita's `smoothPressure` / `stabilizeSensors`. Pressure jitter → width jitter → wobbly stroke
*thickness*, which klein sees (thick-vs-thin paint is high-leverage). We smooth position but leave
pressure raw, so a steady-looking line can still have ragged width. Make it a toggle.

**E. Catch-up-on-lift (LOW-MEDIUM, hand-feel + correctness).** Any lag-based smoother ends the
stroke *short* of where you lifted. Krita's `finishStabilizedCurve` drains the buffer to the true
endpoint. With our EMA + `factor≥0.08` we *mostly* converge, but a heavy-streamline stroke visibly
ends short. A superset flushes the remaining lag to the true last raw point on `touchesEnded`.

**F. Speed from a smoothed sample-rate model, not raw timestamps (MEDIUM, enabling).** Krita
explicitly distrusts event timestamps and derives velocity from an estimated tablet cadence
(`KisSpeedSmoother`). We don't compute velocity at all yet. Any of A/D that needs speed should use
this approach rather than raw `Δt` from `UITouch.timestamp` — Pencil timestamps are regular but
coalesced-touch timestamps and the 120 Hz/predicted-touch mix make raw Δt noisy.

**G. Dead-zone / delay-distance (LOW, hand-feel).** Nice for inking; low priority. Cheap to add
once we have a distance accumulator (it's just "don't emit until cursor escapes radius R").

**Out of scope:** Pixel-Perfect (pixel-art only — our canvas is antialiased 2048²). Krita's
LoD/buddy-stroke distance hacks (`buddyDragDistance`, `...:212-227`) are an internal
level-of-detail artifact, irrelevant.

---

## 4. img2img leverage call

**Overall: HIGH** — this topic changes stroke *geometry*, which is exactly what klein conditions on.

- **Stroke path shape (B, Bézier):** HIGH leverage. Klein resynthesizes from the conditioning JPEG;
  smooth vs. faceted curves are visible large-scale structure. A wobbly hand-drawn line vs. a clean
  confident curve produces materially different generations.
- **Width/thickness stability (D, pressure smoothing):** HIGH leverage — thick-vs-thin paint is
  explicitly called out as model-consumed in `_CONTEXT.md`. Jittery width reads as a different mark.
- **Heavy steadying (A, C):** MEDIUM-HIGH leverage *and* high hand-feel. A steadier line is a
  cleaner edge for the model, and stabilization is explicitly listed as "felt-by-the-hand
  regardless of output" — it's half of "feels pro."
- **Dead-zone / catch-up (E, G):** mostly HAND-FEEL; small geometry effect at stroke ends.

Net: stabilization is one of the **highest-leverage** brush-feel investments because it sits
*upstream of the JPEG* and shapes the very lines klein sees. Prioritize A and B.

---

## 5. Metal translation notes (perf invariants respected)

All of this is **CPU, upstream of the GPU**, in the touch-handling path
(`MetalCanvasView.touchesMoved`). **None of it touches the Metal hot path** — no new passes, no
`waitUntilCompleted`, no `drawHierarchy`. The cost is a small per-event CPU computation; the budget
concern is the <8ms/frame *total*, and these are O(window) float ops per coalesced touch.

- **Arc-length Gaussian (A):** keep a ring buffer of recent `(position, segmentDistance)`. Per new
  point, walk newest→oldest accumulating distance, apply Krita's `baseRate/rate > 100` early-out so
  the window self-bounds to ~3σ (verified bound, `krita: ...:577`). With σ≈50px and brush spacing,
  the window is a few dozen points worst case — sub-microsecond. **Do not** use an unbounded
  history; cap it (Krita's `history` grows per stroke but the early-out makes the *loop* bounded —
  we should additionally cap stored history to ~256 to avoid unbounded growth on long strokes,
  mirroring `KisSpeedSmoother`'s `MAX_SMOOTH_HISTORY=512`, `krita: kis_speed_smoother.cpp:17`).
- **Bézier (B):** we currently emit a polyline into the stamp resampler. Translation: keep the
  Bézier fit on CPU (compute control points exactly as `paintBezierSegment`), then **flatten the
  cubic to line segments at our existing arc-length spacing** before stamping — i.e. the resampler
  walks the Bézier instead of the chord. No shader change; the stamp instancing is unchanged.
- **Speed model (F):** port `KisSpeedSmoother`'s filtered-mean-cadence approach. Cheap scalar math;
  store `lastSpeed` on the active stroke. Avoid trusting `UITouch.timestamp` deltas directly.
- **Determinism trap:** smoothing is baked into stored points
  (`MetalCanvasView.swift:2584-2585`), so replay/undo already see smoothed geometry — good. Any new
  mode (especially the timer-driven Stabilizer) must **not** introduce wall-clock or RNG into the
  *geometry*, or replay diverges. The Stabilizer's `KisStabilizedEventsSampler` uses real elapsed
  time for *cadence*; if we port it we must record the emitted points, not re-derive them on
  replay. Easiest safe path: ship A/B/D/E (all deterministic from the event stream) first; defer
  the timer-driven rope (C) or make it record-and-replay its emitted points.
- **No `waitUntilCompleted` regressions:** these changes never read back a texture, so the color
  pipeline and the once-per-stroke flatten are untouched.

---

## 6. Open questions / risks

1. **Default mode for Kiki.** Krita's factory default is Basic (code: `lineSmoothingType` returns
   `1` = `SIMPLE_SMOOTHING`), but Weighted is what artists turn on. For an Apple Pencil + img2img
   app, **Weighted-equivalent (A+B) should likely be the default** with a single user-facing
   "Stabilization" slider mapping to σ. Confirm with on-device feel.
2. **Slider mapping.** Our `streamline` is 0–1; Krita's distance is in px (default 50, 3σ). Decide
   the curve from `streamline` → σ-in-document-px. Must be zoom-aware (scalableDistance) or heavy
   smoothing will feel different at different canvas zooms.
3. **Coalesced + predicted touches.** iOS gives coalesced (high-rate) and predicted touches. Krita
   has no equivalent. Risk: feeding predicted touches into a recursive smoother then replacing them
   on the real event could double-count distance. Decide explicitly whether predicted touches enter
   the smoother (probably **no** — smooth only confirmed coalesced touches).
4. **Latency budget for img2img.** Heavy stabilization adds lag; the frame is captured every ~250ms
   for klein. A laggy *on-screen* line that the user has already moved past could be captured
   mid-lag, sending klein a shorter line than drawn. The catch-up-on-lift (E) mitigates the
   *final* state, but mid-stroke captures see the lagged line. Likely fine (klein re-renders
   continuously), but worth a deliberate call: do we cap max σ lower than Krita's because our
   canvas is a *live conditioning feed*, not a final artifact?
5. **Tail-aggressiveness semantics.** Krita's `tailAggressiveness` keys on *rising* pressure (code),
   not stroke end (comment). If we port it, port the **code** behavior (pressure-onset bias) and
   rename it honestly, or skip it — it's a minor refinement and the misleading name has caused
   confusion even in Krita.
6. **Stabilizer determinism (see §5).** The rope mode's timer-driven catch-up is the one piece that
   fights our replay-determinism requirement. Either record emitted points or defer the mode.

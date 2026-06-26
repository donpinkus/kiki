# 04 — Dab Spacing, Placement, Dab Caching, and Airbrush (timed dabs)

**Scope.** How Krita decides *where* and *when* to drop a dab along a stroke: distance-based vs
time-based spacing, the spacing sensors/feedback loop, isotropic vs anisotropic (elliptical)
spacing, auto-spacing, the airbrush rate timer, and the dab-mask cache as a perf strategy. Then
where Kiki sits today (hardcoded arc-length resample at `width*0.3`), what a Krita-grade superset
adopts, the img2img leverage call, and the Metal translation respecting our `<8ms` invariant.

Read `_CONTEXT.md` + `00-krita-brush-architecture.md` first. Everything below is **verified against
Krita source** unless explicitly marked *(inferred)*. Citations are `krita: <path-rel-to-~/krita_src>:<line>`
and `<path>:<line>` for our code.

---

## 1. How Krita does it (grounded)

### 1.1 Two independent spacing axes: distance and time, combined by `min`

Krita runs **two parallel spacing decisions** and paints a dab when *either* fires first. This is the
single most important structural fact, and it is what unifies "normal brush" and "airbrush" into one
mechanism.

`KisDistanceInformation::getNextPointPosition(start, end, startTime, endTime)` returns an
interpolation factor `t ∈ [0,1]` (the fraction along the current segment where the next dab lands),
or `-1` meaning "no dab on this segment yet." It computes a **distance factor** and a **time factor**
independently and returns whichever is smaller (earliest):

```
distanceFactor = isIsotropic ? getNextPointPositionIsotropic(...) : getNextPointPositionAnisotropic(...)
timeFactor     = getNextPointPositionTimed(startTime, endTime)            // only if timed spacing enabled
t = (both valid) ? min(distanceFactor, timeFactor) : whichever ≥ 0
```

`krita: libs/image/kis_distance_information.cpp:405-448`. The `min` is the airbrush-meets-motion
rule: a moving airbrush stamps on whichever threshold (distance traveled OR time elapsed) trips
first.

When **no** dab is due (`t < 0`), it *accumulates* the elapsed time toward two separate update
intervals (`timeSinceSpacingUpdate`, `timeSinceTimingUpdate`, `krita:…:437-438`); when a dab *is*
due it resets those accumulators (`:443-444`). This is the hook that lets spacing/timing be
**re-evaluated mid-segment even when no dab is painted** — see §1.5.

### 1.2 Distance spacing — isotropic (the common case)

`getNextPointPositionIsotropic` (`krita: libs/image/kis_distance_information.cpp:460-490`):

```
spacing          = max(MIN_DISTANCE_SPACING, distanceSpacing.x())   // px
nextPointDistance = spacing - accumDistance.x                       // remaining gap
if nextPointDistance <= 0:        t = 0   (paint immediately; reset accum)   // spacing shrank since last
elif nextPointDistance <= |end-start|: t = nextPointDistance / |end-start|; reset accum
else:    t = -1; accumDistance.x += |end-start|                     // not enough travel yet, bank it
```

This is a running arc-length accumulator: distance is banked across segments until it reaches the
spacing threshold, then a dab is emitted at the exact fractional position and the accumulator resets.
**Conceptually identical to our `traveled`/`leftover` loop** (`MetalCanvasView.swift:2400-2436`) —
but Krita keeps the accumulator in a persistent `KisDistanceInformation` object that survives across
`paintLine` calls, where we persist `lastStampPos`/`lastEraserSpacing`/`lastWetSpacing` on the view.

### 1.3 Distance spacing — anisotropic (elliptical) spacing

When the dab is non-circular (`ratio != 1`, or rotated), spacing becomes an **ellipse** so dabs are
denser across the thin axis and sparser along the long axis. `getNextPointPositionAnisotropic`
(`krita: libs/image/kis_distance_information.cpp:492-555`) solves a quadratic for where the drag
vector crosses the spacing ellipse:

```
a_rev = 1/spacing.x ; b_rev = 1/spacing.y
gamma = (x·a_rev)² + (y·b_rev)² − 1          // x,y = accumulated distance components
if gamma ≥ 0: paint immediately (already outside ellipse)
// rotate drag vector into ellipse frame (krita:…:524-530), then solve:
alpha = (dx·a_rev)² + (dy·b_rev)²
beta  = x·dx·a_rev² + y·dy·b_rev²
D/4   = beta² − alpha·gamma
k     = (−beta + sqrt(D/4)) / alpha          // crossing fraction
t = (0 ≤ k ≤ 1) ? k : -1
```

This is genuinely more sophisticated than anything Kiki has: spacing is a **rotated ellipse keyed to
the dab shape**, not a scalar fraction of width. We don't have elliptical brushes yet, so it's
forward-looking, but it's the correct model the moment we ship a `ratio`/chisel brush.

### 1.4 The spacing value itself: `effectiveSpacing` + auto-spacing

`KisPaintOpUtils::effectiveSpacing` (`krita: libs/image/brushengine/kis_paintop_utils.cpp:18-45`)
turns dab dimensions into the spacing distance:

- **Manual spacing:** `spacing = dabDimension * spacingVal` (where `spacingVal` is the user's spacing
  slider, our `brush.spacing`). For isotropic, `dabDimension = max(width,height)`.
- **Auto-spacing:** `spacing = coeff * (v < 1 ? v : sqrt(v))` per axis
  (`calcAutoSpacing`, `krita: libs/image/brushengine/kis_paintop_utils.h:162-173`). The `sqrt`
  compresses spacing for large brushes — a 400px brush doesn't get a 200px gap; it gets
  `coeff·sqrt(400)≈coeff·20`. This keeps big brushes from going sparse-and-beady while keeping small
  brushes tight. **We have no equivalent;** our gap is strictly linear in width (`width * 0.3`), so
  large brushes get proportionally large gaps.
- Then `spacing *= extraScale`, where `extraScale` comes from the **Spacing sensor** (pressure/etc.).

### 1.5 Spacing is a SENSOR (a `KisCurveOption`), re-evaluated per dab and mid-segment

`extraScale` above is the output of `KisSpacingOption::apply(pi)`
(`krita: plugins/paintops/libpaintop/kis_paintop_plugin_utils.h:59-62`) — i.e. spacing is itself a
full curve-over-sensors option. So spacing can be driven by pressure, speed, tilt, fade, etc. via the
same machinery as size/opacity (the `KisCurveOption` layer documented in topic 00 §2). This is the
"spacing sensors" the task asks about: **there is no separate spacing-sensor type; spacing reuses the
generic curve+sensor stack.** Verified: `KisBrushOp::paintAt` calls
`effectiveSpacing(scale, rotation, &m_airbrushData, &m_spacingOption, info)` and returns it as the
`KisSpacingInformation` that drives the *next* segment's walk (`krita: …/brush/kis_brushop.cpp:143-149`).

Critically, the spacing is **fed back per dab**: `paintAt` returns a fresh `KisSpacingInformation`,
`paintLine` stores it in `currentDistance`, and the *next* `getNextPointPosition` uses it. So if
pressure rises through a stroke, the spacing tightens dab-by-dab. Beyond that, when a long segment
passes with *no* dab, `paintLine` checks `needsSpacingUpdate()` (true once
`timeSinceSpacingUpdate ≥ SPACING_UPDATE_INTERVAL = 50ms`) and calls `op.updateSpacing(pi2, dist)` to
re-evaluate spacing **mid-segment without painting** (`krita: …/kis_paintop_utils.h:97-102`;
interval `krita: libs/ui/tool/kis_tool_freehand_helper.cpp:51`). This matters for a slow-moving
pressure ramp where you'd otherwise hold a stale spacing for a long time.

### 1.6 Time-based spacing and the airbrush

**Airbrush = time-based spacing turned on.** There is no separate airbrush dab-placement path; the
airbrush option just enables `getNextPointPositionTimed` and (optionally) disables distance spacing.

`getNextPointPositionTimed` (`krita: libs/image/kis_distance_information.cpp:557-587`) is the temporal
twin of the isotropic distance accumulator — bank elapsed time until it hits the interval:

```
interval = clamp(timing.timedSpacingInterval(), MIN_TIMED_INTERVAL, MAX_TIMED_INTERVAL)
nextPointInterval = interval - accumTime
if nextPointInterval <= 0:                       t = 0  (reset)
elif nextPointInterval <= (endTime-startTime):   t = nextPointInterval/(endTime-startTime); reset
else: accumTime += (endTime-startTime); t = -1
```

The interval comes from the airbrush **rate**: `timingInterval = 1000.0 / airbrushRate` ms, where
`airbrushRate` is in dabs/sec (default 20, UI default 50)
(`krita: plugins/paintops/libpaintop/kis_paintop_plugin_utils.h:91`;
`krita: …/KisAirbrushOptionData.cpp:11`). A rate of 50 ⇒ a dab every 20ms while the cursor is held.
The rate is *also* a `KisCurveOption` (`m_rateOption`, `krita: …/kis_paintop_plugin_utils.h:94-96`),
so airbrush speed can be pressure-driven.

`KisAirbrushOptionData` has exactly three fields: `isChecked`, `airbrushRate`, `ignoreSpacing`
(`krita: …/KisAirbrushOptionData.h:24-26`). `ignoreSpacing=true` disables distance spacing entirely
(`distanceSpacingEnabled = !ignoreSpacing`, `krita: …/kis_paintop_plugin_utils.h:56-58`) — a pure
time-driven airbrush that ignores motion.

### 1.7 The airbrush timer — generating dabs with NO input events

The above produces timed dabs *while the pointer is moving* (each move event carries a time delta).
But a held-still airbrush must keep depositing with zero pointer events. That's driven at the **tool
layer**, not the paintop, by a `QTimer`:

- On stroke start, if `needsAirbrushing()`, start `airbrushingTimer` at
  `computeAirbrushTimerInterval() = floor(airbrushingInterval * AIRBRUSH_INTERVAL_FACTOR)`, where
  `AIRBRUSH_INTERVAL_FACTOR = 0.5` makes the timer fire **twice as fast as the rate** for
  responsiveness (`krita: libs/ui/tool/kis_tool_freehand_helper.cpp:44-47, 351-353, 991-995`).
- Each timer tick, `doAirbrushing()` synthesizes a new `KisPaintInformation` at the **same position**
  as the previous point, with only `time` (and speed=0) updated, and calls `paint(nextPaint)`
  (`krita: …/kis_tool_freehand_helper.cpp:967-989`). That synthetic event runs through the normal
  `paintLine`→`getNextPointPosition` machinery; since position is unchanged, distance spacing never
  fires, and only `getNextPointPositionTimed` produces dabs.
- The timer is restarted on every real move (`:698-700`) and stopped at stroke end (`:712-714`).

So the airbrush has **two dab sources**: timed dabs from real move events (oversampled by the time
accumulator) and timer-synthesized dabs when held still. Both funnel through the same time
accumulator, so the rate is honored regardless of motion.

There's a separate, related resampler: `KisStabilizedEventsSampler`
(`krita: libs/ui/tool/kis_stabilized_events_sampler.cpp`). It records real events with timestamps and,
on `range()`, replays them at a fixed `sampleTime` cadence: `elapsed = elapsedMs / sampleTime`,
`alpha = realEvents.size()/elapsed`, and the iterator dereferences `realEvents[floor(alpha*i)]`
(`krita: …:68-85`). This is used by the **stabilizer** smoothing mode to feed evenly-time-sampled
points (and to keep airbrushing fed during stabilization). It's a *time-resampling of the event
stream*, distinct from the dab-spacing accumulator, but the same philosophy: decouple dab cadence
from raw event cadence.

### 1.8 The dab cache (perf strategy)

Krita generates each dab mask on a **CPU worker thread** — expensive — so it caches the last
generated mask and reuses it when the next dab's parameters are "close enough." The validity test
(`krita: plugins/paintops/libpaintop/kis_dab_cache_base.cpp:279-280`):

```
shouldUseCache = hasDabInCache && brush->supportsCaching() && solidColorFill
                 && newParams.compare(lastSavedDabParameters, precisionLevel)
```

`compare` (`krita: …:53-68`) does a **quantized** equality: color exact-equal, and
angle/width/height/subpixel/softness/lightness/ratio within per-precision-level tolerances from a
5-row `precisionLevels` table (`krita: …:32-38`). E.g. at the default-ish level, width must match
within `sizeFrac * width` (5% or 1%), angle within 1°, ratio within 0.05–eps. Precision level is
chosen per dab from `precisionOption->effectivePrecisionLevel(effectiveDabSize)` (`krita: …:274-277`)
— larger brushes tolerate looser quantization. `solidColorFill` is required (gradient/pattern/smudge
dabs never cache, `krita: …:260`).

The classification feeds the queue: a cache hit becomes a zero-cost **Copy** (alias the previous
device), a miss is a full **Dab** render, and a same-mask-different-postprocess case is a
**Postprocess** (topic 00 §4). **The lesson:** Krita pays mask-generation cost once per *distinct*
(quantized) parameter set, not once per dab. A constant-pressure round-brush segment regenerates one
mask and copies it N times.

---

## 2. How Kiki does it today

| Concern | Kiki implementation | `file:line` |
|---|---|---|
| Spacing rule | Distance-only, single accumulator (`traveled`/`leftover`) | `MetalCanvasView.swift:2400-2436` |
| Spacing value | `max(width * spacingFraction, 0.5)`, `spacingFraction = max(brush.spacing,0.02)` | `MetalCanvasView.swift:2368, 2401, 2434` |
| Default fraction | `0.3` of width for eraser/legacy paths; `brush.spacing` for main path | `MetalCanvasView.swift:538, 912, 997` |
| Spacing recompute | Per emitted stamp, from interpolated `width` at that point | `MetalCanvasView.swift:2420, 2434` |
| Input pre-resample | `reparameterizeStrokePoints` → 8–64 samples for classification | `MetalCanvasView.swift:1956-1969` |
| Dab cache | **None** — every stamp is a fresh `StampInstance`, one instanced draw/frame | `MetalCanvasView.swift:2360-2436` |
| Time-based spacing | **None** | — |
| Airbrush | **None** — no held-still deposit, no timer-synthesized dabs | — |
| Elliptical/anisotropic spacing | **None** — `radius` only, no per-axis spacing | `MetalCanvasView.swift:2393, 2426` |
| Cross-batch continuity | `lastStampPos`/`lastWetSpacing`/`lastEraserSpacing` persisted on view | `MetalCanvasView.swift:510, 538, 875-919` |

Our spacing is: arc-length walk, gap = `effectiveWidth(force,altitude) * brush.spacing`, recomputed
at each emitted stamp from the locally-interpolated width. It is the **isotropic distance-only**
subset of Krita's model, with a hardcoded `coeff`-less linear width relationship (no `sqrt`
auto-spacing), persisted on the view rather than in a stroke-state object. The unified plan
(`documents/plans/unified-brush-engine.md:57, 214`) keeps "Stroke Path — Spacing, Jitter, Fall Off"
as CPU stamp gen and lists spacing as "Native… exists," confirming we have no plans yet for
time-based spacing/airbrush at the dab level.

---

## 3. Gap analysis + what a Krita-grade superset adopts

| Krita capability | Have it? | Superset verdict | Priority |
|---|---|---|---|
| Distance accumulator (isotropic) | Yes (equivalent) | Keep; refactor into a `StrokeState` object (§5) | — |
| Spacing as a sensor/curve (pressure→spacing) | No | **Adopt** once the curve+sensor layer lands (topic 00 §6) | Med |
| `sqrt` auto-spacing for large brushes | No | **Adopt** — cheap, fixes beading on big brushes | Med-High |
| Time-based spacing (`min(dist,time)`) | No | **Adopt** — it's the airbrush substrate | High (gates airbrush) |
| Airbrush rate + held-still timer | No | **Adopt** — genuinely new capability, Krita-grade | High |
| `ignoreSpacing` pure-timed mode | No | Adopt with airbrush | Med |
| Anisotropic/elliptical spacing | No | **Adopt when chisel/ratio brushes ship** (not before) | Low now |
| Mid-segment spacing re-eval (50ms) | No | Adopt only if slow pressure-ramps look stale | Low |
| Dab-mask quantized cache | No (GPU regen is cheap) | **Skip for dry; consider for the expensive wet/KM path** | Conditional |
| Stabilized time-resampler | No | Folds into stabilizer topic, not this one | — |

**The headline gap is the missing time axis.** Krita's `min(distanceFactor, timeFactor)` is the one
elegant idea that makes airbrush, "drips while held," and time-driven density fall out of the same
loop we already have. We have the distance half built; we are missing the time half entirely. Adding
a parallel time accumulator to our stamp loop is a small, self-contained change that *unlocks a whole
brush family* (airbrush, spray-while-held, time-density).

**Auto-spacing (`sqrt`) is the cheapest high-value adopt.** One line of math, no new state, fixes the
real artifact that large soft brushes bead at high spacing fractions. Krita-grade, low risk.

**The dab cache does not port to our dry path.** Krita caches because CPU mask generation is
expensive; our masks are a static 64×64 R8 texture sampled by an instanced quad — regeneration is
free, the cache would add state for no win (topic 00 §5 reached the same conclusion). The *idea*
worth keeping is the **quantized-parameter key**: on the expensive **wet/KM** path, a per-frame
"did the dab params change enough to matter" gate (à la `compare` with a precision table) could skip
redundant 36-band spectral work — that's the only place the cache concept earns its keep.

---

## 4. img2img leverage call

- **Time-based spacing / airbrush:** **hand-feel + moderate model-leverage.** The *density* and
  *soft build-up* an airbrush produces (large-scale value/saturation gradients, soft edges) is
  exactly the high-leverage class klein consumes (`_CONTEXT.md`: "edge hardness… large-scale value
  structure"). A soft airbrushed value field reads very differently to the model than a hard pen
  line. Worth it for what it *changes in the conditioning image*, not just hand-feel. **High-ish
  leverage.**
- **Auto-spacing (`sqrt`):** **hand-feel, low model-leverage.** It prevents visible beading; klein
  resynthesizes fine spacing regardless. But beading on a big soft brush *does* corrupt the
  large-scale value field the model sees, so it's not zero-leverage. **Adopt for cheapness, not
  leverage.**
- **Anisotropic/elliptical spacing:** **hand-feel.** Matters for chisel/calligraphy stroke *shape*,
  which the model does see (stroke direction/shape is high-leverage), but only once we have
  non-round brushes. **Defer.**
- **Dab cache:** **pure perf, zero leverage.** Only relevant as a wet-path cost gate.
- **Spacing-as-sensor (pressure→spacing):** **mostly hand-feel.** Subtle; the model won't
  distinguish a pressure-tightened gap. Low priority.

**Net:** the airbrush/time axis is the one item here with real model-leverage *and* a new hand-feel
capability. Everything else is hand-feel or perf.

---

## 5. Metal translation notes (respecting perf invariants)

**The whole topic lives on the CPU stamp-generation side** (`generateStampsForStroke`,
`MetalCanvasView.swift:2360`), upstream of the GPU. None of it touches the `<8ms` GPU budget directly
— but the **airbrush timer is the one piece that interacts with our `CADisplayLink` loop**, and that
needs care.

**(a) Add a time accumulator to the stamp walk.** Mirror Krita's `min(distanceFactor, timeFactor)`.
Today we only bank distance; add a parallel `accumTime` banked from `StrokePoint.timestamp` deltas
(we already carry `timestamp`, `_CONTEXT.md`). Emit a stamp when *either* the distance gap or the time
interval (`1000/rate` ms) trips. This is pure CPU arithmetic in the existing loop — no GPU cost
change, no new draw calls (the emitted stamps still batch into the one instanced draw).

**(b) Airbrush held-still dabs via the existing display link — do NOT add a `QTimer` analogue.**
Krita uses a separate `QTimer`; we already have a `CADisplayLink` firing every frame
(`MetalCanvasView.swift:276, 369`). The clean translation: on each `displayLinkFired`, if a stroke is
active *and* the brush is an airbrush *and* the pointer hasn't moved, synthesize a stamp-walk step at
the held position with the current frame time (Krita's `doAirbrushing`,
`krita: …/kis_tool_freehand_helper.cpp:967-989`). The time accumulator from (a) then emits 0..N
timed dabs that frame. **This rides our existing dirty-frame render — no new timer, no new command
buffer, no `waitUntilCompleted`.** The only change is "mark dirty + run the stamp walk" inside the
already-running display link, which is the cheap path. Krita's `AIRBRUSH_INTERVAL_FACTOR = 0.5`
oversample is irrelevant to us: a 120Hz display link already ticks every ~8.3ms, finer than any sane
rate interval, so the accumulator naturally sub-samples.

**Budget watch:** a high rate (say 100/s) on a **large soft/wet brush** could emit several big stamps
per frame. For the dry path that's still one instanced draw — fine. For the **wet/KM path** this is
exactly the unified plan's flagged stress case: *"the stress case is a ~600px wet airbrush"*
(`documents/plans/unified-brush-engine.md:243, 248`). The plan already mandates budget-testing the
600px wet airbrush on the oldest iPad first — **this research confirms that test is load-bearing the
moment we add timed dabs**, because the airbrush is what makes many-big-wet-dabs-per-frame reachable.

**(c) Auto-spacing.** One line: replace `width * spacingFraction` with
`coeff * (w<1 ? w : sqrt(w))` when an auto-spacing toggle is on. CPU-only, no perf concern.

**(d) Refactor the spacing state into a `StrokeState` value object** (Krita's
`KisDistanceInformation`) instead of the scattered `lastStampPos`/`lastWetSpacing`/`lastEraserSpacing`
view fields (`MetalCanvasView.swift:510, 538, 875-919, 2400`). This is the prerequisite that makes
(a) clean: one object holds `accumDistance`, `accumTime`, `lastPos`, `lastSpacing`, `lastTiming`,
shared by dry/eraser/wet walks. Pure refactor, no behavior change.

**(e) Dab cache — skip on the dry GPU path.** Our 64×64 R8 mask is static; the instanced quad samples
it. No regeneration to cache. *If* the wet/KM fragment proves too expensive under airbrush load,
adopt Krita's **quantized-parameter gate** (the `compare`/`precisionLevels` idea,
`krita: …/kis_dab_cache_base.cpp:53-68`) as a per-frame "skip the spectral mix if params barely
changed" early-out — but only after measuring (mirrors the unified plan's "benchmark the cheap fix
first," `documents/plans/unified-brush-engine.md:146, 295`).

**Determinism caveat.** Timed/airbrush dabs depend on *wall-clock* (frame timestamps), so a recorded
stroke replayed at a different frame cadence yields a different dab count — a replay-determinism trap
the unified plan already flags for wet strokes
(`documents/plans/unified-brush-engine.md:185, 305`). For airbrush we must **record the synthesized
timed dabs' positions/times into the stroke**, not re-synthesize them at replay from a fresh clock —
otherwise undo/commit/replay diverge. Krita sidesteps this because each painted dab is committed to
the layer as it happens; our scratch-then-flatten + replay model makes it our problem.

---

## 6. Open questions / risks

1. **Replay determinism for timed dabs (real risk).** Our deterministic replay/undo must reproduce
   the exact timed-dab sequence. Resolution: record each emitted timed dab (position+time) into the
   stroke, replay verbatim — do not re-run the clock. Verify against the unified plan's dab-batch
   recording approach (`unified-brush-engine.md:185`). *(inferred remediation; not yet designed.)*

2. **Held-still detection on iPad.** Krita's timer fires regardless; we'd gate on "pointer hasn't
   moved since last frame." Pencil hover/jitter means "still" needs a small epsilon. Unverified what
   threshold feels right — needs device tuning.

3. **600px wet airbrush budget (confirmed-by-plan risk).** Adding timed dabs makes the unified plan's
   worst-case wet stress trivially reachable by a user. The plan's day-one budget test on the oldest
   iPad (`unified-brush-engine.md:248, 329`) becomes mandatory before shipping airbrush+wet together.

4. **`MIN_TIMED_INTERVAL` / clamp values.** Krita clamps the timed interval
   (`krita: kis_distance_information.cpp:565`); I read `MAX_TIMED_INTERVAL = LONG_TIME` (`:27`) but did
   **not** locate `MIN_TIMED_INTERVAL`'s definition — *(inferred it exists as a floor; value
   unverified)*. Pin it before implementing so a runaway rate can't emit unbounded dabs/frame.

5. **Auto-spacing coefficient.** Krita's `autoSpacingCoeff` is a configured value, not a constant; I
   did not trace its default/UI range. Needs a lookup before exposing an auto-spacing toggle. *(not
   verified.)*

6. **Spacing-as-sensor ordering.** Krita evaluates the spacing sensor in `paintAt` and feeds it
   forward to the *next* segment (`krita: …/kis_brushop.cpp:143`). If we adopt pressure→spacing, we
   must decide whether spacing uses the *current* point's pressure or the previous (Krita: previous,
   via feedback). Subtle; affects stroke onset. *(behavior verified in Krita; our choice open.)*

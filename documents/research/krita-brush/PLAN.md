# Kiki Brush Engine — Krita-Grade Superset Plan (FINAL)

**Written:** 2026-06-20 · **Revised:** 2026-06-20 (incorporating 4 adversarial critiques — see
Revision log §8) · **Status:** Final. **This document is an in-place AMENDMENT to the committed
`documents/plans/unified-brush-engine.md`** (the system-of-record substrate), not a parallel
design. Where it changes the descriptor or migration ladder, it says exactly which unified section
to edit (§2.1 below).

**Method.** Convergence of `documents/research/krita-brush/00–12`, read against the committed target
architecture (`documents/plans/unified-brush-engine.md`) and the per-feature roadmap
(`documents/plans/pro-brush-roadmap.md`), all grounded in Krita source at `~/krita_src`. Citation
discipline per `_CONTEXT.md`: Krita as `krita: <path-relative-to-~/krita_src>:<line>`, ours as
`path:line`; **verified** = read the code this revision, **inferred** = pattern/comment, hedged.
All Krita paths in this revision are full-path-relative-to-`~/krita_src` and were re-opened against
the actual source during critique resolution.

**North star (decided):** Krita-grade *superset* — Krita is the ceiling for *capability*; Procreate
parity is the floor. img2img leverage informs *priority*, never *capability* (capability is foreclosed
nowhere; we reject items on leverage, not reachability — same discipline as `unified-brush-engine.md`).

---

## 0. TL;DR — the spine

The unified-brush-engine plan got the **rendering substrate** right (one isolated Stroke Accumulation
Buffer, bound-source reads, one branch-free dab fragment, a small per-stroke PSO *family*,
Simulator-safe). This plan does **not** relitigate that substrate — it adopts it wholesale.

What the unified plan **under-specifies** is *upstream* of the GPU: it models brush dynamics as a
**fixed matrix of named Procreate couplings** (`dynamics.speedSize`, `pencil.tilt.curve`, four
`colorDynamics` buckets) when Krita's entire expressive power comes from **one orthogonal
abstraction** — *any sensor → any parameter → its own response curve → a chosen combine operator → a
min/max output remap*. Eleven of the twelve findings docs independently converge on this conclusion
(02 names it directly; 03/04/05/06/07/09/11 each say "this depends on the sensor/curve layer first").
**That sensor+curve layer is the keystone. We build the general machine, not more named knobs — and
we amend the committed descriptor to hold it (§2.1).**

Secondary findings the unified plan misses or under-specifies, each cited below:
- **Input width.** `StrokePoint` carries 4 axes and feeds 2 into 1 hardcoded function. We are missing
  azimuth (free, high-leverage), derived speed, drawing-angle, and a per-stroke seed (docs 01, 02, 06).
- **The time axis.** Krita's `min(distanceFactor, timeFactor)` makes airbrush fall out of the spacing
  loop for free; we have only the distance half (doc 04).
- **Flow as the Glaze↔Build-up *target-alpha* dial** — enriches the coverage-curve uniform the unified
  doc *already* has; it is NOT a reason to reduce the PSO count (doc 03; corrected — see §2.3).
- **The directional-smear axis is absent** from the wet model (`pull`/`grade` are dulling-only);
  Krita's smearing reads displaced source pixels (doc 08). This is the one genuinely *new* wet term;
  getBytes-removal and smudge-radius are already committed in unified §3.3/§4.
- **Stabilization has a structural bug:** our EMA is frame-rate-dependent; Krita weights by arc-length
  and adapts σ to speed (doc 10).
- **Lightness-map tips** turn art we already load (alpha-only) into value-carrying strokes — high
  model-leverage, but a color-sensitive fragment change gated behind an offline color oracle, not the
  "two-line change" the draft claimed (corrected — see §2.8).

Where we **exceed Krita** and must defend it: **spectral Kubelka-Munk color mixing** (doc 08 —
blue+yellow→green vs Krita's →gray) and the **carried-load reservoir** (Charge/Pull, which Krita lacks
entirely). Keep both; they are our moat.

---

## 1. The gap — three states

| | **Today (shipped)** | **Committed unified-brush-engine.md** | **Krita-grade superset (this plan = amendment)** |
|---|---|---|---|
| **Per-point input** | `StrokePoint{position, force, altitude, timestamp}` — 4 axes (`DrawingEngine.swift:22-34`, verified) | `StrokePoint` + captured `azimuth`, derived `speed`; `Stroke.seed` (`unified:94,101`) | + `drawingAngle` (lockable), `distance`, `barrelRoll?` (gated); two RNG layers (docs 01, 06) |
| **Dynamics** | `effectiveWidth = baseWidth·pow(force,γ)` ×linear-tilt — **2 inputs → 1 output, hardcoded** (`DrawingEngine.swift:147-153`, verified) | Named fixed couplings: `dynamics{speedSize,speedOpacity,jitterSize,...}`, `pencil.tilt.curve` (`unified:68-70`) | **General `CurveOption` machine**: N sensors × per-param curve × combine(mul/add/max/min/diff) × **TWO remap folds** (size-like + rotation-like, §2.1) (doc 02, `krita: plugins/paintops/libpaintop/KisCurveOption.cpp:61-163`) |
| **Size/opacity/flow** | size has γ; opacity/flow flat per-stroke scalars (`DrawingEngine.swift:69,73`, verified) | per-dab `flow`/opacity baked CPU-side (`unified:94`) | every one a size-like `CurveOption`; flow = the Glaze↔Build-up *target-alpha* dial (doc 03, §2.3) |
| **Spacing / airbrush** | distance-only arc-length walk, linear width gap (`MetalCanvasView.swift:2400-2436`) | "Spacing exists, Native" (`unified:214`) | + time accumulator `min(dist,time)` → airbrush; `sqrt` auto-spacing (doc 04) |
| **Tips** | one in-shader `smoothstep` round + grayscale PNGs, alpha-only (`CanvasRenderer.swift:1520-1547`) | shapeRef bound mask + procedural round; `hasShape` guard (`unified:154`) | + editable falloff LUT (guarded; generality, not perf); aspect ratio; **lightness-map tips** (docs 05, 12) |
| **Shape dynamics** | `rotation` plumbed, fed 0 for round; **zero RNG** (`MetalCanvasView.swift:906`, verified) | scatter/count/jitter/flip CPU-baked from `seed` (`unified:94,217`) | seeded RNG as the spine; scatter direction-aware; anisotropic-tip rotation via the rotation-like fold (doc 06) |
| **Wet** | KM spectral + carried load, device-only, `getBytes`/dab (shipped) | SAB + reservoir Pass A; `pull`/`grade`; getBytes-removal already committed (`unified:133-142`) | + **directional-smear axis** (`smearVector`, the one new term); KM + reservoir kept (doc 08, §2.5) |
| **Color dynamics** | one static swatch, zero dynamics (`DrawingEngine.swift:64`, verified) | 4 fixed buckets `{stamp,stroke,pressure,tilt}` (`unified:68`) | (channel H/S/V) × (sensor + curve + amount); gradient-along-stroke (doc 09) |
| **Stabilization** | per-event EMA, position-only, frame-rate-dependent (`MetalCanvasView.swift:2587-2604`, verified) | "StreamLine shipped; add spring" (`unified:215`) | arc-length-weighted speed-adaptive + Bézier interpolation + optional pressure smoothing (doc 10) |
| **Grain** | none (verified by absence, doc 07) | `grainTex` + doc-space UV + scalar `depth`, MULTIPLY, gated (`unified:218`) | HEIGHT-mode **coarse value-grain** + strength-as-curve; **committed phase — grain confirmed to survive img2img** (Donald, 2026-06-20; doc 07, §2.7) |
| **Brush families** | one pixel brush | one unified brush + presets | + bristle / proximity-connect **stamp-generation strategies** (same class as scatter), filter-brush *category* (doc 11) |

**The headline gap is not any feature — it is the width and generality of the dynamics layer.** Today
2 inputs feed 1 function. The unified plan widens the *outputs* (more named knobs) but keeps the
*inputs* and the *coupling* fixed. Krita's design makes inputs and couplings orthogonal and arbitrary.
Closing that is the keystone; almost every other gap is downstream of it.

---

## 2. What Krita teaches that the unified plan misses / under-specifies

Each item cites both the plan line and the Krita source. Ordered by structural importance.

### 2.1 KEYSTONE — the sensor+curve+combine machine, with its TWO output folds

**Unified models** (`unified:68-70,221-222`): `dynamics:{speedSize, speedOpacity, jitterSize,
jitterOpacity}`, `pencil:{pressure{size,opacity,flow,bleed}, tilt{...curve}}`, `colorDynamics:
{stamp,stroke,pressure,tilt}`. These are **specific (input→output) pairs** — Procreate's surface.

**Krita does** (verified this revision against `krita:
plugins/paintops/libpaintop/KisCurveOption.cpp`): every tunable parameter is a `KisCurveOption =
{ sensors:[{sensor, curve}], combineMode, strength, min, max, useCurve }`. The sensor dispatch is
shared (`computeValueComponents`, `:102-163`): each sensor reads one normalized [0,1] axis through
*its own* 256-entry cubic-spline LUT (`krita:
plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:34-51`,
`krita: libs/image/kis_cubic_curve.cpp:136-152`) with an **identity-curve fast-path** (LUT dropped to
`nullopt` → raw passthrough, `krita: plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:21-23`).
Scaling sensors combine by `combineMode ∈ {multiply(default,curveMode=0/else), add(1), max(2), min(3),
difference(4)}` (`krita: KisCurveOption.cpp:124-151`); additive sensors (Fuzzy, etc.) sum into
`additive`; an absolute-rotation sensor (DrawingAngle) overwrites `absoluteOffset` (`:112-121`).

**THERE ARE TWO FOLDS — quote both. An implementer building from one alone will get rotation/hue wrong.**

1. **size-like fold** — used by size, opacity, flow, spacing, ratio (verified
   `krita: KisCurveOption.cpp:78-88`):
   ```
   offset      = hasAbsoluteOffset ? absoluteOffset : 1.0
   scalingPart = hasScaling   ? scaling                          : 1.0
   additivePart= hasAdditive  ? additiveToScaling(additive)      : 1.0
   sizeLikeValue = clamp(min, constant · offset · scalingPart · additivePart, max)
   ```
   (`constant` = the option's strength.) `additiveToScaling` converts the *additive* bucket into a
   multiplier.

2. **rotation-like fold** — used by rotation, hue, scatter-angle, tilt-direction (verified
   `krita: KisCurveOption.cpp:61-76`):
   ```
   offset      = !hasAbsoluteOffset ? normalizedBaseAngle
                                     : (absoluteAxesFlipped ? 0.5 - absoluteOffset : absoluteOffset)
   scalingPart = (hasScaling && !disableScalingPart) ? scalingToAdditive(scaling) : 0.0   // NOTE: scalingToAdditive
   additivePart= hasAdditive ? additive : 0
   rotationLikeValue = wrapValue(2·offset + constant·(scalingPartCoeff·scalingPart + additivePart), -1, 1)
   ```
   Differences from the size fold that MUST be reproduced: **`2·offset`**, **`wrapValue` into [-1,1]**
   (hue/angle wrap, not clamp), **`scalingToAdditive` on the *scaling* part** (opposite conversion
   direction from the size fold's `additiveToScaling` on the additive part), and the
   absolute-offset-flip semantics (`offset = 0.5 − absoluteOffset` when flipped).

   `KisHSVOption` confirms the runtime split: **hue** calls `computeRotationLikeValue`; **S and V**
   call `computeSizeLikeValue` (then a `(v·strength)+(0.5−halfValue)`, `(v·2)−1` remap) — verified
   `krita: plugins/paintops/libpaintop/KisHSVOption.cpp:44-53`.

**Why the named-coupling shape is wrong, not just smaller:** it cannot express (a) the **combine
operator** when two sensors hit one parameter (speed×pressure multiply or max?), (b) the **min/max
output remap** ("zero pressure still paints 20% width"), (c) **hue/rotation wrapping** (the second
fold), or (d) sensors Procreate never exposes — DrawingAngle, Distance, Fade, FuzzyPerStroke-vs-PerDab,
TiltDirection-as-additive. Build the named knobs and you rebuild them as the general machine later
(doc 02 §2-3).

**Adopt:** one `ResponseCurve` (control points → baked LUT, identity fast-path), one `Sensor` enum,
one `CurveOption` reproducing **both** Krita folds verbatim (enables future `.kpp`/`.brush` import).
Each parameter is tagged size-like or rotation-like and routed to its fold. Make size, opacity, flow,
spacing, scatter, ratio (size-like) and rotation, hue, scatter-angle, tilt-direction (rotation-like)
all `CurveOption`s.

**AMENDMENT to `unified-brush-engine.md` (required — this is the BLOCKING coherence fix).**
This plan restructures the committed `BrushDescriptor`, which is the persistence + preset +
GPU-projection unit (`unified §2.1`). To keep one system-of-record:
- **Edit `unified §2.1`:** replace the named `dynamics`/`pencil`/`colorDynamics` sub-structs with a
  `[ParamID: CurveOption]` map (or per-param `CurveOption` fields), where each `CurveOption` carries
  its `foldKind ∈ {sizeLike, rotationLike}`.
- **Edit `unified §2.3` / `unified §6 Step 0` migration map** (currently `color→Stroke.ink`,
  `opacity→rendering.opacity`, `flow→rendering.flow`, `pressureGamma/tiltSensitivity/...→panels`,
  `wetStrength→wetMix.charge/attack`, `wetPickup→wetMix.pull`, `wetEnabled` dropped) to **seed
  `CurveOption`s from today's scalars**: `pressureGamma` → a Pressure-sensor *size* `CurveOption` whose
  control points reproduce `pow(force,γ)`; `tiltSensitivity` → a TiltElevation *size* `CurveOption`;
  the constants/clamps map to `strength`/`min`/`max`. Old drawings still load via `decodeIfPresent`
  (the pattern at `DrawingEngine.swift:164-191`); a default pen yields a snapshot-identical curve.
- The unified flat-projection invariant (`unified §2.4`) is **preserved**: `CurveOption`s resolve to
  per-stamp scalars baked into `StampInstance` CPU-side; the GPU never samples a curve LUT (see Metal
  sketch, P1).

### 2.2 Input model is too thin to feed the machine (docs 01, 06)

Verified this revision: `StrokePoint` is `{position, force, altitude, timestamp}`
(`DrawingEngine.swift:22-34`). The sensor machine needs more axes. Priority by leverage × availability:
- **azimuth (tilt direction)** — free on every Apple Pencil (`azimuthAngle(in:)`), HIGH leverage
  (chisel/flat-pencil shape, which klein sees). The `rotation // pencil azimuth` comment at
  `CanvasRenderer.swift:156` is **stale — azimuth is never read** (verified this revision; line 156 of
  the `StampInstance` struct).
- **derived speed** — Krita's default is an **estimated-sample-rate** trick (`totalDistance/totalTime`
  over a window, `krita: libs/ui/tool/kis_speed_smoother.cpp:144-165`) because tablet timestamps are
  unreliable. **Krita also has a config flag `useTimestampsForBrushSpeed` (default `false`,
  `:103`) that uses raw timestamps instead.** On iPad, `UITouch.timestamp` is far more reliable than
  tablet timestamps, so the port is a **tuning choice, not a copy-verbatim**: evaluate whether trusting
  `UITouch.timestamp` directly beats the sample-rate estimator before porting the estimator. Free,
  MED-HIGH leverage.
- **drawingAngle (lockable)** — derived from positions; drives oriented-tip orientation via the
  rotation-like fold; the locked variant (`krita: libs/image/brushengine/kis_paint_information.cc:111-113`)
  stops chisel jitter on slow curves.
- **distance / fade / total-length** — derived; for taper/texture ramps.
- **`Stroke.seed: UInt64`** + **two RNG layers** — per-dab (`hash(seed,index,channel)`) and per-stroke
  (`hash(seed,channel)`), mirroring `KisRandomSource` + `KisPerStrokeRandomSource`
  (`krita: libs/image/brushengine/KisPerStrokeRandomSource.cpp:59-74`). Use **stateless hashing**, not
  Krita's stateful taus88 — lock-free, order-independent, strictly better for our parallel CPU bake
  (doc 06 §3).
- **barrelRoll?** — Pencil-Pro-only, optional, deferred (low audience; already Rejected).

All CPU-side, pre-stamp; never touches the <8ms GPU hot path. New `StrokePoint` fields must
`decodeIfPresent` (the pattern at `DrawingEngine.swift:164-191`) so saved strokes still load.

### 2.3 Flow is the Glaze↔Build-up *target-alpha* dial — it does NOT reduce the PSO count (doc 03; CORRECTED)

**Correction (critique).** The earlier draft framed this as "the unified plan splits Glaze/Build-up
into 6 PSOs; maybe collapse to 1." That was a strawman: `unified §3.6` (`unified:189-196`) already
collapses the 6 *named* Procreate render-modes to **two blend-state PSOs** — Glaze (source-over,
coverage capped at 1) and Build-up (source-over, no cap) — the four Glaze intensities being **one
coverage-curve uniform**, plus the eraser `destinationOut` PSO = **3 in the family, sharing one
vertex+fragment**. The realistic floor is **3, and that floor is load-bearing**, not over-engineering.

The blend-state split is *required*, not collapsible to a single source-over PSO: Glaze (saturate/cap
at 1) and Build-up (accumulate past 1) are **different blend equations**, and because the SAB
accumulates incrementally across frames (`.load` source-over re-reads the SAB), the cap **must live in
the blend hardware**, not in a coverage value written into the SAB — an in-shader/written-coverage lerp
is not numerically equivalent (`unified §7 rejection #6`, `unified:306`). The verified AlphaDarken
math (`lerp(zeroFlowAlpha, fullFlowAlpha, flow)`, `krita:
libs/pigment/compositeops/KoCompositeOpAlphaDarken.h:96-137`) shows **flow interpolating the per-dab
*target alpha*** — which is **orthogonal** to the cap-vs-accumulate blend equation. Conflating the two
is the error.

**What we actually adopt:**
- **Flow as the per-dab target-alpha** inside the *existing* Glaze PSO — it enriches the coverage-curve
  uniform the unified doc already has, making the Light/Uniform/Intense/Heavy Glaze variants a curve on
  flow rather than four hardcoded constants.
- **Krita's avg-opacity hysteresis** (exponent `0.1`, verified `krita: libs/pigment/KoCompositeOp.cpp:95`,
  inside `updateOpacityAndAverage` `:93-105`) — a trivial CPU EWMA — **the moment opacity becomes
  pressure-driven**. Note the **asymmetry**: when opacity *rises*, `lastOpacity` tracks immediately
  (`:99-100`); when it *drops*, it decays by `0.1·opacity + 0.9·lastOpacity` (`:101-103`). This is
  exactly why "pressure dips carve light notches" — adopt the asymmetric form (doc 03 §3.3 #2).

**P0 task (re-scoped):** the offline re-derivation is NOT "can we collapse to 1 PSO." It is the unified
doc's BLOCKING gate (`unified §7 open #1`, `unified:292`): **prove the 3-PSO family yields
frame-rate-INDEPENDENT Glaze** — a self-crossing 30% stroke must produce identical flat saturation at
varied dabs-per-frame. Frame the task as "confirm 3, not reduce to 1."

### 2.4 The time axis / airbrush is absent (doc 04)

Krita's dab placement is `t = min(distanceFactor, timeFactor)` (verified
`krita: libs/image/brushengine/kis_distance_information.cpp:405-448`). Airbrush is **not a separate
path** — it's the time half turned on. We have only the distance half (`MetalCanvasView.swift:2400-2436`).
Add a parallel time accumulator banked from `timestamp` deltas; drive held-still dabs from the
**existing `CADisplayLink`** (not a new timer — doc 04 §5b). Also adopt `sqrt` auto-spacing
(`krita: plugins/paintops/libpaintop/kis_paintop_utils.h:162`) to fix large-brush beading.

**Perf coupling (critique).** A held-still airbrush must mark the canvas dirty *every frame* to keep
depositing while the pencil is stationary — converting an idle (zero-cost) hold into a continuous
per-frame render+composite, which **defeats the "only renders when dirty" optimization**
(`CanvasModule/CLAUDE.md`). Bound it: **deposit held-still dabs at the airbrush RATE, not the display
rate** — accumulate time and emit a dab batch only when the accumulator crosses spacing, so a slow
airbrush composites at its own cadence (which may be ≪120Hz), not 120Hz. This also keeps the
replay-determinism recording sane (fewer recorded timed dabs). **Trap:** record each emitted timed dab
into the stroke for deterministic replay (doc 04 §6.1).

### 2.5 The directional-smear axis is the one NEW wet term; getBytes-removal + smudge-radius are already committed (doc 08; SCOPED)

**Correction (critique).** The unified doc **already mandates** killing the per-dab 1px `getBytes`
(`unified §3.3`, names `CanvasRenderer.swift:585` as the anti-pattern, replaced by Pass A) and already
lists Smudge-Radius-adjacent Pull/Grade/Blur as native Wet-Mix params (`unified:220`). This plan does
**not** claim credit for those. They are cited as "enrich the committed Pass A."

The **genuinely new** contribution is the **directional-smear axis**, which the unified reservoir
(point-average dulling only, `unified:139`) lacks. Krita has **two orthogonal axes**: the strategy
(color model) and the **Smearing-vs-Dulling mode** — a `m_useDullingMode` bool that is a ctor parameter
of `KisColorSmudgeStrategyBase` (verified `krita:
plugins/paintops/colorsmudge/KisColorSmudgeStrategyBase.cpp:113-114`, member `:123`, branched at
`:192`), **independent of which concrete strategy** (Lightness/Mask/Stamp) subclasses it. Smearing
reads *displaced* canvas pixels — `srcDabRect` offset by inter-dab travel (verified
`krita: plugins/paintops/colorsmudge/kis_colorsmudgeop.cpp:192`,
`srcDabRect = m_dstDabRect.translated(m_lastPaintPos - newCenterPos)`).

**Adopt:** a `smearVector` carried **per-dab on `StampInstance`** (NOT a `BrushUniforms` field — the
displacement is the inter-dab travel vector, which varies per dab; a per-stroke uniform can't carry
it). The fragment samples `belowTex`/`sabPrev` at `texCoord − smearVector`.
**Correctness coupling (critique):** a displaced read can fall *outside* the frame's dab bbox that was
blitted into `sabPrev` (the dirty-bbox optimization, `unified:181`), reading stale texels.
**Expand the `sabPrev` dirty-bbox blit by the max smear-displacement magnitude** so displaced reads
always hit valid texels (or clamp the displaced UV to the blitted bbox). Call this out as a P7
sub-item.

Also adopt `colorRate²` squaring as the default Mix curve (verified
`krita: plugins/paintops/colorsmudge/KisColorSmudgeStrategyBase.cpp:159`,
`colorRateValue * colorRateValue * opacity`). **Keep our spectral KM and carried load — both exceed
Krita** (doc 08 §3-4).

### 2.6 Stabilization has a frame-rate-dependence bug (doc 10)

Our `streamline` EMA is applied per coalesced touch (`MetalCanvasView.swift:2587-2604`) → smooths
harder at 120 Hz than 60 Hz, and a flick and a crawl get the same lag. Krita weights by **accumulated
arc-length distance** with **speed-adaptive σ** (`(1-speed)·distMax + speed·distMin`, verified
`krita: libs/ui/tool/kis_tool_freehand_helper.cpp:465-479,516-607`) and a self-bounding window.
Replace the EMA (gap A). Add velocity-aware cubic Bézier *between* anchors (gap B) — we currently feed
klein a faceted polyline; **curvature is the HIGH-leverage half** (changes the stroke *shape* klein
conditions on). Optionally smooth pressure/tilt (gap D) — **hand-feel-dominant, MED leverage**; jittery
pressure → jittery width which klein sees, but at a live conditioning feed the gain is smaller. Defer
the timer-driven Stabilizer "rope" (fights replay determinism — record-and-replay or skip). **Cap max σ
*lower* than Krita** because our canvas is a live conditioning JPEG re-read every ~250ms, not a final
artifact (doc 10 §3, §5, §6.4).

### 2.7 Grain — HEIGHT mode + strength-as-curve; CONFIRMED to survive img2img → a committed phase (doc 07; CORRECTED 2026-06-20)

`unified:218` specifies plain MULTIPLY + a scalar `depth`. Krita's dry-media build-up comes from the
**HEIGHT** family (grain as height map, pressure as water level) and a **strength `KisCurveOption`**
(`krita: plugins/paintops/libpaintop/KisStandardOptions.h:50`), not a scalar. The HEIGHT composite has
**two branches** (verified `krita: libs/ui/tool/strokes/KisMaskingBrushCompositeOp.h:555-580`):
- **non-soft-texturing** (`:575-577`): `clamp(0, dst/(1−s) − (src + (1−s)), 1)` — the form quoted here;
- **soft-texturing** (`:569-573`): `clamp(0, dst/(1−s) − src·s, 1)`.

**Correction (Donald, 2026-06-20).** The earlier draft rated grain leverage an **unmeasured
inference** and gated it behind a survival spike, reasoning klein resynthesizes fine grain
(`_CONTEXT.md:29`). **That inference is falsified by direct observation: grain DOES survive the
img2img interpretation.** The distinction the draft missed: klein resynthesizes *fine per-pixel
tooth*, but **coarse value-grain / dry-media break-up changes the value+edge structure klein keys
on**, so it conditions the output rather than being averaged away. Grain is therefore a **committed
phase, not a spike-gated experiment** — build HEIGHT-mode + the strength curve. (Fine per-pixel mask
grain stays out per §5 — that half genuinely is resynthesized; the surviving half is the coarse
HEIGHT/value-grain.) Couples to the keystone (§2.1) for the strength curve. **Sequencing note:** it no
longer has to wait behind a gate, but it still depends on P1 (strength `CurveOption`) and the
document-space UV plumbing, so it lands once those exist.

### 2.8 Lightness-map tips — high leverage, but a color-sensitive fragment change, NOT "two lines" (doc 12; CORRECTED)

The unified plan has no LIGHTNESSMAP concept. Krita's `setLightness(brushColor, quadratic(tipLuma))`
(verified `krita: libs/pigment/KoColorSpacePreserveLightnessUtils.h:41-65`, the Schatz quadratic) turns
the grayscale tip art **we already load and throw away (alpha-only)** into value-carrying strokes —
exactly the large-scale value structure klein consumes. **HIGH model-leverage.**

**Correction (critique).** It is **not "two lines" and not free in the fragment.** The Schatz quadratic
is an RGB→lightness-space→RGB round-trip (~10+ ALU) and it assumes a *specific* lightness space
(sRGB/HSL), while our `.bgra8Unorm_srgb` fragment receives **linear** `in.color` (Metal decodes
sRGB→linear on sample, per the sacred color rule in `CanvasModule/CLAUDE.md`). Applying the quadratic
to linear values double-counts gamma. Two correct options, **prefer the second:**
1. In-fragment: convert `in.color` linear→sRGB, apply the quadratic in sRGB (matching Krita), convert
   back to linear before the premultiplied write — gated behind an **offline color-correctness oracle**
   against the Krita util before any device test (`feedback_verify_shader_color_offline`).
2. **CPU pre-bake (preferred):** `tipLuma` is constant per dab for a given stamp, so compute the
   lightness transform CPU-side and bake the result into `StampInstance.color` — moving the whole
   conversion **off the per-pixel fragment** onto the per-dab bake. Genuinely cheap; no fragment cost.

Characterize as a **small-but-color-sensitive change gated by an offline oracle**, not a two-line edit.

### 2.9 Color dynamics as (channel)×(sensor+curve), and gradient-along-stroke (doc 09)

The unified 4 fixed buckets (`unified:68`) should be one `CurveOption` per H/S/V channel fed by a chosen
sensor — strictly more capable, mirrors `KisHSVOption` exactly (verified
`krita: plugins/paintops/libpaintop/KisHSVOption.cpp:44-53` — and note **hue uses the rotation-like
fold**, S/V the size-like fold, per §2.1). This absorbs per-dab jitter, per-stroke jitter,
pressure→saturation, **and gradient-along-stroke** for free. The gradient source itself consumes only a
scalar `mix∈[0,1]` (verified `krita: plugins/paintops/libpaintop/kis_color_source.cpp:119-124`,
`selectColor(double mix, ...)`, `pi` unused → `m_gradient->colorAt(m_color, mix)`); **the
Distance-sensor→`mix` coupling is INFERRED** — it lives in the option-wiring caller that feeds `mix`,
not at `:119` (doc 09 §3). Bake per-stamp into `StampInstance.color`, jitter in sRGB-HSV *then* `s2l`,
wrap hue mod 1.0. **Skip `TOTAL_RANDOM`** (non-deterministic in Krita itself,
`krita: plugins/paintops/libpaintop/kis_color_source.cpp:181`).

### 2.10 Superset brush families (doc 11) — adopt the *dynamics layer*, then bristle/sketch/filter

Every Krita specialty paintop is a *consumer* of the keystone layer. Beyond it, three are genuine
superset wins. **Naming (critique):** the unified doc bans "mode" for the *render path* (no per-feature
dab branch; `unified §2.4, §7 rejection #1`). Bristle and proximity-connect are **CPU stamp-generation
strategies** (emit N offset sub-stamps / connect buffered points with thin-line instances) feeding the
**same unchanged unified dab fragment with no new render branch** — architecturally identical in class
to scatter/count, which the unified doc already treats as legitimate CPU stamp-gen (`unified:217`).
- **bristle stamp-generation strategy** (hairy — splay + ink depletion + soak,
  `krita: plugins/paintops/hairy/hairy_brush.cpp:166-188`).
- **proximity-connect stamp-generation strategy** (sketch — point buffer + thin lines,
  `krita: plugins/paintops/sketch/kis_sketch_paintop.cpp:212-297`).
- **filter-brush as a new *category*** (paint-with-blur/sharpen/dodge-burn — edits the exact structure
  klein conditions on, run once-per-stroke like our flatten,
  `krita: plugins/paintops/filterop/kis_filterop.cpp:99-133`). This is an acceptable new *category*
  (a compute pass), not a hidden branch.

SKIP particle/curvebrush/gridbrush/hatching; hold tangentnormal as a future second-conditioning-channel
bet.

---

## 3. Where to EXCEED Krita, and where to adopt wholesale

**Exceed Krita (defend our moat):**
| We already beat Krita | Evidence | Action |
|---|---|---|
| **Spectral KM color mixing** (blue+yellow→green) | ours 36-band Mallett-Yuksel (`CanvasRenderer.swift:1587`) vs Krita linear RGB→gray (doc 08 §3) | Keep; move verbatim into the unified dab fragment; never ship Mixbox under its NC license (Critical Constraint #4) |
| **Carried-load reservoir** (Charge/Pull travelling pigment) | Krita has *no* carried load — re-samples canvas every dab (doc 08 §1.4) | Keep + GPU-ify (Pass A); add the *directional-smear* axis Krita has but we lack (§2.5) |
| **Stateless-hash determinism** | replaces Krita's stateful taus88 + mutex'd per-stroke QHash (doc 06 §3) | Lock-free, order-independent — strictly better for our parallel bake |
| **Per-stroke format selection + dirty-bbox SAB** | unified plan §3.2, §3.5 — Krita is CPU full-canvas | Keep the plan's substrate |

**Adopt Krita wholesale (copy the math, not the API):**
- **Both** `CurveOption` folds — size-like AND rotation-like (§2.1) — predictable artist behavior +
  import path.
- Scatter formula (direction-aware, diameter-scaled,
  `krita: plugins/paintops/libpaintop/KisScatterOption.cpp:32-64`).
- `min(distance,time)` spacing + `sqrt` auto-spacing (§2.4).
- Arc-length speed-adaptive smoothing + velocity-aware Bézier (§2.6).
- The lightness-map quadratic (§2.8) and — *if the survival spike passes* — HEIGHT-mode grain (§2.7).
- The asymmetric avg-opacity hysteresis exponent 0.1 (§2.3) — when opacity goes dynamic.

---

## 4. Phased plan

Sequenced so the keystone lands early on the unified substrate, **highest model-leverage CHEAP work
front-loaded** (the revision pulled per-stroke hue/value color, lightness-map tips, and the
substrate-independent wet improvements forward — see §8), every step independently shippable and
`git revert`-able, the risky GPU-reservoir wet rework last on a proven base. **This plan's phases amend
and interleave with `unified-brush-engine.md`'s Steps 0–5** — the substrate refactor is a prerequisite,
called out per phase.

| Phase | What it adds | Krita grounding | img2img leverage | Effort | Risk |
|---|---|---|---|---|---|
| **P0. Substrate refactor** (= unified Steps 0–2, AMENDED descriptor §2.1) | `BrushDescriptor` with `[ParamID: CurveOption]` map, migration map reseeded from today's scalars, `Stroke.seed` + dab-batch boundaries, unified dab fragment, SAB ping-pong + dirty-bbox, the **3-PSO Glaze/Build-up/erase family** frame-rate-independent | unified-brush-engine.md (its substrate) | enabler | M | Med (Glaze frame-rate gate BLOCKING, `unified:292`) |
| **P1. KEYSTONE — sensor+curve layer (both folds)** | `ResponseCurve`(LUT+identity fast-path), `Sensor` enum, `CurveOption`(size-like + rotation-like folds); size/opacity/flow/spacing/ratio (size-like) + rotation (rotation-like) curve-driven; capture azimuth + derived speed (timestamp-vs-estimator tuning) + drawingAngle + seed-RNG on `StrokePoint` | doc 02 (`krita: KisCurveOption.cpp:61-163`); docs 01/06 | **HIGH** | L | Med (CPU-bake cost — **exit-gate benchmark**, vertex-stage escape hatch first-class) |
| **P2. High-leverage dynamics presets + per-stroke COLOR** | pressure/speed→size, pressure→opacity+flow, drawingAngle→ratio/rotation, taper-over-arc-length, scatter (direction-aware), anisotropic-tip rotation; **per-stroke H/S + pressure→value(darken) baked into `StampInstance.color`** (pulled forward from old P6 — same machine, HIGH model-leverage, zero shader risk) | doc 02 §3, doc 06 §3, doc 09 | **HIGH** | M | Low–Med (RNG determinism solved in P1) |
| **P3. Stabilization rebuild** | arc-length speed-adaptive smoothing (replace EMA bug) **[HIGH: Bézier curvature]** + optional pressure/tilt smoothing **[MED: hand-feel, conservative σ cap]**; catch-up-on-lift | doc 10 §3 (`krita: kis_tool_freehand_helper.cpp:465-607`) | HIGH (curvature) / MED (smoothing) | M | Low (pure CPU, upstream) |
| **P4a. Lightness-map tips (standalone)** | reinterpret the alpha-only tip art we already load as value-carrying via the Schatz quadratic; **CPU pre-bake into `StampInstance.color`** (preferred) gated by an offline color oracle | doc 12 §3.3 (`krita: KoColorSpacePreserveLightnessUtils.h:41-65`) | **HIGH** (value structure) | S | Med (HSL gamma — offline oracle FIRST) |
| **P4b. Editable tip + aspect ratio** | falloff-curve LUT tip (GUARDED, generality not perf — analytic round stays default), aspect ratio (chisel) | doc 05 §1.3 | MED (edge hardness) | M | Med (LUT self-AA — keep analytic/fwidth path) |
| **P5. Time axis / airbrush** | parallel time accumulator `min(dist,time)`, held-still dabs at the airbrush RATE via display link, `sqrt` auto-spacing, `ignoreSpacing` mode; airbrush rate a `CurveOption` | doc 04 §1, §5 | MED-HIGH (soft value fields) | S–M | Med (replay determinism; **dry-only budget — wet+airbrush forbidden until P7 budget spike passes**) |
| **P6. Color dynamics (remainder)** | per-dab/low-freq speckle, secondary-ink + gradient-along-stroke (per-stamp `mix∈[0,1]` curved over arc-length; Distance→mix coupling is option-wiring) | doc 09 §3 (`krita: KisHSVOption.cpp:44-53`) | MED (speckle resynthesized; gradient HIGH) | M | Low |
| **P7. Wet rework** (= unified Step 3, enriched) | KM into unified fragment; GPU reservoir Pass A; **directional-smear axis** (`smearVector` per-dab + dirty-bbox expansion); curve-driven Mix/Smear/colorRate (`colorRate²` default) | doc 08 §3, §5 | **HIGHEST** (pigment = conditioning intent) | L | High (600px-wet-airbrush budget; color-space; determinism — `unified:276`) |
| **P8. Grain (COMMITTED — confirmed to survive img2img)** | document-space tiled **coarse value-grain**; HEIGHT mode + strength-as-curve | doc 07 §3 (`krita: KisMaskingBrushCompositeOp.h:555-580`) | **MED-HIGH** (coarse value/edge grain conditions klein — confirmed) | M | Med (doc-space UV invariance; coarse-vs-fine scale tuning) |
| **P9. Superset families + masking + blend modes** | bristle / proximity-connect **stamp-generation strategies**; filter-brush *category*; narrowed masking brush (1 extra tip sample + `maskBlendMode`); curated value blend modes | doc 11 §3, doc 12 §3.1-3.2 | MED-HIGH (bristle/filter) | L | Med (instance budget; mask×Glaze — test) |

**Per-phase detail follows.** P0/P2/P3/P5/P7/P9 detail unchanged in substance from the per-phase notes
below; P1, P4, P6, P8 carry the corrections above.

### P1 — The keystone (both folds), with the input model widened

**Adds.** `ResponseCurve` (control points → 256-entry baked `[Float]` LUT, identity → `nil` fast-path),
a `Sensor` enum (Pressure, Speed, DrawingAngle, Distance, Fade, TiltElevation, TiltDirection,
FuzzyPerDab, FuzzyPerStroke; Rotation/barrel gated), and `CurveOption{sensors:[{sensor,curve}],
combineMode, foldKind, strength, min, max, useCurve}`. Size/opacity/flow/spacing/ratio route to the
**size-like** fold; rotation/hue/scatter-angle/tilt-direction route to the **rotation-like** fold
(§2.1). `StrokePoint` gains `azimuth`, derived `speed`/`drawingAngle`/`distance`; `Stroke` gains
`seed: UInt64`. A `StrokeDynamicsState` accumulates arc-length / dab index / smoothed speed / heading in
the resample loop (Krita threads this via `KisDistanceInformation`).

**Krita grounding (verified this revision).** Both folds — size-like `krita: KisCurveOption.cpp:78-88`,
rotation-like `:61-76`; shared sensor dispatch + combine modes `:102-163`. Sensor → own LUT, identity
dropped to nullopt — `krita: plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:21-23,34-51`.
Curve baked once — `krita: libs/image/kis_cubic_curve.cpp:136-152`. Per-paintop consumption —
`krita: plugins/paintops/defaultpaintops/brush/kis_brushop.cpp:115-144`.

**Metal sketch.** Evaluate `CurveOption`s **CPU-side per interpolated dab** in the existing
`generateStampsForStroke` loop (`MetalCanvasView.swift:2403-2436`), where `effectiveWidth`
(`DrawingEngine.swift:147`) is called today. LUT = flat `[Float]`, runtime read = clamp+floor+lerp.
Identity fast-path keeps the plain pen as cheap as today. Bake resolved scalars into `StampInstance`.
**No fragment-shader change; no GPU round-trip; no new pass.** Do **not** move curves to a
fragment-sampled LUT texture (the obvious-but-wrong GPU answer); dynamics resolve to per-dab scalars,
which belong in `StampInstance`.

**Honest cost framing (critique).** The baseline is **one `effectiveWidth` call per dab**
(`DrawingEngine.swift:147`), **not** the wet path's `getBytes` — do not compare against the readback to
make the bake look free. P1 replaces that one call with N sensor LUT-evals + the fold, on the **same
main-thread per-event path** that already writes the `.shared` `StampInstance` buffer
(`CanvasRenderer.swift:346-351`). The identity fast-path only helps the plain pen; the high-leverage
presets (scatter, color dynamics, multi-sensor size) are exactly where every fast-path is OFF and dab
count is highest. **Two mitigations, both first-class:**
1. **Vertex-stage escape hatch** — move per-instance scalar jitter (scatter offset, color jitter) into
   the vertex shader (which already has per-instance attrs + can take a seed), so the GPU does it for
   free. Treat as a design *option* for P2/P6, not a last-resort fallback (`unified:103`).
2. **Keep `StampInstance` minimal** — bake only fields the GPU reads per-vertex. `wetness`,
   `grainPhase`, `reservoirIndex` are **wet-only**: gate them into a *separate wet-only instance
   layout / parallel buffer* allocated only when `wetness>0` (mirroring the plan's "allocate
   sabPrev/reservoir only if wet" discipline, `unified:121`). Today's `StampInstance` is 6 fields /
   28 bytes (`CanvasRenderer.swift:153-159`, verified); doubling its width doubles the per-dab
   main-thread memcpy at `maxStampsPerFrame=4096` (`:163`). For dry brushes (the 99% path) keep the
   instance near today's width.

**P1 EXIT GATE (mandatory, not "early").** Benchmark a **dense scatter + color-dynamics brush at 240Hz
coalesced touches** (the worst case the identity fast-path cannot cover) at full `StampInstance` width,
measuring the per-frame buffer fill. P1 does not ship until this clears the <8ms budget on the oldest
target iPad.

**img2img.** HIGH — pressure/speed→size, pressure→opacity+flow, drawingAngle→ratio/rotation. The
Fuzzy/jitter family is the lowest-leverage branch (klein resynthesizes fine grain) — build the machine
generally, tune presets toward size/value/edge first.

**Effort L. Risk Med.** Speed normalization constant unverified (Krita's lives in the tool layer);
tune on-device. Azimuth noisy near vertical — freeze at last stable value, measure on device.

### P2 — High-leverage dynamics presets + shape dynamics + per-stroke color

**Adds.** The presets that exercise P1: pressure/speed→size, pressure→opacity & flow
(`krita: kis_brushop.cpp:131`), drawingAngle→ratio/rotation (flat-nib calligraphy), taper as an
α/width ramp over normalized arc-length, **scatter** (port `krita: KisScatterOption.cpp:32-64` verbatim
— `jitter=(2·rand−1)·diameter·strength`, along-path / perpendicular / both-axes), **anisotropic-tip
rotation** (rotation field via the rotation-like fold). **Plus the pulled-forward cheap color slice:
per-stroke H/S jitter + pressure→value(darken)**, baked into `StampInstance.color` — same machine, HIGH
model-leverage, zero shader risk (revision §8).

**De-scope (critique).** **Per-dab size/opacity *speckle* presets are de-scoped from P2's shipped
preset list** (keep the general machine; drop the tuned speckle preset) until a survival spike shows
klein preserves it — the model averages per-dab speckle out at JPEG resolution
(`_CONTEXT.md:29-30`). Reserve preset-tuning budget for size/value/edge/scatter-silhouette presets.

**Metal sketch.** All CPU-bake into `StampInstance`. Scatter perturbs `center`; jitter via
`hash(seed,index,channel)`. Color jitter in sRGB-HSV → `s2l` → premultiply, hue wraps mod 1.0. Fragment
stays branch-free. Dry shape/color dynamics are **not gated behind wet-determinism** — seed+index makes
preview and commit/undo replay identical (doc 06 §5).

**img2img HIGH. Effort M. Risk Low–Med** (hash quality — eyeball a dense scatter field offline).

### P3 — Stabilization rebuild

**Adds.** Replace the per-event EMA with arc-length-weighted, speed-adaptive Gaussian smoothing.
**[HIGH — ship first]:** velocity-aware cubic Bézier between anchors (curvature is the shape klein
reads), flattened to stamp spacing. **[MED — defer/conservative]:** optional pressure/tilt smoothing
toggle (hand-feel; cap σ low at a live conditioning feed). Catch-up-on-lift.

**Krita grounding (verified).** `krita: kis_tool_freehand_helper.cpp:516-607` (Gaussian-over-distance),
`:465-479` (speed-adaptive σ), `:434-457` (velocity-aware Bézier control points). Speed from estimated
sample-rate by default, raw-timestamp path also exists (`krita: kis_speed_smoother.cpp:103,144-165`) —
evaluate iPad `UITouch.timestamp` reliability (§2.2).

**Metal sketch.** Pure CPU, upstream of the GPU, in `touchesMoved`. No new passes, no readback.
**img2img HIGH (curvature) / MED (smoothing). Effort M. Risk Low.** Cap max σ lower than Krita; don't
feed predicted touches into the recursive smoother.

### P4a — Lightness-map tips (standalone, pulled forward) · P4b — Editable tip + aspect ratio

**P4a adds.** Reinterpret the grayscale tip art we already load (alpha-only) as value-carrying via
`setLightness(brushColor, quadratic(tipLuma))`. **Prefer the CPU pre-bake** into `StampInstance.color`
(tipLuma constant per dab → no fragment cost). If done in-fragment instead, do the quadratic in sRGB
(convert linear→sRGB→linear around it). **Offline color oracle against the Krita util FIRST**
(`feedback_verify_shader_color_offline`, `CanvasModule/CLAUDE.md` color rules). Krita grounding:
`krita: KoColorSpacePreserveLightnessUtils.h:41-65`. **img2img HIGH. Effort S. Risk Med (gamma).**

**P4b adds.** Replace the analytic round falloff with a **baked 1D LUT** (R16Float) **only when a brush
specifies a custom falloff curve** (`hasFalloffLUT` binding-guard, mirroring `hasShape`/`hasGrain`).
**The current round fragment is branch-free analytic ALU with `fwidth` AA** (`CanvasRenderer.swift:1520-1529`,
verified) — the LUT is **NOT cheaper** (it adds a binding + a dependent texture fetch and loses
self-AA). **Justify the LUT on GENERALITY, not perf**; keep the analytic hardness-driven falloff as the
default (it self-AAs and costs nothing). On the LUT path, reconstruct screen-space AA explicitly or fall
back to analytic below the oversample threshold. Add **aspect ratio** (vertex Y-scale; reuse the
plumbed rotation → chisel/calligraphy). Krita grounding:
`krita: libs/brush/kis_curve_circle_mask_generator.cpp:26-105`. **img2img MED. Effort M. Risk Med
(LUT self-AA at small radii).**

### P5 — Time axis / airbrush

**Adds.** Parallel time accumulator (`min(distanceFactor, timeFactor)`), held-still dabs synthesized on
the existing `CADisplayLink` **at the airbrush RATE, not the display rate** (§2.4 — bounds the cost and
the dirty-frame defeat), `sqrt` auto-spacing, `ignoreSpacing` pure-timed mode. Airbrush rate a
`CurveOption`. **Wet+airbrush co-enablement is FORBIDDEN until P7's 600px-wet budget spike passes**
(the load-bearing combined risk lives in P7; gate P5 on a dry-only budget test).

**Krita grounding (verified).** `krita: kis_distance_information.cpp:405-448` (min combine),
`:557-587` (time accumulator), `kis_tool_freehand_helper.cpp:967-989` (held-still synthesis),
`kis_paintop_utils.h:162` (sqrt auto-spacing).

**Metal sketch.** CPU stamp-gen; rides the dirty-frame render — no new command buffer, no
`waitUntilCompleted`. Record each emitted timed dab for deterministic replay (doc 04 §6.1).
**img2img MED-HIGH. Effort S–M. Risk Med.**

### P6 — Color dynamics (remainder)

**Adds.** The non-pulled-forward color work: per-dab / low-frequency per-dab jitter, secondary-ink mix
+ **gradient-along-stroke** (per-stamp `mix∈[0,1]` curved over arc-length; **the Distance→mix coupling
is option-wiring, inferred, not at `kis_color_source.cpp:119`** — §2.9). (Per-stroke H/S +
pressure→value already shipped in P2.)

**Krita grounding (verified).** `krita: KisHSVOption.cpp:44-53` (HSV as curve-options; hue =
rotation-like fold), `KisBrushOpResources.cpp:73` (source→mix→darken→HSV order),
`kis_color_source.cpp:81,119-124` (Plain/Gradient scalar mix), `KisDarkenOption.cpp:53` (darken).

**Metal sketch.** Bake per-stamp into `StampInstance.color`; jitter in sRGB-HSV → `s2l` → premultiply.
**Skip `TOTAL_RANDOM`**. **img2img MED (speckle) / HIGH (gradient). Effort M. Risk Low.**

### P7 — Wet rework (the marquee, = unified Step 3 enriched)

**Adds.** Move KM into the unified dab fragment (sample `belowTex`+`sabPrev`, not framebuffer-fetch —
fixes Simulator-dead wet). GPU reservoir Pass A (after benchmarking the per-frame coalesced readback,
`unified:146`). **The directional-smear axis** (`smearVector` per-dab on `StampInstance` + **expand the
`sabPrev` dirty-bbox by the max smear magnitude**, §2.5). Mix/Smear/colorRate become `CurveOption`s
(`colorRate²` default Mix curve, `krita: KisColorSmudgeStrategyBase.cpp:159`).
**Already committed in unified §3.3/§4, cited as enrichment not addition:** killing the per-dab 1px
`getBytes` (`CanvasRenderer.swift:585`), smudge radius (Pull/Grade/Blur).

**Krita grounding (verified).** Smear-vs-dull orthogonal to strategy via the `m_useDullingMode` ctor
flag — `krita: KisColorSmudgeStrategyBase.cpp:113-114,123,192`; displaced srcRect —
`krita: kis_colorsmudgeop.cpp:192`. **Krita has no carried load + linear-RGB smear → blue+yellow→gray;
we keep KM (→green) + the reservoir — our moat.**

**Metal sketch.** Per `unified:276`. Specify the linear↔sRGB-premultiplied composite conversion
(`unified:129`); record dab-batch boundaries for replay; verify `wetness=0 ≡ dry` (identity oracle) and
blue-through-yellow→green offline before device. **Skip Krita's heightmap impasto** — lightness-modulated
micro-relief is exactly the PBR micro-detail klein discards (doc 08 §4).

**img2img HIGHEST. Effort L. Risk High** (600px-airbrush budget — load-bearing once P5+P7 combine —
color-space, determinism).

### P8 — Grain (COMMITTED — confirmed to survive img2img)

**Status (Donald, 2026-06-20): grain survives the img2img interpretation** — the draft's
"unmeasured inference / gate it" stance is corrected (§2.7). This is a committed phase. The target is
**coarse value-grain / dry-media break-up** (the surviving half), NOT fine per-pixel tooth (still skipped
per §5 — that half is resynthesized). Sequenced after P1 only because it reuses the strength `CurveOption`
and document-space UV plumbing, not because of a gate.

**Adds.** Document-space tiled grain (`grainUV = canvasPos·scale + offset`); **HEIGHT
mode** (non-soft branch `clamp(0, dst/(1−s) − (src+(1−s)), 1)`; soft branch `…− src·s` — §2.7) +
strength as a `CurveOption`; brightness/contrast/invert as sample-time uniforms. Tune grain *scale*
toward the coarse end (the value/edge-conditioning band klein honors), away from sub-pixel tooth.

**Krita grounding (verified).** `krita: KisMaskingBrushCompositeOp.h:555-580` (HEIGHT, both branches),
`kis_texture_option.cpp:301-302` (document-space tiling), `KisStandardOptions.h:50` (strength curve).

**Metal sketch.** +1 texture sample + ~5 ALU in Pass B; `hasGrain==0` → identity. Verify document-space
UV invariance under pan/zoom/rotate (`unified:296`). **img2img MED-HIGH (coarse value-grain confirmed
to survive). Effort M. Risk Med.** Depends on P1 (strength curve) + document-space UV plumbing.

### P9 — Superset families + masking + curated blend modes

**Adds.** Bristle **stamp-generation strategy** (instanced sub-strokes per bristle, ink-depletion via a
curve LUT, soak via one footprint `getBytes` at `touchesBegan`), proximity-connect **stamp-generation
strategy** (capped point buffer + thin-line instances), filter-brush **category** (compute
blur/sharpen/saturation through a stroke mask, once-per-stroke like our flatten — the one new category,
not a render branch). Narrowed masking brush (one extra `maskTipTex` sample + `maskBlendMode` uniform,
fused into coverage; **port Krita's "don't erase below" clamps verbatim**,
`krita: KisMaskingBrushCompositeOp.h:375,514`). Curated **value** blend modes (Multiply/Add/Overlay/
Darken — **Krita's masking UI curates ≈148 total composite ops down to ≈15 modes
(`krita: libs/ui/tool/strokes/KisMaskingBrushCompositeOp.h:25-41` — the enum), all value/luminosity,
no hue/sat**; full set ≈148 `COMPOSITE_*` ids in
`krita: libs/pigment/KoCompositeOpRegistry.h`).

**Metal sketch.** All stamp-gen strategies are instanceable, **no new render branch** (same unified dab
fragment); only the filter-brush adds a compute pass (once-per-stroke). Masking-brush precondition
(isolated buffer) is already our SAB. Verify a masked self-crossing stroke still saturates flat under
Glaze (a Linear-Dodge mask that *adds* coverage could fight the cap — doc 12 §6.2).

**img2img MED-HIGH. Effort L. Risk Med** (bristle instance budget; mask×Glaze; filter live-preview cost
— once-per-stroke is safe, per-frame blur on large brushes is the risk).

---

## 5. Deliberately NOT building (with reasons)

| Not building | Why | Source |
|---|---|---|
| **Materials / Metallic / Roughness / PBR relighting** | a relit canvas with no 3D scene is obliterated by klein's own lighting; zero leverage. Fields *stored* for lossless `.brush` import | `unified:225,308`; doc 12 §4 |
| **Tangent-normal / HEIGHT composite impasto** | authors normal/height data for relighting; the JPEG carries no normal channel; klein resynthesizes micro-surface | doc 08 §4, doc 11 §4, doc 12 §4 |
| **Barrel-roll dynamics (full)** | Pencil-Pro-only; small audience; modest at-JPEG-resolution effect. Captured as optional `barrelRoll?` | doc 01 §4, `unified:308` |
| **`TOTAL_RANDOM` color source / per-pixel RGB noise** | non-deterministic in Krita itself (breaks our replay); klein resynthesizes per-pixel noise | doc 09 §1.1, §3 (`krita: kis_color_source.cpp:181`) |
| **Per-dab size/opacity *speckle* presets** (machine kept, preset dropped) | model averages per-dab speckle out at JPEG resolution; build the machine, don't tune the speckle preset until a survival spike says so | `_CONTEXT.md:29-30`, §2.7, revision §8 |
| **Pixel-Perfect stabilization** | pixel-art staircase removal; meaningless on a 2048² antialiased img2img canvas | doc 10 §1.6 |
| **GIH animated-tip pipe / multi-frame selection** | high effort; klein eats per-stamp texture variation | doc 05 §6.3 |
| **Density / spikes / mask grain (fine)** | hand-feel only; klein resynthesizes fine per-pixel dither | doc 05 §4, doc 06 §4 |
| **particle / curvebrush / gridbrush / hatching paintops** | klein overwrites the specifics; the dynamics layer + a texture captures the survivors more cheaply | doc 11 §3 |
| **Full ~148-mode blend matrix / HSL hue modes** | most normalized away; klein re-derives hue. Ship the value subset only | doc 12 §3.2, `unified:308` |
| **Krita's stateful taus88 RNG + mutex'd per-stroke QHash** | a CPU artifact; stateless hashing is lock-free, replay-trivial — we exceed it | doc 06 §3 |
| **Krita's Halton-sampled convergence loop for smudge radius** | a CPU cost-reduction trick; a GPU mip/tap *is* the full average | doc 08 §5.2 |
| **Mixbox under CC-BY-NC** | App Store / Critical Constraint #4 — never *ship* it unlicensed; free spectral KM stays the engine | `pro-brush-roadmap:335`, `unified:309` |
| **On-device full Brush Studio IDE** | curated preset library + dev panel; the descriptor exposes every param, the UI curates | `feedback_ipad_dev_toggles`, `unified:310` |

**Throughline:** capability is foreclosed nowhere (the descriptor *stores* the rejected fields and the
substrate *admits* them). We reject on **leverage**.

---

## 6. Open risks (carried from the findings, must be resolved in implementation)

1. **Glaze frame-rate-independence under incremental accumulation** (BLOCKING, gates P0; `unified:292`).
   The P0 task is "confirm the 3-PSO family is frame-rate-independent," NOT "reduce to 1 PSO" (§2.3).
2. **CPU-bake cost at high count/scatter** — **P1 exit-gate benchmark** (dense scatter+color at 240Hz,
   full StampInstance width); vertex-stage escape hatch + minimal-instance/wet-only-layout first-class
   mitigations, not fallbacks (§P1, `unified:103`).
3. **`StampInstance` byte-width growth** — wet-only fields gated into a separate layout; benchmark the
   per-frame buffer fill at full width as part of the P1 exit gate (§P1).
4. **Speed normalization constant + timestamp-vs-estimator choice** — Krita defaults to the
   sample-rate estimator (tablet timestamps unreliable) but has a raw-timestamp flag; iPad
   `UITouch.timestamp` may be reliable enough to use directly — tune on-device (§2.2).
5. **Azimuth/coalesced-touch fidelity** — sim can't drive Pencil; measure on Donald's device.
6. **HSL lightness-map gamma** in linear-`_srgb` textures — offline oracle FIRST; prefer the CPU
   pre-bake to keep it off the fragment entirely (§2.8).
7. **Falloff-LUT self-AA at small radii** — keep the analytic `fwidth` round path as default; bind the
   LUT only for custom-falloff brushes (§P4b).
8. **Replay determinism for timed/airbrush dabs** — record emitted dabs, don't re-run the clock; emit
   at the airbrush rate to keep the recording small (§2.4).
9. **Held-still airbrush defeats the dirty-frame idle optimization** — deposit at the airbrush rate, not
   the display rate (§2.4).
10. **Directional-smear displaced reads vs dirty-bbox `sabPrev`** — expand the blit bbox by the max
    smear magnitude (§2.5).
11. **Per-dab color/mask spatial scale** — *inference, not measurement*: per-dab micro-jitter may be
    averaged out at JPEG resolution (doc 09 §6.2, doc 12 §6.3). (Grain survival is **no longer** an open
    inference — confirmed to survive per Donald 2026-06-20; §2.7/P8. The remaining grain tuning question
    is coarse-vs-fine *scale*, not whether it survives at all.)
12. **Wet 600px-airbrush budget** on the oldest iPad — load-bearing once P5+P7 combine; **wet+airbrush
    co-enablement forbidden until this passes** (§P5, doc 04 §6.3).
13. **Mask×Glaze interaction** — a coverage-adding mask could fight the saturation cap; test (doc 12 §6.2).

---

## 7. Key files (current → target)

- `ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift` — `StrokePoint`/`BrushConfig`
  → `BrushDescriptor` (the AMENDED `[ParamID: CurveOption]` map) + `CurveOption`/`Sensor`/`ResponseCurve`
  (both folds) + widened `StrokePoint` (`decodeIfPresent`, the pattern at `:164-191`).
- `ios/Packages/CanvasModule/Sources/CanvasModule/MetalCanvasView.swift` — `generateStampsForStroke`
  (`:2403-2436`: CurveOption eval + scatter + time accumulator + airbrush), `smoothedStrokePoint`
  (`:2587-2604`: stabilization rebuild), CPU smear helpers (retired in P7).
- `ios/Packages/CanvasModule/Sources/CanvasModule/CanvasRenderer.swift` — `StampInstance`
  (`:153-159`: minimal dry layout + wet-only layout), unified dab fragment (`:1520-1529`: keep analytic
  falloff default; falloff LUT guarded; lightness-map; grain HEIGHT; masking fuse; KM),
  per-stroke 3-PSO family, reservoir Pass A.
- `documents/plans/unified-brush-engine.md` — **AMEND §2.1 (descriptor → `[ParamID: CurveOption]`
  map), §2.3/§6-Step-0 (migration map reseeded from today's scalars).** P0 = its Steps 0–2, P7 = its
  Step 3. This plan is the amendment; unified is the system-of-record.

---

## 8. Revision log — how the four critiques were addressed

| # | Critique finding (severity) | Resolution |
|---|---|---|
| C1-1 | **Major** — §2.1 keystone states only the size-like fold; rotation/hue use a structurally different `rotationLikeValue` fold | **FIXED.** §2.1 now quotes **both** folds verbatim (size-like `KisCurveOption.cpp:78-88`, rotation-like `:61-76`), notes `wrapValue`, `2·offset`, `scalingToAdditive` direction, and the HSV split (hue→rotation-like, S/V→size-like, `KisHSVOption.cpp:44-53`). Each param tagged with its `foldKind` and routed. Re-verified against source. |
| C1-2 | **Minor** — §P9 masking citation points at a Color-Burn helper; "70→10" numbers imprecise | **FIXED.** Repointed to the enum `KisMaskingBrushCompositeOp.h:25-41` (≈15 modes, all value/luminosity) and `KoCompositeOpRegistry.h` (≈148 total). Corrected figures to "≈148 → ≈15." |
| C1-3 | **Minor** — §2.5 smear-vs-dull cited `:184` (`blendBrush`); orthogonality flag is `m_useDullingMode` | **FIXED.** Now cites the ctor flag `:113-114`, member `:123`, branch `:192`; `:184` was `blendBrush`. Re-verified. |
| C1-4 | **Minor** — §2.3 avg-opacity hysteresis cited `:94`; off by one + asymmetry undescribed | **FIXED.** Cites `:95` (exponent) inside `:93-105`; documents the rise-immediate / fall-EWMA asymmetry that "carves light notches." |
| C1-5 | **Minor** — speed sensor presented as estimator-only; Krita has a raw-timestamp flag | **FIXED.** §2.2 notes `useTimestampsForBrushSpeed` (`kis_speed_smoother.cpp:103`, default false) and frames iPad timestamp-vs-estimator as a tuning choice, not copy-verbatim. Open risk #4. |
| C1-6 | **Minor** — gradient Distance-sensor coupling stated as verified at `:119`; only the scalar `mix` is there | **FIXED.** §2.9 + §P6 mark the Distance→`mix` coupling **inferred** (option-wiring), verified only that `selectColor(double mix, ...)` consumes a scalar (`kis_color_source.cpp:119-124`, `pi` unused). |
| C2-1 | **Major** — "strictly cheaper than getBytes" hides that P1 adds work to the per-event main-thread path; identity fast-path doesn't cover the high-leverage presets | **FIXED.** §P1 reframes the baseline as one `effectiveWidth`/dab (not getBytes), makes the **vertex-stage escape hatch first-class**, and makes the dense-scatter+color 240Hz benchmark a **P1 EXIT GATE**, not "early." |
| C2-2 | **Major** — falloff-LUT called "cheaper than today's branchy shader"; current shader is branch-free ALU with fwidth AA | **FIXED.** §P4b: current fragment is verified branch-free (`CanvasRenderer.swift:1520-1529`); LUT justified on **generality, not perf**, gated behind `hasFalloffLUT`; analytic `fwidth` round stays the default + self-AA preserved. |
| C2-3 | **Major** — lightness-map "two-line fragment change" contradicts the offline-gamma-oracle requirement; adds RGB→HSL per dab | **FIXED.** §2.8/§P4a recharacterized as a **color-sensitive change gated by an offline oracle**, and **prefers the CPU pre-bake** (tipLuma constant per dab) to keep the conversion off the fragment entirely. |
| C2-4 | **Major** — widening `StampInstance` doubles per-dab main-thread memcpy; treated as free | **FIXED.** §P1: keep `StampInstance` minimal (verified 28 bytes today, `:153-159`); **wet-only fields → separate wet-only layout** allocated only when `wetness>0`; buffer-fill width benchmarked in the P1 exit gate. Risk #3. |
| C2-5 | **Minor** — `smearVector` called a per-stroke uniform but the displacement is per-dab; displaced reads vs dirty-bbox `sabPrev` unreconciled | **FIXED.** §2.5/§P7: `smearVector` rides **`StampInstance` (per-dab)**; **expand the `sabPrev` dirty-bbox by the max smear magnitude** so displaced reads hit valid texels. Risk #10. |
| C2-6 | **Minor** — held-still airbrush defeats the "only renders when dirty" idle optimization | **FIXED.** §2.4/§P5: deposit held-still dabs **at the airbrush rate, not the display rate**, bounding cost and keeping the replay recording small. Risk #9. |
| C2-7 / C4-major | **Major / Major** — "6-PSO → 1-PSO collapse" is a strawman: unified already uses 2 blend-state PSOs (3 w/ eraser); a single source-over PSO can't do cap-vs-accumulate (rejection #6); flow-target-alpha ≠ blend equation | **FIXED.** §2.3 fully rewritten: the **3-PSO family is the load-bearing floor**, flow is adopted as the **per-dab target-alpha** enriching the existing coverage-curve uniform, the P0 task is reframed as "confirm 3 + prove frame-rate-independence," and the conflation is called out. |
| C3-1 | **Major** — phase ordering inverts leverage: HIGHEST-leverage color (P6) + wet (P7) sequenced near-last behind cheaper fidelity work | **FIXED.** Pulled the **cheap high-leverage color slice (per-stroke H/S + pressure→value) forward into P2**; split P4 so **lightness-map (P4a) ships standalone early**; extracted no-substrate-needed wet improvements (directional smear is the new term; getBytes/smudge already committed). |
| C3-2 | **Major** — P4 conflates highest-leverage lightness-map with lower-leverage falloff-LUT behind LUT-aliasing + gamma risk; P8 grain leverage is an unmeasured inference yet scoped as a full phase | **FIXED.** Unbundled into **P4a (lightness-map, early)** + **P4b (falloff-LUT/aspect, medium)**; **P8 grain demoted to a survival-spike-gated experiment** (§2.7/§P8), built only if the spike passes. **[SUPERSEDED 2026-06-20: grain confirmed to survive img2img per Donald → re-promoted to a committed phase; the gate is removed. See §2.7/§P8.]** |
| C3-3 | **Minor** — P5 airbrush sequenced before P7 though their combined wet+airbrush budget is the actual risk | **FIXED.** §P5 gates airbrush on a **dry-only budget test** and **forbids wet+airbrush co-enablement until P7's 600px budget spike passes** (risk #12). |
| C3-4 | **Minor** — P3 stabilization rated HIGH overall; pressure/tilt-smoothing half is hand-feel, lower leverage at a live feed | **FIXED.** §2.6/§P3 split: **Bézier curvature = HIGH (ship first)**, **pressure/tilt smoothing = MED (conservative σ cap, deferrable)**; cap max σ lower than Krita. |
| C3-5 | **Minor** — wet (P7) HIGHEST-leverage buried last; some wet wins don't need the substrate | **FIXED.** Acknowledged: getBytes-removal + smudge-radius are already committed in unified §3.3/§4 (not plan additions); the only genuinely new P7 term is the **directional-smear axis**. Substrate-coupled GPU-reservoir KM stays in P7 (legitimately needs the SAB). |
| C3-6 | **Minor** — P2 enumerates size-jitter speckle as a shipped preset though it's the lowest-leverage branch | **FIXED.** §P2 + §5 table **de-scope per-dab size/opacity speckle presets** (keep the machine, drop the tuned preset) until a survival spike. |
| C4-blocking | **Blocking** — plan restructures the committed `BrushDescriptor` (CurveOption machine) but never says to amend `unified-brush-engine.md`, leaving two canonical docs disagreeing + invalidating the Step-0 migration map | **FIXED.** Header + §2.1 declare this an **in-place AMENDMENT to unified §2.1/§2.3/§6-Step-0**; the migration map is rewritten to **seed CurveOptions from today's scalars** (`pressureGamma`→Pressure size-CurveOption, `tiltSensitivity`→TiltElevation size-CurveOption). Unified is the system-of-record. |
| C4-major | **Major** — §2.3 PSO strawman / rejection-#6 conflation | **FIXED** — same as C2-7 above. |
| C4-minor (bristle/proximity "mode") | **Minor** — "mode" invites the banned per-feature render branch | **FIXED.** Renamed to **"stamp-generation strategy"** (same class as scatter/count, no new render branch); filter-brush kept as the one new *category* (§2.10/§P9). |
| C4-minor (§2.5 over-claim) | **Minor** — getBytes-removal + smudge-radius presented as plan additions though already committed | **FIXED.** §2.5/§P7 scope these as "enrich the committed Pass A"; only the directional-smear axis is claimed new. |
| C4-minor (citations) | **Minor** — bare paths, line drift, HEIGHT-branch ambiguity, azimuth-comment line | **FIXED.** All Krita citations normalized to full path-relative-to-`~/krita_src`; azimuth comment confirmed at `CanvasRenderer.swift:156` (the `StampInstance` struct, verified); HEIGHT formula disambiguated (non-soft `:575-577` vs soft `:569-573`, §2.7). |

**Net:** all four reviews are **sound-with-fixes**; one **blocking** finding (declare the plan an
amendment to the unified doc) and seven **major** findings are resolved by FIXING the plan. No finding
was rebutted — every critique was accurate against the source on re-verification. The keystone
(one orthogonal sensor→curve→combine→two-fold-remap machine, CPU-resolved into `StampInstance`, GPU
fragment untouched) and the substrate (SAB / bound-source / 3-PSO family) are unchanged; the fixes
sharpen citations, correct the PSO/cost framing, reorder for model-leverage, and bind the plan to the
committed unified doc as a single system-of-record.

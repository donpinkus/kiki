# 03 — Size / Opacity / Flow / Ratio Dynamics and Accumulation (Build-up)

**Scope.** How Krita splits *opacity* (per-stroke ceiling) from *flow* (per-dab deposit), how
"Build up" vs "Wash" paint modes change the accumulation math, how size/ratio/softness are driven
by the same curve-option machinery, and how all of this maps onto Kiki's Glaze-cap model and the
unified-brush-engine SAB / PSO-selection plan.

Citations: Krita as `krita: <path-rel-to-~/krita_src>:<line>`; ours as `<path>:<line>`. **Verified**
= I read the code. **Inferred** = pattern/comment, hedged explicitly. Read `_CONTEXT.md` +
`00-krita-brush-architecture.md` first.

---

## 1. How Krita does it

### 1.1 The opacity / flow split is computed by one option, applied by the painter

`KisFlowOpacityOption2` owns two child options and produces *two* scalars per dab — opacity and
flow — then pushes both onto the painter (**verified**):

```cpp
void KisFlowOpacityOption2::apply(const KisPaintInformation &info, qreal *opacity, qreal *flow) {
    if (m_opacityOption.isChecked())
        *opacity = m_opacityOption.computeSizeLikeValue(info, !m_indirectPaintingActive);  // line 43
    *flow = m_flowOption.apply(info);                                                       // line 45
}
```
`krita: plugins/paintops/libpaintop/KisFlowOpacityOption.cpp:40`. The two-arg `apply` then calls
`painter->setOpacityUpdateAverage(opacity)` + `painter->setFlow(flow)`
(`krita: …/KisFlowOpacityOption.cpp:36`).

Both opacity and flow are full `KisCurveOption`s — i.e. each is *a response curve over sensors*
(pressure/speed/tilt/fade/…), not a scalar. `KisFlowOption`/`KisOpacityOption` are just typed
aliases of `KisStandardOption<…>` whose `apply` returns `computeSizeLikeValue(info)`
(`krita: plugins/paintops/libpaintop/KisStandardOptions.h:27,44`). So **opacity-by-pressure and
flow-by-speed are first-class** in Krita; the value funnels through `sizeLikeValue()` =
`clamp(constant · offset · scaling · additive, strengthMin, strengthMax)`
(`krita: plugins/paintops/libpaintop/KisCurveOption.cpp:78`).

### 1.2 The load-bearing trick: `opacity` is the *target ceiling*, flow is the *per-dab deposit*, and an **exponential running average** prevents within-stroke darkening

`setOpacityUpdateAverage(opacity)` does **not** just store opacity. It updates a running
*average opacity* (`lastOpacity`) via an exponential filter (**verified**):

```cpp
void ParameterInfo::updateOpacityAndAverage(float value) {
    const float exponent = 0.1;
    opacity = value;
    if (*lastOpacity < opacity) {                 // opacity rose → snap up, no smoothing
        lastOpacity = &opacity;
    } else {                                      // opacity ≤ running avg → ease down 10%/dab
        _lastOpacityData = exponent*opacity + (1.0-exponent)*(*lastOpacity);
        lastOpacity = &_lastOpacityData;
    }
}
```
`krita: libs/pigment/KoCompositeOp.cpp:94`. So `averageOpacity` rises instantly but *decays slowly*
— a hysteresis on the per-stroke opacity target as it varies with pressure.

The accumulation itself lives in the **AlphaDarken** composite op, which is the pixel brush's
default. Its alpha update (`calculateAlpha`, **verified**):

```cpp
if (averageOpacity > opacity) {
    reverseBlend = dstAlpha / averageOpacity;
    fullFlowAlpha = averageOpacity > dstAlpha ? lerp(srcAlpha, averageOpacity, reverseBlend)
                                              : dstAlpha;        // pull dstAlpha UP toward avg, never past
} else {
    fullFlowAlpha = opacity > dstAlpha ? lerp(dstAlpha, opacity, mskAlpha) : dstAlpha;
}
if (params.flow == 1.0f) return fullFlowAlpha;
else {
    zeroFlowAlpha = unionShapeOpacity(srcAlpha, dstAlpha);      // normal over-accumulation
    return lerp(zeroFlowAlpha, fullFlowAlpha, flow);            // flow interpolates ceiling↔buildup
}
```
`krita: libs/pigment/compositeops/KoCompositeOpAlphaDarken.h:96`. Read this carefully — it is the
single most important finding of this topic:

- **`flow = 1.0`** → returns `fullFlowAlpha`, which *clamps the accumulated alpha to the
  (average) opacity ceiling*. Painting back and forth over the same spot **stops darkening once it
  reaches the opacity target** — overlapping dabs within a stroke saturate to `opacity`, they do
  not stack. This is exactly Kiki's "Glaze."
- **`flow < 1.0`** → `lerp(zeroFlowAlpha, fullFlowAlpha, flow)`. `zeroFlowAlpha` is the
  *union/over* accumulation (`srcAlpha + dstAlpha − srcAlpha·dstAlpha`,
  `krita: KoAlphaDarkenParamsWrapper.h:37`) — it keeps building past the ceiling. So lower flow =
  more of the un-clamped build-up path. **Flow is the knob between "saturate to ceiling" and
  "keep accumulating."**

The Hard wrapper additionally pre-multiplies opacity into flow:
`opacity = flow·opacity`, `averageOpacity = flow·(*lastOpacity)`
(`krita: KoAlphaDarkenParamsWrapper.h:17`). The Creamy wrapper does not, and its
`calculateZeroFlowAlpha` returns `dstAlpha` (so zero-flow leaves the canvas untouched) — a
softer, paint-like feel (`krita: KoAlphaDarkenParamsWrapper.h:43`, selected by
`useCreamyAlphaDarken()`).

### 1.3 Build up vs Wash — two *deployment* paths around the same composite op

Krita exposes a **Painting Mode** radio (Build up / Wash) (`krita:
plugins/paintops/libpaintop/KisPaintingModeOptionWidget.cpp:66`). The enum
(`krita: plugins/paintops/libpaintop/KisPaintingModeOptionData.h:16`):

```cpp
enum class enumPaintingMode { BUILDUP, WASH };
```

This maps to `paintIncremental()` (**verified**):

```cpp
bool KisBrushBasedPaintOpSettings::paintIncremental() {
    KisPaintingModeOptionData data; data.read(this);
    return !data.hasPaintingModeProperty || data.paintingMode == enumPaintingMode::BUILDUP;
}
```
`krita: plugins/paintops/libpaintop/kis_brush_based_paintop_settings.cpp:68`. And the tool turns
that into the *render target* (**verified**):

```cpp
bool KisResourcesSnapshot::needsIndirectPainting() {
    return !m_d->currentPaintOpPreset->settings()->paintIncremental();
}
```
`krita: libs/ui/tool/kis_resources_snapshot.cpp:295`.

| Mode | `paintIncremental` | Render target | Within-stroke overlap behavior |
|---|---|---|---|
| **Build up** (default) | `true` | **Direct** — dabs composited straight onto the layer as they render | Overlapping dabs *accumulate* (each dab re-applies AlphaDarken against the growing layer). Crossing your own stroke darkens. |
| **Wash** | `false` | **Indirect** — dabs composited into a *temporary target* device (`KisIndirectPaintingSupport::setTemporaryTarget`), merged onto the layer **once** at stroke end | Overlap within the stroke is flattened in the temp device; the stroke as a whole hits the layer at one opacity. Crossing yourself stays flat. |

`krita: libs/image/kis_indirect_painting_support.cpp:53,120` (temp target), and the temp target is
merged with `COMPOSITE_OVER` at end (`krita: …/kis_indirect_painting_support.cpp:239`).

**The subtlety that the names hide:** the `averageOpacity` ceiling in `calculateAlpha` is what
keeps **Build up** mode from darkening *unboundedly* at `flow=1` even though it composites directly
to the layer every dab. The boolean `!m_indirectPaintingActive` passed into
`computeSizeLikeValue` (`krita: KisFlowOpacityOption.cpp:43`) is `useStrengthValue` — in indirect
(Wash) mode it is `false`, so the opacity strength is *not* baked into the per-dab opacity (the
temp device handles the ceiling at merge time instead). In direct (Build up) mode it is `true`, so
each dab carries the opacity ceiling and the AlphaDarken average-clamp enforces it per-pixel.

So Krita has **two complementary ceilings**: (a) the per-dab `averageOpacity` clamp inside
AlphaDarken (Build up), and (b) the merge-once temp target (Wash). Kiki only has (b).

### 1.4 Size / Ratio / Softness are the same machine

`KisBrushOp::paintAt` runs each as a `KisCurveOption` and assembles a `KisDabShape`
(scale, ratio, rotation) (**verified**, `krita:
plugins/paintops/defaultpaintops/brush/kis_brushop.cpp:113`):

```cpp
scale    = m_sizeOption.apply(info) * lodScale;      // sizeLikeValue: multiplicative
ratio    = m_ratioOption.apply(info);                // anisotropy (width/height)
rotation = m_rotationOption.apply(info);             // rotationLikeValue: additive/angular
... KisDabShape(scale, ratio, rotation) ...
softness = m_softnessOption.isChecked() ? m_softnessOption.apply(info) : 1.0;  // edge hardness curve
```
`KisSizeOption`/`KisRatioOption`/`KisSoftnessOption` are all `KisStandardOption` aliases
(`krita: KisStandardOptions.h:45,46,48`). Size & ratio use `sizeLikeValue()` (multiplicative,
clamped to strengthMin/Max); rotation uses `rotationLikeValue()` (additive + angular wrap,
`krita: KisCurveOption.cpp:61`). **Every one of these is a curve over sensors**, not a scalar — the
core gap §2 names.

When >1 sensor drives a single option, `curveMode` combines them: multiply (default), add, max,
min, difference (`krita: KisCurveOption.cpp:128`).

---

## 2. How Kiki does it today

| Concept | Kiki | `file:line` |
|---|---|---|
| `flow` (per-dab deposit) | Baked into each stamp's **alpha**; stamps source-over into an isolated scratch that saturates toward α=1 | `DrawingEngine.swift:73`; `ios/Packages/CanvasModule/CLAUDE.md:138` |
| `opacity` (per-stroke ceiling) | A single multiply applied **once** when the scratch is flattened onto the layer (`color * opacity`) | `DrawingEngine.swift:69`; `CanvasRenderer.swift:387,649` |
| Glaze (self-overlap stays flat) | Emergent from the isolated scratch + single composite — *this is exactly Krita's Wash/indirect path* | `ios/Packages/CanvasModule/CLAUDE.md:140` |
| Build-up (accumulate past ceiling) | **Not implemented as a mode.** We always do the Wash/Glaze path. | — |
| Size dynamics | One `pressureGamma` scalar (pow curve) + `tiltSensitivity` scalar | `DrawingEngine.swift:75,77` |
| Ratio (anisotropy) | **Not exposed** as a brush param (stamps are isotropic radius; `rotation` plumbed, fed 0 on round) | `_CONTEXT.md:60` |
| Softness/hardness | `hardness` scalar, applied procedurally in fragment from per-stamp distance | `DrawingEngine.swift:85` |
| Opacity/flow driven by a sensor curve | **No** — both are constants per stroke | `DrawingEngine.swift:63` (flat struct) |

**Our model is structurally Krita's Wash path, made unconditional.** The scratch buffer = Krita's
temporary target; the `activeStrokeOpacity` flatten multiply = the COMPOSITE_OVER merge ceiling.
What we *lack*: (1) a Build-up mode (direct accumulation), and (2) opacity/flow as sensor-driven
curves instead of scalars.

---

## 3. Gap analysis + what a Krita-grade superset adopts

### 3.1 Krita's accumulation model vs our Glaze cap — where they differ

| | Krita | Kiki |
|---|---|---|
| Within-stroke ceiling mechanism | Two: (a) AlphaDarken per-pixel `averageOpacity` clamp at `flow=1` (Build up); (b) temp-target merge-once (Wash) | One: isolated scratch + single composite (≡ Krita Wash) |
| `flow<1` semantics | `lerp(over-accumulate, ceiling-clamp, flow)` — flow *interpolates between build-up and glaze* per dab | flow = per-stamp alpha into the saturating scratch; lower flow = slower saturation toward α=1, but **never exceeds 1**, then capped by opacity. We do **not** have the "keep accumulating past ceiling" branch. |
| Build-up (cross-yourself-darkens) | First-class mode (direct paint) | Absent |
| Avg-opacity hysteresis (the 0.1 exponent) | Yes — smooths pressure-driven opacity changes so a dip in pressure doesn't carve a light gap | No analogue (our opacity is a fixed per-stroke scalar, so no need yet — but becomes needed once opacity is pressure-driven) |

**The most important divergence:** in Krita, **flow is the continuous dial between Glaze and
Build-up** (`lerp(zeroFlowAlpha, fullFlowAlpha, flow)`, `krita:
KoCompositeOpAlphaDarken.h:137`), *within the Build up render mode*. Wash is a *separate*
orthogonal axis (where does it accumulate — temp target vs layer). Kiki collapsed both: we only
have the Wash render target, and our "flow" only controls scratch saturation rate, never the
build-past-ceiling branch. **A Krita-grade superset keeps these two axes orthogonal**, which is
precisely what the unified-brush-engine doc already proposes — see §3.3.

### 3.2 How Krita avoids vs produces within-stroke darkening — the precise rule

- **No darkening (Glaze feel):** Wash mode, *or* Build up mode with `flow=1`. In Build up+flow=1
  the AlphaDarken clamp (`averageOpacity > dstAlpha ? lerp(srcAlpha, averageOpacity, …) :
  dstAlpha`, `krita: KoCompositeOpAlphaDarken.h:128`) means a dab can only pull `dstAlpha` *up
  toward* the average opacity, never past it — so repeated dabs converge to the ceiling and stop.
- **Darkening (Build-up feel):** Build up mode with `flow<1`. The `zeroFlowAlpha` union term
  (`krita: KoAlphaDarkenParamsWrapper.h:37`) keeps adding, so each pass over the same spot gets
  darker — like a marker or airbrush layered on itself.

This is a cleaner factoring than "two buttons." A superset should expose: a **render-mode axis**
(Glaze-capped vs Build-up-accumulate) *and* a **flow** that, in build-up mode, dials between them —
matching unified-brush-engine §3.6's "4 Glaze + 2 Blend" modes + flow.

### 3.3 Mapping to the unified-brush-engine PSO-selection plan

The plan already nails the *architecture* (`documents/plans/unified-brush-engine.md:189`):

> "Glaze and Build-up are two pre-built PSOs sharing one vertex+fragment function, differing only in
> the color-attachment blend descriptor, selected once per stroke from `rendering.mode`."

| Render mode | Pass B (dab→SAB) blend (per the plan, line 193) | Krita equivalent |
|---|---|---|
| Light/Uniform/Intense/Heavy **Glaze** | source-over, coverage capped at 1; 4 variants = a coverage-curve uniform | Wash, or Build up+flow=1 (the AlphaDarken `fullFlowAlpha` clamp) |
| Uniform/Intense **Blending** (Build-up) | source-over **without** cap (deposit accumulates past ceiling) | Build up + flow<1 (the `zeroFlowAlpha` union branch) |

**Where Krita teaches the plan something it under-specifies:**

1. **The plan's "no cap" Build-up PSO is the *right call*, but Krita shows the cap isn't a hard
   clamp — it's an asymptotic approach via `averageOpacity`.** Krita's Build-up at flow=1 still
   *ceilings*, just via per-pixel convergence, not a separate render target. The plan's binary
   "capped PSO vs uncapped PSO" loses the *flow-interpolated middle*
   (`lerp(zeroFlowAlpha, fullFlowAlpha, flow)`). If we want true Krita parity, flow should
   **blend between the two PSO behaviors**, which a single blend descriptor can't express — see
   risk in §6. The plan explicitly rejected "lerp the blend factor in-shader" (line 189) as not
   numerically equivalent; Krita's code *confirms* that rejection (the two branches are genuinely
   different equations) **but also shows flow legitimately interpolates them** — so the lerp must
   happen on the *coverage value written into the SAB*, not on the blend factor. That is
   expressible: write `coverage` (capped) vs `coverage` (uncapped accumulation) is the same
   source-over; the difference is whether the SAB is allowed to exceed the ceiling. Resolvable by a
   coverage-shaping uniform feeding the *deposit*, with the PSO still source-over. **Recommendation:
   re-derive whether the 2-PSO split is even needed, or whether one source-over PSO + a
   ceiling-shaping uniform on `deposit` reproduces both Krita branches** (it appears to — both are
   source-over into the SAB; only the per-dab deposit math differs, which is a fragment uniform,
   not a blend state). This would collapse 6 PSOs to 1 + a uniform.

2. **Avg-opacity hysteresis (the 0.1 exponent) becomes load-bearing the moment opacity is
   pressure-driven.** The plan makes opacity/flow per-dab dynamics (`StampInstance.flow`, baked
   CPU-side, line 94). Once opacity varies per dab, a pressure dip will carve a light notch unless
   you replicate Krita's `updateOpacityAndAverage` smoothing (`krita: KoCompositeOp.cpp:94`). The
   plan does not mention this. **Recommendation: when opacity becomes a per-dab dynamic, carry a
   running `averageOpacity` per stroke (CPU-side, trivial) and bake the *smoothed* opacity into the
   SAB composite ceiling**, not the raw per-dab opacity.

3. **Ratio/anisotropy is in the plan (`StampInstance.size: SIMD2` = roundness, line 94)** —
   good; Krita's `KisDabShape` ratio confirms this is the right primitive. No gap.

---

## 4. img2img leverage call

- **Build-up vs Glaze mode = HIGH model-leverage.** It changes large-scale *value density* — the
  single thing klein keys on most. A build-up marker that darkens where strokes cross produces
  exactly the value clustering that reads as "rendered form" to the model; a flat glaze produces
  even fills. This is a *what-klein-sees* difference, not hand-feel. **Top priority of this topic.**
- **Opacity/flow as pressure curves = HIGH leverage.** Pressure→opacity gives tapered value at
  stroke ends and pressure-modulated density mid-stroke — directly visible value structure.
- **The avg-opacity hysteresis = hand-feel + a small correctness guard.** klein won't notice a
  one-dab light notch, but the artist will, and it's cheap. Medium priority, gated on opacity
  becoming dynamic.
- **Ratio/softness curves = medium leverage.** Edge hardness and anisotropic dabs change stroke
  *shape*, which klein sees; softness-by-pressure is a nice-to-have.

**Priority order for this topic:** (1) Build-up mode, (2) pressure→opacity/flow curves,
(3) hysteresis (only after #2), (4) ratio/softness curves.

---

## 5. Metal translation notes (perf invariants respected)

- **Build-up = one extra pre-built PSO, decided at `touchesBegan`** — no per-pixel branch, no hot-
  path cost. This is the plan's existing mechanism (`unified-brush-engine.md:189`); it costs only
  PSO compile time at init. **Sacred invariants untouched.** (But see §3.3 #1: it may collapse to a
  single PSO + uniform — verify offline.)
- **The flow→[glaze,buildup] interpolation is a fragment-uniform deposit shaping**, computed from
  the baked per-stamp `flow`, written into the SAB. No new texture reads, no framebuffer fetch. The
  SAB stays the isolated coverage buffer; only the *deposit value* per dab changes. Order-
  independent for source-over → still **one instanced draw per frame** (the plan's load-bearing
  invariant, line 179).
- **Avg-opacity smoothing is CPU-side** in `generateStampsForStroke` — a scalar EWMA over the
  baked per-dab opacity, identical to `krita: KoCompositeOp.cpp:94`'s exponent=0.1. Zero GPU cost.
  Bake the smoothed value into the SAB composite ceiling at flatten.
- **No new `waitUntilCompleted`.** All of this lives in the existing dab pass + the single
  stroke-end flatten. The Build-up ceiling, if implemented as Krita's asymptotic clamp rather than
  a temp-target merge, would need the SAB to be readable per-dab (ping-pong, which the plan already
  schedules for wet strokes) — **but the simpler Kiki-native form is: Build-up = composite the SAB
  onto the layer *without* the opacity cap, letting alpha exceed the per-stroke ceiling**, which
  needs no per-dab readback. Verify which form klein actually benefits from before paying for ping-
  pong on dry build-up strokes.

---

## 6. Open questions / risks

1. **Does flow truly need to interpolate two blend equations, or is one source-over PSO + a
   deposit-shaping uniform sufficient?** Krita uses `lerp(zeroFlowAlpha, fullFlowAlpha, flow)`
   (`krita: KoCompositeOpAlphaDarken.h:137`) — but both Krita branches are alpha-over-into-a-device;
   the difference is purely the per-pixel *target alpha*. In our isolated-SAB model both collapse to
   source-over with a different per-dab deposit, suggesting the unified-brush-engine's 6-PSO split
   (line 191) is over-engineered. **Must verify offline** (`feedback_verify_shader_color_offline`):
   render the same stroke through (a) capped-PSO, (b) uncapped-PSO, (c) one-PSO+deposit-uniform, and
   diff against a CPU port of `calculateAlpha`.
2. **Build-up past the ceiling needs per-dab SAB readback OR an uncapped final composite.** The
   former (ping-pong) is what the plan schedules for wet only; extending it to dry build-up costs
   bandwidth. The latter (uncapped flatten) is cheaper but only approximates Krita's per-pixel
   asymptote. Which does klein actually see a difference from? **Unknown — needs a klein A/B.**
3. **Creamy vs Hard AlphaDarken** (`krita: KoAlphaDarkenParamsWrapper.h:15,43`) — Krita ships two
   accumulation flavors (Hard pre-multiplies flow·opacity; Creamy leaves zero-flow as a no-op).
   Which feels right for our pencil/marker presets is untested. Default Krita uses `useCreamyAlpha
   Darken()` gating — *inferred* it's the modern default but I did not trace the gate's value.
4. **Hysteresis exponent 0.1** is a magic constant appearing in two places
   (`krita: KoCompositeOp.cpp:95` and `kis_painter.cc:2700`) — confirm both are the same intent
   (they are, both are the avg-opacity ease) before porting; do not invent a different smoothing.
5. **The `useStrengthValue = !m_indirectPaintingActive` coupling** (`krita:
   KisFlowOpacityOption.cpp:43`) means Krita changes *what opacity means* between Wash and Build up
   (ceiling baked per-dab vs applied at merge). If we expose both modes we must replicate this or
   the opacity slider will behave differently between modes — a subtle UX trap.

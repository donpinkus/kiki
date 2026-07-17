# Krita Brush Research — 02: The Sensor + Response-Curve Architecture

> Grounding: see `_CONTEXT.md`. Krita source at `~/krita_src`; cites are
> `krita: <path-relative-to-~/krita_src>:<line>`. Our code cites are bare `path:line`.
> **Verified** = I read the code. **Inferred** = pattern-matched / from a comment; hedged explicitly.

This is the single biggest architectural gap between Kiki and Krita. Krita does **not** have
"a pressure curve for size and a tilt knob for width." It has **one** abstraction — *every*
tunable brush parameter (size, opacity, flow, rotation, ratio, scatter, softness, color rate,
HSV shift, darken, …) is a `KisCurveOption`: a **set of sensors**, each running its raw input
through **its own response curve**, the results **combined by a selectable operator**, then mapped
through a **strength range**. Our whole dynamics surface today is two hardcoded scalars
(`pressureGamma`, `tiltSensitivity`) plus a single smoothing scalar. This doc reverse-engineers
Krita's machine to the math, then designs the Metal-respecting translation.

---

## 1. How Krita does it (grounded)

### 1.1 The data model — one option = (sensors × curves) → combine → strength-remap

`KisCurveOption` holds (verified, `krita: plugins/paintops/libpaintop/KisCurveOption.h:66-72`):

```cpp
bool   m_isChecked;          // option on/off
bool   m_useCurve;           // if false, sensors bypass their curves
int    m_curveMode;          // how multiple sensors combine: 0 mul / 1 add / 2 max / 3 min / 4 diff
qreal  m_strengthValue;      // the "constant" — the option's headline slider (e.g. 1.0)
qreal  m_strengthMinValue;   // output remap floor
qreal  m_strengthMaxValue;   // output remap ceiling
std::vector<std::unique_ptr<KisDynamicSensor>> m_sensors;  // the active sensors
```

Defaults (verified, `krita: plugins/paintops/libpaintop/KisCurveOptionDataCommon.h:56-65`):
`strengthMinValue=0`, `strengthMaxValue=1`, `useCurve=true`, `useSameCurve=true`,
`curveMode=0` (**multiply**), `strengthValue=1.0`, `commonCurve=DEFAULT_CURVE_STRING` (identity).

### 1.2 The sensor — read one axis, normalize to [0,1], run through its curve LUT

A `KisDynamicSensor` is a tiny object: a `KoID`, an optional `KisCubicCurve`, and a pure virtual
`value(info)` that reads exactly one axis of `KisPaintInformation` and normalizes it
(verified, `krita: plugins/paintops/libpaintop/sensors/KisDynamicSensor.h:16-47`). The sensors and
their normalizations (verified, `krita: plugins/paintops/libpaintop/sensors/KisDynamicSensors.h`):

| Sensor | `value(info)` raw → normalized | Notes |
|---|---|---|
| **Pressure** | `info.pressure()` | already [0,1]. `:42` |
| **PressureIn** | `info.maxPressure()` (max-so-far this stroke) | "fade-in by max pressure". `:52` |
| **Speed** | `info.drawingSpeed()` | pre-normalized drawing speed. `:19` |
| **XTilt / YTilt** | `1 − |tilt|/60` | 60° = full tilt. `:62,:71` |
| **TiltDirection** | `scalingToAdditive(tiltDirection(info,true))` | **additive** (azimuth). `:85` |
| **TiltElevation** | `tiltElevation(info,60,60,true)` | `:95` |
| **Rotation** | `info.rotation()/180` | **additive** (barrel/auto rotation). `:33` |
| **DrawingAngle** | `0.5 + angle/(2π) + offset/360` | **absoluteRotation**; stroke heading. `krita: .../KisDynamicSensorDrawingAngle.cpp:20-30` |
| **Distance** | `min(strokeLen,L)/L` or `fmod(strokeLen,L)/L` | length-based, periodic option. `krita: .../KisDynamicSensorDistance.cpp:21-31` |
| **Fade** | `min(dabSeqNo,L)/L` or `dabSeqNo%L/L` | dab-count based. `krita: .../KisDynamicSensorFade.cpp:21-31` |
| **Time** | `info.currentTime()` based | wall-clock fade. |
| **FuzzyPerDab** | `2·rand()−1` from `info.randomSource()` | **additive**; per-dab jitter. `krita: .../KisDynamicSensorFuzzy.cpp:25-37` |
| **FuzzyPerStroke** | `2·rand()−1` from `perStrokeRandomSource(key)` | one draw per stroke. `:30-32` |
| **TangentialPressure / Perspective** | passthrough | rarely used. |

**The curve lookup (the heart — verified, `krita: plugins/paintops/libpaintop/sensors/KisDynamicSensor.cpp:35-51`):**

```cpp
qreal KisDynamicSensor::parameter(const KisPaintInformation &info) const {
    const qreal val = value(info);                       // raw normalized axis
    if (m_curve) {                                       // null if curve is identity (optimization)
        qreal scaledVal = isAdditive() ? additiveToScaling(val)    // [-1,1] → [0,1]
                        : isAbsoluteRotation() ? wrapValue(val+0.5,0,1)
                        : val;
        const QVector<qreal> transfer = m_curve->floatTransfer(256);   // 256-entry LUT
        scaledVal = KisCubicCurve::interpolateLinear(scaledVal, transfer);  // LUT read + lerp
        return isAdditive() ? scalingToAdditive(scaledVal)
             : isAbsoluteRotation() ? wrapValue(scaledVal+0.5,0,1) : scaledVal;
    }
    return val;                                          // identity curve → raw value
}
```

Two things matter here. (1) **Identity curves are dropped to `nullopt` at construction**
(`krita: KisDynamicSensor.cpp:21-23`) so the common case (no curve drawn) skips the LUT entirely.
(2) Additive/rotation sensors are folded into a common [0,1] domain *before* the curve and unfolded
after, so **one** curve representation serves scaling, additive, and angular sensors.

### 1.3 The curve representation — control points → cubic spline → 256-entry LUT

`KisCubicCurve` stores a sorted list of `(x,y)` control points (default
`"0,0;1,1"` identity). A natural cubic spline is fit through them
(`Data::updateSpline` → `spline.createSpline(points)`,
`krita: libs/image/kis_cubic_curve.cpp:106-111`), then **baked into a discrete transfer LUT**
on demand:

```cpp
// krita: libs/image/kis_cubic_curve.cpp:136-152
void Data::updateTransfer(transfer, valid, min, max, size) {
    qreal end = 1.0/(size-1);
    for (int i=0;i<size;++i) {
        val = value(i*end) * max;        // spline eval at each LUT slot, scaled
        (*transfer)[i] = qBound(min,val,max);
    }
}
// floatTransfer(256) caches a 256-entry [0,1] LUT; uint16Transfer(N) is the 0..0xFFFF variant.
```

The per-sample read is a clamped linear interpolation between the two nearest LUT slots
(verified, `krita: kis_cubic_curve.cpp:400-426`):

```cpp
qreal interpolateLinear(normalizedValue, transfer) {
    bilinearX = clamp(0, (N-1)*normalizedValue, N-1);
    t = bilinearX - floor(bilinearX);
    return lerp(transfer[floor], transfer[ceil], t);   // (with sign-copy + eps snapping)
}
```

So the runtime cost per sensor per dab is: one axis read, an optional fold, **one LUT index + one
lerp**. The spline math happens once (LUT bake), cached and invalidated only when the artist edits
the curve. **This is the design we want to copy: author with splines, evaluate with a flat LUT.**

### 1.4 Combining multiple sensors — the exact operator code

When an option has several active sensors, each produces a curved value; `computeValueComponents`
sorts them into three buckets and combines the *scaling* bucket by `m_curveMode`
(verified, `krita: plugins/paintops/libpaintop/KisCurveOption.cpp:102-163`):

```cpp
for (sensor : m_sensors) {
    qreal v = sensor->parameter(info);
    if (sensor->isAdditive())          { components.additive += v; hasAdditive=true; }
    else if (sensor->isAbsoluteRotation()) { components.absoluteOffset = v; hasAbsoluteOffset=true; }
    else                               { sensorValues << v; hasScaling=true; }      // the multiplicative bucket
}
if (sensorValues.count()==1) components.scaling = sensorValues.first();
else if (count>1) switch (m_curveMode) {
    case 1: scaling = Σ vᵢ;                       // add
    case 2: scaling = max(vᵢ);                    // max
    case 3: scaling = min(vᵢ);                    // min
    case 4: scaling = max(vᵢ) - min(vᵢ);          // difference
    default: scaling = Π vᵢ;                       // multiply (DEFAULT)
}
```

**The combine mode applies only to the scaling (multiplicative) bucket.** Additive sensors
(Rotation, Fuzzy, TiltDirection) *always sum*; the absolute-rotation sensor (DrawingAngle)
*overwrites* an absolute offset. Verified — this is a real subtlety the "all sensors multiply"
mental model misses.

### 1.5 Collapsing components → the final brush scalar

Two final mappers turn the buckets into the value a paintop consumes:

**Size-like** (size, opacity, flow, ratio, softness — anything where 1.0 = "no change")
(verified, `krita: KisCurveOption.cpp:78-88`):

```cpp
qreal sizeLikeValue() {
    offset       = hasAbsoluteOffset ? absoluteOffset : 1.0;
    scalingPart  = hasScaling   ? scaling : 1.0;
    additivePart = hasAdditive  ? additiveToScaling(additive) : 1.0;   // [-1,1]→[0,1]
    return clamp(minSizeLikeValue, constant * offset * scalingPart * additivePart, maxSizeLikeValue);
}
```

i.e. **`output = clamp(min, strength · offset · Π(scalingSensors) · additiveTerm, max)`**. With one
pressure sensor on an identity curve and default strength/range this is just `pressure` itself; the
brush then multiplies its base size by that. The `min/max` strength range is the **output remap** —
e.g. size pressure with `min=0.2,max=1.0` means "even zero pressure paints at 20% width."

**Rotation-like** (rotation, HSV hue) wraps in [-1,1] and treats scaling as additive via
`scalingToAdditive` (verified, `krita: KisCurveOption.cpp:61-76`) — the angular analogue.

### 1.6 `useCurve` / `useSameCurve` / per-sensor curves

- **`useCurve=false`** → `computeValueComponents` skips the whole sensor loop; the option degrades
  to its constant strength (verified, `krita: KisCurveOption.cpp:106`).
- **`useSameCurve=true`** (default) → one `commonCurve` is built and passed as the `curveOverride`
  to *every* sensor, so all active sensors share one shape
  (verified, `krita: KisCurveOption.cpp:33-35,40-55`).
- **`useSameCurve=false`** → each sensor falls back to its **own** stored `KisSensorData.curve`
  (verified, the `curveOverride` is `nullopt` so the ctor uses `data.curve`,
  `krita: KisDynamicSensor.cpp:15-17`). So you can give Pressure an ease-in shape and Speed a
  separate falloff on the same parameter.

### 1.7 How a paintop actually consumes it (end-to-end, the pixel brush)

`KisBrushOp::paintAt` (verified, `krita: plugins/paintops/defaultpaintops/brush/kis_brushop.cpp:115-144`):

```cpp
qreal scale    = m_sizeOption.apply(info);      // KisSizeOption::apply → computeSizeLikeValue(info)
qreal rotation = m_rotationOption.apply(info);
qreal ratio    = m_ratioOption.apply(info);
KisDabShape shape(scale, ratio, rotation);
m_scatterOption.apply(info, ...);               // jitters the dab center
m_opacityOption.apply(info, &dabOpacity, &dabFlow);   // opacity AND flow, both curve-options
... effectiveSpacing(scale, rotation, &m_spacingOption, info);   // spacing itself is curve-driven
```

`KisSizeOption::apply` is literally `isChecked() ? computeSizeLikeValue(info) : 1.0`
(verified, `krita: plugins/paintops/libpaintop/KisStandardOptions.h:27-31`). So **size, ratio,
rotation, scatter, spacing, opacity, and flow are all the same `KisCurveOption` machine** with
different sensors enabled — there is no bespoke per-parameter dynamics code.

---

## 2. How Kiki does it today

Our entire dynamics surface (verified, `ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:63-154`):

| Krita concept | Kiki today | Cite |
|---|---|---|
| Size = curve-option over sensors | `width = baseWidth · pow(force, pressureGamma)` — **one fixed power curve, pressure only** | `DrawingEngine.swift:148` |
| Tilt → size sensor + curve | `tiltFactor = 1 + tiltSensitivity·(1−altitude/(π/2))·2` — **one fixed linear ramp** | `DrawingEngine.swift:149-152` |
| Opacity curve-option | `opacity` — **static per-stroke scalar**, no sensor | `DrawingEngine.swift:69` |
| Flow curve-option | `flow` — **static per-stamp scalar**, no sensor | `DrawingEngine.swift:73` |
| Hardness/Spacing/Taper | static scalars; spacing not pressure-driven | `DrawingEngine.swift:85-91` |
| Smoothing (tool layer) | `streamline` one-scalar EMA at input time | `DrawingEngine.swift:82`, `MetalCanvasView.swift:2587` |
| Speed / DrawingAngle / Distance / Fade / Fuzzy sensors | **none exist** | — |
| Rotation / azimuth / barrel input | **not captured** — `StrokePoint` has no azimuth/rotation | `DrawingEngine.swift:22-34` |

`effectiveWidth` is applied per-interpolated-stamp during arc-length resampling
(`MetalCanvasView.swift:899,992`), so the *plumbing* for per-dab evaluation already exists — but the
function it calls is a two-term closed form, not a sensor pipeline. Crucially, **flow and opacity are
never modulated per dab**: there is no "pressure → opacity" or "speed → size," which Krita gives for
free on every parameter. `StrokePoint` captures only `force`, `altitude`, `timestamp`
(`DrawingEngine.swift:22-34`) — no azimuth (tilt *direction*), no rotation, no derived speed/angle.

**What the committed plan already has and still misses.** `documents/plans/unified-brush-engine.md`
*does* anticipate richer dynamics — it lists `dynamics:{speedSize,speedOpacity,jitterSize,...}`,
`pencil:{pressure{size,opacity,flow,bleed}, tilt{...,curve}}`, and even says "curves = LUTs"
(`unified-brush-engine.md:69-70,223`). But it models them as **Procreate-shaped fixed couplings** —
a named `speedSize` knob, a named `pressure.size` graph — i.e. a *fixed matrix of (specific input →
specific output)* pairs. That is Procreate's surface, not Krita's. Krita's design is the
**orthogonal** one: *any* sensor can drive *any* parameter, each through its own curve, combined by
a chosen operator. The plan under-specifies (a) the **combine operator** when two inputs hit one
parameter, (b) the **strength min/max output remap**, (c) sensors Procreate doesn't expose at all
(DrawingAngle, Distance, Fade, FuzzyPerStroke-vs-PerDab, TiltDirection-as-additive). Section 3 is
about closing exactly that.

---

## 3. Gap analysis — what a Krita-grade superset adopts

The north star is "Krita-grade superset," so we adopt the **general** machine, not a bigger pile of
named knobs. Concretely:

1. **One `ResponseCurve` type = control points → baked 256-entry LUT.** Author with cubic spline
   (or even just monotone-cubic / Catmull-Rom; the spline brand is not load-bearing — Krita uses a
   natural cubic, `krita: kis_cubic_curve.cpp:106-111`), evaluate with `lut[i] + t·(lut[i+1]-lut[i])`.
   This subsumes our `pressureGamma`: `pow(x,γ)` is just one curve shape, and an artist-drawn curve
   beats a single exponent (e.g. dead-zone at low pressure + hard ramp — impossible with one γ).

2. **A `Sensor` enum with normalized `value(point, strokeState) → [0,1]`.** Adopt Krita's set,
   prioritized by *what we can actually sense and what the model sees* (§4): **Pressure, Speed,
   DrawingAngle, Distance, Fade, FuzzyPerDab, FuzzyPerStroke** are all derivable from data we already
   have (`force`, `timestamp`, position history, a per-stroke seed). **TiltElevation** maps to our
   `altitude`. **TiltDirection (azimuth) and Rotation** require capturing `azimuthAngle` /
   barrel-roll from `UITouch`/Pencil — a `StrokePoint` extension (see §6).

3. **A `CurveOption` = `{sensors:[{sensor,curve}], combineMode, strength, min, max, useCurve}`** that
   reproduces §1.4–1.5 *exactly*: multiply/add/max/min/diff on the scaling bucket; additive sensors
   (Fuzzy, Rotation, TiltDirection) sum; absolute-rotation (DrawingAngle) overwrites offset; final
   `clamp(min, strength·offset·Πscaling·additive, max)`. **Do not invent a different combine math** —
   matching Krita's lets us import `.kpp`-style presets later and gives predictable artist behavior.

4. **Make size, opacity, flow, spacing, scatter, rotation, hue/sat/value all `CurveOption`s.** Today
   only size has *any* dynamics. The cheapest high-value win is **pressure→opacity** and
   **pressure→flow** (Krita's `m_opacityOption.apply` returns both, `kis_brushop.cpp:131`), then
   **speed→size** (calligraphic taper-by-speed) and **DrawingAngle→ratio/rotation** (flat-nib pen).

5. **Per-sensor vs shared curve (`useSameCurve`).** Cheap to support and a real expressivity gain
   (pressure-ease + speed-falloff on one param). Default shared, like Krita.

The end state: our `BrushConfig`'s flat `pressureGamma`/`tiltSensitivity` become two *presets* of a
general size `CurveOption`; everything else (flow/opacity/spacing dynamics, the new sensors) is new
capability that today we simply cannot express.

---

## 4. img2img leverage call

Per `_CONTEXT.md`, leverage = "does klein *see* it." Ranking the new dynamics:

| Dynamics capability | Leverage | Why |
|---|---|---|
| **Pressure/Speed → size** | **High (model-leverage)** | changes stroke *width/value mass* — large-scale structure the model keys on. |
| **Pressure/Speed → opacity & flow** | **High** | changes value/coverage and thick-vs-thin paint — the model reads density. |
| **DrawingAngle → ratio/rotation** (flat-nib calligraphy) | **High** | changes edge orientation & stroke *shape*; directly conditions strokes. |
| **TiltDirection/Elevation → size/shape** | **Medium-high** | broad shading shape survives; the fine tooth it implies does not. |
| **Distance/Fade → size/opacity** (taper over length) | **Medium-high** | taper = stroke shape, which the model honors. |
| **FuzzyPerDab → size/opacity/scatter** (grain-jitter) | **Low (model overwrites)** | per-dab micro-jitter is exactly the fine grain klein resynthesizes. Keep for *hand-feel*, deprioritize for leverage. |
| **FuzzyPerStroke → hue/value** | **Medium** | a whole-stroke color/value nudge *does* change what the model sees; per-dab does not. |

**Call:** prioritize the *geometry and value* sensors (pressure/speed/angle → size/opacity/flow/
ratio). The **Fuzzy/jitter** family is real Krita capability and worth building for hand-feel, but it
is the lowest-leverage branch for our pipeline — build the machine generally, but tune presets toward
size/value/edge dynamics first. This matches the unified-plan's own ordering
(`unified-brush-engine.md:282`) and refines it: the *reason* jitter is deprioritized is leverage, not
difficulty.

---

## 5. Metal translation notes (respecting perf invariants)

Our perf invariants: <8ms/frame @120Hz; no `drawHierarchy`/`waitUntilCompleted` on the hot path;
per-stamp dynamics already resolved **CPU-side** in `generateStampsForStroke` and baked into the
`StampInstance` buffer (per the unified plan, `unified-brush-engine.md:94`). The sensor/curve
evaluation fits this model **without touching the fragment shader at all**:

1. **Evaluate sensors+curves CPU-side, per interpolated dab, in the existing resample loop.** This is
   where `effectiveWidth` is called today (`MetalCanvasView.swift:899,992`). Replace the two-term
   closed form with a `CurveOption.evaluate(point, strokeState)` per active option (size, opacity,
   flow, ratio, rotation, scatter). The cost is a handful of LUT reads + a few multiplies per dab —
   trivially under budget; **strictly cheaper than the wet path's per-dab 1×1 `getBytes`** we already
   ship (`MetalCanvasView.swift` wet smear). No GPU round-trip, no new pass.

2. **Curve = a flat `[Float]` LUT (256), exactly Krita's `floatTransfer(256)`.** Bake once when the
   brush/preset loads or the artist edits the curve (mirror Krita's invalidate-on-edit,
   `krita: kis_cubic_curve.cpp:113-118`). Runtime read = `interpolateLinear` (§1.3) — a clamp, a
   floor, a lerp. **Identity-curve fast path:** store `nil` for an identity LUT and skip the read
   (Krita's exact optimization, `krita: KisDynamicSensor.cpp:21-23`); most sensors on most brushes
   are identity, so this keeps the common stroke as cheap as today.

3. **Strokes are deterministic for replay/undo.** The Fuzzy sensors draw RNG. We undo/replay from
   stored points, so RNG must be seeded from `stroke.seed + dabIndex` (the unified plan already calls
   this the "Phase-2 trap," `unified-brush-engine.md:101`). Krita solves it with `KisRandomSource`
   (per-dab) vs `KisPerStrokeRandomSource(key)` (one draw per stroke, keyed by option name,
   `krita: KisDynamicSensorFuzzy.cpp:30-32`). **Mirror both:** per-dab seed = `hash(seed,dabIdx)`;
   per-stroke seed = `hash(seed, optionName)`.

4. **Strokes need running state, not just per-point data.** Speed/Distance/Fade/DrawingAngle need
   `totalStrokeLength`, `dabSeqNo`, `drawingSpeed`, and `drawingAngle` — Krita threads these via
   `KisDistanceInformation` registered onto each `KisPaintInformation`
   (`krita: kis_paint_information.cc:134-145`). We must add a small `StrokeDynamicsState` accumulated
   in the resample loop (cumulative arc-length, dab index, smoothed speed from `timestamp` deltas,
   heading angle). `timestamp` is already captured (`DrawingEngine.swift:27`); speed is a derived
   field we currently *don't* compute.

5. **Do NOT move this to a curve-LUT *texture* sampled in the fragment shader.** That would be the
   "obvious" GPU answer and it's the wrong one: dynamics resolve to *per-dab scalars* (size, opacity,
   flow), which belong in `StampInstance` (vertex/uniform-driven), not per-fragment. A per-fragment
   curve texture buys nothing and adds a sampler. Keep the fragment non-branching and uniform-driven
   per the unified plan (`unified-brush-engine.md:94`). (The one exception is if a curve drives a
   *spatial* per-pixel falloff like hardness profile — that, and only that, is a candidate for an LUT
   texture; out of scope here.)

6. **The CPU-bake cost flag still applies** at very high `count`/`scatter`
   (`unified-brush-engine.md:103`): evaluating N options × M sensors per dab × K scattered copies is
   more main-thread work. Mitigation = the identity-curve skip (point 2) plus benchmarking a
   high-count scatter brush early; the vertex-stage escape hatch the plan already names covers the
   worst case.

---

## 6. Open questions / risks

1. **Azimuth & barrel-roll capture.** TiltDirection and Rotation are real Krita sensors but our
   `StrokePoint` lacks azimuth/rotation (`DrawingEngine.swift:22-34`). `UITouch.azimuthAngle(in:)`
   gives tilt direction on all Pencils; barrel-roll needs Apple Pencil Pro. **Risk:** adding fields
   to `StrokePoint` (a `Codable` persisted in stored strokes — `DrawingEngine.swift:22`) is a
   serialization change; needs backward-compat decoding like `BrushConfig` already has
   (`DrawingEngine.swift:158`). *Decision needed:* capture azimuth now (cheap, all Pencils) and defer
   barrel-roll (Pencil-Pro-gated, and the unified plan already Rejects it on leverage,
   `unified-brush-engine.md:308`).

2. **Speed normalization constant.** Krita's Speed sensor returns a pre-normalized `drawingSpeed()`
   (`krita: kis_paint_information.cc:457-460`); I did **not** locate the exact px/ms→[0,1] scaling
   constant in this pass (it's set during `KisPaintInformation` construction in the tool layer, not
   in the sensor) — **inferred** that there's a fixed max-speed divisor. We'll need to pick our own
   normalization (likely a tunable "max speed" like Krita's smoothing uses,
   `krita: kis_tool_freehand_helper.cpp:478`). Flagged as unverified.

3. **Combine-mode UI/serialization scope.** Krita exposes mul/add/max/min/diff per option. Per
   `feedback_ipad_dev_toggles` + `feedback_direct_params`, the *artist-facing* surface should be a
   curated set of presets with direct params, not an on-device Brush Studio clone; the full
   sensor-matrix editor stays a dev panel. **Risk:** building the general engine but only ever wiring
   a few presets is fine (capability ≠ exposed UI), but we should store the full `CurveOption` in the
   descriptor so presets are expressible and importable.

4. **`useSameCurve` default + preset import.** If we ever want to import Krita `.kpp` presets, matching
   `useSameCurve=true` default and the exact combine semantics (§1.4) is required or imported brushes
   will feel wrong. Low priority but cheap to get right now vs. retrofit.

5. **Curve fit choice.** Krita uses a natural cubic spline through control points
   (`krita: kis_cubic_curve.cpp:106-111`). A monotone cubic (Fritsch–Carlson) avoids the overshoot a
   natural spline can produce between widely-spaced points (a curve that dips below 0 / above 1 before
   clamping). **Inferred** that Krita relies on the `qBound(0,y,1)` clamp (`kis_cubic_curve.cpp:133`)
   to hide overshoot; we could either copy that or use monotone-cubic for cleaner authored curves.
   Minor, but worth a deliberate choice.

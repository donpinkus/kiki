# 01 — The Per-Point Input Model (`KisPaintInformation` vs `StrokePoint`)

Scope: the *input bundle* that flows into the brush engine per interpolated point — what axes
exist, their units/ranges, how they're captured/derived, and how they're smoothed. This is the
upstream contract that everything downstream (sensors → curves → dab shape) reads from. Krita's
type is `KisPaintInformation`; ours is `StrokePoint`.

Citation convention: `krita: <path-relative-to-~/krita_src>:<line>`, ours `<path>:<line>`.
**Verified** = I read the code. **Inferred** = pattern-matched / from a comment.

---

## 1. How Krita does it — grounded

### 1.1 The full axis set

`KisPaintInformation` is a pImpl-backed bundle (`krita: libs/image/brushengine/kis_paint_information.cc:87-133`).
There are two tiers of axis: **stored** (captured at the event, copied through `mix`) and **derived**
(computed only inside a `paintAt()` call, when a `KisDistanceInformation` is registered — see §1.3).

| Axis | Accessor | Tier | Units / range | Source |
|---|---|---|---|---|
| Position | `pos()` | stored | image-space pixels, **subpixel** `QPointF` | event `point`, run through `documentToImage` (`krita: libs/ui/tool/kis_painting_information_builder.cpp:126`) |
| Pressure | `pressure()` | stored | `[0,1]`, default `PRESSURE_DEFAULT` (=0.5) | event pressure → tablet response curve (§1.2) |
| xTilt | `xTilt()` | stored | **raw −60..+60°** per the header; "0 to 1" doc comment is stale | `event->xTilt()` (`:134`) |
| yTilt | `yTilt()` | stored | raw −60..+60° | `event->yTilt()` (`:134`) |
| Rotation | `rotation()` | stored | degrees (barrel-roll of stylus) | `event->rotation()` (`:134`) |
| Tangential pressure | `tangentialPressure()` | stored | airbrush finger-wheel rate | `event->tangentialPressure()` (`:134`) |
| Perspective | `perspective()` | stored | reciprocal of distance on perspective grid; default `1.0` | `calculatePerspective()` (`:127`, base returns 1.0 `:100-104`) |
| Time | `currentTime()` | stored | ms since stroke start | `elapsedStrokeTime()` passed in as `timeElapsed` |
| Speed | `drawingSpeed()` | stored | `[0,1]`, **pre-normalized & pre-smoothed** | `KisSpeedSmoother`, ÷ `maxAllowedSpeedValue` (default 30) (`:128,137`) |
| Canvas rotation | `canvasRotation()` | stored | degrees, normalized `[0,360)` (`cc:282`) | canvas view rotation |
| Canvas mirror H/V | `canvasMirroredH/V()` | stored | bool | canvas view state |
| Tilt-direction offset | `tiltDirectionOffset()` | stored | `[0,360)` deg, user calibration | config `tiltDirectionOffset` (`builder.cpp:53`) |
| **Drawing angle** | `drawingAngle()` | **derived** | radians, atan2 of movement vector; can be *locked* | `KisDistanceInformation` last pos/angle |
| **Drawing direction vec** | `drawingDirectionVector()` | derived | unit `QPointF` = `(cos,sin)` of angle | derived from `drawingAngle` (`cc:424-428`) |
| **Drawing distance** | `drawingDistance()` | derived | pixels since last dab | `pos − lastPos`, LoD-scaled (`cc:430-445`) |
| **Total stroke length** | `totalStrokeLength()` | derived | pixels, cumulative before this dab | `KisDistanceInformation::scalarDistanceApprox` (`cc:612-615`) |
| **Max pressure** | `maxPressure()` | derived | `[0,1]`, running max over stroke | `max(lastMax, pressure)` (`cc:447-455`) |
| **Dab seq no** | `currentDabSeqNo()` | derived | int, dabs painted so far | distance info |
| Random source | `randomSource()` | stored | deterministic per-dab RNG | seeded per-stroke (covered in a sibling doc) |
| Per-stroke random | `perStrokeRandomSource()` | stored | one value per stroke | seeded per-stroke |
| Hovering mode | `isHoveringMode()` | stored | bool — Fuzzy returns 1.0, angle-lock skipped | `createHoveringModeInfo` ctor |
| Level of detail | (internal) | stored | int, LoD zoom level scaling | LoD stroke |

**Derived tilt scalars** (static helpers, computed on demand from xTilt/yTilt — not stored fields):
- `tiltDirection(info, normalize)` — `atan2(-xTilt, yTilt)`; when stylus is vertical (both ~0) it
  sticks to a neutral 3-o'clock value `−sign(xTilt)·sign(yTilt)·π/2`; adds `tiltDirectionOffset`;
  normalize maps to `[0,1]` via `angle/2π + 0.5` (`krita: kis_paint_information.cc:651-685`). **Verified.**
- `tiltElevation(info, maxTiltX=60, maxTiltY=60, normalize)` — converts the two tilt components into a
  single elevation angle `acos(√(xTilt²+yTilt²)/e)` in `[0, π/2]`, normalize maps to `[0,1]`
  (`krita: kis_paint_information.cc:687-704`). **Verified.** This is the "how flat is the pen" scalar,
  identical in spirit to our `altitude` but built from two tilt axes rather than captured directly.

So Krita stores **2 tilt components** and derives elevation+direction; iPadOS gives us elevation
(`altitudeAngle`) and direction (`azimuthAngle`) *directly*, which is strictly more convenient (§3).

### 1.2 Pressure capture & the tablet response curve

Raw event pressure is **not** used directly. The builder applies a user-configurable global tablet
curve (`pressureTabletCurve`) sampled into a 1024+1 entry LUT, then linearly interpolated:
`pressureToCurve()` → `KisCubicCurve::interpolateLinear` (`krita: libs/ui/tool/kis_painting_information_builder.cpp:47-48,179-182,131`).
Note this is a *global input-conditioning* curve, distinct from the *per-parameter* `KisCurveOption`
curves downstream. If "disable pressure" is set, pressure is forced to `1.0` (`:131`). **Verified.**

### 1.3 Derived axes need a registered `KisDistanceInformation`

`drawingAngle/Distance/Speed`, `maxPressure`, `totalStrokeLength`, `currentDabSeqNo` are **only valid
inside `paintAt()`**, because they read a `KisDistanceInformation` that is temporarily registered via
an RAII `DistanceInformationRegistrar` (`krita: kis_paint_information.cc:99-117, 135-146`). Calling them
outside emits `warnKrita` and returns a fallback (`cc:406-409,432-435`). This is the mechanism that
lets a *stateless-looking* per-point struct expose *stateful* derived quantities (the previous dab's
position/angle live in the distance object, not in the point). **Verified.**

`drawingAngle` = `KisAlgebra2D::directionBetweenPoints(lastPos, pos, lastAngle)` — if the segment has
zero length it falls back to the last angle (`cc:419-421`). **Angle locking:** at the start of each
`paintAt`, unless hovering, `distanceInfo->lockCurrentDrawingAngle(*this)` captures the angle once and
thereafter returns the locked value (`cc:111-113`, `libs/image/kis_distance_information.cpp:600-609`).
Sensors that want the locked variant pass `considerLockedAngle=true` (`cc:411-415`). This keeps a
"locked rake/flat-brush angle" steady through a stroke instead of jittering per dab. **Verified.**

### 1.4 Speed: estimated sample-rate, not raw timestamps

`KisSpeedSmoother::getNextSpeedImpl` accumulates distance/time over a rolling window
(`NUM_SMOOTHING_SAMPLES=3`, until `totalDistance > MIN_TRACKING_DISTANCE=5px`), and crucially
**ignores raw event timestamps** for the time term — it estimates the tablet's sample rate with a
filtered rolling mean (`timeDiffsMean`) and uses `avgTimeDiff` per sample
(`krita: libs/ui/tool/kis_speed_smoother.cpp:128-165`). The explicit rationale, from the code comment:
"*we don't care about the specific timestamps of the tablet events! They are not reliable*"
(`:147-153`). Exact-duplicate positions are dropped (`:115-118`, "On Android this happens all the
time"). Speed is then clamped to `[0,1]` by dividing by `maxAllowedSpeedValue` in the builder. **Verified.**

### 1.5 Smoothing layering & `mix`

Smoothing happens at the **tool layer** (`KisToolFreehandHelper`), *upstream* of the paintop, in three
modes (Basic / Weighted / Stabilizer) — that's a sibling doc's topic. What matters for the *input
model* is the interpolation primitive: `KisPaintInformation::mix*` lerps **every** axis between two
points — pressure/tilt/tangential/perspective/speed linearly, **rotation via shortest angular distance**
(`incrementInDirection` over `shortestAngularDistance`, so it wraps correctly), time optionally
(`krita: kis_paint_information.cc:610-649`). The Weighted-smoothing path builds a Gaussian-weighted
average of recent points whose sigma is **speed-dependent** (`effectiveSmoothnessDistance(speed)`,
`libs/ui/tool/kis_tool_freehand_helper.cpp:540`). So Krita's smoothness itself responds to an input
axis. **Verified.**

---

## 2. How Kiki does it today

Our per-point struct is dramatically thinner:

```swift
public struct StrokePoint {
    public var position: CGPoint
    public var force: CGFloat       // 0–1 normalized
    public var altitude: CGFloat    // radians: 0 = flat, π/2 = perpendicular
    public var timestamp: TimeInterval
}
```
`ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:22-34`. **Verified.**

Capture (`makeStrokePoint`, `MetalCanvasView.swift:2606-2620`): `position = touch.location(in:self)`,
`force = touch.force / touch.maximumPossibleForce` (falls back to 0.5 if max is 0),
`altitude = touch.altitudeAngle`, `timestamp = touch.timestamp`. Coalesced touches are appended per
`touchesMoved` (`:618-621`). **Verified.**

Consumption is shallow. Only **two** axes drive geometry, via one function:
`effectiveWidth(force:altitude:)` = `baseWidth · max(force,0.01)^pressureGamma`, then if
`tiltSensitivity>0`, multiplied by `1 + tiltSensitivity·(1 − altitude/(π/2))·2`
(`DrawingEngine.swift:147-155`). So:
- `force` → width only (single `pressureGamma` scalar — no per-parameter curves).
- `altitude` → width only (linear tilt-widen; no tilt-direction, no tilt-elevation distinction).
- `timestamp` → **velocity is derived only in the line-correction path** (`MetalCanvasView.swift:1530-1536`,
  `dt = last.timestamp - prev.timestamp`); it is **not** an input to brush dynamics. **Verified.**
- Stamp **rotation** comes from *stroke direction* `atan2(-dx,dy)` (`MetalCanvasView.swift:2375-2391`),
  and round brushes pass `rotation: 0` (`:906,958`). The comment "pencil azimuth" at
  `CanvasRenderer.swift:156` is **stale — code wins**; azimuth is never read. **Verified.**

Smoothing: a single one-pole low-pass on position only (`streamline`), `smoothedStrokePoint`
(`MetalCanvasView.swift:2587-2604`), `factor = max(1 − streamline·0.9, 0.08)`. No speed-dependence,
no per-axis mixing, no angle locking. **Verified.**

---

## 3. Gap analysis + what a Krita-grade superset adopts

| Axis | Kiki today | Krita | iPad availability | Verdict |
|---|---|---|---|---|
| Position (subpixel) | ✅ | ✅ | `preciseLocation(in:)` (we use `location`) | minor: switch to `preciseLocation` |
| Pressure | ✅ (width only) | ✅ + tablet curve + every sensor | `force/maxPossibleForce` | **keep, but route through curves** |
| Altitude/elevation | ✅ (width only) | derived `tiltElevation` | `altitudeAngle` (direct!) | keep |
| **Tilt direction (azimuth)** | ❌ | `tiltDirection`, a first-class sensor | **`azimuthAngle(in:)` — direct, free** | **ADOPT — biggest free win** |
| **Velocity/speed** | ❌ (derived but unused) | ✅ smoothed, normalized, a sensor | derive from coalesced timestamps | **ADOPT** |
| **Drawing angle / direction** | partial (stroke dir → rotation only) | ✅ sensor, with **angle locking** | derive from positions | **ADOPT incl. locking** |
| **Drawing distance / fade / total length** | ❌ | ✅ `Distance`/`Fade`/`Time` sensors | derive | adopt for texture/scatter ramps |
| **Barrel rotation** | ❌ | ✅ `rotation()` sensor | `Apple Pencil Pro` roll (UIKit `rollAngle`) | adopt (Pro-only, capability-gate) |
| Tangential pressure | ❌ | ✅ (airbrush wheel) | no iPad hardware | **skip** (no input device) |
| Perspective | ❌ | ✅ | n/a (no perspective grid feature) | skip |
| Max pressure (running) | ❌ | ✅ | derive | cheap; adopt if a sensor needs it |
| Random (per-dab/per-stroke) | ❌ | ✅ deterministic | n/a | covered in sensor/RNG doc |
| Canvas rotation / mirror | ❌ | ✅ (so tilt stays world-locked) | we have rotate/mirror gestures | adopt so tilt-direction tracks the rotated canvas |

**The headline gap is not any single axis — it's that we capture 2 usable axes and feed them through
1 hardcoded curve, while Krita captures ~8 and feeds them through an N-sensor × per-parameter-curve
matrix.** This doc's job is the *input* half; the curve/sensor half is the sibling doc. But the input
model must be widened *first*, or the dynamics layer has nothing to read.

Concretely, a Krita-grade `StrokePoint` superset (capturing everything iPad hardware actually
provides):

```swift
public struct StrokePoint {
    var position: CGPoint        // use preciseLocation(in:)
    var force: CGFloat           // [0,1]
    var altitude: CGFloat        // radians, elevation (have it)
    var azimuth: CGFloat         // radians, tilt DIRECTION — NEW, free
    var barrelRoll: CGFloat?     // radians, Pencil Pro only — NEW, gated
    var timestamp: TimeInterval
    // Derived once at append time (cheap, CPU) and cached on the point:
    var speed: CGFloat           // px/s smoothed+normalized — NEW
    var drawingAngle: CGFloat    // radians, movement direction (lockable) — NEW
    var distance: CGFloat        // px since last appended point — NEW
}
```
Derived fields belong on the point so the GPU stamp builder and any future per-axis curve read them
without re-deriving. This mirrors Krita's split (captured vs. derived-from-distance-info) but bakes the
derivation at append time instead of via a registered side-object — simpler for our isolated-stroke model.

**What new axes unlock (hand-feel and shape):**
- **azimuth (tilt direction):** orient an elliptical/textured tip to the *pen's lean*, not the travel
  direction — the difference between a chisel/calligraphy nib and a directional rake. Today we only have
  travel-direction rotation; azimuth gives true flat-pencil shading where the broad side faces a fixed
  way regardless of stroke direction.
- **speed:** taper-on-flick, speed→size (gestural thick/thin), speed→opacity (dry-brush when fast).
- **drawing-angle locking:** stops rake/chisel jitter on slow hand-drawn curves (Krita's `lockedDrawingAngle`).
- **barrel roll (Pencil Pro):** continuous tip rotation independent of travel — true twisting flat brush.

---

## 4. img2img leverage call

Per `_CONTEXT.md`, the canvas is a conditioning JPEG for `fal-ai/flux-2/klein/realtime`. Leverage =
"does klein *see* this axis's effect on large-scale structure/edge/shape."

| New axis | Leverage class | Why |
|---|---|---|
| **azimuth → tip orientation** | **HIGH (model-leverage)** | Changes *stroke shape and edge direction* at scale — chisel vs. round reads as a different mark; klein keys on edge orientation/hardness. The single highest-leverage new axis. |
| **speed → size/opacity/taper** | **MEDIUM–HIGH** | Speed→size changes thick-vs-thin paint (high leverage); speed→opacity changes value structure (high). Speed→fine-grain only = low. |
| **drawing-angle locking** | **MEDIUM** | Stabilizes *shape* of directional marks; cleaner silhouettes survive downscale-to-JPEG. Mostly a quality multiplier on the azimuth/shape win. |
| **barrel roll** | **LOW–MEDIUM, hand-feel-dominant** | Tactilely premium, but its visual effect (tip twist) is subtle at JPEG/klein resolution unless paired with a strongly anisotropic tip. Pencil-Pro-only → small audience. |
| **velocity → micro-jitter/grain** | **LOW** | klein resynthesizes fine grain; don't prioritize. |

**Call:** prioritize **azimuth-driven tip orientation** and **speed-driven size/opacity/taper** — both
are HIGH leverage (alter what the model sees) *and* free to capture on every Apple Pencil. Angle-locking
is a cheap quality rider on the azimuth work. Barrel roll is a nice-to-have, capability-gated to Pencil
Pro, low priority because of audience size and modest at-resolution effect.

---

## 5. Metal translation notes (perf invariants respected)

The input model is **CPU-side and pre-stamp** — it never touches the per-frame GPU hot path, so the
sacred invariants (<8ms/frame, no `drawHierarchy`/`waitUntilCompleted` on the hot path) are unaffected
by widening `StrokePoint`. Specifics:

1. **Capture is already in the right place.** `makeStrokePoint` runs in `touchesMoved` over coalesced
   touches (`MetalCanvasView.swift:618-621`). Add `azimuthAngle(in:)`, `rollAngle` (Pro), and
   `preciseLocation(in:)` reads there — all O(1), no allocation, no GPU work.
2. **Derive speed/angle/distance at append time, not in the shader.** Compute against the previous
   appended point and cache on the struct. This is a handful of float ops per coalesced touch (≤ a few
   hundred/sec) — negligible vs. our existing per-stamp arc-length resample.
3. **Speed smoothing:** port Krita's *estimated-sample-rate* idea (`kis_speed_smoother.cpp:147-153`) —
   a tiny rolling mean of `dt` plus a 3-sample distance window. iPad pencil timestamps are far more
   reliable than the tablets Krita distrusts, so a simpler EMA on `dist/dt` is likely sufficient; keep
   the duplicate-position guard (`:115-118`) because coalesced touches can repeat a point.
4. **Angle locking:** one optional cached float on the stroke (`lockedDrawingAngle`), set on the first
   moved segment; trivial.
5. **Stamp builder reads the cached axes.** Where we currently feed `rotation: 0` for round brushes
   (`:906,958`) and travel-direction for textured (`:2375-2391`), the elliptical/textured path would
   instead read `point.azimuth` (+ optional `barrelRoll`) to set `StampInstance.rotation` and
   anisotropy. This is the same instanced-quad draw — only the rotation/scale inputs change. No new pass.
6. **`StampInstance` already has a `rotation` field** (`CanvasRenderer.swift:156`) and the quad shader
   already rotates by it (`:1486`); we are *feeding it correctly*, not adding GPU capability. An
   elliptical tip needs a second radius (`semiMajor/semiMinor` already appear at `MetalCanvasView.swift:1735`).
7. **Serialization:** `StrokePoint` is `Codable` and persisted in stroke JSON. New optional fields must
   decode-with-default (mirror the existing `decodeIfPresent` pattern at `DrawingEngine.swift:173`) so
   old saved drawings still load — schema-compat, not a SwiftData migration (strokes are blob JSON).

---

## 6. Open questions / risks

1. **iPad azimuth validity when flat-vs-vertical.** `azimuthAngle` is undefined/noisy when the pencil is
   near-perpendicular (elevation → π/2), exactly like Krita's vertical-stylus special-case
   (`kis_paint_information.cc:659-668` sticks to a neutral 3-o'clock). We need the same guard: when
   `altitude` is near π/2, freeze azimuth at its last stable value rather than letting the tip spin.
   *Unverified that iPadOS reports azimuth as noisy here — needs a device measurement.*
2. **Coalesced-touch axis fidelity.** Do coalesced (high-frequency) touches carry valid
   `azimuthAngle`/`force`/`rollAngle`, or only predicted/coarse values? Apple's docs imply coalesced
   touches carry full data, but **this must be measured on-device** (sim can't drive Pencil — see
   `project_ios_signin_blocks_sim_automation.md`). If coalesced points lack azimuth, derive it from the
   parent touch.
3. **Speed normalization constant.** Krita's `maxAllowedSpeedValue=30` is tablet-tuned (and over the
   *estimated sample rate*, not real time). Our denominator must be re-tuned for iPad pencil sample
   rates / point-spacing or speed-driven dynamics will feel wrong. Pick empirically on-device.
4. **Angle-locking UX choice.** Krita locks the angle for the *whole* stroke once. That's right for a
   flat/chisel brush but wrong for a directional rake that should follow a curve. Krita exposes both via
   the `considerLockedAngle` flag per sensor; we'd need the same per-brush toggle, not a global behavior.
5. **Barrel roll is Pencil-Pro-only** — must be capability-gated (`UITouch` exposes roll only on Pro
   hardware) and degrade to azimuth/travel-direction when absent. Don't bake it into a non-optional field.
6. **`time` vs our `timestamp`.** Krita stores ms-since-stroke-start; we store the raw `touch.timestamp`
   (absolute uptime). Either works, but a Time/Fade sensor (texture ramp over a stroke) needs
   *elapsed-since-start*; compute it as `timestamp − strokeStartTime` rather than storing absolute. Low risk.
7. **Stale doc comments in Krita itself.** The header's "xTilt … range 0 to 1" (`kis_paint_information.h:38-44`)
   contradicts the class doc's "range is -60 to +60" (`:33-34`) and the `tiltElevation` math which divides
   by `maxTiltX=60`. Code (degrees, ±60) wins. Flagged so a future reader doesn't trust the `[0,1]` comment.

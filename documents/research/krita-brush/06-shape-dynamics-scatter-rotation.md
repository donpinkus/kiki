# 06 — Shape Dynamics: Scatter, Rotation, Mirror/Flip, Size Jitter, Density + the Fuzzy (Random) Sensor & Deterministic RNG

**Scope.** How Krita randomizes and orients each dab — scatter (position jitter), rotation (drawing-angle + fuzzy + device), mirror/flip, size/density jitter — and the **deterministic per-stroke RNG** that makes all of it replay-stable. Then our state, the gap, and the Metal/img2img translation. Read `_CONTEXT.md` + `00-krita-brush-architecture.md` first.

Citations: `krita: <path-rel-to-~/krita_src>:<line>` (verified = I read it; inferred = pattern/comment). Our code: `<path>:<line>`.

---

## 1. How Krita does it (grounded)

### 1.1 The two RNG layers — this is the spine of all shape dynamics

Krita has **two distinct random sources**, both seeded once and carried through the whole stroke. Both are *copyable value types holding a PRNG state*, which is the entire trick to determinism.

**(a) Per-dab source — `KisRandomSource`** (`krita: libs/global/kis_random_source.cpp:33`). Wraps a `boost::taus88` PRNG (a 3×32-bit Tausworthe generator, ~2^88 cycle) chosen explicitly because *"it can be copied very quickly (three 32-bit integers only)"* (`krita: libs/global/kis_random_source.cpp:23-29` — verified, that's the source comment). `generate()` advances the state and returns the next value (`:62`); `generateNormalized()` draws one value and divides by `max()` (`:73-80`). **Crucially it is *stateful and sequential*** — every draw advances the generator. There is no per-dab re-seeding; the stream is just consumed in order as dabs are placed.

**(b) Per-stroke source — `KisPerStrokeRandomSource`** (`krita: libs/image/brushengine/KisPerStrokeRandomSource.cpp:42`). This is **keyed and memoized**, not sequential. It holds a `seed` and a `QHash<QString,qint64> valuesCache` (`:36-38`). `fetchInt(key)` returns a cached value if present, else constructs a *fresh* `boost::taus88(seed + qHash(key))`, draws **one** value, caches it under that key, and returns it (`krita: libs/image/brushengine/KisPerStrokeRandomSource.cpp:59-74` — verified). So *the same key always yields the same number for the life of the stroke* — a "draw a constant for this stroke" facility. Mutex-guarded because dabs render on worker threads (`:61`).

**(c) Seeding + LoD twin — `KisStrokeRandomSource`** (`krita: libs/image/brushengine/kis_stroke_random_source.cpp:9-26`). Owns a `lod0` source and a `lodN` source that is **copy-constructed from lod0** (`KisRandomSource(*lod0RandomSource)`, `:14`), so the low-detail preview replays the *identical* number stream. `source()` returns whichever matches the current LoD (`:52-55`). The seed itself is `QRandomGenerator::global()->generate()` taken **once** at source construction (`krita: libs/global/kis_random_source.cpp:18`; per-stroke seed `krita: libs/image/brushengine/KisPerStrokeRandomSource.cpp:43`).

**(d) Where it attaches to the stroke — `FreehandStrokeStrategy::doStrokeCallback`** (`krita: libs/ui/tool/strokes/freehand_stroke.cpp:155-170`, verified). For **every** paint event the stroke strategy fetches `m_d->randomSource.source()` + `.perStrokeSource()` and calls `pi1.setRandomSource(rnd)` / `pi1.setPerStrokeRandomSource(strokeRnd)` *before* `paintAt`/`paintLine`. The `KisStrokeRandomSource` lives on the stroke strategy (`:57`) — one per stroke, constructed once. **This is the determinism mechanism: a single seeded, copyable PRNG state is threaded through every dab of one stroke, so replaying the same points yields the same jitter.** Undo/redo re-runs the strategy from the recorded points and reproduces it exactly. (The freehand *helper*'s `fakeDabRandomSource`/`fakeStrokeRandomSource` at `krita: libs/ui/tool/kis_tool_freehand_helper.cpp:148-149,235-236` are only for the live cursor-outline preview; the real stroke uses the strategy's source.)

### 1.2 The fuzzy sensor — randomness as just another sensor

Krita does **not** special-case randomness in each option. It exposes random as a **sensor** that plugs into the universal `KisCurveOption` machinery (see `00-…:§3d`). `KisDynamicSensorFuzzyBase::value` (`krita: plugins/paintops/libpaintop/sensors/KisDynamicSensorFuzzy.cpp:25-37`, verified):

```
result = m_fuzzyPerStroke ? perStrokeRandomSource()->generateNormalized(key)   // memoized per stroke
                          : randomSource()->generateNormalized();              // fresh per dab
result = 2.0 * result - 1.0;     // remap [0,1] → [-1,1]   (signed jitter)
```

Two subclasses: **`FuzzyPerDab`** (new value each dab, `fuzzyPerStroke=false`, empty key) and **`FuzzyPerStroke`** (one value for the whole stroke, key = `parentOptionName + "FuzzyStroke"`) — `krita: …/KisDynamicSensorFuzzy.cpp:39-48`. In hovering mode it returns 0 (`:29`) so the preview doesn't jitter. **It is `isAdditive() == true`** (`:20-23`), meaning in `KisCurveOption::computeValueComponents` its output goes into the `additive` bucket (`krita: plugins/paintops/libpaintop/KisCurveOption.cpp:112-114`), not the multiplicative `scaling` bucket. So "fuzzy" *adds* a signed random offset to whatever the option's base value is. Because it's a sensor, the fuzzy value **still runs through that option's response curve** before use (`s->parameter(info)` applies the per-sensor LUT, `:111`) — you can shape the randomness distribution with the curve. This is the elegant part: **size-jitter, rotation-jitter, opacity-jitter, flow-jitter are all "add the Fuzzy sensor to that option,"** not separate features.

### 1.3 Scatter — position jitter (`KisScatterOption`)

`KisScatterOption::apply(info, width, height)` (`krita: plugins/paintops/libpaintop/KisScatterOption.cpp:32-64`, verified):

1. `diameter = max(width, height)`; `sensorValue = computeSizeLikeValue(info)` — the option's own curve/sensor output (typically driven by pressure or constant strength).
2. `jitter = (2*randomSource()->generateNormalized() - 1) * diameter * sensorValue` — **signed, scaled by the dab diameter** so scatter is proportional to brush size.
3. Two **axes**, independently toggleable:
   - both X and Y → `pos + (jitterX, jitterY)` — a square cloud around the point (draws a *second* normalized value for Y, `:46`).
   - X only → offset **along the drawing direction**: `movement = (cos(drawingAngle), sin(drawingAngle)) * jitter` (`:51-56`).
   - Y only → offset **perpendicular** to the stroke: `(-movement.y, movement.x) * jitter` (`:57-60`).

So scatter is *direction-aware* — the single-axis modes spread along/across the path, not in screen space. It uses the **per-dab** `randomSource` (sequential), so every dab scatters independently; replay-stable because the source is seeded once.

### 1.4 Rotation — drawing-angle + device + fuzzy, combined as angles

`KisRotationOption::apply(info)` (`krita: plugins/paintops/libpaintop/KisRotationOption.cpp:34-53`, verified) returns a final dab angle in radians. The math:

- If unchecked, returns just the canvas rotation (`kisDegreesToRadians(info.canvasRotation())`, `:36`) — i.e. round brushes still respect a rotated canvas.
- Else it calls `computeRotationLikeValue(info, normalizedBaseAngle=-canvasRotation/360, absoluteAxesFlipped, scalingPartCoeff=-1, …)` then `value = 1.0 - value; normalizeAngle(value * M_PI)` (`:40-52`). The `scalingPartCoeff = -1` and `1.0 - value` flips exist *"to conform global legacy code … we measure rotation in the opposite direction relative Qt's way"* (verified comment, `:48-50`).

The interesting work is in `ValueComponents::rotationLikeValue` (`krita: plugins/paintops/libpaintop/KisCurveOption.cpp:61-76`, verified): it combines **offset** (from an absolute-rotation sensor or the base angle), a **scaling part** (`scalingToAdditive(scaling)`), and an **additive part**, all wrapped into `[-1,1]` by `KisAlgebra2D::wrapValue` (`:70`) — i.e. angle arithmetic that wraps cleanly at the seam. The three angle inputs come from three sensor *categories* in `computeValueComponents` (`:112-121`):

- **`isAbsoluteRotation()` sensors** → `absoluteOffset`. The **Drawing-Angle sensor** is the key one: `KisDynamicSensorDrawingAngle::value = 0.5 + drawingAngle(locked)/(2π) + angleOffset/360`, and **`isAbsoluteRotation() == true`** (`krita: plugins/paintops/libpaintop/sensors/KisDynamicSensorDrawingAngle.cpp:20-35`, verified). This is how a textured/elliptical tip *orients to the stroke direction* — same as our auto-orient, but expressed as a sensor that can be curved, offset, locked, and mixed.
- **`isAdditive()` sensors** → `additive`. The **Rotation sensor** (`info.rotation()/180`, additive, `krita: plugins/paintops/libpaintop/sensors/KisDynamicSensors.h:24-36`, verified — this is Apple-Pencil-style barrel/tip rotation) and the **Fuzzy sensor** (random angle jitter) both land here and *sum*.
- The **scaling** bucket → spun into additive via `scalingToAdditive`.

**Drawing-Angle has a special side-effect: fan corners.** When the drawing-angle sensor is active, `KisRotationOption` reads `fanCornersEnabled`/`fanCornersStep` and calls `op->setFanCornersInfo(...)` (`krita: …/KisRotationOption.cpp:26-31,55-64`), because *"A special case for the Drawing Angle sensor … changes the behavior of KisPaintOp::paintLine()"* (verified comment, `:59-61`) — at sharp corners it inserts extra fan dabs so an oriented tip doesn't snap-rotate with a gap. **Verified that the hook is set here; not traced into `paintLine`'s consumption** (inferred from the comment + name that it densifies dabs at angle discontinuities).

### 1.5 Mirror / flip (`KisMirrorOption`)

`KisMirrorOption::apply` (`krita: plugins/paintops/libpaintop/KisMirrorOption.cpp:31-56`, verified) is a **boolean threshold on a curve value**: `result = computeSizeLikeValue(info) >= 0.5` (`:39-41`). When true and the corresponding axis is enabled, it increments a mirror counter; the final flip is `count % 2` (`:51-52`). To get *random* flips you drive this option with a **Fuzzy sensor** — the random `[0,1]` value crossing 0.5 flips the tip. It also folds in `canvasMirroredH/V` so it respects a mirrored canvas. The actual pixel mirroring happens later (`painter->mirrorDab`, `krita: plugins/paintops/defaultpaintops/brush/kis_brushop.cpp:185`).

### 1.6 Size jitter & density

There is **no dedicated "size jitter" or "density" option** — both are emergent:
- **Size jitter** = the **Fuzzy sensor added to the Size option** (`KisSizeOption` is a `KisCurveOption`; its additive bucket takes fuzzy). Verified by construction: any `KisCurveOption` accepts any sensor (`generateSensors`, `KisCurveOption.cpp:~40-58`), and `isRandom()` explicitly checks for fuzzy sensors on *any* option (`krita: plugins/paintops/libpaintop/KisCurveOption.cpp:197-204`).
- **Density** in the pixel brush is governed by **spacing** (the `paintLine` walk, `00-…:§3b`) plus scatter; the dedicated "density/randomness" sliders live in the **spray** paintop (`plugins/paintops/spray/`, not read in depth here — inferred from the directory + `00`'s map).

### 1.7 Summary table — Krita shape dynamics

| Feature | Class | Random source | Bucket | `krita:` |
|---|---|---|---|---|
| Scatter (position) | `KisScatterOption` | per-dab `randomSource` | offset on pos | `KisScatterOption.cpp:32` |
| Rotation: stroke-orient | Drawing-Angle sensor | none (deterministic) | absoluteOffset | `KisDynamicSensorDrawingAngle.cpp:20` |
| Rotation: pencil barrel | Rotation sensor | none | additive | `KisDynamicSensors.h:24` |
| Rotation: jitter | Fuzzy sensor on Rotation opt | per-dab/per-stroke | additive | `KisDynamicSensorFuzzy.cpp:25` |
| Mirror/flip | `KisMirrorOption` | (Fuzzy for random) | threshold ≥0.5 | `KisMirrorOption.cpp:31` |
| Size jitter | Fuzzy sensor on Size opt | per-dab/per-stroke | additive | `KisCurveOption.cpp:197` |
| Determinism | `KisStrokeRandomSource` | seeded once/stroke | — | `freehand_stroke.cpp:155` |

---

## 2. How Kiki does it today

| Capability | State | Our cite |
|---|---|---|
| Per-stamp **rotation field** | **Plumbed but fed `0` for round brushes**; textured shapes orient to stroke direction (computed in stamp gen, not via a sensor). | `CanvasRenderer.swift:156` (`var rotation: Float // pencil azimuth`); brush stamps hardcode `rotation: 0` at `MetalCanvasView.swift:906`, eraser at `:958`, wet at `:958` |
| **Scatter** (position jitter) | **None.** Stamps placed exactly on the arc-length-resampled path. | `MetalCanvasView.swift:893-914` (the spacing walk; `center` = interpolated `(x,y)` verbatim) |
| **Size jitter** | **None.** `radius = effectiveWidth(force,altitude)*0.5` deterministically. | `MetalCanvasView.swift:899,905` |
| **Mirror / flip** | **None.** | — |
| **Density jitter** | **None.** Spacing is `max(width*0.3, 0.5)` deterministic. | `MetalCanvasView.swift:912` |
| **RNG of any kind** | **None.** Every stroke is a pure function of its points + `BrushConfig`. No `seed`, no random draw anywhere in the brush path. | `DrawingEngine.swift` (`BrushConfig` has no seed/jitter fields, lines 63+); `Stroke` has no seed |
| **Per-point input axes** | `StrokePoint { position, force, altitude, timestamp }` — **no azimuth (tilt direction), no barrel rotation.** So even our "pencil azimuth" comment on `rotation` is currently unfed. | `DrawingEngine.swift` `StrokePoint` |

So our entire shape-dynamics surface is **one field (`rotation`) that is currently always 0 for the default round brush**, and zero randomness. The `00` doc's open-question #1 ("deterministic RNG is a trap if we adopt scatter/fuzzy") is live the moment we add any jitter.

**The target architecture already anticipates this.** `unified-brush-engine.md` §2.4 specifies a `seed: UInt64` on `Stroke` and bakes per-stamp dynamics CPU-side into a superset `StampInstance` (`size: SIMD2` anisotropy, `rotation`, `seed`), with the explicit rule: *"every jitter/scatter/count/color-dynamics RNG draw is seeded from `stroke.seed` + stamp index. Undo/replay re-renders from points; a wall-clock RNG would desync. This is the known Phase-2 trap, made structural"* (`documents/plans/unified-brush-engine.md:101`). The §6 table lists scatter/count/roundness/flip/azimuth as **"Native, High (geometry)"** leverage (`:217`). **So this research validates the plan's design and refines its RNG strategy** (see §3).

---

## 3. Gap analysis + what a Krita-grade superset adopts

**The core gap is not "we lack scatter" — it's that we have no dynamics layer and no RNG, while Krita expresses *all* of shape dynamics as `(sensor → curve → additive/scaling bucket)` over a seeded stroke RNG.** Adopting the *mechanism* gets scatter, rotation-jitter, size-jitter, random-flip, and stroke-orientation **for one design cost**, exactly as Krita does.

What a superset adopts, in priority order (geometry = high img2img leverage):

1. **A seeded per-stroke RNG (prerequisite for everything else).** Add `seed: UInt64` to `Stroke`, generated at `touchesBegan`, persisted in the stroke JSON. This is non-negotiable before any jitter — and it's already in the plan (`unified-brush-engine.md:263`). **Refinement from Krita:** mirror Krita's *two* RNG layers, not one. (a) A **sequential per-dab stream** for true per-dab independence (scatter, per-dab fuzzy), and (b) a **keyed per-stroke memoized** facility (per-stroke fuzzy = "pick one random tilt/flip/hue for this whole stroke"). Our plan's "`seed` + stamp index" is the per-dab layer; the per-stroke layer is just `hash(seed, key)` with no index — cheap to add and it unlocks "stroke-level variation" presets (each dab consistent, strokes differ), which is a distinct and useful feel.

2. **Drive `rotation` from a drawing-angle term, not just textured-shape auto-orient.** Krita's drawing-angle is a first-class *sensor* that is curvable, offsettable (`angleOffset`), and **lockable** (`lockedAngleMode` freezes the orientation at stroke start — great for calligraphy/ribbon). We currently auto-orient textured shapes only and feed `0` to round. A superset: compute `drawingAngle` in stamp gen (we already have consecutive points), add an `angleOffset` + `followStroke ∈ {off, follow, locked}` to the descriptor, and feed `rotation`. For round procedural tips this is invisible (rotational symmetry) — but the moment a tip is **anisotropic** (`size: SIMD2` roundness, §2.4) or textured, orientation is the difference between a calligraphic ribbon and a fat noodle.

3. **Scatter — direction-aware, diameter-scaled, exactly Krita's formula.** Port `KisScatterOption`'s math verbatim into CPU stamp gen: `jitter = (2*rand-1) * diameter * strength`, with along-path / perpendicular / both-axes modes. Bake the jittered `center` into `StampInstance`. High leverage (it changes the silhouette klein sees) and trivially cheap.

4. **Size + opacity + flow jitter via an additive fuzzy term.** Adopt Krita's "fuzzy is a sensor in the additive bucket" generalization rather than bolting a `sizeJitter` scalar onto each. Concretely: a small per-stamp `jitter(seed, index, key) ∈ [-1,1]` added to size/opacity/flow before baking. The plan already lists `jitterSize/jitterOpacity` in `dynamics` (`unified-brush-engine.md:69`); ground them on the seeded RNG.

5. **Mirror/flip as a thresholded per-dab boolean** (Krita's `≥0.5`). Cheap; for textured tips it kills the "obvious repeated stamp" tiling artifact. Lower priority than scatter/rotation but free once RNG exists.

**Where a superset can *exceed* Krita:** Krita's per-stroke fuzzy is memoized by string key (a `QHash` lookup + mutex per draw — a CPU artifact). We can fold both RNG layers into pure stateless hashing (`hash(seed, stampIndex, channelTag)`), which is **embarrassingly parallel and lock-free** — strictly better for a GPU/SIMD bake than Krita's stateful taus88 stream. The cost: we lose Krita's exact number sequence (irrelevant — we never need bit-compatibility with Krita), but we gain trivial determinism under any parallel stamp-gen.

---

## 4. img2img leverage call

**Geometry is high-leverage: scatter, rotation, and roundness change the *silhouette and edge structure* klein sees, and the model preserves those.** Per `_CONTEXT.md`'s leverage frame, "stroke shape/direction, edge hardness, thick-vs-thin" are explicitly model-consumed. Ranking:

| Feature | Leverage | Why |
|---|---|---|
| **Rotation/orientation of anisotropic tips** | **High (model + hand)** | Calligraphic direction, ribbon edges, chisel marks are macro-shape the model reads and resynthesizes faithfully. Only matters once tips are non-round (pairs with §2.4 `size: SIMD2`). |
| **Scatter** | **High (model)** | Breaks a clean stroke into a textured band — changes the value/coverage distribution at a scale klein keeps (stippling, spray-like grain-of-marks, foliage). |
| **Size jitter** | **Med-high (model + hand)** | Width variation reads as organic line-weight; survives if coarse. Fine high-frequency jitter is partly resynthesized. |
| **Random flip** | **Low-med (hand)** | Mostly an anti-tiling cosmetic on textured tips; the model resynthesizes tip-level detail anyway. Cheap, so worth it, but not a priority. |
| **Per-stroke (vs per-dab) fuzzy** | **Hand-feel** | Stroke-to-stroke variation is felt by the artist; within a single conditioning frame it's a second-order effect. |

**Net:** scatter + anisotropic-tip rotation are the two shape-dynamics features worth prioritizing for img2img; both are "High (geometry)" in the plan's §6 table and this confirms it. The RNG plumbing is the unlock for all of them.

---

## 5. Metal translation notes (respecting perf invariants)

- **Bake all jitter CPU-side in stamp gen, exactly as the plan dictates (§2.4).** Scatter perturbs `center`, size/flip/rotation jitter perturb the per-instance fields, all written into `StampInstance` in `appendStamp`. The fragment shader stays uniform-driven and branch-free. This matches Krita conceptually (Krita resolves the dab params on the paint thread before the dab renders) and respects our **<8ms / no-waitUntilCompleted** invariant — no new GPU pass, no readback.
- **Use stateless hashing, not a stateful PRNG, for the per-dab draws.** A pure `hash(seed, stampIndex, channel)` (e.g. PCG/xxhash-style integer mix, ~5 ALU ops) gives per-dab independent values that are **order-independent and replay-stable**, sidestepping Krita's sequential-consumption fragility entirely. Krita *must* be careful that dabs are consumed in `seqNo` order on worker threads (`00-…:§4`); a hash keyed on `stampIndex` makes that concern vanish — we can generate stamps in any order and get the same result. This is a strict improvement enabled by being downstream of a fixed point array.
- **The CPU-bake cost is the one real risk** and the plan already flags it (`unified-brush-engine.md:103`): at high `count`/`scatter`, per-stamp scalar work on the main thread (which already writes through the `.shared` `stampBuffer` pointer) competes with the frame budget. Mitigation per plan: keep the bake to cheap scalar/hash ops (a hash is ~5 ALU, negligible), benchmark a high-count scatter brush early, and keep the vertex-stage escape hatch (the seed + stamp index are per-instance attributes, so jitter *can* move into the vertex shader if the bake ever dominates).
- **`StampInstance` is the bake target.** Today it's `{center, radius, rotation, color, hardness}` (`CanvasRenderer.swift:153-159`). The plan's superset adds `size: SIMD2` (anisotropy), `seed`, `grainPhase`, etc. (`unified-brush-engine.md:94`). Scatter/rotation/size-jitter all write into existing-or-planned fields — no new buffer plumbing beyond §2.4.
- **Live-preview vs flatten determinism.** For *dry* shape dynamics this is a non-issue: stamps are seeded by `(seed, index)`, so the per-frame incremental preview and the commit/undo replay produce identical stamps regardless of batching (source-over is order-independent). This is strictly easier than the *wet* case the plan worries about (`unified-brush-engine.md:185,293`) — call it out so shape dynamics aren't gated behind the wet-determinism work.

---

## 6. Open questions / risks

1. **Per-dab vs per-stroke fuzzy as a UI concept.** Krita exposes both as distinct sensors (FuzzyPerDab / FuzzyPerStroke). Do we surface both, or just per-dab + a "lock per stroke" toggle? The per-stroke layer is cheap (`hash(seed, key)`, no index) but adds descriptor surface. **Recommend:** ship per-dab first (covers scatter + size jitter, the high-leverage cases); add per-stroke fuzzy when the preset library needs stroke-to-stroke variation.
2. **Fan corners.** Verified that `KisRotationOption` sets `fanCornersInfo` (`KisRotationOption.cpp:63`) but **not traced** into how `paintLine` inserts fan dabs at corners. If we adopt locked/oriented anisotropic tips, sharp corners will gap without an equivalent. Needs a follow-up read of `KisPaintOpUtils::paintLine` corner handling before promising calligraphy parity. *(inferred risk from the comment, not verified end-to-end.)*
3. **Hash quality.** A weak integer hash produces visible regular patterns in scatter (banding). Need a decent mixer (PCG-style) and a quick visual check — verifiable offline per `feedback_verify_shader_color_offline` (render a dense scatter field, eyeball for structure) before device testing.
4. **Seed persistence + schema.** `seed: UInt64` must be added to `Stroke` and survive save/reopen, or reopened drawings re-jitter differently. The plan puts it in stroke JSON, not SwiftData (`unified-brush-engine.md:263`) — confirm the stroke-replay path reads it back before relying on it for undo.
5. **Scatter + clip-path interaction.** Our stamp gen already does `clipPath.contains(pos)` rejection (`MetalCanvasView.swift:902`). Scatter perturbs `pos` *after* the path interpolation — decide whether the clip test runs pre- or post-jitter (Krita scatters then renders; the dab can land outside the nominal path). Minor, but a correctness decision.
6. **Drawing-angle at low speed / stroke start.** Krita's drawing-angle is undefined for a zero-length segment; it has `lockedAngleMode` partly for this. Our first stamp has no previous point — need a defined fallback (carry the first valid angle backward) or the initial dab orients arbitrarily.

# 09 — Color Dynamics + Color Source

**Scope:** how Krita varies a dab's *color* (vs. its shape/opacity): per-dab and per-stroke HSV
jitter, pressure→darken, pressure/speed→HSV, gradient-along-stroke, mix toward a secondary color,
and the random/pattern color sources. Then: what Kiki has (a single static swatch), the gap, the
img2img leverage call, and Metal translation.

Citation key: `krita: <path-relative-to-~/krita_src>:<line>` for verified reads of Krita source;
`<path>:<line>` for our code. **Verified** = I read the code; **inferred** = pattern-matched or
from a comment, hedged explicitly.

---

## 1. How Krita does it — grounded

Krita splits "what color comes out of a dab" into two orthogonal layers that compose:

1. **Color *source*** — *where* the base color comes from (the swatch, a gradient, a pattern, or
   noise). One of six types.
2. **Color *dynamics*** — *transformations* applied to that base color per dab, driven by the
   same sensor+curve machinery as size/opacity (pressure, speed, tilt, fade, fuzzy/random, …).

For the **pixel brush**, both layers are resolved once per dab in a single chokepoint:
`KisBrushOpResources::syncResourcesToSeqNo` (verified, `krita: plugins/paintops/defaultpaintops/brush/KisBrushOpResources.cpp:73`):

```cpp
void KisBrushOpResources::syncResourcesToSeqNo(int seqNo, const KisPaintInformation &info) {
    colorSource->selectColor(m_d->mixOption.apply(info), info);   // 1. source + mix
    m_d->darkenOption.apply(colorSource.get(), info);             // 2. darken (pressure→value)
    if (m_d->hsvTransformation) {                                 // 3. HSV jitter/shift
        Q_FOREACH (KisHSVOption * option, m_d->hsvOptions) {
            option->apply(m_d->hsvTransformation, info);
        }
        colorSource->applyColorTransformation(m_d->hsvTransformation);
    }
    KisDabCacheUtils::DabRenderingResources::syncResourcesToSeqNo(seqNo, info);
}
```

Order is **source → mix → darken → HSV**. Each dab's color is computed *before* the dab mask is
stamped. (Note for our §5: this is per-dab CPU work on the brush thread, exactly the place we'd
bake a per-stamp color into a `StampInstance`.)

### 1.1 Color sources (the six types)

Enum + ids (verified, `krita: plugins/paintops/libpaintop/KisColorSourceOptionData.h:18` and
`KisColorSourceOptionData.cpp:16`): `PLAIN`, `GRADIENT`, `UNIFORM_RANDOM`, `TOTAL_RANDOM`,
`PATTERN`, `PATTERN_LOCKED`. The dispatcher
(`krita: plugins/paintops/libpaintop/kis_color_source_option.cpp:36`) constructs the matching
`KisColorSource` subclass. The base interface
(`krita: plugins/paintops/libpaintop/kis_color_source.h:29`) is:

```cpp
virtual void selectColor(double mix, const KisPaintInformation &pi) = 0;   // pick this dab's color
virtual void applyColorTransformation(const KoColorTransformation*) = 0;    // darken/HSV mutate it
virtual void colorize(KisPaintDeviceSP, const QRect&, const QPoint&) const; // paint it into the dab
```

| Source | `selectColor(mix, pi)` behavior | Cite (verified) |
|---|---|---|
| **Plain** | Linearly blends **foreground** and **background** color by `mix`. `weight = (mix==1)?255:mix*256`; `mixColors([bg,fg], [255-weight, weight])`. So `mix=1`→pure foreground, `mix=0`→pure background. | `kis_color_source.cpp:81` |
| **Gradient** | `m_gradient->colorAt(m_color, mix)` — samples the active gradient at position `mix∈[0,1]`. This is **gradient-along-stroke** when `mix` is driven by the Mix curve-option (see §1.2). | `kis_color_source.cpp:119` |
| **Uniform random** | One random RGB per dab via the **deterministic** per-stroke `pi.randomSource()`; the *whole dab* is that color. `QColor(generate(0,255)×3)`. | `kis_color_source.cpp:139` |
| **Total random** | Per-*pixel* random RGB across the dab rect — uses `std::default_random_engine` seeded by `std::random_device` (i.e. **non-deterministic**, no replay guarantee). Pure RGB noise fill. | `kis_color_source.cpp:163`, fill loop `:175` |
| **Pattern** | Tiles the active pattern image, offset by the dab's document position (`offset % bounds`) so the pattern is continuous across dabs. `selectColor` is a no-op; work happens in `colorize`. | `kis_color_source.cpp:215`, `:231` |
| **Pattern (locked)** | Same but `fillRect(..., m_bounds)` ignores the dab offset → pattern is pinned to dab-local (0,0), so each dab samples the same pattern corner. | `kis_color_source.cpp:234` |

**Determinism trap, verified in source:** `UNIFORM_RANDOM` uses `pi.randomSource()`
(`KisRandomSource`, seeded, "two sources with the same seed generate the same sequence" —
`krita: libs/global/kis_random_source.h:20`), so it replays identically on undo/redo.
`TOTAL_RANDOM` uses a fresh `std::random_device`+`default_random_engine`
(`krita: plugins/paintops/libpaintop/kis_color_source.cpp:181`) and is therefore **not
replay-deterministic** — a real inconsistency in Krita itself. We must use the seeded path
exclusively (our §5 / `unified-brush-engine.md:101`).

### 1.2 The Mix option — gradient-along-stroke & color-along-stroke

`mix` passed to `selectColor` comes from `m_d->mixOption.apply(info)`
(`krita: KisBrushOpResources.cpp:75`). `KisMixOption = KisStandardOption<KisMixOptionData>`
(`krita: plugins/paintops/libpaintop/KisStandardOptions.h:51`), and `apply` is just
`computeSizeLikeValue(info)` (returns 1.0 if unchecked) (`krita: KisStandardOptions.h:27`).

So **Mix is an ordinary curve-option**: bind it to a Distance/Fade/Pressure/Speed sensor and the
gradient is swept along the stroke, or the foreground↔background blend tracks pressure. With Mix
unchecked → `1.0` → always pure foreground (Plain) / gradient end (Gradient). This is the elegant
part: gradient-along-stroke is **not a special feature**, it's "Gradient source + a Mix curve on
the Distance sensor." (Verified by tracing the call chain; the *artistic interpretation* —
"sweep along stroke" — is inferred from what Distance/Fade sensors produce.)

### 1.3 Darken option (pressure→value, the classic ink feel)

`KisDarkenOption` is a curve-option (`krita: plugins/paintops/libpaintop/KisDarkenOption.cpp:22`).
Per dab:

```cpp
quint32 darkenAmount = (qint32)(255 - 255 * computeSizeLikeValue(info));         // :53
KoColorTransformation* t = colorSpace()->createDarkenAdjustment(darkenAmount, false, 0.0);
colorSource->applyColorTransformation(t);                                        // :57
```

`computeSizeLikeValue` returns the curve value (≈ pressure through the curve) in [0,1], so high
curve value → `darkenAmount≈0` → no darkening; low value → `darkenAmount≈255` → fully darkened.
Bound to pressure, light strokes go darker/lighter depending on the curve — the classic
"pressure controls ink density without controlling opacity" behavior. Verified math; the precise
perceptual meaning of `createDarkenAdjustment`'s amount is acknowledged fuzzy *in Krita's own
comment* (`krita: KisDarkenOption.cpp:36` "Darken docs aren't really clear…") — code wins: it's a
linear `255 - 255*curve`.

### 1.4 HSV options (the real per-dab color dynamics) — the key mechanism

This is the most important finding. The pixel brush exposes **three independent curve-options** —
Hue, Saturation, Value (`krita: KisBrushOpResources.cpp:53`) — each a `KisHSVOption : KisCurveOption`
(`krita: plugins/paintops/libpaintop/KisHSVOption.cpp:15`). They share one `hsv_adjustment`
`KoColorTransformation` (`krita: KisBrushOpResources.cpp:59`). Per dab (`KisHSVOption::apply`,
`krita: KisHSVOption.cpp:36`):

- **Hue** uses `computeRotationLikeValue(info, 0, false, 1.0, isHoveringMode())`
  (`krita: KisHSVOption.cpp:47`) — hue is angular/wrapping, so it uses the *rotation* combiner.
- **Saturation / Value** use `computeSizeLikeValue` then **remap to a signed range**
  (`krita: KisHSVOption.cpp:50`):
  ```cpp
  v = computeSizeLikeValue(info);
  qreal halfValue = strengthValue() * 0.5;
  v = (v * strengthValue()) + (0.5 - halfValue);   // recenters around 0.5 scaled by strength
  v = (v * 2) - 1;                                  // map [0,1] → [-1,1] signed shift
  ```
- Then `transfo->setParameter(paramId, v)`, type=HSV, colorize=false, compatibility=false
  (`krita: KisHSVOption.cpp:54`).

**Where the randomness comes from — the Fuzzy sensor.** HSV "jitter" is not a separate code path:
you attach a **Fuzzy** sensor to the Hue/Sat/Value curve-option. The sensor returns signed noise
(`krita: plugins/paintops/libpaintop/sensors/KisDynamicSensorFuzzy.cpp:25`):

```cpp
result = m_fuzzyPerStroke
    ? info.perStrokeRandomSource()->generateNormalized(key)   // one value for the whole stroke
    : info.randomSource()->generateNormalized();              // a new value per dab
result = 2.0 * result - 1.0;                                  // → [-1, 1], additive
```

`isAdditive()==true` (`:20`), so in the curve combiner the value lands in `components.additive`
and is folded via `additiveToScaling` (verified the additive branch at
`krita: plugins/paintops/libpaintop/KisCurveOption.cpp:113`; final fold at
`KisCurveOption.cpp:82` `sizeLikeValue` = `qBound(min, constant*offset*scaling*additivePart, max)`).
**`FuzzyPerDab` = per-dab jitter; `FuzzyPerStroke` = one offset for the whole stroke**
(`krita: KisDynamicSensorFuzzy.cpp:39` and `:45`). That single distinction is exactly the
"stamp vs stroke" split in our descriptor (`unified-brush-engine.md:68`).

So the full sentence: **per-dab HSV jitter = HSV curve-option + Fuzzy(per-dab) sensor; per-stroke
HSV jitter = same option + Fuzzy(per-stroke) sensor; pressure→saturation = same option + Pressure
sensor.** It's all one abstraction. (Verified by reading the option + sensor; the artistic naming
is the inference.)

### 1.5 The spray paintop's color jitter (a *separate*, simpler, bounded model)

The spray paintop does **not** use curve-driven HSV. It has its own flat `KisColorOptionData`
(`krita: plugins/paintops/libpaintop/KisColorOptionData.h:50`) with bools
`useRandomHSV/useRandomOpacity/sampleInputColor/fillBackground/colorPerParticle/mixBgColor` and
integer bounds `hue/saturation/value`. Per particle (`krita: plugins/paintops/spray/spray_brush.cpp:282`):

```cpp
params["h"] = (hue / 180.0) * randomSource->generateNormalized();   // hue jitter ∈ [0, hue/180]
params["s"] = (saturation / 100.0) * randomSource->generateNormalized();
params["v"] = (value / 100.0) * randomSource->generateNormalized();
m_transfo->setParameters(params); ... transfo->transform(inkColor, inkColor, 1);
```

Plus: `sampleInputColor` reads the canvas under the particle (`:261`); `mixBgColor` blends ink
toward background by `info.pressure()` (`:266`); `useRandomOpacity` randomizes per-particle alpha
(`:292`); `colorPerParticle` decides whether to recolor every particle or once per dab (`:298`).
This is a **bounded one-sided jitter** ([0, amount], not ±amount) and uses the deterministic
`randomSource` (`:153`). Useful as a *second* mental model: spray = explicit bounded knobs;
pixel brush = general curve+sensor. Our `colorDynamics` panel should expose the *bounded knob*
UI but implement it via the *general* mechanism. (All verified.)

---

## 2. How Kiki does it today

Color is a **single static premultiplied swatch baked at stamp generation. There are zero
dynamics.** Facts:

- `BrushConfig.color: CodableColor` is one RGBA value on the brush
  (`ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:64`). No secondary color,
  no gradient, no pattern, no jitter fields.
- Every stamp in a stroke gets the *same* color: stamp color is `premultipliedColor`, fed in
  **linear** (`s2l(brush.color)`) into the `_srgb` scratch (per `CanvasModule/CLAUDE.md` →
  "Brush rendering flow" step 3; `StampInstance.color` is one value, not per-stamp-varied).
- The only per-stamp *variation* we have is on **alpha/coverage** (flow, pressure→width, taper),
  never on hue/sat/value. `StrokePoint` carries `{position, force, altitude, timestamp}` only
  (`_CONTEXT.md` engine facts) — no azimuth/rotation, so even tilt-driven color is impossible
  today.
- The wet path mixes color, but only with **canvas pixels under the brush** (KM smear), not with
  a configured secondary ink or noise — that's color *mixing*, not color *dynamics*.

The committed target (`unified-brush-engine.md`) already anticipates this gap:
`colorDynamics: { stamp{hue,sat,light,dark,secondary}, stroke{...}, pressure{...}, tilt{...} }`
(`unified-brush-engine.md:68`); color moves off the brush onto the stroke as `ink`/`secondaryInk`
(`:75`); per-dab color is "baked CPU-side from descriptor + seed into `StampInstance.color`;
secondary = `Stroke.secondaryInk`" (`:221`); determinism via `stroke.seed` + stamp index
(`:101`). So the *plan* is right — this doc's job is to check it against Krita.

---

## 3. Gap analysis + what a Krita-grade superset adopts

| Capability | Krita | Kiki today | Kiki target plan | Verdict |
|---|---|---|---|---|
| Per-dab HSV jitter | Yes (HSV opt + Fuzzy-per-dab) | None | `colorDynamics.stamp{hue,sat,light,dark}` | **Adopt; high img2img value** |
| Per-stroke HSV jitter | Yes (Fuzzy-per-stroke) | None | `colorDynamics.stroke{}` | Adopt; cheap |
| Pressure/speed/tilt→HSV | Yes (any sensor on HSV curve) | None | `colorDynamics.pressure/tilt{}` | Adopt |
| Pressure→darken (value w/o opacity) | Yes (Darken opt) | None | folds into `colorDynamics.dark` | Adopt; ink feel |
| Mix toward secondary color | Plain source (fg↔bg by Mix curve) | None | `Stroke.secondaryInk` + stamp `secondary` | Adopt |
| Gradient-along-stroke | Yes (Gradient source + Mix on Distance) | None | not in plan explicitly | **Plan gap — add** |
| Uniform-random color (per dab) | Yes (deterministic) | None | partially via stamp hue jitter at max | Optional |
| Total-random (per-pixel noise) | Yes (non-deterministic) | None | — | Reject (no img2img value, breaks replay) |
| Pattern / locked-pattern source | Yes | None | — | Reject for v1 (low leverage) |

**What a superset adopts beyond the plan:**

1. **Make Color Dynamics a *sensor-driven curve*, not just a jitter scalar.** The plan's
   `colorDynamics.{stamp,stroke,pressure,tilt}` buckets read as four separate jitter sources. Krita's
   insight is that they are **one curve-option per channel (H,S,V) fed by a chosen sensor**
   (Fuzzy-per-dab, Fuzzy-per-stroke, Pressure, Speed, Tilt, Distance/Fade). Modeling it as
   "(channel) × (sensor + response curve + amount)" is *more* capable than four fixed buckets and
   directly mirrors `KisHSVOption` (`KisHSVOption.cpp:36`). This also makes gradient-along-stroke
   (#6 above) fall out for free: it's "Mix channel + Distance sensor."

2. **Add the gradient/color-along-stroke source.** The plan tracks `ink`/`secondaryInk` but never a
   *gradient* mix swept by arc-length. Krita gets this for almost no code (`KisGradientColorSource`
   + Mix-on-Distance, `kis_color_source.cpp:119`). For img2img this is *high* leverage (a stroke
   that shifts hue along its length is a strong conditioning signal). Recommend: model
   `secondaryInk` mix as a per-stamp `mix∈[0,1]` that a curve can drive along arc-length — that *is*
   gradient-along-stroke with a 2-stop gradient, and a multi-stop gradient is a later extension.

3. **Signed vs one-sided jitter.** Note Krita has *both*: the pixel brush's Fuzzy is **±amount**
   (`KisDynamicSensorFuzzy.cpp:33` `2*r-1`), the spray's is **[0, amount]** one-sided
   (`spray_brush.cpp:283`). Our panel should default to **±** (centered jitter reads more natural)
   but the implementation cost is identical.

4. **Darken-without-opacity is a distinct, worth-having behavior.** Pressure→opacity and
   pressure→value(darken) look similar but differ: darken keeps coverage solid while shifting the
   *color* darker. For an ink/marker feel under img2img (value structure is high-leverage) this is
   worth a dedicated `dark` channel, exactly as the plan lists.

---

## 4. img2img leverage call

**This is the highest-leverage *color* feature in the whole brush research, second only to wet
color mixing.** Per `_CONTEXT.md`: hue, saturation, and large-scale value structure are things the
model *reads*, while grain/tooth/micro-detail are *resynthesized away*. Color dynamics moves
exactly the leverage axes:

- **Hue/Sat per-stroke jitter → HIGH.** A field of strokes whose hue wanders ±10° reads to klein as
  "varied, painterly color region" rather than "flat fill" — it changes what the model generates,
  not just how the canvas looks. Cheap to implement, big perceptual swing in the output.
- **Pressure→value/darken → HIGH.** Value structure is the single strongest conditioning signal;
  letting pressure carve value (not just opacity) gives the model real tonal structure to latch
  onto.
- **Gradient/secondary-along-stroke → HIGH.** A directional hue shift along a stroke is a clear
  large-scale signal the model honors.
- **Per-dab (vs per-stroke) jitter → MEDIUM.** The model may average out very high-frequency per-dab
  hue noise the way it eats grain; per-*stroke* and slow per-dab drift survive better. Prioritize
  per-stroke + low-frequency per-dab over aggressive per-dab speckle.
- **Total-random / pattern sources → LOW.** Per-pixel RGB noise and pattern fills are mostly
  resynthesized; also `TOTAL_RANDOM` breaks replay determinism. Skip for v1.

Priority within color dynamics: **per-stroke H/S jitter + pressure→value** first (max leverage,
min code), then **secondary/gradient-along-stroke**, then **per-dab jitter** tuned low-frequency.

---

## 5. Metal translation notes (respecting perf invariants)

The translation is **clean and cheap** because color dynamics is pure CPU arithmetic at stamp
generation — it never touches the fragment hot path.

- **Bake per-stamp color CPU-side into `StampInstance.color`.** The plan already specifies this
  (`unified-brush-engine.md:94`, `:221`): per-dab dynamics are "resolved CPU-side at stamp
  generation (`generateStampsForStroke`) and baked here." This mirrors Krita's
  `syncResourcesToSeqNo` running per dab on the brush thread
  (`krita: KisBrushOpResources.cpp:73`) — same architecture, different thread. **No new GPU pass,
  no new bound texture, no per-frame readback.** The fragment shader stays uniform/instance-driven,
  so the <8ms/120Hz invariant and the "no `waitUntilCompleted` on the hot path" rule are untouched.

- **Color math: do HSV in a perceptually sane space, then convert to linear premultiplied for the
  `_srgb` scratch.** Critical interaction with our color pipeline (`CanvasModule/CLAUDE.md`):
  jitter the swatch in **sRGB or HSV space** (matching how the user picked it), *then* apply
  `s2l()` (sRGB→linear) before packing into `StampInstance.color`, exactly as the static path does
  today. Jittering *after* the linearization would shift perceived hue/value nonlinearly. Krita
  works in the color space's HSV adjustment (`hsv_adjustment` transform); we should compute HSV
  shift on the sRGB swatch, convert RGB→HSV→RGB in Swift, then `s2l`.

- **Determinism: seed from `stroke.seed` + stamp index, never wall-clock.** This is the named
  Phase-2 trap (`unified-brush-engine.md:101`). Krita's deterministic path is `pi.randomSource()`
  (per-stroke seeded — `kis_random_source.h:20`) and `perStrokeRandomSource()` for the per-stroke
  variant (`KisDynamicSensorFuzzy.cpp:31`). The matching design: a small splitmix/PCG seeded by
  `(stroke.seed, stampIndex, channelId)` for per-dab; `(stroke.seed, channelId)` for per-stroke.
  Undo/replay re-runs `generateStampsForStroke` and reproduces identical colors. **Do not port
  `TOTAL_RANDOM`'s `std::random_device` path** — it's the one place Krita itself is
  non-deterministic (`kis_color_source.cpp:181`).

- **Secondary-ink / gradient-along-stroke = a per-stamp `mix` scalar.** Store `mix∈[0,1]` per stamp
  (a curve over arc-length, computed in stamp gen), then `lerp(ink, secondaryInk, mix)` in Swift
  before `s2l`. This reuses the exact `mix` semantics of `KisPlainColorSource::selectColor`
  (`kis_color_source.cpp:81`) — a weighted 2-color blend — and is the 2-stop case of
  gradient-along-stroke. No shader change; it's just which RGBA gets baked per stamp.

- **Per-stamp color cost is negligible.** A few RGB↔HSV conversions + one RNG draw per stamp, on
  the CPU, alongside the arc-length resample we already do. No `getBytes`, no GPU sync — unlike the
  wet smear's per-dab 1×1 readback (`CanvasRenderer.swift:585`, the named anti-pattern). Color
  dynamics is strictly cheaper than what we already ship.

---

## 6. Open questions / risks

1. **Color space of the jitter.** Krita's `hsv_adjustment` operates in the document color space's
   HSV; we'd jitter in sRGB-HSV. For sRGB-only canvases this is fine, but if we ever widen gamut the
   "where does the HSV math live" question reopens. Low risk for v1 (we're sRGB throughout). *Verify
   before shipping wide-gamut.*

2. **Per-dab hue jitter frequency vs img2img.** Unverified empirically: how much high-frequency
   per-dab hue noise survives klein vs gets averaged out. The leverage call in §4 (favor per-stroke +
   low-freq per-dab) is *inferred* from the `_CONTEXT.md` leverage model, not measured. Worth a quick
   img2img-survival spike (same kind the plan gates Grain behind, `unified-brush-engine.md:218`)
   before tuning per-dab jitter aggressively.

3. **Hue wrap-around.** Krita treats hue as rotational (`computeRotationLikeValue`,
   `KisHSVOption.cpp:47`) precisely because hue wraps at 360°. Our Swift implementation must wrap hue
   mod 1.0, not clamp — clamping would pile jittered reds against a hue boundary. Easy to get wrong;
   call it out in implementation.

4. **Signed-additive fold subtlety.** Krita folds additive sensor contributions through
   `additiveToScaling` then bounds by `[min,max]` (`KisCurveOption.cpp:82`). I read the additive
   branch and the final `sizeLikeValue` fold but **did not** read `KisDynamicSensor::additiveToScaling`
   itself — the exact additive→multiplicative remap is *unverified*. For our purposes (we control the
   whole curve), this is a "match the feel, not the formula" item; flagging it as the one piece of
   the HSV math I inferred rather than read line-by-line.

5. **Gradient resources.** Adopting gradient-along-stroke beyond a 2-stop secondary-ink lerp means
   bringing in a gradient resource model (multi-stop, interpolation mode). The plan doesn't model
   gradients at all. Recommend shipping the 2-stop `secondaryInk` mix first (covers ~80% of the
   visual value) and deferring true multi-stop gradients.

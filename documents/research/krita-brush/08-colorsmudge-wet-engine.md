# 08 — The Color-Smudge / Wet Engine

**Topic:** Krita's `colorsmudge` paintop vs. Kiki's spectral-KM wet path. The single
highest-leverage brush topic for an img2img app, because the smudge/wet engine is the only
brush that **reads the canvas it sits on and re-deposits a color that depends on it** — i.e.
the only place where *color mixing* (high-leverage for klein) and *wet drag* (hand-feel)
are produced together.

Citations: `krita: <path>:<line>` is relative to `/Users/donald/krita_src`; our code is
`<path>:<line>`. Claims are marked **[verified]** (read the code) or **[inferred]**.

---

## 1. How Krita does it — grounded

### 1.1 The shape of the engine: one paintop, four strategies, two *modes*

`KisColorSmudgeOp` is a single paintop that, at construction, picks **one of four strategy
objects** based on the brush's *application type* and an engine flag — and, orthogonally,
each strategy runs in one of **two blend modes** (Smearing vs Dulling). The strategy is
chosen here **[verified]**:

| Condition (`kis_colorsmudgeop.cpp:81–111`) | Strategy |
|---|---|
| `brushApplication() == LIGHTNESSMAP` | `KisColorSmudgeStrategyLightness` (paint-thickness / heightmap) |
| `useNewEngine() && brushApplication() == ALPHAMASK` | `KisColorSmudgeStrategyMask` (the modern default) |
| `IMAGESTAMP` or `GRADIENTMAP` | `KisColorSmudgeStrategyStamp` |
| else | `KisColorSmudgeStrategyMaskLegacy` (pre-2021 path) |

The crucial conceptual correction to the task brief: **Dulling vs Smearing is NOT
Stamp-vs-Mask.** They are independent axes.

- **Strategy** (Mask / Lightness / Stamp / Legacy) = *what kind of dab mask & color source*
  (alpha mask, heightmap-modulated lightness, image stamp). `kis_colorsmudgeop.cpp:81`.
- **Mode** (`SMEARING_MODE` / `DULLING_MODE`) = *how the background is sampled into the dab*.
  It comes from the **Smudge Length** option (`KisSmudgeLengthOptionMixInImpl::Mode`,
  `KisSmudgeLengthOptionData.h:17`) and is read into `useDullingMode` at
  `kis_colorsmudgeop.cpp:76`, then handed to *every* strategy's base ctor. Both Mask and
  Stamp strategies support both modes. **[verified]**

The Smearing-vs-Dulling fork lives in `KisColorSmudgeStrategyBase::blendBrush`
(`KisColorSmudgeStrategyBase.cpp:184`), which all strategies call:

- **Smearing** (`m_useDullingMode == false`): `blendInBackgroundWithSmearing`
  (`:264`) reads the **previous-position** rectangle (`srcRect`) and the **current-position**
  rectangle (`dstRect`) from the source device and composites the *displaced* background onto
  the dab with `smudgeRateOpacity`. This is the literal "drag the pixels along" smear — the
  dab is filled with a copy of the neighbourhood the brush just came from. `srcRect` is
  computed in the paintop as `m_dstDabRect.translated(m_lastPaintPos - newCenterPos)`
  (`kis_colorsmudgeop.cpp:192`) — i.e. offset by the inter-dab travel vector. **[verified]**
- **Dulling** (`m_useDullingMode == true`): `sampleDullingColor` (`:172`) collapses the
  source neighbourhood to **one average color**, then `blendInBackgroundWithDulling` (`:286`)
  fills the dab with that solid color at `dullingRateOpacity`. "Dulling" because repeated
  averaging desaturates / dulls. `dullingRateOpacity = 0.8 · smudgeRate · opacity`
  (`:162`) — note the magic `0.8` damping. **[verified]**

So: *Smearing = directional pixel drag (keeps texture/edges); Dulling = average-then-fill
(loses texture, smooth blend).* That is the real distinction, and it is finer than the brief
assumed.

### 1.2 The three weights every dab combines

`blendBrush` composes the final dab from three contributions, each with its own opacity
derived from per-dab curve values (`KisColorSmudgeStrategyBase.cpp:190–247`) **[verified]**:

| Contribution | Opacity formula | Source line |
|---|---|---|
| **Smear/Dulling background** | smear: `smudgeRate·opacity`; dull: `0.8·smudgeRate·opacity` | `:167`, `:162` |
| **Color rate** (fresh paint color) | `colorRate² · opacity` (note the **square**) | `:154` |
| **Final blt opacity** | `OPACITY_OPAQUE_F` (=1; the dab itself is opaque, all weighting is internal) | `:146` |

The `colorRate²` squaring (`:159`) is a deliberate perceptual curve so the color slider feels
linear; that is a free, cheap nicety. `smudgeRate` and `colorRate` are **not constants** —
each is a `computeSizeLikeValue(info)` of a full curve option (`kis_colorsmudgeop.cpp:201–202`),
so pressure/speed/tilt can drive "how much I pick up" vs "how much fresh paint I lay down"
*independently per dab*. This is the dynamics layer (topic 02) applied to smudge.

There is also a **fused fast path** (`blendInFusedBackgroundAndColorRateWithDulling`,
`:24`/`:218`): when dulling + both ops are simple OVER (or COPY at full opacity), Krita pre-mixes
the dulling color and the paint color into one solid `dullingFillColor` and fills once,
skipping a composite. Pure CPU micro-opt; irrelevant to a GPU port. **[verified]**

### 1.3 Smudge **Radius** — weighted, converged, Halton-sampled averaging

`KisSmudgeRadiusOption` (range `0.0–3.0`, `KisSmudgeRadiusOptionData.cpp:13`) controls **how
large an area is averaged** in dulling mode. The sampling is genuinely sophisticated
(`KisColorSmudgeSampleUtils.h:134` `sampleColor<>`) **[verified]**:

1. Blow up `srcRect` by `0.5·(radius−1)` (`:152`) to get the sample area.
2. Sample "random" pixels via **two Halton sequences** (bases 2 and 3, `:163`) — a
   low-discrepancy quasi-random sequence so coverage is even, not clumpy.
3. Accumulate into a `KoMixColorsOp::Mixer`, **weighted by the brush mask alpha** at each
   point (`WeightedSampleWrapper::samplePixel`, `:39–46`) — so the center of the brush
   contributes more than the rim.
4. Stop early when the mixed color **converges**: after a 64-sample (or 2%) seed, batches of
   16 are added until the color difference drops `≤ 2` (`:204`). Adaptive cost.
5. If "all sampled pixels were masked out" (`currentWeightsSum() < 128`, `:60`), **grow the
   radius by 0.05 and retry** (`:214`) — robustness against transparent regions.

This is materially more advanced than a box blur: it is a **mask-weighted, importance-stopped,
quasi-random average**. The `AveragedSampleWrapper` variant (`:73`) is the unweighted sibling
used when no mask weighting is wanted.

### 1.4 Interstroke data — the real "reservoir," and it is NOT what we have

`KisColorSmudgeInterstrokeData` (`KisColorSmudgeInterstrokeData.h:25`) is Krita's carried
state. It is **only created for `LIGHTNESSMAP` brushes** (`kis_colorsmudgeop.cpp:246` —
`needsInterstrokeData = brushApplication == LIGHTNESSMAP`). It holds **three full-canvas
high-precision paint devices** **[verified]**:

- `colorBlendDevice` — high-precision color projection,
- `heightmapDevice` — an RGB8 **heightmap** (paint thickness),
- `projectionDevice` — the composited low-precision result written back to the layer.

The header comment is the design intent (`:18–24`): *"The layer itself stores only the
low-precision final projection, so as soon as the interstroke data is reset, the paint is
considered as 'dried-out'."* This is a profound idea: **wet paint persists at higher precision
between strokes; "drying" = discarding the interstroke buffer.** It survives across *strokes*,
not just dabs, wrapped in undo transactions (`beginTransaction`/`endTransaction`, `:32`/`:41`).

**Critical correction to the brief's framing:** Krita's interstroke data is **NOT a small
1-D carried-load reservoir** analogous to our `wetLoad`. It is full-canvas-sized high-precision
mirror buffers. The "carried pigment along the stroke" concept (our `wetLoad`, the unified
plan's `reservoirBuf`) **does not exist in Krita's smudge at all.** Krita re-samples the
canvas neighbourhood every dab (smearing reads `srcRect`; dulling averages a radius) — it does
not carry a running pigment load forward. *This is a genuine architectural divergence, and a
place where our model is arguably closer to physical media than Krita's.* (See §3.)

### 1.5 The Lightness strategy — heightmap + paint thickness (Krita's "impasto")

`KisColorSmudgeStrategyLightness` (`KisColorSmudgeStrategyLightness.cpp`) is where Krita does
something genuinely "thick paint." It keeps a **separate RGB8 heightmap device**; each dab:

1. Fetches a *normalized image dab* (`fetchNormalizedImageDab`, `:94`) — grayscale brush tip
   used as a height field.
2. **Paint Thickness** (`KisPaintThicknessOption`, range derived from a curve) scales the
   height excursion around mid-gray 127: `gray = 127 ± multiply(|g−127|, thickness·255)`
   (`:111–124`). Thickness `<1` flattens toward neutral. **[verified]**
3. Composites the height into `heightmapDevice` with opacity
   `opacity · lerp(smudgeRate−0.01, 1.0, thickness)` in OVERLAY thickness-mode, or `·1.0` in
   OVERWRITE mode (`:165–171`). OVERWRITE = each stroke replaces height; OVERLAY = height
   accumulates.
4. Then `modulateLightnessByGrayBrush` (`:190`) **re-lights the color layer by the heightmap**
   — the stored color is modulated by the height field, so paint looks raised/lit. This is a
   software bump-lighting of the paint. **[verified]**

So Krita's "paint thickness/height" is a **lightness-modulation impasto fake**, not a normal
map or a real lighting pass. The heightmap is the only thing that lives in the interstroke
data's `heightmapDevice`.

### 1.6 Overlay mode & Gradient — two smaller features

- **Overlay mode** (`KisColorSmudgeStrategyWithOverlay.cpp:26`): when on, the smudge **samples
  from the whole image projection** (all layers composited, via `KisColorSmudgeSourceImage`,
  `KisColorSmudgeSource.cpp:42`) instead of just the active layer. So you can smudge using
  colors from layers below without merging them. Pure *sampling-source* swap. **[verified]**
- **Gradient** (`KisGradientOption.cpp:21`): replaces the fresh paint color per dab by looking
  up a gradient at `computeSizeLikeValue(info)` — i.e. the curve drives a position along a
  gradient. Pressure/speed → gradient position. Cheap, expressive. **[verified]**
- **HSV options** (`kis_colorsmudgeop.cpp:116–126`, `:209–214`): per-dab hue/sat/value shifts
  on the paint color via a color transform, also curve-driven. **[verified]**

---

## 2. How Kiki does it today

Our wet path is a **single direct-to-layer framebuffer-fetch RMW** with a **CPU-carried
running pigment load**, plus spectral Kubelka-Munk color mixing — a different architecture
from every Krita strategy.

**The carried load (`wetLoad`) — our "reservoir":** a single `SIMD3<Float>` linear color
(`MetalCanvasView.swift:93` declares it). Per stroke it is reset to the brush color
(`MetalCanvasView.swift:945`), then **each dab**:

1. Emits a stamp carrying the *current* `wetLoad` as its color, deposit weight `dep`
   (`MetalCanvasView.swift:956–959`).
2. **Reads one canvas pixel** under the dab via `sampleLayerColor` — a synchronous 1×1
   `getBytes` (`CanvasRenderer.swift:585`).
3. **Contaminates the load** toward that pixel: `wetLoad = kmMixCPU(wetLoad, s.color,
   pickup · s.alpha)` (`MetalCanvasView.swift:960–961`).

So our load *travels and evolves* along the stroke — fundamentally the Procreate "Charge/Pull"
model, **which Krita does not have** (§1.4). `pickup` = our **Smear** knob (`wetPickup`);
`dep = wetStrength · opacity` (`MetalCanvasView.swift:938`) = our **Mix** knob folded with the
opacity slider.

**The deposit (`wetStampFragment`, `CanvasRenderer.swift:1587`):** the marquee difference from
Krita. We do **spectral Kubelka-Munk pigment mixing**:

1. Coverage `cov` from procedural hardness falloff (`:1594–1598`).
2. Mix target = `mix(brushLin, under, dst.a)` so unpainted canvas mixes toward the load color,
   painted canvas toward the under-color (`:1606`).
3. Both colors **upsampled to a 36-band reflectance spectrum** via Mallett-Yuksel 7-basis
   (`:1608–1621`), KM-mixed per band (`ks = (1−R)²/2R`, `:1630–1633`), integrated back to
   linear RGB through a precomputed spectrum→RGB matrix (`:1628`), with **endpoint-exact
   residual correction** so unmixed colors stay faithful (`:1641`). Tables built once in
   `setupWetKMTables` (`CanvasRenderer.swift:491`). **[verified]**
4. Alpha builds by coverage (`:1644`) — opaque wet paint, no translucent fringe.

The CPU `kmMixCPU` (`CanvasRenderer.swift:564`) is the *same* spectral model used to evolve
the carried load, so load contamination and on-canvas deposit are color-consistent.

**Our two knobs** (vs Krita's ~7 curve options): **Mix** (`wetStrength` → deposit weight) and
**Smear** (`wetPickup` → load contamination rate). Both are **scalars, not curve options** —
no per-dab pressure/speed/tilt response.

**Architecture:** direct-to-layer RMW, `applyWetStamps` (`CanvasRenderer.swift:444`), async
commit, no `waitUntilCompleted`. This is the path the unified-brush-engine plan calls out for
replacement: it only sees **committed** paint (not the in-flight stroke), and it does a
**synchronous main-thread `getBytes` per dab** (`unified-brush-engine.md:135`).

---

## 3. Gap analysis — what a Krita-grade superset adopts

| Capability | Krita | Kiki today | Verdict |
|---|---|---|---|
| **Spectral KM color mixing** | ❌ RGB/lightness smear only (`KoMixColorsOp` is linear) | ✅ 36-band Mallett-Yuksel | **We exceed Krita.** Keep it; it is our moat. |
| **Carried pigment load (Charge/Pull)** | ❌ none — re-samples canvas every dab | ✅ `wetLoad` travels & contaminates | **We exceed Krita** (closer to physical media). |
| **Smearing vs Dulling as two distinct samplers** | ✅ directional drag vs averaged fill | ⚠️ only one behavior (load + 1-px pickup) | **Adopt both.** Our pickup is closer to dulling-of-1-px; we have no directional drag. |
| **Smudge Radius (weighted Halton-converged average)** | ✅ 0–3, mask-weighted, importance-stopped | ❌ single pixel (`sampleLayerColor` 1×1) | **Adopt.** Biggest *quality* gap — see below. |
| **Per-dab curve dynamics on smudge/color rate** | ✅ every weight is a curve option | ❌ Mix/Smear are flat scalars | **Adopt** (fold into the topic-02 curve layer). |
| **Paint Thickness / heightmap impasto** | ✅ lightness-modulated bump | ❌ none | Adopt *as lightness modulation*, low priority (model eats micro-height). |
| **Overlay (sample whole image)** | ✅ | ❌ (we have one active layer anyway) | Defer — single-layer makes it moot today. |
| **Gradient / HSV per-dab color** | ✅ curve-driven | ❌ | Cheap, expressive; fold into color-dynamics. |
| **Interstroke "wet persists, drying = discard buffer"** | ✅ full-canvas hi-precision | ❌ load resets per stroke | **Conceptually adopt** the "drying" idea; see §6. |

**The single biggest quality gap is Smudge Radius (§1.3).** Our pickup reads **one pixel**
(`CanvasRenderer.swift:585–591`). Krita averages a **mask-weighted neighbourhood** with
adaptive convergence. A 1-pixel pickup on a textured or noisy canvas produces a jittery,
aliased load color; a radius-weighted average is what makes Krita's smudge feel like it
*grabs a swatch of color* rather than chasing a single texel. This is also **high img2img
leverage** (it changes the actual hue/value the brush lays down — see §4).

**The biggest architecture lesson:** Krita's strategy split proves that *sampler behavior
(smear/dull/radius) is orthogonal to color model (mask/lightness/stamp)*. Our unified plan's
`reservoirBuf` Pass A (`unified-brush-engine.md:133`) should expose **both** a directional
smear (read displaced `srcRect` — i.e. read `belowTex`/`sabPrev` at the *previous* dab center)
and a radius-averaged dulling pickup, selected by a uniform — not collapse to one. The plan's
`pull`/`grade` only model the *dulling/average* axis; **the directional drag axis is missing
from the plan** and is exactly what Krita's smearing mode provides. (Confirmed against
`unified-brush-engine.md:139`: `newLoad = KM_mix(prevLoad, sampledCanvas, pull·canvasAlpha)` —
that is dulling-style point sampling, no displacement vector.)

**Where the brief was wrong, restated for the record:** Dulling≠Stamp and Smearing≠Mask.
They are orthogonal axes (§1.1). The unified plan must not conflate them either.

---

## 4. img2img leverage call

**Smudge/wet is the highest-leverage brush family for klein**, because it is the only brush
that **emits a color the model has never been told about** — a *physically mixed* hue/value
produced from the canvas + the load. Per the `_CONTEXT.md` leverage frame:

- **High leverage (model consumes):**
  - **Spectral KM mixing** (ours) — produces the *correct* subtractive mix (blue+yellow→green),
    which is large-scale hue/value structure the model reads directly. This is our single most
    leverage-positive brush feature and a real edge over Krita's linear RGB smear (Krita's
    blue+yellow→gray; ours→green). **Keep & defend.**
  - **Smudge Radius** — changes the *actual deposited color* (averaged swatch vs single texel).
    A radius-averaged pickup gives smoother, more intentional hue gradients that survive JPEG
    capture and re-synthesis. **High leverage, adopt.**
  - **Smearing directional drag** — produces edge *direction* and soft value transitions the
    model reads as brush-stroke structure. Medium-high.
  - **Color/Smudge rate as curves** — pressure→ "more pickup vs more fresh paint" changes the
    color the model sees per stroke; high leverage and cheap (curve layer already planned).
- **Hand-feel (model may eat, artist feels):** the *travel* of the carried load (Charge/Pull),
  taper of the smear. Worth keeping for "feels pro."
- **Low leverage (model overwrites):** **Paint Thickness / heightmap impasto** — the lit
  micro-relief is precisely the "PBR micro-detail / single-pixel burnt edges" the model
  discards. *Deprioritize Krita's heightmap impasto.* If we want thick-paint signal the model
  will read, it must come through **value/hue contrast** (KM mixing already does this), not a
  bump-lighting pass.

**Net:** double down on KM mixing + smudge radius + curve-driven rates; skip heightmap impasto
as a leverage loser.

---

## 5. Metal translation notes (respecting perf invariants)

The unified plan (`unified-brush-engine.md` §3.3–3.4) already sketches the GPU reservoir; here
is how Krita's specifics map, with the sacred perf invariants (`CanvasModule/CLAUDE.md` →
no `waitUntilCompleted`/`drawHierarchy` on the hot path; `.shared` textures; one flatten).

1. **Kill the per-dab `getBytes` (`CanvasRenderer.swift:585`).** It is a synchronous
   main-thread readback per stamp — the named anti-pattern. Replace pickup with a
   **bound-source `sample()`** of `belowTex`/`sabPrev` inside the dab fragment (plan §3.4),
   or a per-frame coalesced reservoir Pass A (plan §3.3). The plan already says "benchmark the
   coalesced CPU readback first" (`:146`) — do that before the full GPU reservoir.

2. **Smudge Radius → a small in-shader weighted average, not Halton.** Krita's Halton +
   convergence loop (`KisColorSmudgeSampleUtils.h`) is a *CPU cost-reduction* trick. On the
   GPU the cheap equivalent is a **fixed small mask-weighted tap kernel** (e.g. 3×3/5×5 or a
   mip-level fetch of `belowTex` sized by the radius value), weighted by the brush mask. We do
   **not** port the quasi-random sampler or the convergence early-out — they exist purely
   because Krita can't afford a full average on CPU. A GPU box/gaussian tap *is* the full
   average, cheaper. **[inferred from the algorithm's intent; verify visual parity offline.]**
   A radius driven by mip LOD of `belowTex` is essentially free.

3. **Smearing (directional drag) → read the displaced source.** Krita reads `srcRect`
   translated by the inter-dab vector (`kis_colorsmudgeop.cpp:192`). In Metal: in the dab
   fragment, sample `belowTex`/`sabPrev` at `texCoord − dabTravelVector` (a per-stroke or
   per-dab uniform). One extra `sample()`, no readback. This is the **missing axis** in the
   plan; add a `smearVector` uniform.

4. **KM stays verbatim.** `setupWetKMTables` (`CanvasRenderer.swift:491`) and the spectral loop
   move into Pass A / Pass B unchanged (plan `:142`). The 36-band loop is ~36×7 MACs per pixel
   — already shipped at framerate; fine inside one instanced pass. **Verify any refactor
   offline** against the current shader (`feedback_verify_shader_color_offline`) before device.

5. **Curve-driven Mix/Smear/colorRate.** Once the topic-02 curve+sensor layer exists, Mix and
   Smear become `KisCurveOption`-style LUT lookups resolved **CPU-side at stamp generation**
   and baked into `StampInstance` (plan §3.1, `:94` — keeps the fragment uniform-driven). The
   `colorRate²` squaring (`KisColorSmudgeStrategyBase.cpp:159`) is a one-line response-curve we
   can copy as the default Mix curve.

6. **Determinism trap (plan §3.4, `:185`).** Our current wet path is already non-deterministic
   in the sense that `wetLoad` evolves by frame-batched dabs; the plan's "replay through the
   identical batched pipeline + record dab-batch boundaries" applies directly. Krita sidesteps
   this entirely by **not carrying a load** (it re-samples each dab from a stable canvas), which
   is *why* Krita's smudge is replay-trivial. Our richer model pays for itself with this
   determinism cost — a real, acknowledged trade.

---

## 6. Open questions / risks

1. **"Drying" semantics.** Krita's interstroke buffer encodes "wet persists across strokes,
   drying = discard buffer" (`KisColorSmudgeInterstrokeData.h:18`). We reset `wetLoad` every
   stroke (`MetalCanvasView.swift:945`) → our paint always "dries" between strokes. Should a
   Krita-grade superset let the load persist across strokes (cross-stroke wet-on-wet)? It would
   be more capable, but **interacts badly with our img2img capture** (the layer is flattened &
   sent every 250ms — what is "still wet"?). **Open product question, not just technical.**

2. **Smudge-radius on a low-alpha canvas.** Krita's "restart with bigger radius if all masked
   out" (`KisColorSmudgeSampleUtils.h:60,214`) handles smudging into transparency. Our 1-px
   pickup already guards `s.alpha > 0.05` (`MetalCanvasView.swift:960`) and falls back to the
   carried load — arguably a *simpler, equivalent* behavior. A GPU radius average must decide
   the same: weight by alpha, fall back to load when the neighbourhood is empty. **Specify
   before building.**

3. **Single-layer assumption.** Overlay mode (§1.6) and `KisColorSmudgeSourceImage` assume a
   multi-layer image. We're effectively single-active-layer; overlay is moot until layers ship.
   Don't build it speculatively.

4. **Heightmap impasto leverage is unproven-negative, not measured.** §4 *argues* the model
   eats it; we have not A/B'd a thick-paint canvas through klein. If we ever want to test it,
   the cheap version is lightness-modulation (Krita's `modulateLightnessByGrayBrush`,
   `KisColorSmudgeStrategyLightness.cpp:190`) — not a normal-map pass. **[inferred leverage; not
   measured.]**

5. **The `0.8` dulling damp** (`KisColorSmudgeStrategyBase.cpp:164`) and the `colorRate²`
   (`:159`) are unexplained magic constants — likely hand-tuned for feel. If we copy the dulling
   path we should treat these as **tunable defaults**, not ported constants, and tune against
   our KM model (which has different perceptual behavior than Krita's linear smear).

6. **Smear vs our pickup are not the same operation.** Our `wetPickup` contaminates a *carried
   load* (a memory); Krita's smearing drags *displaced canvas pixels* with no memory. A
   superset wants **both** independently exposed (load-contamination *and* directional drag),
   which means the unified plan needs a third wet term beyond `pull`/`grade`. **Flag for the
   plan owner.**

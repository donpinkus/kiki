# 12 — Masking (Dual) Brush, Per-Dab Compositing, and Height/Lightness Brushes

Research topic: Krita's **masking brush** (a second brush tip that multiplies/masks the primary
dab — a capability Procreate lacks), the **per-paintop composite-op selection**, and the
**lightness/height-map brushes** (embossed strokes). Grounded in `~/krita_src`; our code cited as
`<path>:line`. Verified = I read the implementation; inferred = pattern-matched / from a comment.

---

## 1. How Krita does it

### 1.1 Masking brush — the data model (two brushes, one stroke)

The masking brush is **a complete second brush tip stapled onto any pixel-family paintop**. Its
config (`MaskingBrushData`) carries: `isEnabled`, an embedded `BrushData` (the full brush-tip
chooser — auto/predefined/text), a `compositeOpId`, and a size-coupling (`useMasterSize` +
`masterSizeCoeff`, so the mask tip can track the primary brush size or be independent). **Verified:**
`KisMaskingBrushOptionProperties.cpp:22-57` (`read`) and the `MaskingBrushModel` fields at
`KisMaskingBrushOption.cpp:60-115`. Default composite op is `COMPOSITE_MULT` (multiply) —
`KisMaskingBrushOptionProperties.cpp:27`.

Critically, **the option UI is titled "Brush Tip"** (`KisMaskingBrushOption.cpp:211`) and presents
a full `KisBrushSelectionWidget` plus a "Blending Mode" combo (`KisMaskingBrushOption.cpp:172-181`).
So the artist picks a *second* tip image and the blend math that fuses it into the primary stroke's
alpha.

### 1.2 The rendering pipeline — two devices, one fuse

The fusion happens in **`KisMaskingBrushRenderer`** (`libs/ui/tool/strokes/KisMaskingBrushRenderer.cpp`).
At stroke setup it allocates **two paint devices** (verified, `:26-30`):

- `m_strokeDevice` — same color space as the target layer; this is where the **primary brush paints
  its color**.
- `m_maskDevice` — an **8-bit GrayA** device; this is where the **masking brush tip paints its
  grayscale shape**.

The wiring lives in `kis_painter_based_stroke_strategy.cpp:319-332` (verified): when the preset
`needsMaskingBrushRendering()` and indirect (isolated-buffer) painting is active, it constructs the
renderer and calls `initPainters(strokeDevice, maskDevice, …)` — i.e. **two `KisPainter`s share one
stroke**, one writing color, one writing the mask. A safety assert enforces the hard dependency:
**"masked brush cannot work without indirect painting mode"** (`:315-317`, verified) — exactly Kiki's
isolated-SAB requirement; you cannot mask a stroke you've already flattened.

The actual fuse is `KisMaskingBrushRenderer::updateProjection(rc)` (verified, `:72-117`):

1. Copy the primary stroke's color from `m_strokeDevice` into the destination (`copyAreaOptimized`,
   `:76`).
2. Walk the dirty rect row-by-row, and for each contiguous run call
   `m_compositeOp->composite(maskData, …, dstData, …)` (`:106-108`).

The composite op writes **only into the destination's alpha channel** — note `dstRowStart +=
m_dstAlphaOffset` at `KisMaskingBrushCompositeOp.h:737` (verified). So **the masking brush never
touches color; it sculpts the alpha (coverage) of the primary stroke.** The grayscale mask value
becomes `src`, the existing stroke alpha becomes `dst`, and the per-pixel result replaces the alpha:
`*dstDataPtr = m_compositeFunction.apply(maskScaled, *dstDataPtr)` (`:751`).

For a GrayA mask, the mask value fed in is **gray × alpha pre-multiplied**:
`preprocessMask` returns `KoColorSpaceMaths<quint8>::multiply(pixel->gray, pixel->alpha)`
(`KisMaskingBrushCompositeOp.h:769-772`, verified). So a soft, semi-transparent mask tip both dims
*and* feathers the primary stroke's coverage.

### 1.3 The composite functions (the actual math)

`KisMaskingBrushCompositeOpFactory::supportedCompositeOpIds()` exposes exactly **10 modes** in the
UI (verified, `:247-262`): Multiply, Darken, Overlay, Color-Dodge, Color-Burn, Linear-Burn,
Linear-Dodge, Hard-Mix (Photoshop), Hard-Mix-Softer, Subtract. The math (verified, all in
`KisMaskingBrushCompositeOp.h`, operating on the alpha channel with `src`=mask, `dst`=stroke alpha):

| Mode | Function | Effect on stroke alpha |
|---|---|---|
| Multiply (`MULT`) | `cfMultiply(src,dst)` `:63` | mask darkens coverage; the classic "stencil" — grain/texture multiplied into the stroke |
| Darken | `cfDarkenOnly(src,dst)` `:101` | coverage = min; mask can only *remove* |
| Overlay | `CFOverlay::composeChannel` `:139` | mid-contrast boost of coverage |
| Color-Dodge | `colorDodgeAlpha` `:228` (clamped to [0,1], special-cased to avoid ÷0 — `:180-202`) | mask *brightens*/sharpens coverage edges |
| Color-Burn | `CFColorBurn` `:276` | mask deepens coverage |
| Linear-Dodge (add) | `min(src+dst, 1)` but **returns 0 if dst alpha already 0** (`:331-335`) | additive coverage; comment notes "don't resurrect dead pixels from ashes" |
| Linear-Burn | `max(0, src+dst-1)` (`:375-377`) | clamped so it can't *erase* below |
| Hard-Mix / Hard-Mix-Softer | `CFHardMixPhotoshop` / custom (`:421`, `:464-472`) | threshold/posterize coverage |
| Subtract | `max(0, dst-src)` (`:514-516`) | clamped to ≥0 — comment cites bug 424210 (negative alpha = artifacts) |

**Key verified detail:** every one of these is a **per-channel scalar function on the alpha channel
only**, applied via a tight CPU loop (`KisMaskingBrushCompositeOp.h:733-760`). It is *not* a
full-color compositor — the masking brush is a coverage/shape multiplier, not a color blend. That's
why it lives in a templated `<channel_type, composite_function, mask_is_alpha, use_strength,
use_soft_texturing>` class and runs at the same cost as a normal mask blit.

### 1.4 Per-paintop composite-op selection (different question, same registry)

Separately from the masking brush, **every pixel-family paintop has its own normal blend mode** for
how the *whole stroke* composites onto the layer below. That's `KisCompositeOpOptionData` (verified,
`KisCompositeOpOptionData.cpp:15-27`): two fields — `compositeOpId` (defaults to the registry's
default = Normal/`over`) and `eraserMode` (a bool). It reads/writes `"CompositeOp"` + `"EraserMode"`
to the flat preset config. The actual blend math comes from `KoCompositeOpRegistry` — Krita's
**full ~70-mode Photoshop-style blend library** (Multiply, Screen, Overlay, the HSL/HSY modes,
etc.). So a Krita brush preset bakes in *both* a per-stroke layer blend mode *and* (optionally) a
masking-brush sub-blend.

### 1.5 Lightness / height-map brushes (embossed strokes)

This is a third, distinct mechanism — **`enumBrushApplication`** on the brush tip itself
(`kis_brush.h:38-43`, verified): `ALPHAMASK`, `IMAGESTAMP`, `LIGHTNESSMAP`, `GRADIENTMAP`.

- **ALPHAMASK** — the tip's luminance is read as coverage; you paint flat color (our model).
- **IMAGESTAMP** — the tip's RGBA is stamped verbatim (a rubber stamp).
- **LIGHTNESSMAP** — the magic one. The tip image's **luminance modulates the lightness of your
  chosen paint color**, producing an embossed/textured stroke that still takes your color.

The lightness math is `fillGrayBrushWithColorPreserveLightnessRGB` (verified,
`KoColorSpacePreserveLightnessUtils.h:14-67`). The algorithm (Peter Schatz's, documented in the
source comment `:27-42`): fit a quadratic `f(x)=ax²+bx` such that `f(0)=0, f(1)=1, f(0.5)=z` where
`z` is the **lightness of your paint color**. Then for each tip pixel of mask-luminance `x` (scaled
by a `strength` knob around 0.5, `:50`), set the output pixel's HSL lightness to `f(x)` while
keeping your color's hue/saturation (`setLightness<HSLType>`, `:59`). Result: mid-gray tip pixels =
exactly your color; lighter tip pixels brighten toward white; darker ones darken toward black —
**a 3D-feeling, value-carrying stroke from a flat color pick.** `modulateLightnessByGrayBrushRGB`
(`:70-123`) is the in-place variant (modulates whatever's already on the layer — used by smudge's
Lightness strategy).

There's also a **Paint-Thickness option** in the color-smudge engine
(`KisPaintThicknessOptionData.h:18-28`, verified) with modes `OVERWRITE` / `OVERLAY` — it's a
`KisCurveOption` returning a size-like scalar (`KisPaintThicknessOption.cpp:23-27`) that drives "how
much paint height this dab lays down," feeding the lightness/height accumulation in the smudge
strategies. And the masking-brush composite factory has **four height-specific modes not exposed in
the standard 10** — `HEIGHT`, `LINEAR_HEIGHT`, `HEIGHT_PHOTOSHOP`, `LINEAR_HEIGHT_PHOTOSHOP`
(`KisMaskingBrushCompositeOp.h:37-40`, `:554-709`) — used internally with a `strength` and an
optional `use_soft_texturing` flag for the texture-option path, treating the mask as a heightmap
(`div(dst, invStrength) - src` style math, `:565-579`).

The **tangent-normal paintop** (`plugins/paintops/tangentnormal/`) is the extreme end: it converts
pen tilt/direction into an **RGB normal-map color** painted through the tip
(`kis_tangent_normal_paintop.cpp:78` `m_tangentTiltOption.apply(info,&r,&g,&b)`), so a stroke
literally paints a tangent-space normal map for later relighting. Pure PBR-authoring; noted for
completeness.

---

## 2. How Kiki does it today

| Capability | Kiki status | Cite |
|---|---|---|
| Second masking tip | **None.** One shape mask per stroke (`shapeID`). | `DrawingEngine.swift:107` |
| Per-paintop layer blend mode | **None.** Only source-over (dab→scratch→layer) + destination-out (eraser). | `CanvasRenderer.swift:183-184` (`makeBrushStampPSO eraser:false/true`) |
| Lightness/height-map tip | **Partial, accidental.** Textured PNG tips (chalk/charcoal/etc.) are read as **alpha masks only** — grayscale → coverage. We have no LIGHTNESSMAP equivalent that turns tip luminance into stroke *value*. | `BrushConfig.shapeID` + `_CONTEXT.md:60-61` |
| Wet color mixing | **Yes** — spectral KM (Mallett-Yuksel) + carried-load smear. This is *richer* than Krita's smudge in pigment fidelity but orthogonal to masking/compositing. | `_CONTEXT.md:55-58` |
| Isolated per-stroke buffer (the precondition Krita's masking brush needs) | **Yes** — scratch texture today; SAB in the unified plan. | `unified-brush-engine.md:17-20` |

The unified plan (`unified-brush-engine.md`) **already commits to two of the three building blocks**
but not the masking brush itself:

- §3.6/§4 (verified, `:189-219`): ship **3–4 curated value/hue blend modes** as **per-stroke
  pre-built PSOs** (one shared vertex+fragment, differing only in the color-attachment blend
  descriptor), selected once at `touchesBegan`. Reject the full ~70-mode matrix on leverage grounds.
- §4 grain row (`:218`): a **second bound `grainTex`** in the dab fragment whose depth **modulates
  coverage** — gated behind an "img2img-survival spike."
- The plan has **no masking-brush concept** and **no LIGHTNESSMAP concept**. The grain texture is
  the closest thing, but it's document/stamp-UV tiled noise multiplied into coverage, not a *second
  full brush tip with its own dynamics and its own blend mode*.

---

## 3. Gap analysis — what a Krita-grade superset adopts

Three distinct features here; they rank very differently for us.

### 3.1 Masking (dual) brush — **adopt a narrowed form; this is the headline gap**

This is the capability the task flags as "Procreate lacks." Procreate's grain/texture is a single
tiled source multiplied into coverage; Krita's masking brush is **a fully independent second brush
tip with its own size, its own shape, and its own choice of 10 blend functions, fused into the
primary stroke's alpha.** That is strictly more expressive: you can stroke a soft round primary and
multiply a hard noise tip into it (granulation), or Linear-Dodge a sparkle tip to punch holes of
*extra* coverage, etc.

**Verified architectural fit:** Krita's masking brush requires exactly what our unified plan already
mandates — an isolated per-stroke buffer (`kis_painter_based_stroke_strategy.cpp:315-317` asserts
"cannot work without indirect painting"). Our SAB *is* that buffer. So the masking brush is not a
new path; it is **one extra read-only texture (the mask tip's accumulated coverage) and one extra
blend term inside the single dab fragment.**

**The narrowing:** Krita generates the mask tip as a *second full stroke* through a *second
`KisPainter`* with full dynamics. That doubles the dab-gen work. For us, the high-leverage 80% is a
**static second tip image multiplied (or dodge/subtract'd) into coverage**, where the mask tip
shares the primary's size/position but has its own shape and its own blend function. That collapses
to: sample `shapeTex`, sample `maskTipTex`, combine via a `maskBlendMode` uniform, use the result as
coverage. No second dab pass.

### 3.2 Per-stroke layer blend mode — **already in the plan; this research confirms the curation**

Krita exposes ~70 modes via `KoCompositeOpRegistry`; the masking sub-brush exposes 10. Our plan's
"3–4 curated value/hue modes" (§3.6) is the right call and this research *strengthens* it: even
Krita's own masking-brush UI curates 70→10, and the 10 it keeps are overwhelmingly **coverage/value
operators** (Multiply, Darken, Dodge, Burn, the Linear pair, Subtract) — almost none are hue
operators. **Recommendation: our curated set should be Multiply, Linear-Dodge (Add)/Screen,
Overlay, and one Darken — the value operators klein actually "sees" — not the HSL hue modes.**

### 3.3 Lightness/height-map tip — **adopt; high img2img leverage, low cost**

LIGHTNESSMAP (`KoColorSpacePreserveLightnessUtils.h:44-65`) turns a flat color pick into a
value-carrying embossed stroke. **This is pure model-leverage** (see §4) and it's a *tiny* shader
change: instead of `coverage = tipLuma; color = brushColor`, do `coverage = tipAlpha; color =
setLightness(brushColor, quadratic(tipLuma, brushColorLightness))`. We already load grayscale PNG
tips; today we throw away everything but alpha. LIGHTNESSMAP *uses the luminance we discard.*

The four `HEIGHT*` composite modes and the tangent-normal paintop are **low/negative leverage**
(§4) — defer.

---

## 4. img2img leverage call

This is where the three features split hard.

- **Lightness/height-map tip → HIGH leverage.** klein consumes large-scale **value structure** and
  **edge hardness** (`_CONTEXT.md:28-30`). A LIGHTNESSMAP stroke injects exactly that: a single
  charcoal stroke stops being a flat gray smear and becomes a value-modulated, textured mass with
  internal light/dark structure the model reads as form and material. **This is arguably the single
  highest-leverage item in this entire topic** — it changes what the model sees, from one cheap
  shader edit, reusing tip art we already ship.
- **Masking (dual) brush → MEDIUM-HIGH leverage.** Multiplying a noise/grain tip into coverage
  produces **broken, granulated edges and stroke interiors** — coarse value/edge variation the model
  *does* see (vs. the fine paper tooth it resynthesizes, `_CONTEXT.md:30-31`). The leverage depends
  entirely on the mask tip's **spatial scale**: a coarse mask (big blotches) survives the JPEG +
  re-render; a fine mask (single-pixel speckle) is low-leverage decoration the model overwrites. So
  adopt it, but the *default* mask tips should be coarse. It is also strong **hand-feel** regardless
  — a masked stroke simply looks more like a real medium.
- **Per-stroke blend modes → MEDIUM leverage.** Multiply/Add/Overlay change value relationships
  between overlapping strokes, which the model sees. HSL hue modes are lower-leverage (klein
  re-derives hue from the prompt + structure). Confirms the value-mode curation in §3.2.
- **Tangent-normal / HEIGHT composite modes → LOW/negative.** These author PBR normal/height data
  for *relighting*; klein relights and resynthesizes micro-surface (`unified-brush-engine.md:308`).
  The JPEG carries no normal channel. **Reject for img2img.**

---

## 5. Metal translation notes (respecting perf invariants)

The whole topic fits inside the unified plan's **one dab fragment + per-stroke PSO** discipline. No
new pass, no hot-path `waitUntilCompleted`, no `getBytes`.

**Masking (dual) brush — one fragment, two tip samples:**
- Bind a second `maskTipTex` (R8, like our existing shape tip) alongside `shapeTex` in Pass B.
- Add a `maskBlendMode` uniform (small enum) to `BrushUniforms`.
- In the fragment, after computing primary `coverage = sample(shapeTex, …)`, compute
  `m = sample(maskTipTex, …)` and fuse: `coverage = maskBlend(m, coverage, mode)` where `maskBlend`
  is a tiny `switch` over Multiply/Add-clamped/Subtract-clamped/Dodge. **This is the verified Krita
  math** (`KisMaskingBrushCompositeOp.h`) but applied per-fragment to coverage instead of per-row to
  an alpha device. The clamps matter — port Krita's "don't erase below" guards verbatim
  (Linear-Burn `max(0,…)`, Subtract `max(0,…)`, `:375`,`:514`) or self-overlap can punch holes.
- A `switch` over 4 modes is acceptable in the fragment (it's value-uniform per stroke; the GPU
  takes one branch). If profiling shows divergence cost, promote to **per-stroke PSO specialization**
  exactly as §3.6 does for Glaze/Build-up — one fragment, N pre-built blend variants. The masking
  fuse, though, must be *inside* the shader (it's a coverage computation), not a color-attachment
  blend state, so the function-constant route is the right specialization knob, not the blend
  descriptor.
- The mask tip should share the primary's size/rotation transform by default (one extra UV in the
  vertex stage), with an optional independent-size coefficient mirroring Krita's `masterSizeCoeff`
  (`KisMaskingBrushOptionProperties.cpp:39-53`). **Do not** spawn a second dab pass to give the mask
  its own dynamics in v1 — that doubles dab-gen cost for marginal leverage.

**Lightness-map tip — same fragment, two-line change:**
- We already sample grayscale tips. Today: `coverage = tipLuma`. LIGHTNESSMAP:
  `coverage = tipAlpha; pigment = setLightness(brushColor, f(tipLuma))` where `f` is the verified
  quadratic `(1-(4z-1))·x² + (4z-1)·x` with `z = lightness(brushColor)`
  (`KoColorSpacePreserveLightnessUtils.h:41-52`).
- Needs RGB→HSL `getLightness`/`setLightness`. **Color-correctness landmine:** our textures are
  `.bgra8Unorm_srgb`, so the fragment sees **linear** values (`_CONTEXT.md:63`); Krita's lightness
  math runs in its working space (sRGB-encoded HSL via `HSLType`). Compute the lightness
  remap in the same space Krita does and verify offline against `KoColorSpacePreserveLightnessUtils`
  before any device test (per `feedback_verify_shader_color_offline`). Getting the gamma space wrong
  here will tint or wash strokes exactly like the bugs catalogued in the color CLAUDE.md.
- A `brushApplication` enum (ALPHAMASK default / LIGHTNESSMAP) on the descriptor selects it; at
  ALPHAMASK the branch collapses to today's behavior (the plan's non-regression discipline).

**What NOT to port:** Krita's row-wise CPU `composite()` loop (`KisMaskingBrushCompositeOp.h:733`)
and the second `KisPainter`/`KisMaskingBrushRenderer` device — those are CPU-architecture artifacts.
We do the same fusion per-fragment on the GPU for free. The two-device split is *their* way of
isolating mask-from-color; our SAB already isolates the whole stroke.

---

## 6. Open questions / risks

1. **Mask-tip determinism under live-preview vs. flatten.** If the mask tip ever gets its own
   scatter/jitter dynamics (Krita allows it), it must use the same `KisPerStrokeRandomSource`-style
   deterministic seed our replay needs (`unified-brush-engine.md:175` ping-pong determinism). v1
   static-mask avoids this; flag it before adding mask dynamics.
2. **Coverage-clamp interaction with Glaze.** The masking fuse modifies coverage *before* the
   Glaze coverage-saturating blend state (§3.6). Need to verify offline that a self-crossing masked
   stroke still saturates flat (the BLOCKING Glaze invariant, `unified-brush-engine.md:292`) — a
   Linear-Dodge mask that *adds* coverage could fight the cap. **Unverified; must test.**
3. **img2img survival of mask spatial scale is asserted, not measured.** §4's "coarse survives, fine
   doesn't" mirrors the grain-survival spike the plan already gates on (`:218`). Run the masking
   brush through *the same spike* — don't ship default mask tips until the JPEG-round-trip test
   confirms which scales the model keeps. (Consistent with `feedback_continuous_observability`:
   measure on the real pipeline, not by intuition.)
4. **HSL lightness in linear-sRGB textures.** Highest-confidence risk (see §5). The Schatz quadratic
   assumes a specific lightness space; our texture sampling delivers linear. Verified-offline-first
   is mandatory.
5. **Scope creep toward the full composite registry.** Krita's masking brush curates to 10, the
   full registry is ~70. Resist re-expanding; the value-operator subset (§3.2) is the leverage-justified
   set. The four `HEIGHT*` modes and tangent-normal are explicitly out (§4).

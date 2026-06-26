# Krita Brush Engine — Texture / Grain

*Research doc 07. Shared grounding: `_CONTEXT.md`. Citation discipline: `krita: path:line`
(relative to `~/krita_src`) vs our `file:line`; **verified** = read the code, **inferred** =
pattern-matched / from a comment.*

---

## 1. How Krita does it — grounded

Krita's "Texture" option is a **post-process pass on the already-rendered, already-colored dab**.
It is *not* part of the brush-tip mask, *not* part of the color source, and *not* applied at
composite-to-layer time. It runs inside `postProcessDab()`, right after the sharpness threshold and
before the dab is handed to the layer compositor (verified, `krita:
plugins/paintops/libpaintop/KisDabCacheUtils.cpp:93-104`):

```cpp
void postProcessDab(KisFixedPaintDeviceSP dab, const QPoint &dabTopLeft,
                    const KisPaintInformation& info, DabRenderingResources *resources) {
    if (resources->sharpnessOption) resources->sharpnessOption->applyThreshold(dab, info);
    if (resources->textureOption)   resources->textureOption->apply(dab, dabTopLeft, info);
}
```

The key architectural fact: `dabTopLeft` is the dab's **position on the image (document space)**
(verified, the doc comment on `apply` says "offset … used to calculate the position of the mask
pattern", `krita: plugins/paintops/libpaintop/kis_texture_option.h:41-47`). So the texture is a
**tiled, document-anchored field**, and each dab samples the slice of that field under its current
footprint — paint twice over the same spot and the same paper grain shows through. This is
"texturized" / paper behavior. (Krita's *other* mode — grain that moves *with* the stamp — is not
in this option; it lives in the brush-tip/auto-brush, out of scope here.)

### 1a. Building the mask (once, cached)

The pattern (`KoPattern`, a loaded image) is converted to a single-channel mask in
`recalculateMask()` (verified, `krita: plugins/paintops/libpaintop/KisTextureMaskInfo.cpp:139-244`).
The per-pixel pipeline is, in order:

| Step | Math | Cite |
|---|---|---|
| **Grayscale** | `gray = (R*11 + G*16 + B*5) / 32` (luma-ish, weights ≈ 0.34/0.5/0.16) | `:189` |
| **Alpha flatten** | `m = (gray/255)*alpha + (1-alpha)` — unpainted pattern pixels read as **white (1.0)** | `:190` |
| **Brightness** | `m = m - brightness` (additive shift, `brightness∈[-1,1]`, default 0) | `:192` |
| **Contrast** | `m = (m-0.5)*contrast + 0.5` (pivot at 0.5; default 1.0) then clamp [0,1] | `:194-197` |
| **Invert** | `m = 1-m` (optionally XOR'd with auto-invert-on-erase) | `:199-201, 131` |
| **Neutral point** | piecewise-linear rescale around `neutralPoint` (default 0.5) into two linear segments to "prevent loss of detail (clipping)" | `:205-213` |
| **Cutoff** | if `cutoffPolicy==1`: pixels with value outside `[cutoffLeft,cutoffRight]/255` → fully **transparent**; `==2` → fully **opaque**; `==0` → off | `:215-226` |

The neutral-point remap (verified, `:209-213`): for `m ≤ neutralPoint`, `m' = m/(2·neutralPoint)`;
else `m' = 0.5 + (m-neutralPoint)/(2-2·neutralPoint)`. It re-centers the midtone of the grain so
"neutral" texture pixels land at 0.5 regardless of the source pattern's average value — i.e. it lets
you say "this gray level is the no-effect level."

The mask is computed **once per (pattern, scale, brightness, contrast, neutralPoint, invert,
cutoff)** tuple and globally cached (`KisTextureMaskInfoCache`, verified, `:254-273`) — separate
cache slots for main vs LOD-preview. Scale is applied here by resampling the pattern image
(`:162-168`); it is *not* a per-dab UV scale. So `scale` changes the cached mask, while
`offset`/`randomOffset` are applied per-dab at sample time (below).

### 1b. Per-dab application — three code paths

`apply()` (verified, `krita: plugins/paintops/libpaintop/kis_texture_option.cpp:280-397`) computes
the tiled sample window: `x = offset.x() % maskWidth - effectiveOffsetX(info)`, same for y
(`:301-302`). `effectiveOffsetX` returns the fixed `offsetX`, **or** a per-stroke deterministic
random offset when `isRandomOffsetX` is set, drawn from `info.perStrokeRandomSource()` (verified,
`:115-129`) — so "random offset" decorrelates the grain phase per stroke but stays stable *within*
a stroke. It then dispatches on `texturingMode`:

1. **LIGHTNESS** (`applyLightness`, `:191-222`) — for lightness brushes (color comes from the tip's
   luminance). Calls `fillGrayBrushWithColorAndLightnessWithStrength(...)`, mixing the grain into the
   dab's *lightness* rather than its alpha. Preserves alpha.
2. **GRADIENT** (`applyGradient`, `:224-278`) — remaps the grain value through the active gradient
   (`cachedAt(gradientvalue)`), so the texture drives *color* lookups, blended by `strength` and the
   pattern's own alpha. Preserves alpha.
3. **Everything else** (`:294-397`) — the common case: the grain modulates the dab's **alpha
   channel** via a `KisMaskingBrushCompositeOp`. The enum (verified, `KisTextureOptionData.h:29-46`):

   `MULTIPLY, SUBTRACT, DARKEN, OVERLAY, COLOR_DODGE, COLOR_BURN, LINEAR_DODGE, LINEAR_BURN,
   HARD_MIX_PHOTOSHOP, HARD_MIX_SOFTER_PHOTOSHOP, HEIGHT, LINEAR_HEIGHT, HEIGHT_PHOTOSHOP,
   LINEAR_HEIGHT_PHOTOSHOP` (+ LIGHTNESS, GRADIENT handled above).

   These map to composite-op IDs (`:335-351`) and are realized as templated per-channel functions
   over the **alpha** channel (verified, `krita:
   libs/ui/tool/strokes/KisMaskingBrushCompositeOp.h:25-41` enum, `:733-760` the inner loop). The op
   reads the grain pixel as `src`, the dab alpha as `dst`, writes `dst = f(src·, dst·)`.

### 1c. Strength — and what "strength" actually does

`strength = m_strengthOption.apply(info)` (verified, `kis_texture_option.cpp:312`).
`KisStrengthOption` is a **full `KisCurveOption`** (verified, typedef `krita:
plugins/paintops/libpaintop/KisStandardOptions.h:50`; data `KisStandardOptionData.h:113-119`) — i.e.
the texture depth is **sensor-driven**: pressure → strength, speed → strength, fade → strength, etc.,
run through the same 256-entry curve LUT as every other Krita dynamic. *This is the single most
important thing Kiki is missing* (see §3).

How strength enters the math depends on `useSoftTexturing` (verified,
`KisMaskingBrushCompositeOp.h`):

- **Hard texturing** (`use_soft_texturing=false`, the classic mode): strength scales the **dst (dab
  alpha)** before compositing. For MULTIPLY: `f = mul(src, dst)` but with strength applied as
  `inv(strength)` to weaken the grain's bite — actually the strength variant pre-blends src toward 1
  via `unionShapeOpacity(src, invertedStrength)` (verified, MULT-true-false `:73-77` vs
  MULT-true-true `:90-93`). Net effect: `strength=0` ⇒ grain disappears (dab passes through
  untouched); `strength=1` ⇒ full grain bite.
- **Soft texturing** (`use_soft_texturing=true`): strength scales the **src (grain)** instead, a
  perceptually gentler ramp. Selected per-op via the `if constexpr (use_soft_texturing)` branches
  (e.g. DODGE `:240-244`, LINEAR_DODGE `:351-357`).

The **HEIGHT** family (verified, `:554-709`) is special and only exists in the strength path: it
treats the grain as a **height map** and the strength as a "water level." `HEIGHT`:
`div(dst, invStrength) - (src + invStrength)` clamped — i.e. raise the dab alpha by 1/(1-strength)
then carve out the grain heights, so low-lying grain valleys go transparent first as you press
harder. `LINEAR_HEIGHT` takes `max(multiply, height)` of the two formulations. The `_PHOTOSHOP`
variants scale by `weight = 9..10 × strength` to match PS's curve. This is how Krita gets *dry-media
build-up* — pencil/charcoal that fills paper tooth valley-by-valley with pressure — out of a static
grain image. (Verified the `0.99 * strength` guard at `:561,589` that avoids a divide-by-zero at
strength=1.)

### 1d. Summary of the data model (verified, `KisTextureOptionData.h:71-90`)

`textureData` (embedded/linked pattern), `isEnabled`, `scale`, `brightness`, `contrast`,
`neutralPoint`, `offsetX/Y`, `isRandomOffsetX/Y`, `texturingMode`, `useSoftTexturing`,
`cutOffPolicy/Left/Right`, `invert`, `autoInvertOnErase`. Plus the separate **Strength curve
option** (`Texture/Strength/`). Note the `equality_comparable` operator (`:48-69`) is what feeds the
dab cache's `params.compare()` validity check — change any texture param and the dab cache
invalidates.

---

## 2. How Kiki does it today

**Kiki has no grain/paper stage at all.** Verified by absence: the only texture-like assets are
**brush-tip shape stamps**, not a tiled surface field.

- The brush tip is either a procedural soft circle `(1-r²)²` (64×64 R8, generated once) or a
  grayscale PNG stamp from `BrushShapeCatalog` (chalk/charcoal/drybrush/pastel/spray) — verified by
  the engine comments `CanvasRenderer.swift:15` ("Brush mask texture: soft-circle (quadratic
  falloff)") and `:104` ("Loaded grayscale stamp textures keyed by `BrushShapeDescriptor.id`"),
  loaded at `:222`.
- That stamp **is the dab mask** and **travels with the dab** (it is the quad's texture, oriented to
  stroke direction per `_CONTEXT.md:60-61`). It is *stamp-space*, not document-space. There is no
  second, position-anchored texture multiplied in. So Kiki today has Krita's *brush-tip* texturing
  but **none** of Krita's *paper/grain* texturing — the thing that makes the same spot show the same
  tooth no matter how the brush passes over it.
- `BrushConfig` (`ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:63`, per
  `_CONTEXT.md:43-49`) has **no** `grain*` fields, no texture strength, no neutral-point/cutoff.
- Dynamics: Kiki has exactly **one** scalar curve in the whole engine — `pressureGamma`
  (pressure→width). There is no sensor→strength curve of any kind, so even if we add a grain texture,
  "press harder, more tooth fills" (Krita's HEIGHT mode) is not expressible without first building a
  curve+sensor layer (the gap doc 00/04 covers; this topic depends on it).

**The committed plan already anticipates grain** (verified, `unified-brush-engine.md`):
`BrushDescriptor.grain { grainRef, behavior(moving|texturized), movement, scale, zoom, depth,
jitters, blend, brightness/contrast }` (`:63`); `grainTex r8Unorm mip … app` lifetime (`:119`);
the dab fragment does `base *= mix(1.0, sample(grainTex, grainUV).r, grainDepth)` (`:155`); grain UV
mode is `behavior` selecting stamp-space (moving) vs **document-space** (texturized) via the
`canvasPos` the vertex shader already computes (`:173`). Crucially it is **gated on an img2img-survival
spike** (`:218`, `:296-297`) — the plan explicitly flags grain as lower-leverage and refuses to build
the asset pipeline until a spike proves the grain survives klein.

---

## 3. Gap analysis — what a Krita-grade superset adopts

| Capability | Krita | Kiki today | Plan | Superset verdict |
|---|---|---|---|---|
| Tiled document-anchored grain field | yes (`dabTopLeft` % maskBounds) | **none** | designed (`:173`) | **adopt** — this is the core of "paper" |
| Texturing modes | 16 (mult/subtract/darken/overlay/dodge/burn/linear·/hard-mix/4×height) | n/a | one (`base *= mix(…)` = MULTIPLY only) | **adopt a curated 3–4**: MULTIPLY, SUBTRACT, and the **HEIGHT** family (the dry-media one) |
| **Strength as a sensor curve** | yes (`KisCurveOption`) | **none** (no curve layer) | `depth` + `jitters` (scalar) | **adopt curve** — depends on the sensor/curve layer (doc 04); without it, HEIGHT-mode build-up is impossible |
| HEIGHT mode (pressure carves tooth) | yes (`:554-709`) | n/a | not called out | **adopt** — the single highest-value texture behavior for pencil/charcoal feel |
| neutralPoint / contrast / brightness | yes | n/a | brightness/contrast yes; neutralPoint no | adopt brightness/contrast; **neutralPoint optional** (nice for asset authoring, low runtime value) |
| cutoff (mask-out dab where grain extreme) | yes (3 policies) | n/a | no | **defer** — niche; reproducible via contrast+invert |
| randomOffset per-stroke | yes (deterministic per-stroke RNG) | n/a | `jitters` | adopt — cheap, kills tiling repetition |
| soft vs hard texturing | yes (`if constexpr`) | n/a | no | adopt as `grainBlend`-ish toggle; trivial in shader |

**The portable wins, ranked:**
1. **Document-space tiled grain with a HEIGHT-style pressure response.** This is the one thing that
   makes a mark look like *media on paper* rather than *flat ink*. Krita gets it from a static grain
   PNG + the HEIGHT composite op + a pressure→strength curve. The plan has the texture and the UV
   mode but does **not** mention HEIGHT or a strength curve — it does plain MULTIPLY. *Krita teaches
   the plan that MULTIPLY alone is not enough: dry-media tooth needs the height/water-level math.*
2. **Strength must be a curve, not a scalar `depth`.** Krita's whole texture expressiveness comes
   from `strength = curve(sensor)`. The plan's `depth` (`:218`) is a scalar; that reproduces a fixed
   grain veil but not "lighter pressure shows more paper." This couples the grain stage to the
   sensor/curve layer — they cannot be shipped independently if we want Krita parity.
3. **The cache discipline.** Krita rebuilds the grain mask *only* when a texture param changes and
   keys it globally. Our `grainTex` is a static app-lifetime texture (`:119`) so scale/brightness/
   contrast must be applied **in the shader at sample time** (we can't afford Krita's
   resample-the-pattern approach per change). That's fine and cheaper, but note the divergence: Krita
   bakes scale/contrast/neutralPoint into the mask; we'd push them to uniforms.

---

## 4. img2img leverage call

> **UPDATE (Donald, 2026-06-20): grain is CONFIRMED to survive the img2img interpretation.** The
> coarse-value-grain-survives / fine-tooth-resynthesized boundary this section predicted is now an
> *observation*, not an inference. Consequence: grain is a **committed phase, not a spike-gated
> experiment** (PLAN.md §2.7/§P8). The open question is no longer "does it survive" but "tune the grain
> *scale* toward the coarse/structural band klein honors." Build HEIGHT-mode coarse value-grain; still
> skip the fine paper-tooth asset pipeline (that half genuinely is resynthesized). The §4 analysis below
> stands — only the "keep the gate" verdict is superseded.

**This was rated the lowest-leverage topic in the brush study, with one sharp exception — the coarse
value-grain band — which has now been confirmed to survive (see update above).**

- **Fine paper tooth / micro-grain → LOW leverage.** klein re-reads a flattened JPEG at ~1024² every
  ~250ms and resynthesizes surface micro-detail from the style prompt. Sub-stroke grain frequency is
  exactly the "fine grain / paper tooth" the model discards (`_CONTEXT.md:30-31`). Building a
  high-res paper-tooth asset pipeline to feed klein is largely wasted bits — *for the output*.
- **Coarse value-grain → MEDIUM leverage, and it survives.** The part of grain that changes the
  dab's **coverage at a scale klein can see** — i.e. broken/scumbled strokes where whole patches of
  the mark drop to zero alpha (charcoal skipping over tooth, dry-brush gaps) — is *value structure*,
  which is high-leverage (`_CONTEXT.md:28-29`). This is precisely what Krita's **HEIGHT mode at low
  strength + high contrast** produces: not a fine veil, but large, irregular voids. **That coarse
  value-grain survives img2img; fine tooth does not.** This is the survival boundary the plan's spike
  must measure, and it directly gates *which* texturing mode we build: HEIGHT (coarse, structural)
  over MULTIPLY (fine veil).
- **Hand-feel → real regardless of output.** Even where the model eats the grain, the *artist sees
  it on the Kiki canvas while drawing*. A pencil that visibly catches on paper feels pro even if
  klein flattens it. So grain has nonzero hand-feel value — but it's a "feel" win, not a "what klein
  sees" win, so it ranks below wet/taper/stabilization.

**Verdict (updated 2026-06-20):** grain survives — **build HEIGHT-mode coarse value-grain as a
committed phase.** Tune grain *scale* toward the coarse/structural band (large irregular voids,
dry-brush gaps), away from sub-pixel veil. Still skip the high-res paper-tooth asset pipeline (the fine
half is resynthesized). Priority: a real MED-HIGH-leverage feature now, sequenced after the keystone
(P1) it reuses the strength `CurveOption` from — no longer behind wet-mix/taper purely on leverage.

---

## 5. Metal translation notes (respecting perf invariants)

Krita does all of §1 on CPU, per-dab, with a cached mask. Our translation is a **single fragment
texture sample inside the existing dab pass** — strictly cheaper, and it must touch none of the
sacred invariants (no `drawHierarchy`, no hot-path `waitUntilCompleted`, `.shared` textures).

- **One static `grainTex`** (`r8Unorm`, mipped, tileable), app-lifetime (matches plan `:119`). No
  per-change resample — `scale`/`brightness`/`contrast`/`neutralPoint`/`invert`/`soft` are
  **uniforms applied at sample time** in the fragment, diverging from Krita's bake-into-mask (cheaper
  for us; see §3 note 3). Mips give us free `scale` quality and anti-alias on minification.
- **Document-space vs stamp-space UV — the load-bearing decision.** This mirrors Krita's
  `dabTopLeft % maskBounds` exactly:
  - **Texturized (paper):** `grainUV = canvasPos * grainScale + grainOffset`, where `canvasPos` is
    the **fixed 2048² document coordinate** the vertex shader already computes (plan `:173`). Because
    it's keyed to the document, it is invariant under the display's pan/zoom/rotate (the container
    transforms the *display*, not the document — `_CONTEXT.md` / the Document-resolution invariant).
    **This is the Krita-equivalent and the one to build.** *Open risk: the plan flags "verify
    texturized-grain stability under pan/zoom/rotate" as an explicit open item (`:296`) — do not
    promise paper-grain parity until this is confirmed on device.*
  - **Moving (stamp-locked):** `grainUV = stampLocalUV` — grain rides the dab. Cheaper, but it is
    *not* what "paper" means and largely a different feature (closer to a textured tip, which we
    already have). Lower priority.
- **HEIGHT mode in MSL.** Krita's height formula is `clamp(dst/(1-s) - (src + (1-s)), 0, 1)`
  (verified `KisMaskingBrushCompositeOp.h:565-578`). Translating: `dst` = the dab's coverage at this
  fragment (`base`), `src` = `sample(grainTex, grainUV).r`, `s` = the resolved strength. One `clamp`,
  two muls, two adds — negligible. The `_PHOTOSHOP` `weight = 9..10·s` variants are tuning curves; we
  pick **one** (likely plain LINEAR_HEIGHT) rather than porting all four. Selected by
  `switch grainMode` (data-driven, plan §2: not a feature branch).
- **Strength curve.** Resolved **CPU-side per stamp** in `generateStampsForStroke` (the plan bakes
  all per-stamp dynamics into `StampInstance`, `:94`) and passed as a per-stamp float — this keeps
  the fragment uniform/attribute-driven and avoids sampling a curve LUT in the shader. Requires the
  sensor/curve layer to exist first (doc 04 dependency).
- **`hasGrain` binding guard, not a feature flag.** With `hasGrain==0` the grain term is `1.0`
  (identity) — exactly the plan's `:97` design and the non-regression property: a plain pen is
  `grainDepth=0`.
- **Cost:** +1 texture sample + ~5 ALU ops per fragment in Pass B. At 2048² with adaptive spacing
  this is well inside the <8ms/frame budget. No new pass, no new `waitUntilCompleted`.

---

## 6. Open questions / risks

1. **Survival spike framing (gating).** The plan gates grain on "img2img survival" but as a binary.
   §4 argues the real question is *which mode* survives: **HEIGHT coarse value-grain (likely
   survives) vs MULTIPLY fine veil (likely resynthesized).** Reframe the spike accordingly before
   committing asset work. *Inference, not measured.*
2. **Texturized-grain stability under display transform.** Plan's explicit open item (`:296`). The
   document-space UV *should* make it invariant, but this is unverified on device. Do not promise
   paper parity until confirmed.
3. **Strength-curve dependency.** Grain-with-pressure-response is *blocked* on the sensor/curve layer
   (doc 04). Shipping grain with only a scalar `depth` gives a static veil, not Krita's dry-media
   build-up — a real but lesser feature. Sequence accordingly: curve layer → then HEIGHT grain.
4. **Mode count.** Krita ships 16 texturing modes; most are blend-mode completeness for non-img2img
   workflows. For Kiki a curated **MULTIPLY + SUBTRACT + LINEAR_HEIGHT** likely covers the
   expressive range. *Inferred from the leverage frame; verify by trying HEIGHT vs MULTIPLY in the
   spike.*
5. **Bake-vs-uniform divergence from Krita.** We push scale/contrast/neutralPoint to shader uniforms
   instead of baking into a recalculated mask (§3 note 3, §5). Functionally equivalent at default
   sampling, but mip selection under extreme `scale` may differ subtly from Krita's
   `SmoothTransformation` resample. Low risk; flag only if asset authors A/B against Krita.
6. **neutralPoint / cutoff worth it?** Both are authoring conveniences with low runtime leverage
   under img2img. Recommend deferring both; reproducible via brightness/contrast/invert at asset-prep
   time.

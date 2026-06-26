# Brush Tips — Procedural Mask Generators & Predefined Brushes

Research doc 05 of the Krita brush deep-dive. Scope: **brush tip generation** — the procedural
mask math (circle/rect, soft/gauss/curve, fade, AA, spikes, density) and the predefined-brush
system (GBR / GIH / PNG / ABR, color-vs-mask, scaling/mipmap). Grounded in `~/krita_src`; cites are
`krita: <path>:<line>`. **Verified** = I read the code; **inferred** = pattern-matched or from a
comment. When a comment and code disagreed, code wins (flagged inline).

---

## 1. How Krita does it

Krita's tip system has **two completely separate families** that both produce a per-dab alpha mask
(a `KisFixedPaintDevice`): **auto brushes** (procedural mask generators) and **predefined brushes**
(loaded image resources, scaled through a mipmap pyramid). A third, **text brushes**, is a thin
wrapper that rasterizes glyphs into the predefined path. The dab consumer (`KisBrushOp`) doesn't
care which produced the mask.

### 1.1 The mask-generator class tree

`KisMaskGenerator` is the abstract base (`krita: libs/image/kis_base_mask_generator.h:33`). It owns
the **shape-independent geometry**: `diameter`, `ratio` (aspect), `horizontalFade`/`verticalFade`,
`spikes`, `antialiasEdges`, `softness`, `scaleX/scaleY`, and a `type ∈ {CIRCLE, RECTANGLE}`
(`:36`). The single virtual that subclasses must implement is:

```cpp
virtual quint8 valueAt(qreal x, qreal y) const = 0;   // krita: kis_base_mask_generator.h:67
```

**Value convention (verified, and counter-intuitive):** `valueAt` returns **0 = fully painted
(opaque center)** and **255 = fully transparent (outside)**. The scalar applicator inverts it:
`alphaValue = (OPACITY_OPAQUE_U8 - value) * random`
(`krita: libs/image/kis_brush_mask_scalar_applicator.h:65`). So inside the generators, "value" is
*coverage-complement*. Keep this in mind reading the math below — `nf < 1.0 ⇒ return 0` means "this
pixel is solidly inside the core."

The concrete generators (`krita: libs/image/kis_mask_generator.h:10-17`):

| Generator | Shape | Falloff law | `KoID` |
|---|---|---|---|
| `KisCircleMaskGenerator` | circle/ellipse | rational fade ("Default") | `default` |
| `KisRectangleMaskGenerator` | rect | per-axis rational fade | `default` |
| `KisCurveCircleMaskGenerator` | circle | **user curve LUT** ("Soft") | `soft` |
| `KisCurveRectangleMaskGenerator` | rect | separable curve LUT | `soft` |
| `KisGaussCircleMaskGenerator` | circle | true Gaussian (`erf`) | `gauss` |
| `KisGaussRectangleMaskGenerator` | rect | separable Gaussian | `gauss` |

So the UI's three "Default / Soft / Gaussian" tip types × two shapes = these six. **Our `(1-r²)²` is
none of them** — it's a fixed quadratic, closest in spirit to the Default-circle but with a
different, non-parameterized law (see §3).

### 1.2 The Default circle — rational fade (verified)

`krita: libs/image/kis_circle_mask_generator.cpp:71-92`:

```cpp
qreal n  = norme(xr*xcoef, yr*ycoef);            // squared, normalized radius (1.0 at edge)
if (n > 1.0) return 255;                          // outside → transparent
qreal nf = norme(xr*transformedFadeX, yr*transformedFadeY);  // fade-scaled radius²
if (nf < 1.0) return 0;                           // inside fade core → fully opaque
return 255 * n * (nf - 1.0) / (nf - n);           // the falloff band
```

`norme(a,b) = a*a + b*b` (it's *squared* distance — verified, that's why `xcoef = 2.0/width`, not a
sqrt anywhere). The key insight: there are **two** radii — `n` (the hard edge at the diameter) and
`nf` (a fade radius scaled by `xfadecoef = 2.0/(horizontalFade*width)` and by `safeSoftnessCoeff =
1/max(0.01, softness)`, `krita: kis_circle_mask_generator.cpp:51-53,97`). The region `nf < 1` is the
solid core; between `nf=1` and `n=1` is a **rational (not polynomial) falloff** `n·(nf-1)/(nf-n)`.
**This is the crucial difference from ours:** the softness of the edge is set by the *ratio of the
fade radius to the hard radius*, both independently controllable, and additionally per-axis
(`horizontalFade ≠ verticalFade` gives an asymmetric feather). Our single quadratic has none of
these knobs.

`setSoftness(s)` recomputes `safeSoftnessCoeff = 1/max(0.01,s)` and folds it into the fade coeffs
(`:97-100`) — so "softness" *scales the fade radius outward*, pushing the feather start inward.

### 1.3 The Soft (curve) circle — arbitrary user falloff (verified)

This is the real power move. `KisCurveCircleMaskGenerator` replaces the analytic falloff with a
**256-ish-entry LUT sampled from a user-editable cubic curve**:

```cpp
d->curveResolution = qRound(qMax(width,height) * OVERSAMPLING);  // OVERSAMPLING=4
d->curveData = curve.floatTransfer(d->curveResolution + 2);      // bake curve → LUT
// krita: kis_curve_circle_mask_generator.cpp:26-27
```

Then per-pixel (`:76-105`):
```cpp
qreal dist = norme(xr*xcoef, yr*ycoef);          // normalized radius² in [0,1]
// linear-interpolate the LUT at dist*curveResolution
qreal alpha = lerp(curveData[i], curveData[i+1], frac);
return (1.0 - alpha) * 255;                        // invert to value-convention
```

So **the entire radial profile is a freehand curve** — the artist draws how opacity falls from
center to edge. The procedural circle is just one curve shape; you can make a ring, a hard-soft-hard
profile, etc. `setSoftness` *multiplies the curve's interior Y-values by `softness`*
(`transformCurveForSoftness`, `krita: kis_curve_circle_mask_generator.cpp:124-147`) — softness here
literally scales the whole falloff curve down, and for a 2-point curve it inserts a midpoint to bend
it. This is a far richer "softness" than a single gamma.

### 1.4 The Gaussian circle — `erf` blur (verified)

`krita: libs/image/kis_gauss_circle_mask_generator.cpp`. The mask is the integral of a Gaussian:

```cpp
d->fade   = 1.0 - (fh+fv)/2.0;                                  // :37
d->center = (2.5*(6761.0*fade - 10000.0)) / (M_SQRT_2*6761.0*fade);  // :42
d->alphafactor = 255.0 / (2.0*erf(center));                    // :43
// per-pixel:
dist *= distfactor;
ret = alphafactor * (erf(dist+center) - erf(dist-center));     // :77
return 255 - ret;
```

The `erf(d+c) - erf(d-c)` form is the **convolution of a hard disc with a Gaussian** (a "box blurred
by a Gaussian" → a smooth-shouldered bump), which is *the* physically-correct soft round tip — no
sharp core, no hard edge, just a bell. The magic constants (`6761`, `10000`, `2.5`) are an empirical
fit so that the `fade` slider maps intuitively to blur radius (inferred from the comment-free
constants + the `1e-6` clamps at `:39-40` guarding `fade∈{0,1}` singularities; **not independently
derived**).

### 1.5 Rectangles & the separable trick (verified)

`KisRectangleMaskGenerator` (`krita: kis_rect_mask_generator.cpp:90-127`) computes the *same rational
fade independently on X and Y* then combines: it takes `fxnorm`/`fynorm` per axis and returns the
larger where each axis is in its fade band (`:113-126`). `KisCurveRectangleMaskGenerator` is cleaner
— it's **fully separable**: `blend = curve(s)·(1-curve(1-s))·curve(t)·(1-curve(1-t))`
(`krita: kis_curve_rect_mask_generator.cpp:76-77`), i.e. the 2D mask is the outer product of a 1D
curve profile on each axis. Rect tips matter for calligraphy/marker brushes (a chisel nib).

### 1.6 Spikes — N-fold rotational symmetry (verified)

`fixRotation` (`krita: kis_base_mask_generator.cpp:306-321`) implements "spikes" (star/flower tips):
if `spikes > 2`, it rotates the sample point by `2π/spikes` repeatedly until the angle falls within
one wedge, so the base shape is mirrored N-fold. Cheap, runs per-pixel inside `valueAt`. This is a
whole tip-family (asterisk/sparkle/grass brushes) we have no analog for.

### 1.7 Antialiasing — the 1D/2D fade maker (verified)

The edge AA is **not** supersampling (that's separate, §1.8). It's a dedicated 1-pixel-wide linear
ramp at the boundary, `KisAntialiasingFadeMaker1D/2D` (`krita: libs/image/kis_antialiasing_fade_maker.h`).
`setRadius` sets `antialiasingFadeStart = radius - 1.0` and a coefficient that linearly ramps the
last device pixel from the base value to 255 (`:52-59`). `needFade(dist, &value)` short-circuits:
outside radius → 255, inside the last pixel → interpolate, else fall through to the real falloff
(`:61-78`). The curve & gauss generators delegate their edge to this; the analytic circle/rect bake
AA differently — they add `+1.0` to the coordinate before the fade calc (`kis_circle_mask_generator.cpp:82-85`,
comment: *"we add +1.0 to ensure correct antialiasing on the border"*) so the falloff naturally
ramps over the boundary pixel.

### 1.8 Supersampling — for tiny dabs only (verified)

`shouldSupersample()` returns true only when `antialiasEdges && (width<10 || height<10)`
(`krita: kis_base_mask_generator.cpp:118-120`) — i.e. **small brushes oversample, large ones don't**
(large brushes get enough natural AA from the 1px fade ramp). The applicator then does 3×3 or 6×6
box supersampling per output pixel (6×6 for *very* small, "to smooth out dashed strokes",
`krita: kis_brush_mask_scalar_applicator.h:39-59`). This is `OVERSAMPLING=4` for the curve LUT
resolution too. **Lesson:** tip quality at small radii needs explicit oversampling; our 64×64 fixed
mask + linear sampling gets this "for free" from GPU bilinear only down to a point.

### 1.9 Density & randomness — the dab-level dither (verified)

Two more auto-brush params applied in the applicator (`krita: kis_brush_mask_scalar_applicator.h:61-75`):
- **randomness**: `random = (1-r) + r·rand()`; multiplies each pixel's alpha — adds per-pixel noise
  to the whole mask (grainy tip).
- **density**: for each *visible* mask pixel, with probability `1-density`, zero it out
  (`if (!(density >= rand())) alpha = 0`). This is a **stochastic erosion** — density < 1 makes the
  tip a random dot-screen, the basis of spray/stipple looks. RNG is `KisRandomSource` (`:90`), with a
  `TODO: make it more deterministic for LoD` — note Krita itself flags non-determinism here (relevant
  to our replay-determinism concern from doc context, but out of this doc's scope).

### 1.10 Predefined brushes — GBR / GIH / PNG / ABR

The other family. `KisBrushServerProvider` is a flat `KoResourceServer<KisBrush>`
(`krita: libs/brush/KisBrushServerProvider.cpp:21-23`) — all predefined tips, regardless of file
format, are `KisBrush` subclasses served from one registry. The format-specific loaders:

| File | Class | What it is |
|---|---|---|
| `.gbr` | `KisGbrBrush` (`kis_gbr_brush.cpp`) | GIMP single brush — one mask **or** one RGBA image |
| `.gih` | `KisImagePipeBrush` (`kis_imagepipe_brush.cpp`) | GIMP **animated/pipe** brush — a *stack* of GBR frames + a selection "parasite" |
| `.png` | `KisPngBrush` (`kis_png_brush.cpp`) | PNG → grayscale mask or color stamp |
| `.abr` | `KisAbrBrush` (`kis_abr_brush.cpp`) | Photoshop brush collection (multiple brushes per file) |
| (glyphs) | `KisTextBrush` (`kis_text_brush.cpp`) | rasterized text, optionally pipe-mode per-char |

**Color vs mask — `enumBrushApplication`** (`krita: libs/brush/kis_brush.h:38-43`):
`ALPHAMASK` (use only alpha, paint with current FG color), `IMAGESTAMP` (stamp the brush's own RGBA
pixels — a "color brush"), `LIGHTNESSMAP` (use the image's *lightness* as a height/shade map, paint
in FG color — this is how textured-but-tintable brushes work), `GRADIENTMAP` (map lightness through
a gradient). `KisColorfulBrush` (`krita: libs/brush/KisColorfulBrush.cpp`) implements the
lightness/contrast path: when application ≠ IMAGESTAMP it converts the RGBA tip to grayscale and
applies a **brightness/contrast remap around an auto-detected midpoint** (`brushTipImage()`,
`:64-136`) — `estimateImageAverage` computes an alpha-weighted mean lightness (`:21-39`) so the brush
auto-centers its tonal pivot. The remap is a piecewise-linear contrast curve through `(midX, midY)`
(`:94-122`). This is what lets *one painted-texture brush* serve both "stamp my exact pixels" and
"use my texture as a tintable height map."

**GBR auto-detects mask-vs-image and defaults to LIGHTNESSMAP** for color GBRs
(`krita: kis_gbr_brush.cpp:250,286` set `LIGHTNESSMAP`) — verified the two `setBrushApplication(LIGHTNESSMAP)`
sites; this is the "make a photo-texture brush tintable by default" behavior.

### 1.11 GIH pipe selection — animated tips (verified)

The GIH "parasite" is the interesting bit (`krita: libs/brush/kis_pipebrush_parasite.{h,cpp}`,
`kis_imagepipe_brush.h:25-34`). A pipe brush holds up to **4 dimensions** of brush frames, each
dimension with a **selection mode** choosing which frame to stamp next:

```cpp
enum SelectionMode { Constant, Incremental, Angular, Velocity, Random, Pressure, TiltX, TiltY };
// krita: libs/brush/kis_imagepipe_brush.h:25-34
```

So you can build a brush whose tip cycles `Incremental`ly (frame 1,2,3,… along the stroke — animated
texture), or picks by `Angular` (tip rotates with stroke direction — a real chisel/grass), or by
`Pressure`/`Velocity`/`Tilt`/`Random`. **This is dynamics applied to *tip selection*, orthogonal to
the curve-option dynamics in doc 02.** Our "textured shapes orient to stroke direction" is a
degenerate single-axis Angular pipe.

### 1.12 Scaling / rotation / mipmap — `KisQImagePyramid` (verified)

Predefined tips are pre-scaled into a **mipmap pyramid** (`krita: libs/brush/kis_qimage_pyramid.cpp`):
levels from `MAX_MIPMAP_SCALE=8×` down, halving, until below a 512px threshold, then the base, then
down to 1px (`:13-63`). `findNearestLevel(scale)` picks the level ≥ the requested scale then the
applicator does the residual sub-level resample (`:70-89`). Enlarging optionally uses smooth vs fast
transform (`:38-42`). **Rotation/sub-pixel** is handled at dab time (`subPixelX/Y`, `angle` in
`generateMaskAndApplyMaskOrCreateDab`, `krita: kis_auto_brush.cpp:323-343`). The pyramid exists to
avoid minification shimmer and re-scaling cost per dab — exactly what our `mipmapped:true` +
`generateMipmaps` does for PNG shapes (`CanvasRenderer.swift:1431,1440`), but Krita also *pre-renders
multiple enlargement levels* with chosen filtering, which we don't.

---

## 2. How Kiki does it today

| Concern | Kiki implementation | Cite |
|---|---|---|
| Round tip | **Analytic in-shader**, not a baked mask: `d=length(texCoord-0.5)*2; alpha=1-smoothstep(start,1,d)` where `start = hardness - (1-hardness)²·0.85` | `CanvasRenderer.swift:1520-1529` |
| The 64² R8 mask | `(1-norm²)²` quadratic, **but only the eraser uses it** | `CanvasRenderer.swift:1361-1388`, `:1560-1570` |
| Hardness | single scalar → shifts `start` (round) or coverage gamma `mix(1.8,0.55,h)` (textured) | `:1526`, `:1544` |
| Textured tips | grayscale PNG → mipmapped R8 mask, luminance=coverage, gamma by hardness | `:1538-1547`, `BrushShapeCatalog.swift` |
| Catalog | 6 fixed entries: round + chalk/charcoal/drybrush/pastel/spray | `BrushShapeCatalog.swift:27-34` |
| Orientation | textured shapes orient to stroke dir; round fed rotation=0 | `BrushShapeCatalog.swift:44-46` |
| Color/mask | **mask only** — all tips paint in brush FG color; no IMAGESTAMP/LIGHTNESSMAP/GRADIENTMAP | (no color-brush path exists) |
| Scaling | GPU bilinear + mipmaps on PNG masks | `:1431,1440` |
| AA | shader `fwidth`-based 1px rim (round); bilinear (textured) | `:1524,1527` |

**Key structural facts:** (1) the procedural round is computed analytically per-fragment — no LUT, no
fade-radius, no per-axis fade, no spikes, no density; (2) textured tips are static single-frame PNGs
(no GIH-style animation/selection); (3) there is exactly **one** falloff law for round and it's not
any of Krita's three; (4) hardness is a single scalar with no editable curve behind it.

---

## 3. Gap analysis — what a Krita-grade superset adopts

| Krita capability | Have it? | Superset target | Priority |
|---|---|---|---|
| Default rational fade w/ **independent fade radius** | ❌ (fixed quadratic) | Parameterize falloff start + per-axis fade | Med |
| **Soft = arbitrary curve LUT** for radial profile | ❌ | Bake a user falloff curve → R8/R16 1D LUT, sample by normalized radius | **High** |
| Gaussian (`erf`) tip | ❌ | Add as a falloff preset (cheap in-shader or LUT) | Low |
| **Aspect ratio + rotation** (ellipse/chisel) | ⚠️ (rotation plumbed, ratio not) | Expose `ratio`; rect tip type | **High** (calligraphy) |
| Rectangle / chisel tips | ❌ | Separable rect falloff (analytic, trivial) | Med |
| **Spikes** (N-fold symmetry) | ❌ | `fixRotation` analog in shader | Low |
| **Density** (stochastic dot-screen) | ❌ | per-pixel/per-dab dither in shader (deterministic RNG!) | Med |
| Randomness (mask grain) | ❌ | per-pixel noise multiply | Low |
| **Color brushes (IMAGESTAMP)** | ❌ | sample tip RGBA, stamp directly | Med (see §4) |
| **LIGHTNESSMAP** (tintable texture) | ⚠️ (we tint, no contrast remap) | Adopt `KisColorfulBrush` midpoint+contrast remap | **High** |
| GRADIENTMAP | ❌ | low | Low |
| **GIH pipe / tip animation** | ⚠️ (single Angular only) | Multi-frame tip stack + selection modes | Med |
| Mipmap pyramid w/ chosen filter | ⚠️ (GPU mipmaps only) | adequate; maybe pre-rendered enlargement | Low |
| Supersampling tiny dabs | ⚠️ (relies on bilinear) | analytic falloff avoids it; PNG tips may need it | Low |

**The single biggest tip-system gap is the editable radial-falloff curve (§1.3).** Krita's "Soft"
generator means *every* round brush's profile is artist-authorable; we have one hardwired `(1-r²)²`
(eraser) / `smoothstep` (paint) curve. This is the difference between "soft/hard slider" and "design
the exact dab shoulder." Second is **aspect ratio + rotation** (chisel/calligraphy), which Krita gets
from `ratio` + `angle` and we only half-have. Third is the **LIGHTNESSMAP contrast remap** that makes
photo-texture tips behave as tintable height maps instead of fixed-coverage stamps.

---

## 4. img2img leverage call

Per the shared frame, the canvas is conditioning for klein at 1–10 FPS, so the model sees
**large-scale value, hue, saturation, edge hardness, stroke shape/direction** and *discards*
single-pixel grain.

- **Edge hardness / falloff curve (§1.2-1.3): HIGH model-leverage.** klein reads edge softness as a
  semantic cue (hard edge ⇒ object boundary; soft ⇒ shadow/atmosphere). An editable falloff curve
  *directly changes what the model resynthesizes* — a soft-shouldered tip pushes klein toward
  painterly blending, a hard tip toward crisp forms. **Worth prioritizing.**
- **Aspect ratio + rotation (chisel): HIGH model-leverage + hand-feel.** Directional thick/thin
  strokes are exactly the "stroke shape/direction" the frame calls high-leverage; calligraphic
  variation reads strongly in the output.
- **LIGHTNESSMAP tintable texture (§1.10): MEDIUM.** Texture *coverage shape* survives (edge break-up
  reads as media), but fine paper-tooth micro-detail is the "model discards" bucket. The contrast
  remap mostly buys hand-feel + correct value, modest model-leverage.
- **Density/randomness/spikes/grain (§1.6,1.9): LOW model-leverage.** Per-pixel dither and tip grain
  are squarely in klein's resynthesize-away bucket. **Hand-feel only** — worth it for how the brush
  *feels*, not for what klein sees. Deprioritize relative to falloff + ratio.
- **Color brushes / IMAGESTAMP: LOW-MED.** Stamping literal RGBA texture pixels is mostly overwritten
  unless it establishes large-scale value/hue blocks; the *color* of the stamp is high-leverage, the
  *texture* of it is not.

**Net priority for img2img:** editable falloff curve and aspect/rotation are the two tip features
that change what the model generates; everything else (density, grain, spikes, micro-texture) is
hand-feel that klein eats. Build the leverage features first.

---

## 5. Metal translation notes (respecting perf invariants)

Perf invariants (from `CanvasModule/CLAUDE.md`): <8ms/frame @120Hz; no `drawHierarchy`/
`waitUntilCompleted` on the hot path; `.shared` textures + async commits; the one sanctioned
`waitUntilCompleted` is the per-stroke flatten or one-time init.

- **Falloff curve LUT (§1.3):** Krita bakes the curve to a CPU float array. We do the same **once at
  brush-config change** (not per frame): rasterize the user curve into a **1D R16Float texture (256–
  512 wide)** at config time, sample it in `brushStampFragment` by normalized radius `d`. Zero
  per-fragment cost beyond one texture fetch; rebuild only when the curve edits. This *replaces* the
  current analytic `smoothstep` with a fully general profile and is strictly cheaper to extend.
- **Rational/Gaussian falloff:** can stay analytic in-shader (the `erf` Gaussian is a couple of
  `metal::erf` calls, cheap) — offer them as named presets that pre-fill the same LUT, so the shader
  has **one** code path (sample LUT) regardless of tip type. Avoids the per-tip-type branch.
- **Aspect ratio + rotation:** already nearly free — the stamp quad is instanced with `center,
  radius, rotation` (`CanvasRenderer.swift:1461-1467`). Add a `ratio` (or `radiusY`) field, scale the
  quad's Y by it in the vertex shader, and the existing rotation handles the chisel angle. Falloff
  reads from the *post-aspect* normalized coords. No new pass.
- **Density/randomness:** must use a **deterministic** hash (e.g. `wang_hash(dabSeqNo, pixelIndex)`),
  **not** a stateful RNG — Krita's own `KisRandomSource` is flagged non-deterministic
  (`kis_brush_mask_scalar_applicator.h:90`), and we have the replay-determinism trap noted in context.
  A pure hash per (stamp, fragment) keeps replays identical. In-shader, ~free.
- **Spikes:** port `fixRotation` as an in-shader angle-fold before the falloff lookup. Trivial.
- **Color brushes / IMAGESTAMP:** the textured-stamp shader (`shapedStampFragment`, `:1538`) already
  samples a tip texture; an IMAGESTAMP variant samples an **RGBA** tip and outputs its color
  premultiplied instead of `in.color * cov`. One extra PSO. **But:** color tips break the
  Glaze/flow-into-scratch model (the scratch assumes a single stroke color saturating toward alpha 1);
  needs care w/ the unified-brush SAB plan — flag as design question.
- **LIGHTNESSMAP remap:** the `KisColorfulBrush` midpoint + piecewise contrast is a per-texel CPU
  pass at *load* time in Krita; we'd do it once when building the tip texture (CPU, like
  `makeGrayscaleMaskTexture` already does, `:1420`) — bake the remapped coverage into the R8 mask.
  No hot-path cost.
- **Mipmap:** we already do `generateMipmaps` (`:1440`). Krita's pre-rendered *enlargement* levels
  (smooth-filtered upscales) are likely unnecessary on GPU bilinear; revisit only if large-tip
  upscaling shimmers.

**Architecture fit:** all of this collapses to **one tip abstraction** = `{falloff-LUT texture,
optional RGBA stamp texture, ratio, rotation, spikes, density-seed, application-mode}` feeding the
existing instanced-stamp path. That mirrors Krita's `KisMaskGenerator` + `KisBrush` split while
staying single-pass. It also slots cleanly under the unified-brush `BrushDescriptor` (the falloff LUT
is just another bound texture alongside `belowTex`/`sabPrev`).

---

## 6. Open questions / risks

1. **Falloff LUT vs. analytic — resolution & AA.** Krita oversamples 3×3/6×6 for tiny dabs
   (`shouldSupersample`, §1.8) because a baked profile aliases at small radii. A 256-wide LUT sampled
   at a 2px-radius dab may band. **Risk:** small soft brushes look stepped. Mitigation: keep the
   `fwidth` AA rim; possibly analytic falloff for radius < ~8px (matching Krita's <10 threshold),
   LUT above. **Needs a visual test at small radii.**
2. **Color-brush + Glaze interaction.** IMAGESTAMP tips paint their own RGBA — incompatible with the
   single-color scratch-accumulation (flow→alpha-saturate) model. How do color tips compose under
   per-stroke opacity? Likely a separate PSO/path. **Design decision needed before building.**
3. **GIH pipe value.** Multi-frame animated tips are powerful but high-effort (frame stack +
   selection state machine + determinism). Given img2img eats most of the per-stamp texture variation
   (§4), is the payoff worth it vs. just better falloff + ratio? **Probably defer.**
4. **Determinism of density/randomness.** Must be hash-based (see §5). Confirm the unified-brush
   replay path seeds per-dab deterministically; Krita's own code punts on this.
5. **Whether `ratio` belongs in `BrushConfig` or per-stamp.** Krita keeps it in the generator
   (per-brush) but modulates rotation per-dab via dynamics. We'd want `ratio` static + `rotation`
   per-stamp (already is). Confirm against the unified `BrushDescriptor` shape.
6. **Verified-but-unexplained constants** in the Gaussian generator (`6761`, `10000`, `2.5`,
   `kis_gauss_circle_mask_generator.cpp:42`) — empirical fit, not re-derived here. If we port the
   Gaussian, copy the formula verbatim rather than reinventing; flagged as **inferred** that they map
   `fade`→blur-radius.

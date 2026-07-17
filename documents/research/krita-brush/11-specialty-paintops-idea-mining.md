# Specialty Paintops — Capability Idea-Mining (the Krita superset beyond Procreate)

**Scope.** This surveys Krita's *specialty* paintops — the brush families that exist
*beyond* the pixel brush + smudge engine covered elsewhere in this research. These are
where Krita's "Krita-grade superset" identity lives: capabilities Procreate's surface
never imagined. For each, I characterize the actual algorithm (grounded in source), the
expressive capability it adds, its leverage for our img2img pipeline, and an
ADOPT / ADAPT / SKIP verdict for Kiki.

**Citation discipline.** `krita: <path>:<line>` (relative to `~/krita_src`) for Krita,
`<path>:<line>` for ours. **Verified** = I read the code. **Inferred** = pattern-matched
or from a comment. When a comment and code disagreed, code wins (noted inline).

**The organizing lens (from `_CONTEXT.md`).** Our canvas is a *conditioning image* for
`fal-ai/flux-2/klein/realtime`, captured as a flattened JPEG at 1–10 FPS. So per paintop
I tag value as **model-leverage** (changes the large-scale value/hue/edge structure klein
sees), **hand-feel** (the artist feels it even if klein resynthesizes it), or
**low-leverage** (klein overwrites the detail).

---

## The verdict table (read this first)

| Paintop | Core mechanism (one line) | Expressive capability | img2img leverage | Verdict |
|---|---|---|---|---|
| **hairy** (sumi-e) | N independent **bristles** transformed per-dab, each laying a connected sub-stroke; per-bristle ink depletion + soak-from-canvas | Splayed bristle strokes, dry-brush splitting, ink running out | **High** (edge break-up, thick→thin, color pickup) | **ADAPT** |
| **sketch** (Harmony) | Per-dab, connect lines to *recently-visited points within a radius* (proximity graph) | Self-shading "scribble"/hairy/web look; sketchy gesture | **High** (distinctive value structure) | **ADAPT** |
| **spray** | Scatter K particles per dab under tunable angular×radial **distributions** | Stipple, foliage, texture, noise fields | **Medium** (texture/value, klein eats fine grain) | **ADAPT** (as scatter sub-option) |
| **tangentnormal** | Map tilt/direction/rotation → an RGB **tangent-space normal vector** | Paint *normal maps* (height/lighting), not color | **Speculative-high** (a 2nd conditioning channel) | **SKIP now, flag** |
| **particle** | K particles with **Verlet physics** (acceleration toward cursor + gravity damping) | Springy, trailing, organic "comet" strokes | **Low–Medium** (motion artifact, mostly hand-feel) | **SKIP** |
| **deform** | Per-dab, **resample the canvas** under the brush through a warp field (grow/swirl/move/lens) | Smear/liquify/bloat/pinch as a *brush* | **Medium** (warps structure klein sees) | **ADAPT later** (it's liquify-as-brush) |
| **curvebrush** | Draw a **bezier through the last N stroke points** (history ribbon) | Calligraphic ribbons, "rake"/lazy lines | **Low** (mostly stylistic) | **SKIP** |
| **roundmarker** | Continuous **SDF circle-sweep** (`fillCirclesDiff`) — no stamping | Perfectly even marker/ink, zero spacing artifacts | **Medium** (clean solid fills feed klein well) | **ADOPT (concept)** |
| **hatching** | Fill the dab footprint with **parallel ruled lines** at angle+separation | Engraving/crosshatch shading | **Medium** (directional value texture) | **SKIP (niche)** |
| **gridbrush** | Tile the footprint into a **grid of cells**, paint a shape per cell | Halftone/mosaic/pixel-grid | **Low** (klein dissolves it) | **SKIP** |
| **filterop** | The dab is a **mask**; run an *image filter* (blur/sharpen/etc.) through it | Blur-brush, sharpen-brush, dodge/burn | **High** (directly edits klein-visible structure) | **ADAPT (high value)** |
| **mypaint** | Full **9-sensor × per-sensor-curve** dynamics model (libmypaint) | The richest dynamics vocabulary in the app | **High** (the dynamics layer itself) | **ADOPT the *model*, not the engine** |

The single highest-value finding is at the bottom of this doc (executive summary). The
threads worth pulling are **hairy + sketch** (distinctive marks klein *loves*),
**filterop** (a whole brush *category* — modify-don't-deposit), and the **mypaint sensor
model** (the dynamics abstraction our flat `BrushConfig` is missing). The rest are
documented for completeness with honest SKIPs.

---

## 1. How Krita does it — grounded mechanisms

### 1.1 hairy — dynamic bristles, ink depletion, soak-from-canvas (the sumi-e brush)

**Mechanism (verified).** Where the pixel brush stamps a single mask, the hairy brush
maintains an explicit array of **`Bristle` objects** — each a 2D offset from the brush
center plus a `length`, a `KoColor`, an `inkAmount`, and a per-bristle `counter`
(`krita: plugins/paintops/hairy/bristle.h:92-104`). The bristle set is *seeded from a
dab mask*: `fromDabWithDensity` walks every pixel of the source dab and, for each
non-transparent pixel, creates a bristle at `(x-centerX, y-centerY)` whose **length =
that pixel's alpha** (`krita: plugins/paintops/hairy/hairy_brush.cpp:77-92`). So the brush
tip's grayscale shape literally *becomes* the bristle layout — a soft round tip yields a
dense circular bristle cloud, a textured tip yields a sparse splayed one.

Per drawn segment, `paintLine` builds a `QTransform` per bristle = `rotate(-angle) ·
scale(scale) · translate(randomX, randomY) · shear(shear, shear)`
(`krita: plugins/paintops/hairy/hairy_brush.cpp:168-172`). Two key behaviors:

- **Connected path (the splay).** If `connectedPath` is on and it's not the first stroke,
  each bristle continues *from its own previous transformed endpoint* (`fx1 = bristle->prevX()`)
  rather than from the stroke center (`krita: .../hairy_brush.cpp:174-188`). This is what
  makes bristles *trail and splay* like real hairs catching on the paper — each hair has
  memory. `shear = pressure * shearFactor` (`:166`) spreads the bristles wider as you
  press, the canonical sumi-e "the brush fans out under pressure" gesture.

- **Ink depletion (the dry-brush run-out).** When `inkDepletionEnabled`, each bristle
  reads a depletion value from a **response curve** indexed by its own dab counter
  (`fetchInkDepletion`, `krita: .../hairy_brush.cpp:239-246`) — i.e. the longer a bristle
  has been painting, the more depleted. Depletion then drives **opacity**
  (`opacityDepletion`, `:277-294`) and optionally **saturation** (`saturationDepletion`,
  `:249-275`, via an `hsv_adjustment` color transform), optionally combined with weighted
  factors (pressure / bristle length / ink amount / depletion). The result: strokes start
  saturated and opaque, then fade and desaturate as the "ink runs out."

- **Soak ink (color pickup).** If `useSoakInk` and it's the first stroke, `colorifyBristles`
  samples the *canvas under each bristle's seed position* and assigns that as the bristle's
  color (`krita: .../hairy_brush.cpp:418-434`, called at `:140`). The brush literally picks
  up the colors it's sitting on — wet-into-wet, per bristle.

Each bristle then plots along its segment via either antialiased `paintParticle`
(4-pixel bilinear splat, `:318-355`) or hard `plotPixel`/`darkenPixel` (`:387-399`). Note
`darkenPixel` only writes if the new opacity *exceeds* the existing — a "darken" composite
that prevents self-overlap brightening. Options live in `KisHairyBristleOptionData`
(scaleFactor, randomFactor, shearFactor, connectedPath; `krita:
plugins/paintops/hairy/KisHairyBristleOptionData.h:30-38`) and `KisHairyInkOptionData`
(inkDepletionCurve, useSaturation/useOpacity/useWeights/useSoakInk; `krita:
plugins/paintops/hairy/KisHairyInkOptionData.h:33-47`).

### 1.2 sketch — proximity-connecting lines (the Harmony brush)

**Mechanism (verified).** This is the most *algorithmically distinctive* paintop. It's a
port of mrdoob's "Harmony" sketch tool (`krita:
plugins/paintops/sketch/kis_sketch_paintop.cpp:37`). The op keeps a growing list of every
mouse position it has visited this stroke (`m_points`, appended each `doPaintLine` at
`:153`). Per drawn segment it does two things:

1. Optionally draw the literal connecting line from prev→current (`makeConnection`,
   `:167-169`).
2. **The signature move:** loop over *all previously-visited points*, and for any point
   within a threshold radius of the current cursor, *draw a faint line between them*
   (`krita: .../kis_sketch_paintop.cpp:212-297`, "MAIN LOOP"). Proximity test is either a
   circle (`distance < thresholdDistance`, `:219`) or the actual brush-mask footprint
   (`:225-235`). The connection is drawn probabilistically (`randomSource->generateNormalized()
   >= probability`, `:251`) with optional distance-based opacity (`:275-279`), distance-based
   density (`:244-246`), random RGB per line (`:254-271`), and a **`magnetify`** mode that
   offsets both endpoints (`:287-292`).

The emergent effect: as your cursor revisits a region, a *web of fine lines* fills in
between nearby parts of your gesture — automatic cross-hatched shading, "furry" contours,
"sketchy" energetic linework. It's a **proximity graph rendered as ink**. The header
comment preserves the original Harmony presets (`chrome: diff 0.2, sketchy: 0.3, fur: 0.5`,
`:39`) — diff/threshold tuning gives chrome (tight metallic), sketchy (loose), and fur
(long reaching strands). Critically there is **no spacing model** — `updateSpacingImpl`
returns airbrush-only spacing (`:316-321`), so the density comes from the proximity loop,
not from dab spacing.

### 1.3 spray — particle scatter with tunable distributions

**Mechanism (verified).** Per dab, spray scatters `m_particlesCount` particles inside a
disk of radius `m_radius` (`krita: plugins/paintops/spray/spray_brush.cpp:184`). Particle
count is either fixed or **density-driven**: `coverage · π·r² / scale²`
(`:195-200`) — bigger brush ⇒ proportionally more particles for constant density. Each
particle's polar position is drawn from two pluggable **distributions**: an *angular*
distribution (uniform or curve-based) and a *radial* distribution
(uniform / gaussian / cluster-based / curve-based, with center-biased vs.
area-uniform variants), dispatched through a template ladder
(`krita: .../spray_brush.cpp:98-137`). Position: `nx = r·cos(angle)·length;
ny = r·sin(angle)·length·aspect` then a rotation/scale transform (`:249-256`).

Per particle it can: sample the canvas color (`sampleInputColor`, `:261`), mix toward a
background color weighted by pressure (`:266-280`), jitter HSV randomly
(`useRandomHSV`, `:282-290`), randomize opacity (`:292-296`), and randomize size/rotation
via **shape dynamics** — `followCursor`, `followDrawingAngle`, `randomRotation` each as a
*weighted lerp* toward the relevant angle (`krita:
plugins/paintops/spray/spray_brush.cpp:228-247`; options in `KisSprayShapeDynamicsOptionData.h:32-43`).
The particle itself is an ellipse / rectangle / wu-pixel / hard pixel / a QImage stamp / or
the brush's own auto-mask (`switch` at `:308-408`).

### 1.4 tangentnormal — paint a tangent-space normal map

**Mechanism (verified).** Instead of depositing the *chosen* color, every dab deposits a
**color computed from the pen's orientation** so the resulting image is a usable
tangent-space normal map. `KisTangentTiltOption::apply` takes the pen's tilt direction
(azimuth) + elevation (or drawing-angle / rotation, selectable), converts to spherical
coordinates, and emits a unit vector remapped to [0,1] RGB: `horizontal = cos(elev)·sin(dir)`,
`vertical = cos(elev)·cos(dir)`, `depth = sin(elev)·max`, each rescaled around 0.5
(`krita: plugins/paintops/tangentnormal/KisTangentTiltOption.cpp:90-108`). A `swizzleAssign`
lets you map h/v/depth (and their inverses) onto any of R/G/B (`:27-37`) to match a
GL vs DirectX normal convention. The paintop forces an 8-bit RGB space, builds the
KoColor from those channels, then stamps a *standard mask dab* filled with that color
(`krita: plugins/paintops/tangentnormal/kis_tangent_normal_paintop.cpp:53-148`). So the
plumbing is the pixel brush; only the *color source* is replaced. Default neutral is
`RGB(0.5, 0.5, 1.0)` = flat normal pointing at viewer (`:73-75`).

### 1.5 particle — Verlet-physics dab cloud

**Mechanism (verified).** K particles, each with a position, a "next position", and an
acceleration. Per iteration each particle is pulled toward the cursor and damped by
gravity — a **Verlet-style integrator**: `dist = (cursor - pos)·scaleXY·accel;
nextPos += dist; nextPos *= gravity; pos += nextPos·TIME`
(`krita: plugins/paintops/particle/particle_brush.cpp:115-121`, `TIME = 0.00003` at `:19`).
Particles overshoot, oscillate, and trail behind the cursor, leaving springy comet tails.
The code explicitly guards against the integrator going unstable to infinity with negative
scale (`:123-145`), and the comment admits "the effect of instability might be quite
interesting for the painters." Splat is the same 4-pixel bilinear `paintParticle` as spray.

### 1.6 deform — liquify-as-a-brush (resample the canvas through a warp)

**Mechanism (verified).** The deform brush does **not** deposit color — per dab it
*resamples the existing canvas* through a deformation field, like Photoshop Liquify but as
a continuous brush. `paintMask` iterates the dab footprint; for each pixel within the
elliptical radius it applies `m_deformAction->transform(maskX, maskY, distance, rng)` to
warp the *source coordinate*, then samples the canvas at the warped coordinate (bilinear or
nearest) and writes it (`krita: plugins/paintops/deform/deform_brush.cpp:207-258`). The
action is polymorphic: GROW/SHRINK (scale), SWIRL_CW/CCW (rotation), MOVE (drag),
LENS_IN/OUT (spherical lens), DEFORM_COLOR (`:40-78`, `setupAction` `:80-155`). `useOldData`
chooses whether to read the pre-stroke or live canvas (`:245-249`) — the wet-vs-frozen
source distinction we already grapple with in our smudge path.

### 1.7 curvebrush — bezier ribbon through stroke history

**Mechanism (verified).** Keep the last `curve_stroke_history_size` points; each segment,
draw a quad/cubic bezier through them with `QPainter` strokes (`krita:
plugins/paintops/curvebrush/kis_curve_paintop.cpp:83-121`). Optional connection line and a
separate opacity for the "curve" ribbon vs. the connection. It's a thin geometric flourish
on top of stroke history — calligraphic lazy-lines.

### 1.8 roundmarker — continuous SDF circle-sweep (no stamping)

**Mechanism (verified).** Instead of stamping discrete dabs, the round marker draws the
*swept area between the last circle and the current one* analytically:
`KisMarkerPainter::fillCirclesDiff(prevPos, prevRadius, pos, radius)`
(`krita: plugins/paintops/roundmarker/kis_roundmarkerop.cpp:90-99`). First touch fills a
full circle (`:80-88`); subsequent touches fill only the *new* crescent. Because it's a
swept-disk fill (effectively an SDF of a capsule), there are **no spacing artifacts at any
speed** — a perfectly even, dense marker/ink line, no overlapping-stamp build-up, no
visible dabs. `KisMarkerPainter` is the worth-studying class here (it computes the
analytic difference region).

### 1.9 hatching — ruled parallel lines filling the footprint

**Mechanism (verified).** Per dab, fill the brush footprint with **parallel straight lines**
at a chosen angle and separation. `hatch()` turns angle→slope, computes the per-line
intercept step `dy = |separation / cos(angle)|`, finds the "hot" line nearest the cursor,
then iterates lines forward and backward filling the area (`krita:
plugins/paintops/hatching/hatching_brush.cpp:42-91`, `iterateLines` `:93+`). Separation and
thickness are themselves curve-driven (`separationAsFunctionOfParameter`, `:52-55`).
Crosshatch = multiple passes at different angles. Classic engraving / pen-and-ink shading.

### 1.10 gridbrush — tile the footprint into a cell grid

**Mechanism (verified).** Snap a grid to the canvas, divide the footprint into
`grid_division_level` cells (optionally pressure-divided, `krita:
plugins/paintops/gridbrush/kis_grid_paintop.cpp:88-95`), and paint one shape per cell
(`:136-188`), each cell optionally sampling canvas color, mixing background, jittering HSV,
randomizing opacity. Halftone / mosaic / dithered-pixel-art looks.

### 1.11 filterop — the dab is a mask through which an *image filter* runs

**Mechanism (verified).** This is a whole *category*, not a brush. The dab mask is a
*selection*; the op copies the canvas under the dab into a temp device, runs an arbitrary
**Krita filter** (blur, sharpen, desaturate, levels, dodge/burn, pixelize, …) on it, then
composites the filtered result back *through the dab mask* (`krita:
plugins/paintops/filterop/kis_filterop.cpp:99-133`). `smudgeMode` controls whether it reads
fresh or accumulated data (`:117-120`). So you "paint with" blur, sharpen, saturation — the
brush *modifies what's there* instead of depositing pigment.

### 1.12 mypaint — the 9-sensor × per-sensor-curve dynamics model

**Mechanism (verified).** Krita embeds libmypaint as a paintop. The interesting artifact is
its **sensor vocabulary**, registered in `MyPaintSensorPack`: Pressure, FineSpeed,
GrossSpeed, Random, Stroke (position along stroke 0→1), Direction, Declination (tilt
elevation), Ascension (tilt azimuth), Custom (`krita:
plugins/paintops/mypaint/MyPaintSensorPack.cpp:42-72`). Every brush *setting* (radius,
opacity, hardness, color h/s/v, dabs-per-radius, offset-by-random, …) is a curve over a
*sum of these sensors*. This is the same architecture as Krita's native
`KisCurveOption`+`KisDynamicSensor` (documented in `00-krita-brush-architecture.md`) — the
**dynamics layer** that our flat `BrushConfig` lacks.

---

## 2. How Kiki does it today

We have **one** brush family: an instanced-stamp pixel brush with a Glaze flow/opacity
split and a device-only wet (KM) path. There is **no** bristle model, **no** proximity
graph, **no** particle scatter, **no** normal-map mode, **no** filter brush, and **no**
deform/liquify.

- **Dynamics layer.** A single scalar `pressureGamma` maps pressure→width
  (`ios/Packages/CanvasModule/Sources/CanvasModule/DrawingEngine.swift:74-75`), plus
  `tiltSensitivity` (`:77`). No azimuth, no velocity field, no per-parameter response
  curves, and `StrokePoint` carries only `position/force/altitude/timestamp` (per
  `_CONTEXT.md`) — **no tilt azimuth, no rotation**. So tangentnormal and the richer
  spray/hairy dynamics aren't even expressible with our current inputs.
- **Tips.** Six fixed tips: a procedural soft circle `(1-r²)²` plus five grayscale PNGs
  (chalk/charcoal/drybrush/pastel/"ink"-spray), oriented to stroke direction when textured
  (`ios/Packages/CanvasModule/Sources/CanvasModule/BrushShapeCatalog.swift:27-46`). The
  "drybrush"/"ink" PNGs *fake* hairy/spray statically — a single fixed texture, no live
  bristle dynamics or ink depletion.
- **Deposit model.** Stamp into an isolated scratch, single flatten at `touchesEnded`
  (per `_CONTEXT.md` + CanvasModule/CLAUDE.md). Our wet path is the only thing that
  *reads* the canvas back (the carried-load smear), and it's `getBytes`-per-dab on the CPU.
- **No modify-don't-deposit brush.** We have no analog to filterop or deform — every brush
  adds pigment; none edits existing pixels through a mask (except the eraser's
  destination-out).

---

## 3. Gap analysis + what a Krita-grade superset adopts

The honest framing: most of these paintops are *niche looks* that a finished-artwork tool
ships for completeness. **We are not a finished-artwork tool — we are a conditioning-image
generator.** That flips the priority hard toward "does this change the value/edge/hue
structure klein resynthesizes from" and away from "is this a pretty final mark."

**The genuine superset gaps (worth building):**

1. **A dynamics layer (from mypaint/KisCurveOption), not more brushes.** The thing every
   one of these paintops *shares* and we *lack* is the sensor×curve abstraction. Adopting
   it (Direction, Speed, Tilt-azimuth/elevation, Random, Stroke-position, Fade as inputs;
   per-parameter curves as the mapping) is higher value than any single specialty op,
   because it *unlocks* hairy splay, spray follow-angle, tangentnormal, and richer taper
   all at once. This is the same conclusion `00-krita-brush-architecture.md` reached for
   the pixel brush; the specialty ops *reinforce* it — they're all downstream of it.

2. **Bristle dynamics (from hairy), as a brush *mode*.** Real splaying bristles + ink
   depletion + soak-from-canvas produce edge break-up, thick→thin, and wet color pickup —
   exactly the marks klein reads as "expressive brushwork." Our static drybrush PNG is a
   poor stand-in (it can't splay under pressure or run out of ink). This is the single most
   *distinctive* expressive capability in the survey.

3. **Proximity-connect (from sketch), as a brush *mode*.** The Harmony scribble is unlike
   anything in Procreate and produces strong, legible value structure with very little
   user effort — a "gesture → shaded form" brush. Cheap to implement (it's just line
   draws against a point buffer) and visually unique.

4. **Filter-brush (from filterop).** A *category* we're missing entirely: paint-with-blur,
   paint-with-sharpen, paint-with-saturation/dodge/burn. For img2img this is unusually
   high-leverage because it edits the *exact* structure klein conditions on (soften an
   edge → klein softens that region; sharpen → klein hardens it).

5. **Scatter as a sub-option (from spray).** Not a separate brush — a `scatter`/`count`
   parameter on the unified brush (position jitter + per-dab count + follow-angle), which
   is how the unified-brush plan should expose it anyway.

**Deliberate SKIPs (documented so we don't relitigate):** particle (physics motion is
mostly hand-feel, klein eats the trails), curvebrush (stylistic flourish), gridbrush
(halftone dissolves under klein), hatching (niche; the dynamics layer + a hatch *texture*
gets 80% of it), and tangentnormal *as a color brush* (see §4 — its real use is a separate,
speculative second conditioning channel, not a brush we ship now).

---

## 4. img2img leverage call (per capability)

| Capability | Leverage class | Why |
|---|---|---|
| **hairy bristle splay + ink depletion** | **model-leverage** | Edge break-up, thick→thin, and desaturation-on-runout are large-scale shape/value/hue cues klein conditions on. Soak-ink color pickup changes hue directly. The *splay shape* survives JPEG capture. |
| **sketch proximity-connect** | **model-leverage** | Produces dense directional value structure (shading) from sparse gesture — exactly the kind of tonal mass klein turns into form. Very high signal-per-effort. |
| **filterop (blur/sharpen/dodge-burn brush)** | **model-leverage (highest, direct)** | Unlike deposit brushes, it edits klein's *input structure* in place: soften/harden edges, push local contrast/saturation. klein's `output_feedback_strength` loop means these edits steer regeneration immediately. |
| **deform/liquify-brush** | **model-leverage** | Warping the canvas warps the silhouette/structure klein sees. Useful for reshaping a generated region by hand. |
| **spray scatter** | **medium** | Coarse stipple/texture reads as value/material; fine grain is resynthesized away. Useful for foliage/texture *fields*, not detail. |
| **tangentnormal** | **speculative-high, but not as a brush** | A painted normal/height map is worthless as klein's *color* input. Its real leverage is as a **second conditioning channel** (depth/normal control) *if* klein/ControlNet-style conditioning ever supports one. File it as a future model-capability bet, not a v1 brush. |
| **particle / curvebrush** | **hand-feel / low** | Springy trails + calligraphic ribbons are felt by the hand; klein mostly overwrites the specifics. |
| **gridbrush / hatching** | **low–medium** | Halftone is dissolved; hatch *direction* survives as value texture but the dynamics-layer-plus-hatch-texture combo captures it more cheaply. |
| **roundmarker SDF sweep** | **medium (quality, not look)** | Not a look — a *fidelity* win: perfectly even solid fills with zero spacing artifact feed klein cleaner flat regions. Worth absorbing the *technique*. |

---

## 5. Metal translation notes (respecting our perf invariants)

Perf invariants (from `_CONTEXT.md` + CanvasModule/CLAUDE.md): <8ms/frame @120Hz; never
`drawHierarchy`/`waitUntilCompleted` on the hot path; `.shared` textures + async commits;
the only sanctioned `waitUntilCompleted` is the once-per-stroke flatten.

- **hairy (ADAPT).** Bristles are *embarrassingly instanceable*. Seed N bristle offsets
  from the chosen tip mask once at `touchesBegan` (CPU, or a compute pass). Per dab, expand
  each bristle into a short run of stamp instances along its `prev→current` segment — this
  drops straight into our existing instanced-stamp draw (the `StampInstance` buffer) with
  **no new pass**. Per-bristle `prevX/prevY` (the splay memory) lives in a small CPU array
  carried across the stroke. Ink depletion = a per-bristle counter indexing a 256-entry
  curve LUT (same LUT machinery the dynamics layer wants). **Soak-ink** needs a canvas read
  at stroke start — do it as a single `.shared`-texture `getBytes` of the footprint at
  `touchesBegan` (off the per-frame path), not per-dab. Krita's per-pixel `darkenPixel`
  composite is CPU; we'd instead let bristles accumulate in the isolated scratch
  (Glaze semantics already prevent self-overlap brightening). Risk: bristle count × dab
  count is the instance budget — cap bristles (Krita's are seeded from the mask, which can
  be thousands; we'd subsample, like `fromDabWithDensity`'s `density` does at
  `krita: .../hairy_brush.cpp:81`).

- **sketch (ADAPT).** Maintain the visited-point buffer (`m_points`) on CPU per stroke. Per
  dab, the proximity loop is O(points) — but the radius bound makes it sparse; a coarse
  spatial hash (grid bucket) keeps it cheap as the stroke grows. Each accepted connection is
  *one thin line* = a 2-vertex segment or a tiny capsule of stamp instances. No texture
  read-back, no new pass. The RNG must be the deterministic per-stroke source (our replay
  determinism trap from MEMORY — mirror Krita's `pi2.randomSource()` usage at
  `krita: .../kis_sketch_paintop.cpp:248`). Risk: unbounded `m_points` growth on long
  strokes — Krita doesn't cap it; we should (ring buffer) to bound the loop.

- **filterop (ADAPT, high value).** This is a *compute/blit* brush, not a stamp brush. Per
  stroke (not per dab) accumulate the dab footprint as a mask in the scratch, then at
  `touchesEnded` run the filter (Metal compute: separable gaussian blur / unsharp /
  saturation matrix) over the affected layer rect, compositing back through the mask. Doing
  it once-per-stroke (like our flatten) keeps it off the hot path. *Live preview* of a
  blur-brush is the hard part — a full-res blur every frame may blow the 8ms budget on
  large brushes; mitigate with a downsampled preview tile and the real pass at stroke end.
  No `waitUntilCompleted` except the existing flatten.

- **deform (ADAPT later).** A fragment shader that samples the *belowTex/SAB* (we already
  bind source textures per the unified-brush plan) through a per-pixel warp computed from
  brush center + radius + action (swirl/grow/move/lens are all closed-form). Reads the
  canvas → must run against a snapshot of the layer (the "old data" vs "live" choice Krita
  exposes), bound as a source texture, not the render target. Fits the bound-source-reads
  model the unified plan already designs.

- **spray scatter (ADAPT).** Pure instancing: per dab, emit `count` extra stamp instances
  at jittered polar offsets (uniform/gaussian via a small precomputed distribution LUT or
  Box-Muller in the vertex stage). Follow-angle = feed `drawingAngle` into the instance
  rotation. Zero new passes. Deterministic RNG again.

- **roundmarker SDF (ADOPT concept).** Our soft round tip is `(1-r²)²`; a capsule-SDF
  fragment (distance to the segment between consecutive centers) would give Krita's
  artifact-free sweep for *hard* round brushes without per-dab stamping. Drop-in as an
  alternate PSO; only helps the hard-round case.

- **tangentnormal (SKIP now).** Trivial to compute (the spherical→RGB math is ~10 lines),
  but pointless until we *need* a normal map. Requires adding tilt-azimuth + rotation to
  `StrokePoint` first (we don't capture them), which is a dynamics-layer prerequisite
  anyway.

---

## 6. Open questions / risks

1. **Determinism (recurring trap).** hairy, sketch, and spray all pull from
   `KisRandomSource` per dab. Our stroke replay must use the same deterministic per-stroke
   seed or replays/undo diverge (MEMORY: replay-determinism trap). Verify our stamp path
   has a seedable per-stroke RNG before building any scatter/bristle op.
2. **Bristle instance budget.** Krita seeds bristles from the *full mask* (thousands of
   pixels) and runs on CPU. On GPU at 120Hz we must subsample to a fixed N (e.g. 32–128)
   and validate the instance count × dabs-per-frame stays in budget. Unverified that the
   look survives heavy subsampling — needs a prototype.
3. **filterop live preview cost.** Whether a per-frame blur preview fits 8ms for large
   brushes is unverified. The once-per-stroke model is safe; the live preview is the risk.
4. **`m_points` growth (sketch).** Krita never caps the visited-point list
   (`krita: .../kis_sketch_paintop.cpp:153` just appends); long strokes degrade to O(n²)
   overall. We must bound it. Confirmed by reading the code — there is no eviction.
5. **Dynamics-layer dependency.** hairy splay, spray follow-angle, and tangentnormal all
   assume richer per-point input (azimuth, drawing-angle, speed) than our `StrokePoint`
   carries. None can be done *well* before the sensor/curve dynamics layer lands. The
   sequencing is: dynamics layer → then bristle/scatter modes → then (maybe) filter brush.
6. **Is "more brush families" even on-strategy?** Honest risk: shipping 5 specialty brushes
   may be lower ROI than deepening the *one* brush + dynamics layer + filter category. The
   table's many SKIPs reflect that. The recommendation deliberately narrows to 3 threads.
7. **tangentnormal as a 2nd channel is a model bet, not a brush bet.** It only pays off if
   our generation path adds a structural conditioning channel. Unverified whether
   fal/klein realtime supports any such input today (it's an img2img feedback loop per
   `_CONTEXT.md`, with no obvious normal/depth conditioning) — so this stays a flagged idea.

---

## Executive summary

**Most important finding.** The specialty paintops are not really "more brushes" — read
together, every one of them is a *consumer of the same sensor→curve dynamics layer* that
our flat `BrushConfig` (one `pressureGamma` scalar) doesn't have. hairy's splay, spray's
follow-angle, tangentnormal's azimuth mapping, and richer taper are all *downstream* of
that layer and aren't even expressible today because our `StrokePoint` drops tilt-azimuth,
rotation, and a velocity field. The superset win is the **dynamics abstraction**
(mypaint/`KisCurveOption`: ~9 sensors, per-parameter response curves), not a pile of
niche brush families. This reinforces the same conclusion the core-architecture pass
reached — the specialty ops are corroborating evidence, not a new direction.

**Top recommendations (in priority order):**

1. **Build the sensor/curve dynamics layer first** (add tilt-azimuth + rotation + a derived
   speed field to `StrokePoint`; make size/flow/scatter/taper curve-driven over sensors).
   It unlocks the next two and is higher-leverage than any single brush.

2. **Add a bristle mode (from hairy) and a proximity-connect mode (from sketch) as the two
   "superset" brushes.** Both are GPU-instanceable with no new render pass, both produce
   *distinctive, klein-legible* value/edge structure Procreate can't, and sketch in
   particular is cheap (a point buffer + thin line draws). These are the highest
   model-leverage *looks* in the survey.

3. **Treat filterop as a new brush *category*, not a brush:** paint-with-blur / sharpen /
   dodge-burn. It's the single highest-leverage capability for img2img because it edits the
   exact edge/contrast/saturation structure klein conditions on, in place — run once-per-
   stroke (like our flatten) to stay off the hot path. SKIP particle/curvebrush/gridbrush/
   hatching, and hold tangentnormal as a *future second-conditioning-channel* bet rather
   than a v1 brush.

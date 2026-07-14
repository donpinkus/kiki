# Pro-Brush Roadmap — From Soft Circle to Procreate-Class Paint Engine

**Written:** 2026-06-06 · **Status updated:** 2026-06-07

## Status (2026-06-07)

Shipped to `origin/main` and verified on device:
- ✅ **Phase 0** — Flow / Opacity split (per-stamp flow vs per-stroke opacity ceiling).
- ✅ **Phase 1** — StreamLine stabilization.
- ✅ **Phase 2** — Hardness / Spacing / Taper, moved secondary controls into a **gear popover**
  (`BrushSettingsPopover`), each slider with a "?" help popover.
- ✅ **Phase 4 — Wet paint** (jumped ahead of Phase 3, it was the headline want). What actually
  shipped:
  - Direct-to-layer, eraser-style framebuffer-read RMW (`wetStampFragment`, `applyWetStamps`).
    **Device-only** — framebuffer fetch makes the wet PSO nil on the Simulator, so wet no-ops there.
  - **Spectral Kubelka-Munk** pigment mixing (Mallett-Yuksel 7-basis, 36-band; tables in
    `CanvasRenderer.setupWetKMTables`; CPU mirror `kmMixCPU`). Per-channel KM was rejected
    (collapses blue+yellow to black). See `documents/references/wet-paint-color-spike/`.
  - **Carried-load smear** (`MetalCanvasView.wetLoad`): the brush carries a paint load that
    picks up the canvas color it crosses (`sampleLayerColor` 1×1 read) and redeposits the
    evolving mix → green throughout overlaps + directional smear.
  - Alpha builds by **coverage** (opaque; no white halo). Controls: **Mix** (`wetStrength`) +
    **Smear** (`wetPickup`) in the popover.
- ⬜ **Phase 3** — Shape & grain (gate grain on an img2img survival spike).
- ⬜ **Phase 5** — Brush preset library.

Wet-paint follow-ups / known tradeoffs:
- The per-stamp canvas read sees **committed** paint only, not the in-flight current stroke →
  smearing your *own* just-laid paint within one stroke is approximate. It is also
  **timing-dependent**: stamps commit async (no waitUntilCompleted), so whether earlier
  batches of the same stroke have landed when the CPU samples depends on GPU scheduling —
  the same gesture can smear slightly differently run to run. The "truer" fix for both is a
  **GPU reservoir** (carry the load in a small texture updated in the wet pass).
- **Low-Mix strokes still opacify + tint soft edges** (chosen tradeoff, 2026-07-14 review):
  alpha builds by *coverage* regardless of deposit, and `dstLin = mix(brushLin, under, dst.a)`
  leaks the load color into any semi-transparent pixel even at near-zero Mix. So a wet pass
  over an AA fringe fills it toward the load color and hardens it opaque — and smudge's
  "no new ink" contract bends at soft edges. This is the cost of the deliberate "no white
  halo" design (opaque wet paint); revisit only alongside the GPU reservoir.
- Wet ignores Shape/Flow/Taper and Brush Studio dynamics (round tip, own deposit model);
  the popover grays these out while wet is on. Honoring size dynamics is a cheap later add.
- A **Smudge preset** (Mix low / Smear high) is a trivial add once presets exist.
- KM gotcha: clamp integrated linear RGB to [0,1] **before** the endpoint-residual correction.
- KM/recovery math lives in `WetKM.swift` (UIKit-free) so `OfflineTests` asserts the shipped
  tables, mix, and premult-texel recovery on macOS (the 2026-07-14 decode-order fix is
  regression-pinned there).

## Context

Kiki's Metal canvas engine (see `metal-canvas-rewrite.md`) ships a single hardcoded
soft-circle stamp brush. It's good enough to sketch with, but it is a long way from
Procreate-class expressiveness — and the headline want is **wet/oil paint** where
colors physically mix and smear instead of layering as flat opaque coats.

This plan was produced by reviewing Procreate's full Brush Studio parameter surface
against the actual engine, then having four independent architecture agents each draft a
roadmap and reconciling them. The four converged hard on the spine below; the
disagreements (stabilization placement, grain priority) are resolved in-line with the
reasoning that won.

### The organizing constraint: the canvas feeds an img2img model

Kiki's canvas is **not the final artifact** — it's a conditioning image for
`fal-ai/flux-2/klein/realtime`, captured as a flattened JPEG at 1–10 FPS and
re-rendered by the model every ~250ms. This reframes the whole roadmap:

- **What the model consumes (high leverage):** large-scale value structure, hue,
  saturation, edge hardness, stroke shape/direction, where paint is thick vs. thin.
  The model reads these as compositional intent and amplifies them.
- **What the model discards (low leverage):** fine grain, paper tooth, PBR
  micro-detail, single-pixel burnt edges. The diffusion pass resynthesizes surface
  texture from its own prior.
- **What the *artist's hand* still feels even if the model eats it:** wet drag, color
  pull, taper, stabilization. Tactile handling is half of "feels pro" regardless of the
  output frame.

Two consequences run through every phase:

1. **Pigment *color* mixing (blue+yellow→green) is the highest-leverage half of wet
   paint for this product** — more than the smear *motion* — because color is exactly
   what conditions the generation.
2. **The flow/opacity fix (Phase 0) is a correctness fix, not just cosmetics.** Today a
   translucent self-crossing stroke sends the model a *darker, more opaque* image than
   the user sees mid-stroke. Fixing it aligns what the user perceives, what's stored,
   and what the model receives.

## Current engine — verified state

| Fact | Evidence |
|---|---|
| `BrushConfig` has 5 fields: color, baseWidth, opacity, pressureGamma, tiltSensitivity | `DrawingEngine.swift:63-99` |
| "Opacity" is baked **per-stamp** into premultiplied color → overlapping stamps in one stroke stack alpha (no per-stroke ceiling) | `MetalCanvasView.swift:2295-2301`; brush PSO is plain source-over `CanvasRenderer.swift:1018-1026` |
| Active stroke re-stamped into a **freshly-cleared scratch every frame**, composited, then flattened into the layer once on `touchesEnded` (the only hot-path `waitUntilCompleted`) | `CanvasRenderer.swift:302-342` |
| Spacing hardcoded `max(width*0.3, 0.5)` in 3 places | `MetalCanvasView.swift:2203, 2235`; eraser `:840` |
| Single hardcoded soft mask `(1-r²)²`, 64×64 R8Unorm, CPU-generated. No hardness/shape/grain | `CanvasRenderer.swift:1080-1107` |
| `StampInstance.rotation` plumbed through the vertex shader but always fed `0` | `MetalCanvasView.swift:2197, 2229, 2247`; shader `CanvasRenderer.swift:1145-1151` |
| **GPU read-canvas-under-brush / mix / write-back already proven safe** — the eraser uses programmable framebuffer-read (`float4 dst [[color(0)]]`, `isBlendingEnabled=false`), per-touch, no readback, no `waitUntilCompleted` | `CanvasRenderer.swift:1016, 1189-1199` |
| Textures `.bgra8Unorm_srgb` → in-shader blend math is **linear-space** for free | PSO `CanvasRenderer.swift:1007`; CanvasModule CLAUDE.md sRGB rules |
| `BrushConfig` `Codable` already has a backward-compat decoder (`decodeIfPresent`) tolerating missing keys | `DrawingEngine.swift:108-129` |

The per-frame full-stroke re-stamp into a clean scratch (`CanvasRenderer:302-316`) is the
load-bearing fact for the whole roadmap: the scratch already represents "the entire
current stroke in isolation," which makes per-stroke opacity, wet-edge accumulation, and
a single-buffer wet pass all tractable.

## Perf invariants (sacred — never violate)

- Canvas responsiveness never depends on network/generation state.
- Target <8ms stroke latency at 120 Hz.
- **Never** `drawHierarchy` or `waitUntilCompleted` on the main-thread hot path.
- `.shared` textures + async command-buffer commits.

Every phase below is checked against these. The one legitimate `waitUntilCompleted`
(once per stroke, at flatten) stays put.

---

## A note on Glaze vs. Build-up (matters for Phase 0)

Procreate's Rendering panel exposes two accumulation behaviors, and they are the precise
thing we're fixing:

- **Glaze (uniform):** dabs build a *coverage mask* capped at 1.0, composited once at
  opacity → overlaps within a stroke **do not** darken. This is what the headline test
  ("a 30% stroke crossing itself stays 30%") checks.
- **Build-up (blend):** each dab deposits `flow` and overlaps accumulate past it,
  darkening → overlaps within a stroke **do** darken.

The recommended first step — render dabs into the scratch, composite scratch→canvas at
`opacity` — **is the Glaze path**, which is exactly the bug fix. `flow` as a separate
knob enables Build-up later. Implement Glaze first; the Glaze/Build-up toggle is a fast
follow.

---

## Roadmap

### Phase 0 — Flow/Opacity split + `BrushConfig` → layered descriptor  ← FIRST STEP

**Delivers:** strokes that respect a per-stroke opacity ceiling. A 30%-opacity stroke
that crosses itself reads as one flat 30% coat, not a piled-up 60%+. `flow` (per-dab
deposit) and `opacity` (per-stroke ceiling) become independent — the foundational
Procreate distinction.

**Procreate parameters:** Rendering → Flow vs. Opacity; the basis of Glaze vs. Blend;
Apple Pencil → Pressure → Opacity & Flow as separate axes; Properties → max/min opacity.

**Engine changes:**
- `DrawingEngine.swift` (`BrushConfig`, `:63-99`): add `flow: CGFloat` (per-dab deposit,
  default 1.0); reinterpret `opacity` as the per-stroke ceiling. Extend the Codable shim
  (`:108-129`) with `decodeIfPresent(... ?? 1.0)` for `flow` so old saved configs decode
  unchanged.
- `MetalCanvasView.swift` (`premultipliedColor`, `:2295-2301`): bake **flow**, not
  opacity, into the per-stamp premultiplied alpha. Dabs still source-over into the
  scratch, saturating toward 1.0 within the stroke.
- `CanvasRenderer.swift` (`flattenScratchIntoCanvas` + the live `compositeToDrawable`
  scratch draw): composite the whole scratch onto the active layer multiplied by the
  stroke's **opacity**. The compositor fragment already multiplies a layer by a scalar
  opacity uniform (`:1219-1227`, currently hardcoded `1.0` at `:334`) — reuse it at both
  the flatten **and** the live preview draw so preview == committed result.
- Begin restructuring `BrushConfig` into nested sub-configs mirroring Brush Studio
  panels (`StrokePath`, `Taper`, `Shape`, `Grain`, `Rendering`, `WetMix`, `Pencil`,
  `Dynamics`). Doing this now, while the struct is 5 fields, avoids N future migrations.

**Effort:** S–M.  **Risk:** Low — reuses the existing scratch→flatten seam, off the
per-stamp hot path; eraser/lasso/persistence untouched.

**Why first:** highest leverage per line of code (fixes the most-felt "amateur" tell
*and* a model-correctness bug); a hard prerequisite for glaze/blend modes, pressure
dynamics, wet edges, and the entire Wet Mix phase, all of which are *defined* in terms of
a flow/opacity split. Build them on the conflated model and you rebuild them later.

**Acceptance:**
- A 30%-opacity stroke crossing itself in an X/spiral: the crossover is the **same** value
  as the legs (today it's visibly darker).
- A 30%-opacity stroke drawn, lifted, then re-drawn over: the second pass **does** darken
  (cross-stroke build-up still works → we capped *within* a stroke, not *across*).
- Live preview during the drag is identical to the flattened result after lift (both
  composite sites use the ceiling).
- Default pen (flow 1.0, opacity 1.0) is pixel-identical to today (before/after snapshot
  diff — provably non-regressive).
- Frame time stays <8ms at 120 Hz; no `waitUntilCompleted` added.
- Old saved drawings still load.

---

### Phase 1 — Stabilization & input conditioning

**Delivers:** clean, confident strokes — StreamLine smoothing, stabilization, motion
filtering. The cheapest perceptible "feels pro" win after Phase 0, and it **survives
img2img** because it changes stroke geometry.

**Procreate panel:** Stabilization (StreamLine Amount/Pressure, Stabilization Amount,
Motion Filtering).

**Engine changes:** a CPU point-filter stage between touch capture and arc-length
resample, in front of `appendStampsForLatestPoints` (`MetalCanvasView.swift:778`).
StreamLine = pull stamp position toward a lagged anchor (exponential smoothing);
Stabilization = pull-toward-target spring. Pure CPU, upstream of the GPU, zero new passes.
The repo already has arc-length reparameterization plumbing
(`MetalCanvasView.swift:1736-1788`) as a sibling reference.

**Effort:** S–M.  **Risk:** Low–Med — the only risk is latency: StreamLine trades latency
for smoothness by design. Keep it a bounded-window filter, never block on future points
beyond coalesced touches, and tune conservatively against the <8ms budget. Expose Amount
so it's the user's call.

**Why second (pulled early):** it's input-side and independent of everything downstream,
and a stabilized, well-handled round brush already reads as professional. Two of the four
agents placed it later; the reconciliation pulls it up because it's the highest-leverage,
lowest-risk win available once opacity is fixed.

---

### Phase 2 — Stamp parameterization (cheap expressiveness, no new architecture)

**Delivers:** a real brush-settings surface over machinery already latent in the
pipeline — hardness, spacing, taper, scatter/count/roundness, pressure→opacity/flow,
speed→size. Turns one pen into a brush *family*.

**Procreate panels:** Stroke Path (Spacing, Jitter, Fall Off), Shape (Scatter, Count,
Count Jitter, Randomized, Flip X/Y, Roundness, Pressure/Tilt Roundness), Taper (pressure
size/opacity/tip, classic taper), Apple Pencil → Pressure & Tilt → size/opacity,
Dynamics → Speed.

**Engine changes (rough leverage order):**
- **Hardness:** replace the fixed `(1-r²)²` exponent (`CanvasRenderer.swift:1080-1107`)
  with a `hardness` uniform applied in `brushStampFragment` (`:1169-1176`) — a
  `smoothstep`-style remap so one mask serves the full soft↔hard range (the eraser
  already does this remap at `:1196`). Default reproduces today's look.
- **Spacing:** lift the hardcoded `* 0.3` (`:2203, 2235`) to `BrushConfig.spacing`.
- **Scatter / Count / Jitter / Roundness / Rotation:** all in `generateStampsForStroke`
  (`:2183-2249`) — perturb each `StampInstance` center, emit N dabs per step, set a
  non-uniform x/y radius, and *use* the `rotation` field the vertex shader already
  supports but is fed `0`. Needs a **deterministic per-stamp RNG seed** so undo/replay
  match the live stroke (the stroke is re-rendered from points; a wall-clock RNG would
  desync replays).
- **Taper / pressure→opacity / speed→size:** taper is a width/alpha ramp over normalized
  arc-length in the same loop; pressure→opacity feeds the now-separated flow; speed needs
  a velocity estimate from `StrokePoint.timestamp` (already captured).

**Effort:** M (mostly one file + a one-line mask-shader change + config fields).
**Risk:** Low–Med — the RNG-determinism trap above.

**Dependency:** finalizes the layered `BrushConfig` schema; do it before grain/shape so
those extend a stable schema rather than forcing extra persistence migrations.

---

### Phase 3 — Shape & grain (textured "real media") — *gated behind an img2img spike*

**Delivers:** custom shape stamps (chalk, charcoal, chisel, bristle nibs) and grain/paper
texture — the visual signature of non-digital media.

**Procreate panels:** Shape (custom shape source, Shape Filtering), Grain (Moving vs.
Texturized, Scale, Zoom, Depth, Rotation, Blend Mode), Rendering glaze modes.

**Engine changes:**
- **Shape:** generalize the single bound mask (`CanvasRenderer.swift:1080-1107, 1171`)
  into a *library* of loadable grayscale stamp textures (alpha = coverage). The shader
  already samples a mask — this is "bind a different texture" + an asset/import pipeline.
- **Grain:** a second texture sampled in canvas-space (Texturized) or stamp-space
  (Moving), modulating coverage by Depth. Canvas-locked mode needs canvas-space UVs
  passed from the vertex shader (`canvasPos` exists at `:1154`) to the fragment.

**Effort:** M–L — shader work is moderate; the **asset pipeline** (import/store/preview
brush shapes & grains) is the real cost and is mostly app-side.  **Risk:** Med, mostly
scope **plus an open product question**: fine grain may be re-interpreted or discarded by
the model.

> **GATE:** before building the grain asset pipeline, run a spike — draw a grainy stroke,
> push it through `fal-ai/flux-2/klein/realtime`, and check whether grain survives the
> diffusion pass. Custom *shape* stamps are safe (they change edge character / coverage,
> which conditions the model). *Grain* is built only if the spike shows it survives.
> Don't invest in grain fidelity the model overwrites.

---

### Phase 4 — Wet Mix / oil paint (the marquee feature)

**Delivers:** colors that physically mix and smear — oil/gouache/wet acrylic, plus smudge.
Blue dragged through yellow yields green-ish transitions; paint picks up and carries
underlying color. The user's headline ask.

**Why it's last — three prerequisites the engine doesn't have until now:**
1. A coherent flow/opacity accumulation model (Phase 0) — Dilution/Charge only mean
   something relative to a defined accumulation model.
2. A brush-side GPU destination-read reconciled with the scratch model. The eraser proves
   the primitive is safe (`CanvasRenderer.swift:1189-1199`), but the brush currently
   writes to the *scratch* while wet mixing must read the *accumulated canvas* — so wet
   brushes write closer to the eraser's direct-to-layer path. Reconciling that with
   Phase 0's scratch/flow model is this phase's core design problem.
3. A colorimetry decision (also a licensing decision — see below).

**Engine changes:**
- A `wetStampFragment` + PSO modeled on the eraser (programmable framebuffer read,
  `isBlendingEnabled=false`, async commit, no readback). Instead of `dst*(1-mask)` it
  computes a pigment mix of `dst`, a carried-paint color, and the brush color, weighted by
  Dilution/Charge/Attack/Pull.
- A small **per-stroke paint reservoir** (carried color + remaining volume) updated
  stamp-to-stamp: loads from canvas (Pull/Charge), unloads to canvas (Attack), depletes
  along the stroke, recharges on lift.
- **Smudge** = the zero-charge / pure-pull special case — read `dst`, carry it forward,
  redeposit. This finally delivers the Metal smudge deferred in `metal-canvas-rewrite.md`.
- Extend undo to wet brushes (they touch the layer directly — reuse the eraser's
  snapshot-at-`touchesBegan` pattern).

**Color model (licensing-critical):**
- Linear-space `mix()` (free, already linear via `_srgb` textures) removes muddiness but
  blue+yellow→gray — reads as *broken* for paint.
- **Mixbox** is the productized SOTA (ships a Metal shader + LUT) but is **CC BY-NC** — a
  shipping App Store app needs a **paid commercial license**. Do NOT ship it unlicensed.
- **Recommended:** a **free single-constant Kubelka-Munk approximation** in the wet
  shader (RGB→K-space, mix, invert) — blue+yellow→green-ish, ~80% of the perceptual win,
  zero licensing entanglement. Isolate it behind one shader function so a later licensed
  Mixbox swap is a one-function change.
- **Prioritize the K-M color work over perfecting reservoir physics** — color is what the
  model consumes, so it's the higher-leverage half for this product.

**Effort:** L (the biggest phase).  **Risk:** High — convergence of perf (per-touch
destination-read + reservoir updates, must stay async like the eraser), correctness
(linear-space + premultiplied-alpha pitfalls — the module CLAUDE.md is a minefield here),
the licensing/colorimetry call, and the fact that wet mix is notoriously tuning-heavy.

---

### Phase 5 — Brush management & polish

Brush library UI, preset import/export, per-brush previews, per-brush blend/render modes
(Glaze/Blend, Wet Edges, a curated 3–4 blend modes), and the long-tail Color Dynamics.

> Per `feedback_ipad_dev_toggles` / `feedback_direct_params`: ship a **curated preset
> library** (a dozen great brushes), not an on-device Brush Studio clone. A full parameter
> IDE serves power users we don't have yet; pre-launch tuning belongs in a dev panel.

**Effort:** M, ongoing.  **Risk:** Low–Med.

---

## What we will deliberately NEVER build (and why)

| Not building | Why |
|---|---|
| **Materials panel (Metallic / Roughness / PBR relighting)** | Relit-canvas sim with no 3D scene; the img2img model does its own lighting and obliterates it. Zero product leverage. |
| **3D grain, "grain follows camera"** | Materials-adjacent micro-detail the diffusion pass resynthesizes. |
| **Color Barrel Roll / full Barrel Roll dynamics** | Apple Pencil Pro hardware dependency; tiny audience, large input-plumbing cost. |
| **Full Photoshop blend-mode matrix / Luminance Blending / Burnt Edges** | Most are normalized away by the model; ship only the 3–4 that change value/hue meaningfully. |
| **Hover / Hover-fill cursor features** | UI polish, hardware-gated, trivially deferrable; low leverage on a landscape-locked single canvas. |
| **Mixbox under its NC license** | Not a "never build" of the capability — a never-*ship* of that dependency without a paid license (Critical Constraint #4 / App Store). Use the free K-M approximation. |

**Throughline:** the img2img model is the final renderer, so any feature whose value is
"the final pixels look exactly so" is low-value; features whose value is "the user feels in
control and the model gets richer intent" are high-value.

---

## Risk summary

1. **Licensing (Phase 4):** Mixbox is the obvious answer and the wrong one to ship
   unlicensed. Contained by architecture — isolate the color-mix function, ship K-M,
   treat Mixbox as a legal-gated upgrade.
2. **Perf (Phases 1 & 4):** stabilization adds latency by design; wet mix adds per-touch
   destination-read + reservoir updates. De-risked by the eraser, which already proves
   async programmable-blend RMW respects the invariants. Budget-test on the oldest target
   iPad early in Phase 4, not at the end.
3. **Scope (whole Brush Studio):** the "Never build" list is load-bearing — it cuts the
   bottom third of the parameter surface that returns ~nothing for this product.
4. **img2img coupling (Phases 3 & 4):** the canvas is a model input, not the final image.
   De-risks low-level fidelity (the model forgives small artifacts) but means grain/texture
   work must be spiked against the live model before the asset pipeline is built. Also
   reframes Phase 0 as a correctness fix and makes pigment color the priority inside wet
   paint.

## Quality-vs-effort frontier

Phases 0–1 are the steepest part of the curve: small, low-risk changes that move the app
from "obviously digital" to "feels like a brush," all img2img-durable. Phase 2 is linear
effort for linear polish. Phase 3 is gated. Phase 4 is the cliff — most of the remaining
engineering risk concentrated in the headline feature, worth it once its substrate exists.
If forced to ship "pro brushes" with finite time, **0 + 1 + 2 alone reads as pro to most
users**; 3 adds media character; 4 is the differentiator.

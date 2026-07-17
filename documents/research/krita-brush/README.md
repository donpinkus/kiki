# Krita Brush Engine — Deep-Dive Research (index)

**What this is.** A grounded, source-verified study of Krita's brush engine (`~/krita_src`) aimed at
making Kiki's Metal brush engine a **Krita-grade superset** — Krita as the *capability* ceiling,
Procreate parity as the floor. The organizing constraint: Kiki's canvas is **not a final artifact** —
it is a conditioning JPEG re-read by `fal-ai/flux-2/klein/realtime` every ~250ms, so img2img *leverage*
(what the model consumes vs. resynthesizes) sets *priority*, never *capability*. Read
[`_CONTEXT.md`](_CONTEXT.md) first — it is the shared grounding (goal, north star, our engine facts,
img2img frame, Krita source map, citation discipline).

## Executive summary

Twelve findings docs dissect Krita topic-by-topic; eleven of them independently converge on **one
conclusion**: Krita's expressive power is not a pile of named knobs but **one orthogonal abstraction** —
*any sensor → any parameter → its own response curve → a chosen combine operator → an output remap*.
Our committed plan (`documents/plans/unified-brush-engine.md`) gets the GPU *substrate* right (one
isolated Stroke Accumulation Buffer, bound-source reads, a single branch-free dab fragment, a 3-PSO
Glaze/Build-up/erase family, Simulator-safe) but models *dynamics* as Procreate's fixed coupling matrix.
[`PLAN.md`](PLAN.md) is the synthesis — an **in-place amendment** to the unified doc that replaces the
named couplings with Krita's general sensor+curve machine (reproducing **both** of Krita's runtime folds
verbatim), widens our 4-axis input model, adds the time/airbrush axis, the directional-smear axis,
arc-length speed-adaptive stabilization, lightness-map tips, and curve-driven color — all resolved
**CPU-side into `StampInstance`**, leaving the sacred <8ms GPU fragment untouched. It was then hardened
against four adversarial reviews ([`CRITIQUE.md`](CRITIQUE.md)): every finding was accurate on
re-verification; the keystone and substrate survived unchanged.

## Top 5 recommendations (priority order)

1. **Build Krita's sensor→curve→combine→remap machine as the keystone — and reproduce BOTH folds.**
   One `CurveOption`/`Sensor`/`ResponseCurve` layer (identity-curve fast-path) with the **size-like**
   fold (size/opacity/flow/spacing/ratio) AND the **rotation-like** fold (rotation/hue/scatter-angle/
   tilt-direction, with `wrapValue` + `2·offset` + `scalingToAdditive`). This is an amendment to the
   committed `BrushDescriptor`; the migration map reseeds it from today's scalars.
2. **Solve Glaze frame-rate-independence first (BLOCKING).** Confirm the **3-PSO family** (not "reduce
   to 1") yields identical flat self-overlap at varied dabs-per-frame — the cap must live in the blend
   hardware, not a written coverage value.
3. **Front-load the cheap high-leverage color work.** Per-stroke H/S + pressure→value(darken), baked
   into `StampInstance.color`, rides the same machine at zero shader risk and moves what klein reads
   first — pull it into P2 (done in `PLAN.md`).
4. **Fix the stabilization frame-rate-dependence bug.** Replace the per-touch EMA with arc-length
   speed-adaptive Gaussian smoothing + velocity-aware Bézier (curvature = the HIGH-leverage half;
   pressure smoothing = MED hand-feel).
5. **Defend the moat, gate the speculative.** Keep spectral Kubelka-Munk mixing (blue+yellow→green)
   and the carried-load reservoir (both exceed Krita); add the directional-smear axis Krita has but we
   lack. **Grain is a committed phase** — confirmed to survive img2img (Donald, 2026-06-20): build
   HEIGHT-mode *coarse value-grain* (skip only the fine paper-tooth, which klein resynthesizes).

## Document index

| Doc | One-line hook |
|---|---|
| [`_CONTEXT.md`](_CONTEXT.md) | Shared grounding: goal, north star (Krita-grade superset), img2img leverage frame, our engine facts, Krita source map, citation discipline. |
| [`00-krita-brush-architecture.md`](00-krita-brush-architecture.md) | The architectural spine — how paintop / preset / option / sensor / dab-rendering pieces fit together. |
| [`01-input-model-paintinformation.md`](01-input-model-paintinformation.md) | `KisPaintInformation` vs our 4-axis `StrokePoint` — the input axes we're missing (azimuth is free + high-leverage; the stale azimuth comment). |
| [`02-sensor-curve-architecture.md`](02-sensor-curve-architecture.md) | **The keystone** — every parameter is a response curve driven by sensors, combined and remapped; the fold math verbatim. |
| [`03-size-opacity-flow-dynamics.md`](03-size-opacity-flow-dynamics.md) | Size/opacity/flow/ratio + Build-up accumulation; flow as the Glaze↔Build-up target-alpha dial; avg-opacity hysteresis. |
| [`04-spacing-dab-placement-airbrush.md`](04-spacing-dab-placement-airbrush.md) | `min(distance,time)` makes airbrush fall out of the spacing loop for free; `sqrt` auto-spacing; dab caching. |
| [`05-brush-tips-mask-generators.md`](05-brush-tips-mask-generators.md) | Procedural tip mask math (soft/gauss/curve, circle/rect) — our `(1-r²)²` is one point; editable falloff curves. |
| [`06-shape-dynamics-scatter-rotation.md`](06-shape-dynamics-scatter-rotation.md) | Scatter/rotation/flip/jitter + the Fuzzy sensor; deterministic RNG — and why stateless hashing beats Krita's stateful taus88 for us. |
| [`07-texture-grain.md`](07-texture-grain.md) | Grain as HEIGHT-mode (height map + pressure as water level) + strength-as-curve, not scalar MULTIPLY — **coarse value-grain confirmed to survive img2img (2026-06-20); committed phase**. |
| [`08-colorsmudge-wet-engine.md`](08-colorsmudge-wet-engine.md) | Krita's smudge/wet engine — smear-vs-dull orthogonality + displaced source reads; where our spectral KM + carried-load reservoir exceed it. |
| [`09-color-dynamics-source.md`](09-color-dynamics-source.md) | Color dynamics as (H/S/V channel)×(sensor+curve); gradient-along-stroke; skip `TOTAL_RANDOM` (non-deterministic). |
| [`10-stabilization-smoothing.md`](10-stabilization-smoothing.md) | Krita's smoothing modes — arc-length-weighted, speed-adaptive σ, velocity-aware Bézier; our EMA's frame-rate-dependence bug. |
| [`11-specialty-paintops-idea-mining.md`](11-specialty-paintops-idea-mining.md) | The superset beyond Procreate — bristle/sketch stamp-gen strategies + filter-brush category; what to skip (particle/grid/hatching). |
| [`12-masked-dual-brush-compositing.md`](12-masked-dual-brush-compositing.md) | Masking (dual) brush + per-dab compositing; **lightness-map tips** (highest-leverage/lowest-cost); curated value blend modes. |
| [`PLAN.md`](PLAN.md) | **The actionable synthesis** — keystone + 9 phases, an amendment to `unified-brush-engine.md`, with the revision log of how critiques were addressed. |
| [`CRITIQUE.md`](CRITIQUE.md) | The four adversarial reviews (Krita fidelity / Metal feasibility / img2img prioritization / architecture coherence) + per-finding resolution and re-verification evidence. |

## How to read this

- **Just want the plan?** → [`PLAN.md`](PLAN.md). Start at §0 (the spine) and §4 (the phased plan).
- **Want to know it's sound?** → [`CRITIQUE.md`](CRITIQUE.md) + `PLAN.md §8` (revision log).
- **Want the grounding for a specific feature?** → the numbered findings doc, each with: how Krita does
  it (with math + `krita: path:line`), how we do it today, gap analysis, the img2img leverage call, and
  Metal translation notes.

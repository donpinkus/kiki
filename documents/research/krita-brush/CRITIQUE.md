# PLAN.md — Adversarial Critique Record

**Purpose.** Preserve the reasoning behind the final `PLAN.md`. Four independent adversarial reviews
were run against the draft plan, each through a different lens. This document summarizes each review,
its findings (severity + the one-line crux), and how each was resolved. The authoritative
finding→resolution table lives in `PLAN.md §8 (Revision log)`; this doc adds the *why* and the
re-verification evidence.

All disputed claims were re-opened against the actual Krita source at `~/krita_src` and our code during
resolution. **Every finding was accurate on re-verification — none was rebutted.** All four reviews
graded the plan **sound-with-fixes**: the keystone architecture and the committed substrate are
correct; the defects were in precision, cost framing, phase ordering, and doc-coherence.

---

## Review 1 — Krita fidelity (re-verify every Krita claim against `~/krita_src`)

**Verdict:** sound-with-fixes. The keystone and all load-bearing structural claims (sensor+curve+combine
machine, identity fast-path, smudge smear-vs-dull orthogonality with displaced srcRect, colorRate²,
AlphaDarken flow-lerp, arc-length speed-adaptive stabilization, min(dist,time) spacing, sqrt
auto-spacing, scatter formula, lightness quadratic, HEIGHT grain composite, HSV-as-curve-options,
per-stroke RNG, smudge-radius averaging, sample-rate speed estimator, masking "don't erase below"
clamps) all check out. Defects are precision, not substance.

| Finding | Sev | Crux | Resolution |
|---|---|---|---|
| 1 | Major | §2.1 states only `sizeLikeValue`; rotation/hue use `rotationLikeValue` (`2·offset`, `wrapValue`, `scalingToAdditive`). HSV splits: hue→rotation-like, S/V→size-like. | FIXED — §2.1 now quotes both folds; re-verified `KisCurveOption.cpp:61-88`, `KisHSVOption.cpp:44-53`. |
| 2 | Minor | §P9 cited a Color-Burn helper, not the curated enum; "70→10" wrong. Actual: ≈148 → ≈15, all value/luminosity (substance *understated*). | FIXED — repointed to `KisMaskingBrushCompositeOp.h:25-41` + `KoCompositeOpRegistry.h`; figures corrected. |
| 3 | Minor | Smear-vs-dull orthogonality is the `m_useDullingMode` ctor flag (`:113-114/:123/:192`), not `:184` (`blendBrush`). | FIXED — citation corrected; re-verified. |
| 4 | Minor | Hysteresis exponent 0.1 is at `:95` not `:94`; rises immediately, falls by EWMA (`:99-103`) — the asymmetry is what carves notches. | FIXED — cited `:95` in `:93-105`; asymmetry documented. |
| 5 | Minor | Speed sensor presented estimator-only; Krita has `useTimestampsForBrushSpeed` (`:103`, default false). iPad timestamps may be reliable → tuning choice. | FIXED — §2.2 + risk #4 note both paths; framed as a port decision. |
| 6 | Minor | Gradient Distance→`mix` coupling stated verified at `:119`; only the scalar `mix` is there (`pi` unused). Coupling is caller-side. | FIXED — §2.9/§P6 mark it inferred. |

**Re-verification this turn:** read `KisCurveOption.cpp:55-169` (both folds + dispatch),
`KisHSVOption.cpp:30-58`, `KoCompositeOp.cpp:88-105`, `KisColorSmudgeStrategyBase.cpp:108-196`,
`KisMaskingBrushCompositeOp.h:24-43,555-580`, `kis_color_source.cpp:110-125`. All confirmed.

---

## Review 2 — Metal feasibility + perf invariants (CanvasModule)

**Verdict:** sound-with-fixes. The plan correctly keeps the keystone CPU-side (no fragment change, no
GPU round-trip) and forecloses the fragment-sampled-LUT trap; the wet rework correctly targets the one
verified shipped anti-pattern (per-dab 1px `getBytes` at `CanvasRenderer.swift:585`). The four genuine
risks are all flagged by the draft as open items; the fixes are sharpenings.

| Finding | Sev | Crux | Resolution |
|---|---|---|---|
| 1 | Major | "Strictly cheaper than getBytes" hides that P1 adds N LUT-evals to the per-event main-thread `.shared`-buffer-write path; identity fast-path doesn't cover the high-leverage presets. | FIXED — §P1 baseline reframed to one `effectiveWidth`/dab; vertex-stage escape hatch first-class; dense-scatter+color 240Hz benchmark is a **P1 exit gate**. |
| 2 | Major | Falloff-LUT called "cheaper than today's branchy shader"; current round fragment (`:1520-1529`) is branch-free ALU with `fwidth` AA. LUT loses self-AA + adds a fetch. | FIXED — §P4b justifies the LUT on generality, gates it behind `hasFalloffLUT`, keeps analytic default + self-AA. |
| 3 | Major | Lightness-map "two-line change" contradicts the gamma-oracle requirement; adds RGB→HSL per dab in a linear-`_srgb` fragment. | FIXED — §2.8/§P4a: color-sensitive change gated by an offline oracle; **prefer CPU pre-bake** (tipLuma constant per dab) off the fragment. |
| 4 | Major | Widening `StampInstance` (28 → ~56 bytes) doubles the per-dab main-thread memcpy at 4096 stamps/frame; treated as free. | FIXED — §P1 keeps the instance minimal; wet-only fields → separate wet-only layout; width benchmarked in the P1 exit gate. |
| 5 | Minor | `smearVector` is per-dab (inter-dab travel), not a per-stroke uniform; displaced reads can miss the dirty-bbox `sabPrev`. | FIXED — §2.5/§P7: rides `StampInstance`; expand the `sabPrev` blit bbox by max smear magnitude. |
| 6 | Minor | Held-still airbrush marks dirty every frame → defeats the "only renders when dirty" idle optimization (600px stress case on a *hold*). | FIXED — §2.4/§P5: deposit at the airbrush rate, not the display rate. |
| 7 | Minor | P0 "6-PSO → 1-PSO" reopens unified rejection #6: cap-vs-accumulate are different blend equations; a single source-over PSO can't express both across frames. | FIXED — see Review 4 major below; §2.3 reframed to "confirm the 3-PSO family + prove frame-rate-independence." |

**Re-verification this turn:** `CanvasRenderer.swift:153-159` (StampInstance = 6 fields / 28 bytes),
`:1520-1529` (branch-free analytic falloff + fwidth AA), `CanvasModule/CLAUDE.md` color rules.
All confirmed.

---

## Review 3 — img2img leverage + prioritization

**Verdict:** sound-with-fixes. The keystone decision is correct and exactly grounded; the **phase
ordering inverted its own leverage ratings** — the highest-model-leverage capabilities (color P6, wet
P7 "HIGHEST") were sequenced near-last behind lower-leverage curvature/tip/airbrush fidelity, because
the ordering implicitly optimized "cheap-CPU-first / risky-on-proven-base-last" over
"highest-model-leverage-first."

| Finding | Sev | Crux | Resolution |
|---|---|---|---|
| 1 | Major | Color (P6) + wet (P7) HIGHEST-leverage sequenced near-last; the cheap high-leverage color bake rides the same machine and should lead. | FIXED — per-stroke H/S + pressure→value pulled into **P2**; lightness-map split out as early **P4a**. |
| 2 | Major | P4 bundles highest-leverage lightness-map with lower-leverage falloff-LUT behind LUT-aliasing + gamma risk; P8 grain leverage is an unmeasured inference yet a full phase. | FIXED — unbundled into **P4a/P4b**; **P8 grain demoted to a survival-spike-gated experiment**. |
| 3 | Minor | P5 airbrush before P7, but the combined wet+airbrush 600px budget is the actual risk. | FIXED — §P5 gates on a dry-only budget test; wet+airbrush co-enablement forbidden until P7's spike passes. |
| 4 | Minor | P3 rated HIGH overall; the pressure/tilt-smoothing half is hand-feel, lower leverage at a live feed. | FIXED — §2.6/§P3 split: Bézier curvature HIGH (ship first), smoothing MED (conservative σ). |
| 5 | Minor | Wet P7 HIGHEST buried last; some wet wins (directional smear, getBytes-removal) don't need the substrate. | FIXED — getBytes-removal/smudge-radius noted as already-committed; directional smear is the new term; GPU-reservoir KM legitimately needs the SAB → stays P7. |
| 6 | Minor | P2 lists size-jitter speckle as a shipped preset though the draft concedes Fuzzy is lowest-leverage. | FIXED — de-scoped per-dab speckle presets (machine kept, preset dropped). |

---

## Review 4 — Architecture coherence vs the committed `unified-brush-engine.md`

**Verdict:** sound-with-fixes. The plan integrates cleanly with the committed substrate on every
load-bearing rule (SAB/bound-source, flat-projection invariant, no `wetEnabled`/no per-feature branch,
keystone math verbatim). The coherence breaks are doc-divergence and one strawman, not architecture.

| Finding | Sev | Crux | Resolution |
|---|---|---|---|
| 1 | **Blocking** | The plan restructures the committed `BrushDescriptor` (CurveOption machine replacing named buckets) but never says to amend `unified-brush-engine.md` — leaving two canonical docs disagreeing + silently invalidating the Step-0 migration map (`unified:264`, which has no CurveOption concept). | FIXED — header + §2.1 declare this an **in-place amendment to unified §2.1/§2.3/§6-Step-0**; migration map rewritten to seed CurveOptions from today's scalars (`pressureGamma`→Pressure size-CurveOption, `tiltSensitivity`→TiltElevation size-CurveOption). Unified is the system-of-record. |
| 2 | Major | §2.3 "6-PSO → 1-PSO" attacks a strawman — unified §3.6 already uses 2 blend-state PSOs (3 w/ eraser), 4 Glaze = 1 uniform — and the "single source-over PSO" idea reopens rejection #6. Flow-as-target-alpha (the verified AlphaDarken evidence) is orthogonal to the cap-vs-accumulate blend equation; the draft conflated them. | FIXED — §2.3 rewritten: 3-PSO family is the load-bearing floor; flow adopted as the per-dab target-alpha enriching the existing coverage-curve uniform; P0 task reframed as "confirm 3 + prove frame-rate-independence." |
| 3 | Minor | §2.5 over-claims getBytes-removal + smudge-radius as plan additions; both already committed in unified §3.3/§4. Only the directional-smear axis is new. | FIXED — §2.5/§P7 scope these as "enrich the committed Pass A"; only directional smear claimed new. |
| 4 | Minor | "Bristle mode"/"proximity-connect mode" invites the banned per-feature render branch; they are CPU stamp-gen (same class as scatter). | FIXED — renamed "stamp-generation strategy," stated to use the unchanged unified dab fragment with no new render branch; filter-brush kept as the one new *category*. |
| 5 | Minor | Citation-path imprecision (bare paths, line drift, HEIGHT-branch ambiguity, azimuth-comment line). | FIXED — all Krita citations normalized to full path; azimuth comment confirmed at `CanvasRenderer.swift:156`; HEIGHT formula disambiguated (non-soft `:575-577` vs soft `:569-573`). |

**Re-verification this turn:** `unified-brush-engine.md §3.6` (2 blend-state PSOs, 4 Glaze = 1 uniform,
`:189-196`), §7 rejection #6 (`:306`), §6 Step-0 migration map (named scalars, no CurveOption),
`KoCompositeOpAlphaDarken.h:96-137` (flow lerps the target alpha). All confirmed; the strawman and the
blocking doc-divergence are both real.

---

## Summary of the resolution posture

- **1 blocking finding** (declare the plan an amendment to the unified doc + rewrite the migration map)
  — FIXED.
- **7 major findings** (rotation-like fold; CPU-bake cost framing; falloff-LUT perf claim;
  lightness-map cost; StampInstance width; the PSO strawman ×2 reviews; phase-ordering inversion ×2) —
  all FIXED.
- **~12 minor findings** (citation hygiene, smear-vector placement, airbrush dirty-frame, σ split,
  speckle de-scope, gradient-coupling inference, naming, scoping) — all FIXED.

No finding was rebutted. The keystone (one orthogonal sensor→curve→combine→two-fold-remap machine,
CPU-resolved into `StampInstance`, GPU fragment untouched) and the substrate (SAB / bound-source /
3-PSO family) survived every lens unchanged; the critiques tightened citations, corrected the
PSO/cost framing, reordered for model-leverage, and bound the plan to the committed `unified-brush-engine.md`
as a single system-of-record.

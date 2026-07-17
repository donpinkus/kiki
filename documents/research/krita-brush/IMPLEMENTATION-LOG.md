# Krita-Grade Brush Dynamics — Implementation Log

**Branch:** `feature/canvas-krita-brush-dynamics` (abandonable; not pushed).
**Goal:** implement the `PLAN.md` keystone (sensor→curve→combine→remap machine) + high-leverage
phases, on the existing engine, **without ever regressing the default pen** (sacred canvas).

This log is the running record for review. Newest section at the bottom. Every step:
builds green (xcodebuild iPad Pro 13" M4 sim), passes offline correctness tests, and is
reviewed by independent agents grounded in Krita + our perf invariants.

> **The one thing only Donald can verify:** the *feel* of dynamic brushes on a real device.
> The Simulator can't get past Sign in with Apple to the canvas, and the wet path is
> device-only. Everything else (compile, math correctness, default-pen non-regression by
> construction, determinism) is verified here. See the **Device verification checklist** at the end.

---

## Foundation (committed earlier) — the engine + data model

- `BrushDynamics.swift` — the sensor+curve machine: `ResponseCurve` (control points → 256-LUT,
  monotone cubic), `BrushSensor` (pressure/speed/tilt-elevation/tilt-direction/drawing-angle/
  distance/fade/fuzzy×2), `CurveOption` (both Krita folds + 5 combine modes + min/max remap),
  `StrokeDynamicsState` (arc-length/dab-index/speed/heading accumulator), stateless-hash RNG.
- Data model (additive, backward-compatible): `StrokePoint.azimuth`, `BrushConfig.dynamics`
  (both `decodeIfPresent` → default = today's pen exactly).
- Verified: 30+ offline asserts vs Krita reference formulas (`OfflineTests/`).

---

## P1 — Wire the engine into the live stroke loop  ✅ (committed `81b7ea0`, then hardened)

**What:** `generateStampsForStroke` now resolves per-dab **size / flow / rotation** through the
curve machine when a brush has non-inert `dynamics`, via a `dabAttrs()` helper threaded with a
per-stroke `StrokeDynamicsState`. Azimuth is captured from `UITouch` (pencil only). The
per-stroke RNG seed is a stable FNV-1a hash of the stroke UUID (replay-stable across launches).

**Non-regression (the sacred guarantee):** when `dynamics == nil` (default pen + every legacy
brush), `dabAttrs` takes a `!hasDyn` early-return that yields **exactly** today's values
(`effectiveWidth` / constant premultiplied color / shape rotation). Byte-identical by
construction. All three review agents independently confirmed this.

**Determinism:** state rebuilds per frame from the full point list (the fn re-runs each frame),
so live-preview / replay / undo are identical for the same points + seed.

### P1 review round (3 independent adversarial agents) + fixes

| # | Sev | Finding | Resolution |
|---|---|---|---|
| B1 | **BLOCKING** | `ResponseCurve` LUT re-baked **per dab per frame** — the lazy/mutating cache was written to a throwaway value-copy in `SensorChannel.parameter` and discarded. Blows <8ms for any dynamic brush. | **FIXED.** `ResponseCurve` is now immutable (`points` is `let`) with an **eagerly-baked LUT** (once at init/decode); `value()` is a pure read; copies share the LUT via COW. Zero per-dab bakes. |
| M3 | major | Speed sensor was dab-density-dependent (segment `dt` reused N times into a fixed-weight EMA). | **FIXED.** Time-constant EMA (`alpha = 1−e^(−dt/τ)`) + per-dab step `dt`/displacement, so speed response is density-independent. |
| §4 | minor | Premultiplied flow alpha unclamped (a brush with `flow.maxValue>1` → malformed alpha). | **FIXED.** `a = clamp(0,1, baseFlow·flowMul)`. |
| m7 | minor | Azimuth interpolated linearly across the 0/2π seam (chisel spins the long way). | **FIXED.** Shortest-arc delta before lerp. |
| m11 | minor | `ResponseCurve.points` was a mutable `var` (stale-LUT footgun). | **FIXED.** Now `let` (immutable). |
| — | minor | Header overclaimed "mirrors Krita verbatim" (tiltElevation/speed are iOS input substitutions; distance/fade single-mode). | **FIXED.** Header documents the deliberate divergences + substitutions. |
| — | minor | Dead sRGB→linear compute on the legacy path. | **FIXED.** `baseLinRGB` gated behind `hasDyn`. |
| tests | — | Coverage gaps: `.add`/`.difference`, rotation fold w/ scaling+additive+flipped, non-identity curves on additive/absolute sensors, normalizations. | **FIXED.** Added all; 30 asserts pass. |

Math fidelity verdict (Krita line-by-line): **sound** — folds, combine modes, fold routing,
sensor folding, the scalar helpers, and `wrapValue` all match Krita exactly. Only the two
declared divergences (monotone-cubic LUT, stateless RNG) differ, both sound.

**D18 (noted, not a bug):** the end cap advances stroke state for the terminal point. In the
normal case the end cap is a genuine distinct dab (the interior loop stops before the endpoint),
so this is correct; only if the last interior dab exactly coincides with the endpoint is there a
one-dab double-count. Deterministic either way. Documented; not restructured.

---

## P2 — Curated preset catalog  ✅ (in progress)

`BrushPresets.swift` — four presets that make the keystone tangible, each authored from
offline-verified curves:
- **Inker** — pressure → size (min 0.15) + flow (min 0.4); crisp, tight spacing.
- **Soft Pencil** — pressure → size via a soft `gamma(1.6)` ramp; light deposit.
- **Speed Pencil** — size = pressure × descending speed curve (fast = thinner); `useSameCurve=false`
  so the speed channel uses its own curve (the Krita per-sensor-curve subtlety).
- **Calligraphy** — drawing-angle → rotation (rotation-like fold) on an oriented "ink" tip;
  pressure → size.

Preset dynamics verified offline (`/tmp` harness: size rises with pressure, speed-taper thins,
calligraphy rotation tracks heading). The preset → BrushConfig wrapper preserves the user's
color / baseWidth / opacity.

### P2 continued — scatter + per-stroke color jitter  ✅

- **Scatter** (`BrushDynamics.scatter`): per-dab random center displacement (magnitude = curve
  value × dab diameter), independent seeded X/Y draws. Displaces only the rendered stamp; the
  spacing/path walk uses the un-scattered point. Krita `KisScatterOption`.
- **Per-stroke color jitter** (`BrushDynamics.colorJitter` = `ColorJitter{hue,saturation,brightness}`):
  one coherent HSV shift per stroke (NOT per-dab speckle, which img2img averages out), applied in
  sRGB-HSV then converted to linear. Pure sRGB↔HSV helpers added + offline-verified (round-trip,
  no-op at r=0.5, changes color otherwise).
- Presets added: **Stipple** (wide spacing + scatter) and **Pastel** (soft size + subtle
  per-stroke color jitter). Offline suite now 40 asserts, all pass.

> **Not yet wired into the production brush-picker UI** — those files (AppCoordinator /
> SettingsPanel / brush controls) are mid-edit by the in-progress overlay-mode work, and I'm
> avoiding conflicts with it. Wiring a preset picker is a small follow-up (apply
> `BrushPreset.applied(to:)` to the active brush). See the checklist.

---

## P3 — Stabilization: frame-rate-independence fix  ✅ (committed `99ff437`)

The streamline low-pass applied a **fixed pull factor per coalesced touch**, so it smoothed ~2×
harder at 120 Hz than 60 Hz and gave a flick and a crawl the same lag (the concrete bug the
Krita-stabilization research flagged). Now the factor is **time-constant-derived**:
`factor = 1 − e^(−dt/τ)`, τ scaling with `streamline`, so steady-state lag is event-rate
independent. **Default (`streamline == 0`) is unchanged** (early return).

**Deliberately bounded:** the full **velocity-aware Bézier** rebuild and the exact `streamline→τ`
curve are *device-tuning* work — stabilization feel is subjective and can't be validated in the
Simulator, so I fixed the provable bug and left the feel-tuning for a device session (PLAN.md P3).

---

## P4 — v1 Smudge  ✅ (committed next)

`BrushConfig.wetSmudge` (Bool, backward-compatible) + `BrushConfig.smudge(...)` factory. With
`wetEnabled`, the carried paint load is **seeded from the canvas color under the first dab**
instead of the brush ink — so the brush pushes existing color around (Procreate-style smudge) and
introduces no new ink. The existing carried-load + Smear machinery does the rest. `wetStrength`
(Mix) = redeposit strength; `wetPickup` (Smear) = how fast it re-grabs canvas color.

**Limitations (v1):** device-only (inherits the wet render path — the wet PSO is nil on the
Simulator); on blank canvas it falls back to ink; it smears *committed* paint (in-flight
self-smear needs the SAB rework). A true displacement-drag smear is the P7 SAB follow-up. **I could
not feel-test this** — only confirmed it compiles.

---

## Build & verification status

Every commit: **BUILD SUCCEEDED** (iPad Pro 13" M4 sim). Offline correctness: **40 asserts pass**
(`OfflineTests/`, re-run per README). Default-pen non-regression: **by construction** (every new
behavior gated behind non-inert `dynamics` / `wetSmudge`; legacy branches unchanged) — and the P1
review confirmed it byte-identical.

## What is NOT done / deferred (honest list)

- **UI wiring** — no preset picker / smudge-tool button in the shipping UI yet (avoided the
  overlay-mode WIP that owns those files). Engine + presets are ready; wiring is small.
- **Device feel-tuning** — dynamic-brush feel, stabilization τ curve, smudge strength: all need
  Donald's device. Numbers in presets are sensible starting points, not final.
- **P5–P9** (airbrush/time-axis, editable tips, grain HEIGHT-mode, masking/blend modes, bristle
  families) and the **P7 SAB wet rework** (true displacement smear, Simulator-safe wet, GPU
  reservoir) — not attempted overnight; they're larger GPU reworks better done with device
  iteration. The keystone (P1) is the unlock; these layer on it.

## Final review round — P2/P3/P4 (3 independent agents) + fixes

All three verdicts: **APPROVE / PASS / GO** — no blocking or major findings. Independently confirmed:
the LUT-cache fix eliminates per-dab spline bakes; the default pen is byte-identical across P1–P4
(incl. the `stepFrac` scaling — `atan2` is scale-invariant); commit integrity is clean (no overlay
leak, no dropped hunks; HEAD builds + offline tests pass in a fresh worktree); scatter/color are
faithful to Krita; Codable migration is safe.

Minor items, all **FIXED** in the final review-fix commit:
| Finding | Fix |
|---|---|
| Scatter+lasso clip tested the *un-scattered* point → dabs could bleed ≤0.7×diameter past the clip edge | Clip-test the **scattered** point at all 3 emission sites (default pen unaffected — offset is `.zero`). |
| Per-dab `[Double]` heap alloc in `computeComponents` (dynamics path only) | Rewrote combine to track running product/sum/max/min inline — **alloc-free**, behavior-identical (all 5 combine modes still pass offline). |
| Stabilization could "catch-up jerk" after a long hitch (dt→large → factor→1) | Clamp `dt` to ~4 frames. |
| Test gaps | Added scatter-determinism + X/Y decorrelation + gray/black HSV round-trips. Offline suite now **67 asserts, all pass**. |

## Brush Studio dev panel + third review round (3 agents, incl. dev panel)

Added `BrushStudioView` — a live tuning panel (sensors / response-curve drag / combine / strength·min·max / color jitter / smudge / preset loader), opened from the brush gear popover, applied to the active brush in real time via `AppCoordinator.toolDynamics`.

Third review round verdicts: **GO (non-regression/e2e/rebase) · GO-WITH-FIXES (dev panel) · GO for P5–P9 (fidelity/perf/arch)**. The rebase onto main+overlay merged coherently; default pen still byte-identical; offline 40/40 + Codable safe. Fixes applied:

| Finding | Sev | Fix |
|---|---|---|
| **H1** TiltElevation inverted vs Krita (perp should be 1) | high | Flipped to `altitude/(π/2)`; offline tests updated. (No shipped preset used it → no regression.) |
| **H2** `opacity` CurveOption decoded but never consumed (dead control) | high | **Deleted** the field (Glaze opacity is a per-stroke ceiling, not a per-dab sensor; flow covers the per-dab feel). |
| **M6** `wetEnabled`/`wetSmudge` are mode-toggles | med | Annotated "deleted at the SAB rework / P7 — do not extend." |
| **M1** curve editor desync (load preset → drag clobbers curve) | major | Re-seed control points `.onChange(of: curve)` unless mid-drag. |
| **M2** editing curve silently drops per-sensor curves (Speed Pencil) | major | Seed from the first real per-sensor curve + warn that editing collapses to one shared curve. |
| **m1** sheet-from-popover may auto-dismiss on iPad | minor | Present the Studio from the **sidebar** (stable parent) via `coordinator.showBrushStudio`, not from inside the popover. |
| **m2/m3** strip-all-sensors / min>max | minor | Caption when sensors empty; clamp `min ≤ max`. |
| Enum persistence stability (review INFO) | info | Comment: `BrushSensor` cases + `CombineMode`/`BrushFold` ints are now append-only (in saved JSON). |
| **P1 exit-gate** never built | process | Added an offline per-dab timing harness. Worst-case (4 CurveOptions, multi-sensor) ≈ **180 ns/dab** → ~0.7 ms for 4000 dabs: the dynamics math is well within the 8 ms budget. |

### H3 — open follow-up (perf, NOT done)
`generateStampsForStroke` re-walks the **entire** point list every frame (pre-existing; the dynamics multiply the constant). The per-dab math is cheap (timing above), but a very long held stroke is O(total points) per frame. **Follow-up:** incrementalize stamp-gen to only re-walk new points (helps the legacy path too); needs device profiling. Documented, not landed blind. Also fidelity nits deferred to device-tuning: speed normalization (`maxSpeed`) and HSV S/V jitter form differ slightly from Krita (round-trip/`.kpp`-import only).

## Device verification checklist (for Donald)

1. **Build + run on device** (not Simulator — canvas needs past Sign-in; wet path is device-only).
2. **Non-regression first:** draw with the default pen — must feel/look exactly as before. Save a
   drawing, reopen — strokes intact (StrokePoint/BrushConfig schema changes are backward-compatible).
3. **Dynamics:** set the active brush to each preset (`BrushPresetCatalog.all`) — quickest path is a
   temporary dev button calling `coordinator.brush = preset.applied(to: coordinator.brush)`:
   - *Inker* — width + darkness rise with pressure.
   - *Speed Pencil* — fast strokes thin out.
   - *Calligraphy* — the "ink" tip orients to stroke direction (thick/thin edges).
   - *Stipple* — broken, scattered dab field.
   - *Pastel* — successive strokes vary slightly in color.
4. **Tilt/azimuth:** a tilt-driven brush should respond to pencil tilt direction (chisel feel).
5. **Smudge:** `BrushConfig.smudge()` over existing paint — should drag/blend color, add no new ink.
6. **Perf:** dynamic brushes (esp. Stipple/scatter) must hold 120 Hz / <8 ms — watch for hitching.
   The per-stroke LUT-cache fix should keep it cheap; confirm on the oldest target iPad.
7. **Determinism:** draw a scatter stroke, undo, redo — the scattered dabs must land identically.

## P4b (aspect half) + rotation-output validation — 2026-07-15

**Aspect-ratio tips shipped** (`BrushConfig.aspectRatio`, default 1, backward-compatible
Codable): packed as `StampInstance.aspect` — it fits in the struct's existing 12-byte tail
padding (SIMD4 alignment), so the stride stays 48 and no buffer plumbing changed — and
applied as a **vertex-stage local-Y squash before rotation** in `brushStampVertex`.
Because texCoord is untouched, every fragment (procedural falloff, shape mask, wet KM)
lands on an elliptical footprint with zero fragment cost; eraser defaults to 1 (unchanged).
"Aspect" slider (0.1–1.0) added to the brush settings popover. The falloff-LUT half of P4b
(generality, explicitly not perf) remains unbuilt.

**Rotation output validated visually** (the last unverified dynamics output, closing the
handoff's item 1) — via BrushHarness, no device round-trip:
- `dry-05-aspect`: round → ellipse → blade footprints at aspect 1.0/0.4/0.15.
- `dry-06-calligraphy-rotation`: a fixed-45° flat nib (no-sensor rotationLike folds to its
  constant strength; 0.25 turns = π/4) produces the classic thick/thin italic S-curve, and
  a Distance-driven rotation visibly spins the nib along a straight stroke.
Scatter + color jitter were already confirmed by `dry-03-dynamics` (2026-07-14).

Verified: offline suite ALL PASSED, full 9-scene harness battery renders, app builds
(iPad sim). Fixture-replay caveat recorded in HANDOFF item 2: fixtures store canvas-pixel
positions (~2.7× view points), so Speed-sensor brushes replay faster in the harness than
they felt on device — tune maxSpeed on device.

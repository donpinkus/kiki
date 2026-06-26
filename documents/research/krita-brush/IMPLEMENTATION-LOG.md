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

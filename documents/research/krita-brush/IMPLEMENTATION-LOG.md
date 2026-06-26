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

> **Not yet wired into the production brush-picker UI** — those files (AppCoordinator /
> SettingsPanel / brush controls) are mid-edit by the in-progress overlay-mode work, and I'm
> avoiding conflicts with it. Wiring a preset picker is a small follow-up (apply
> `BrushPreset.applied(to:)` to the active brush). See the checklist.

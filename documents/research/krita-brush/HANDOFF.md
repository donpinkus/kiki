# Handoff: Krita-grade brush dynamics + wet paint (Kiki iOS)

> **Handoff written:** 2026-07-15 00:28 PDT
> **As-of state:** branch `feature/canvas-krita-brush-dynamics` @ `1e3a2e8` (fast-forward ahead of `main` @ `4b1db93`).
> This is a point-in-time snapshot for a fresh agent to continue the work. Verify against current
> code/git before trusting any file:line or "done/next" claim below — the repo is the source of truth.

## What this is
Kiki is an iPad sketch-to-image app (SwiftUI + a custom **Metal** brush engine in `ios/Packages/CanvasModule/`). We're rebuilding the brush engine to be a **Krita-grade superset**: any Pencil input (pressure, speed, tilt, azimuth, stroke-angle, distance, fade, randomness) can drive any brush parameter through an editable response curve — plus a wet/smudge paint path with spectral color mixing. The canvas is *not* the final artifact; it's a conditioning image re-rendered by `fal-ai/flux-2/klein/realtime` every ~250ms, so "img2img leverage" (what the model actually sees) sets priority.

## Current state (verified 2026-07-15)
- **Branch:** `feature/canvas-krita-brush-dynamics` @ `1e3a2e8`. It's a clean **fast-forward ahead of `main`** (main is at `4b1db93`, the overlay-mode commit).
- **All brush work is committed.** Nothing under `ios/` is uncommitted.
- **Still uncommitted:** a *separate* backend thread (fal keep-warm `falWarmer`, `falConnectionLog`, Insights "Ops" page, `stream.ts`/`schema.sql`/`config` + the fal-billing notes in root `CLAUDE.md`). Not brush-related; commit it on its own.
- **Not yet done:** merging the branch → `main` (Donald wants this; it's a fast-forward).

## The engine (keystone architecture)
Read `documents/research/krita-brush/PLAN.md` §0–2 first. The core idea (Krita's, verified against `~/krita_src`): **one orthogonal machine** — `sensor → its own response-curve LUT → combine operator → output fold → clamp/remap`, all resolved **CPU-side per dab** and baked into `StampInstance`; the GPU fragment is untouched. There are **two folds**: `sizeLike` (clamp) for size/opacity/flow/scatter, `rotationLike` (wrap) for rotation/hue.

Key files in `ios/Packages/CanvasModule/Sources/CanvasModule/`:
- **`BrushDynamics.swift`** — the keystone: `ResponseCurve` (eager-baked 256-LUT), `BrushSensor` (9 sensors), `CurveOption` (both folds + 5 combine modes), `StrokeDynamicsState` (arc-length/speed/heading accumulator), `BrushInputSample` (live HUD), stateless-hash RNG.
- **`StrokeStampGenerator.swift`** — the dab pipeline (extracted from MetalCanvasView; pure, headless-compilable).
- **`WetStrokeWalker.swift`** + **`WetKM.swift`** — wet/smudge path + spectral Kubelka-Munk color mixing (`straightLinear` texel recovery — see Gotchas).
- **`BrushPresets.swift`** — currently the **10 control-isolation TEST brushes** (dev harness), not real presets.
- **`BrushFixture.swift`** — recorded-stroke fixtures for replay.
- `CanvasRenderer.swift` (now UIKit-free), `MetalCanvasView.swift` (slimmed ~434 lines).

## The dev loop (the big unlock — no iPad needed for most work)
**Offline correctness** (fold math, combine, KM color regression) — run after any engine math change:
```bash
cd ios/Packages/CanvasModule/OfflineTests
swiftc ../Sources/CanvasModule/BrushDynamics.swift ../Sources/CanvasModule/WetKM.swift main.swift -o /tmp/bdtest && /tmp/bdtest   # expect ALL PASSED
```
**Headless rendering incl. the WET brush** (`ios/Packages/CanvasModule/BrushHarness/README.md`) — Apple-silicon Macs have the framebuffer fetch the iOS Simulator lacks, so the real engine renders to PNGs you can read directly:
```bash
cd ios/Packages/CanvasModule/BrushHarness   # see README for the full swiftc line + --fixtures
```
Recorded fixtures come from the app: **Brush Studio → "Record strokes" → Upload** (posts JSON + canvas PNG to Insights; `fetch-fixtures.sh` pulls them Mac-side).
**On-device (feel/latency/real input only):** build `kiki_root/ios/Kiki.xcodeproj` (scheme Kiki) to an iPad — the canvas needs past Sign-in and the Simulator can't get there. Open **Brush Studio** (brush gear → "Brush Studio (dev)") — it's a **docked left panel** with the test brushes, a **live input HUD**, live **response-curve markers**, and **engine-tuning sliders** (Max speed / Distance / Fade periods).

## Reference docs (all in `documents/`)
- `research/krita-brush/PLAN.md` — the actionable plan (keystone + 9 phases). **Start here.**
- `research/krita-brush/IMPLEMENTATION-LOG.md` — everything built + 3 review rounds + follow-ups.
- `research/krita-brush/00–12*.md` — deep per-topic Krita research (grounded in source).
- `research/krita-brush/{README.md, CRITIQUE.md, _CONTEXT.md}` — index / reviews / shared grounding.
- `plans/unified-brush-engine.md` — the committed target architecture (PLAN.md amends it).
- `plans/pro-brush-roadmap.md` — wet-paint phasing + the **2026-07-14 wet-review tradeoffs** (read the tail).
- `ios/Packages/CanvasModule/CLAUDE.md` — **the color pipeline mental model (sRGB vs linear) — read before touching any color code** + the BrushHarness dev-loop note.

## What's DONE
- Sensor+curve engine (keystone), 10 test brushes, Brush Studio dev panel, live HUD + curve markers, engine-tuning sliders.
- **All 9 input sensors validated on device** (pressure/speed/tilt-elevation/tilt-direction/drawing-angle/distance/fade/fuzzy×2 all capture + curve-map correctly).
- Wet/smudge path with spectral KM; **wet color bug fixed** (`sampleLayerColor` was un-premultiplying *before* sRGB→linear decode → smear ~3× too light; now `WetKM.straightLinear` decodes first, regression-pinned in OfflineTests).
- BrushHarness headless loop + stroke recorder.

## What's NEXT (open threads, roughly prioritized)
1. ~~Finish the control-isolation validation~~ **DONE 2026-07-15 (via BrushHarness, no device needed):** all outputs now visually confirmed — `size` ✓, `flow` ✓, **scatter ✓ + color jitter ✓** (`dry-03-dynamics` scene), **rotation ✓** (`dry-06-calligraphy-rotation`: fixed-45° nib gives classic thick/thin; Distance-driven rotation visibly spins the tip).
2. **Tune `maxSpeed`.** Default is **1500** everywhere, but measured device speeds are **12,000–33,000 px/s**, so the Speed sensor is pinned at 1.0 (no variation). Use the **Max speed** slider (Brush Studio → Dev tools) to find the right value live, then bake it as the default in `BrushDynamics.swift` (~:493), `MetalCanvasView.swift` (~:63), `AppCoordinator.swift` (~:195), `CanvasView.swift` (~:29), `StrokeStampGenerator.swift` (~:20). (Verify these line numbers — they drift.) **Note:** recorded fixtures store canvas-pixel positions (~2.7× view points), so Speed-sensor brushes see faster speeds in harness replay than on device — tune on device, not from fixtures.
3. **Wet-brush refinement** (use BrushHarness): the low-Mix "opacify + tint soft edges" tradeoff (pro-brush-roadmap tail), and the **GPU-reservoir** "truer fix" for in-flight self-smear + the async-timing nondeterminism (`sampleLayerColor` sees committed paint only).
4. ~~Anisotropy / aspect-ratio tip (P4b)~~ **DONE 2026-07-15:** `BrushConfig.aspectRatio` (Codable-compat, default 1) → `StampInstance.aspect` (fits in existing tail padding, stride unchanged) → vertex-stage local-Y squash before rotation, so procedural/textured/wet dabs all get elliptical footprints free. "Aspect" slider in the brush popover. Harness scenes `dry-05-aspect` + `dry-06-calligraphy-rotation`. Remaining P4b half: the falloff-LUT (generality, explicitly NOT perf) — unbuilt, low priority.
5. **Grain (P8)** — Donald confirmed coarse value-grain **survives img2img**, so it's a committed phase (HEIGHT-mode + strength curve), not yet built. See `07-texture-grain.md`.
6. **H3 perf follow-up** — `StrokeStampGenerator` re-walks the whole point list every frame (O(n)); incrementalize to only new points. Per-dab math is cheap (~180 ns/dab), so this is only a very-long-held-stroke risk.
7. **Housekeeping:** commit the backend/fal-warmer thread; merge branch → main (fast-forward).

## Gotchas / conventions
- **Color pipeline is a minefield** — `.bgra8Unorm_srgb` textures mean texture-side math is **linear**, file/UI output is **sRGB**. Read `CanvasModule/CLAUDE.md` first. (Recent: DeviceRGB≠P3 retraction 2026-07-13; premult-decode-order fix 2026-07-14.)
- **Wet path is device-only** on-device (framebuffer fetch is nil in the iOS Simulator) — but **renders in BrushHarness** on the Mac. Verify wet color there.
- **Verify offline/harness before device** — device round-trips are the slow loop.
- **Determinism:** RNG is stateless-hash seeded from `stroke.id`; replay/undo must reproduce identical dabs. Don't introduce wall-clock/`arc4random` in the stamp path.
- **The `wetEnabled`/`wetSmudge` Bools are mode-toggles slated for deletion** at the SAB rework (unified-brush-engine.md Step 3 / PLAN P7) — don't extend them.
- **`BrushPresets.swift` is currently TEST brushes**, not shippable presets — real curated presets come back after the engine is tuned.
- Git: push directly to `main`, no PR (repo convention). Commit trailer required.

# 13 — Procreate Brush Studio parity map (2026-07-15)

> Fresh analysis on top of the 00–12 Krita research. Sources: the official Procreate handbook
> (`help.procreate.com/procreate/handbook/brushes` + `/brush-studio` + `/brush-studio-settings`,
> crawled 2026-07-15 — full parameter inventory in the appendix below) mapped against the
> engine as shipped at `22fb0ac` (keystone + P2 + P4b-aspect + wet alpha-carry).
>
> **Strategic conclusion: Krita mechanisms inside, Procreate vocabulary outside.** The engine's
> internals are already a verified Krita superset (per-sensor response curves, both folds,
> spectral KM — all things Procreate does NOT expose). What "feels like Procreate" still needs
> is (a) two missing subsystems — Grain and the stabilization family, (b) the Wet Mix / Rendering
> control vocabulary on top of machinery we largely have, (c) a batch of cheap knobs, and
> (d) curated presets. It does NOT need a rebuild or a switch of reference model.

## Gap matrix — every Brush Studio section vs. our engine

Status: ✓ have · ◐ expressible via dynamics but not surfaced as the Procreate knob ·
△ partial · ✗ missing. "Where" names the closing work item.

| Procreate section | Setting | Status | Notes / where |
|---|---|---|---|
| **Stroke Path** | Spacing | ✓ | `brush.spacing` |
| | Spacing Jitter | ✗ | cheap-knobs batch (random per-gap in the stamp walk) |
| | Jitter Lateral / Linear | △ | our Scatter is isotropic; split into ⊥/∥ components (cheap — direction already known) |
| | Fall Off | ◐ | Fade sensor → flow curve expresses it; surface as one knob |
| **Stabilization** | StreamLine Amount | △ | shipped EMA has the frame-rate-dependence bug → **P3 rebuild** |
| | StreamLine Pressure (pressure smoothing) | ✗ | P3 [MED] item |
| | Stabilization (moving avg) / Motion Filtering / Expression | ✗ | P3 family |
| **Taper** | taper both-ends | ✓ | single knob today |
| | per-end lengths, Size/Opacity amounts, Tip, pressure-vs-touch | △ | richer taper model — cheap-knobs batch (CPU-only) |
| **Shape** | Shape source (import/editor) | △ | 5 built-in tips; import later (presets era) |
| | Azimuth orientation | ◐ | TiltDirection sensor → rotation |
| | Rotation −100…100 (follow↔inverse stroke) | △ | orientsToStroke is on/off; make it the signed knob |
| | Scatter (rotation), Randomized | ◐ | fuzzy sensors → rotation |
| | **Count / Count Jitter** (≤16 stamps/point) | ✗ | multi-stamp per dab — small stamp-gen feature, big texture win |
| | Flip X/Y | ✗ | trivial (UV flip) |
| | Roundness | ✓ | = aspect (P4b, just shipped) |
| | **Pressure/Tilt Roundness + jitters** | ✗ | make aspect a CurveOption — small, high-feel (nib squash under pressure) |
| **Grain** | ALL of it (source, Moving/Texturized, Scale, Zoom, Depth±jitter, Offset Jitter, Blend Mode, Brightness/Contrast) | ✗ | **P8 — the single biggest missing section.** Their *Texturized* = our planned document-space HEIGHT grain; *Moving* (streaky, travels with stroke) is the second mode, add after. |
| **Rendering** | Glaze modes (Light/Uniformed/Intense/Heavy Glaze, Uniform/Intense Blending) | △ | our flow/opacity Glaze split ≈ Light Glaze; the 6-mode family maps onto P0's planned 3-PSO Glaze/Build-up family + Wet Mix coupling |
| | Flow | ✓ | |
| | Wet Edges | ✗ | pigment-bleed edge softening — worth a spike (klein-visible) |
| | Burnt Edges (+mode) | ✗ | edge darkening on overlap — defer, revisit (it IS a value effect klein would honor) |
| | Blend Mode / Luminance / Alpha Threshold | ✗ | P9 curated set |
| **Wet Mix** | Dilution (water in the paint) | △ | new alpha-carry gives the mechanism; needs the knob |
| | Charge (paint load at stroke start, runs out) | △ | loadAlpha depletion (2026-07-15) = the mechanism; expose volume + depletion |
| | Attack | ✓ | = Mix (`wetStrength`) |
| | Pull | ✓ | = Smear (`wetPickup`) |
| | Grade / Blur / Blur Jitter | ✗ | smudge radius/blur — P7 |
| | Wetness Jitter | ✗ | wetness as CurveOption — P7 |
| **Color Dynamics** | Stroke Color Jitter H/S/L | ✓ | shipped (P2) |
| | Darkness (separate) + Secondary Color | ✗ | P6 (+ secondary ink) |
| | **Stamp (per-dab) Color Jitter** | ✗ | P6 — deferred for img2img reasons, but FEEL-wise this is what makes pastel/oil sparkle; revisit priority |
| | Color Pressure (pressure→hue/sat/brightness/secondary) | △ | pressure→value shipped; hue/sat/secondary = P6 wiring |
| | Color Tilt / Barrel Roll | ✗ | sensors exist (tilt) / missing (roll); P6 wiring |
| **Dynamics** | Speed → Size/Opacity | ◐ | Speed sensor shipped but **pinned until maxSpeed is tuned on device** (handoff item 2) |
| | Speed → Spacing | ✗ | spacing isn't curve-driven yet — cheap-knobs batch |
| | Jitter Size/Opacity | ◐ | fuzzy sensors |
| **Apple Pencil** | Pressure graph | ✓ | ResponseCurve (richer: per-sensor) |
| | Pressure → Size/Opacity/Flow | ✓ | |
| | Pressure/Tilt → Bleed, Tilt Gradation | ✗ | ties to Wet Edges work |
| | Tilt trigger angle | ◐ | curve on TiltElevation |
| | **Barrel roll (Pencil Pro)** | ✗ | new input: `UITouch.rollAngle` — easy sensor add, unlocks 3 Procreate groups |
| **Properties** | preview, size/opacity bounds, Smudge Pull | ✗ | preset-library era |
| **Materials** | metallic/roughness (3D) | — | skip: 3D painting; img2img discards |
| **Preview / About** | — | — | preset-library era / skip |

**Score at a glance:** of the sections that matter for 2D feel, we fully or expressibly cover
Stroke Path, Taper, most of Shape, Rendering-core, Wet-Mix-core, stroke-level Color Dynamics,
Dynamics, and Apple-Pencil-core. The genuinely missing *subsystems* are *Grain*, the
*stabilization family*, *wet Grade/Blur*, *per-dab color*, and *multi-stamp Count* — plus a
long tail of cheap knobs on machinery we already have. Nothing requires abandoning the Krita
internals; several of our internals (per-sensor curves, spectral KM) exceed Procreate.

## Re-prioritized next work (supersedes the handoff's ordering)

1. ~~P3 — Stabilization rebuild~~ **DONE 2026-07-15** (`dfec818`): StrokeStabilizer —
   StreamLine EMA (verbatim port) + two-pass Gaussian arc-length Smoothing (new popover
   slider) + pressure smoothing (config) + catch-up-on-lift. Offline-asserted (passthrough,
   rate-independence, wobble energy 9×, catch-up exact); harness scene dry-07.
   Still open from P3: velocity-aware Bézier emission (curvature upgrade) — deferred.
2. ~~P8 — Grain~~ **DONE 2026-07-15** (`30a9c59`): three procedural document-space grains
   (paper/canvas/speckle), carved at scratch-COMPOSITE time (per-dab carving rejected in
   harness — overlap refills tooth), Grain picker + depth in the popover. Harness dry-08.
   Still open from P8: Moving-mode grain (streaky), grain strength as a CurveOption.
3. **Cheap-knobs batch** — PARTIAL 2026-07-15 (`1704690`): DONE — ratio/Roundness
   CurveOption (pressure nib squash, Studio section), spacing jitter (config), barrel-roll
   sensor (StrokePoint.rollAngle + BarrelRotation, harness-proven). Harness dry-09.
   Remaining: signed follow-stroke rotation knob, lateral/linear scatter split,
   speed→spacing, Flip X/Y, Fall Off knob, stamp Count/Count Jitter.
4. **P4a — Lightness-map tips** (S effort, HIGH img2img leverage, offline color oracle first).
5. **P7 — Wet rework**, adopting **Procreate's Wet Mix vocabulary as the control surface**
   (Dilution/Charge/Attack/Pull/Grade/Blur over our KM+reservoir internals). After Donald's
   device pass on the current wet fixes.
6. **Preset library** (Procreate-style organization; Properties-section behaviors) once 1–4 land
   — presets are where "feels like Procreate" actually materializes for a user.

**Parallel, Donald-gated:** maxSpeed tuning (5 min, unpins ALL Speed dynamics), device feel
passes, fixture uploads.

## Appendix — full Procreate Brush Studio inventory (handbook-grounded, crawled 2026-07-15)

See `14-procreate-brush-studio-inventory.md` (companion file) for the complete per-section
setting list with handbook descriptions, exact rendering-mode names, Wet Mix slider names,
and the input-modulation summary. Notable verbatim details: the mode is spelled "Uniformed
Glaze"; Wet Mix's sliders are Dilution, Charge, Attack, Pull, Grade, Blur, Blur Jitter,
Wetness Jitter; Dynamics has only Speed (Size/Opacity/Spacing) and Jitter (Size/Opacity).

# Wet-paint color-mixing spike (pro-brush Phase 4, Step 2)

Reference tooling for the spectral **Kubelka-Munk** pigment-mixing model used by the wet
brush. These are standalone macOS Swift scripts (run with `swift <file>`), kept here because
they're the source-of-truth for re-tuning the color model. The model itself is ported into
`CanvasRenderer.setupWetKMTables()` + `wetStampFragment` (and the CPU mirror `kmMixCPU`).

## Files

- **`km_swatches.swift`** — renders a swatch grid (`/tmp/km_swatches_final.png`) of how pigment
  pairs mix (blue+yellow→green, red+blue→violet, …) under the model. Has a parameter sweep for
  the blue-basis tuning. This is what produced the validated swatches. **The locked tuning lives
  here** (`BLUE_SHOULDER_AMP=0.32`, width 26, red-bump 0.32) and is mirrored in
  `setupWetKMTables()`.
- **`km_port_verify.swift`** — replicates the SHIPPED renderer tables + the `wetStampFragment`
  math in pure Swift and checks the port reproduces the spike at deposit `w=0.5`
  (blue+yellow→(78,137,104), red+blue→(125,0,92), yellow+red→(234,109,32)). Run this after any
  change to the KM tables/shader to confirm fidelity **before** an on-device round-trip.

## Model summary

RGB → 36-band reflectance spectrum (Mallett-Yuksel 7-basis: white + RGB + CMY, tuned blue basis
= ultramarine-like hump + green shoulder + red-end bump) → single-constant KM mix per band →
integrate back to linear RGB (Wyman CMF approx + D65) → endpoint-exact residual correction
(**clamp integrated linear RGB to [0,1] before the residual** — matches the reference; skipping
this shifts saturated colors).

Per-channel KM (no spectral upsampling) was tried and **rejected** — it collapses blue+yellow to
black, not green. Mixbox is better still but is CC BY-NC (don't ship unlicensed); the spectral
model here is free and the `pigmentMix`/`kmMixCPU` seam is where a licensed Mixbox LUT could drop
in later.

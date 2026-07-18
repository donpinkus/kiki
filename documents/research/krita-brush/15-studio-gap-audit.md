# 15 — Studio ⇄ Procreate gap audit (2026-07-17)

Produced while re-organizing the Brush Studio to Procreate's exact tab/setting taxonomy
(`14-procreate-brush-studio-inventory.md`). Every Procreate attribute is now visible in
the Studio as a bound control, a "via curves" pointer, or a grayed N/A gap row. This doc
is the engineering-facing ledger of those gaps, ranked by likely impact on brush cloning.

## Bound (Procreate name → Kiki knob)

| Procreate | Kiki |
|---|---|
| Stroke Path: Spacing / Spacing Jitter / Fall Off | toolSpacing / toolSpacingJitter / toolFallOff |
| Stroke Path: Jitter Lateral / Jitter Linear | dyn.scatterLateral / scatterLinear strength (CurveAmountSlider) |
| StreamLine Amount / Pressure | toolStreamline / toolPressureSmoothing |
| Stabilization Amount | toolStabilization |
| Taper: dual ends / Opacity | toolTaperStart + toolTaperEnd (new; symmetric preset taper folds in via max) / toolTaperOpacity |
| Shape: Rotation / Azimuth / Scatter / Count / Count Jitter / Flip X/Y / Roundness / Pressure Roundness | toolRotationFollow / dyn.rotation+tiltDirection / **toolRotationJitter (new engine knob)** / toolStampCount / toolStampCountJitter / toolFlipX/Y / toolAspect / dyn.ratio minValue |
| Grain: Moving–Texturized / Scale / Depth | toolGrainMoving / toolGrainScale / toolGrainDepth |
| Rendering: Flow (mode ≈ Light Glaze) | toolFlow |
| Wet Mix: Charge / Attack / Pull / Blur / Wetness Jitter | toolWetCharge / toolWetStrength / toolWetPickup / toolWetBlur / toolWetJitter |
| Color Dynamics: Stamp/Stroke Color Jitter (H/S/Lightness≈Brightness) / Color-Pressure Secondary | dyn.dabColorJitter / dyn.colorJitter / dyn.secondary |

## Gaps (N/A rows), ranked

**Likely to block cloning specific popular brushes:**
1. **Grain import from image** (+ jitters: Depth Min/Jitter, Offset Jitter, Rotation, Zoom, Blend Mode) — grains are procedural-only. Known pre-requisite for the cloning loop.
2. **Shape import from image** — engine supports arbitrary grayscale PNGs (catalog is folder-drop), only the UI/import path is missing.
3. **Rendering modes beyond Light Glaze** (Uniformed/Intense/Heavy Glaze, Uniform/Intense Blending) — many Procreate brushes lean on Heavy Glaze / Blending.
4. **Wet Edges** — pigment-bleed edges (roadmap spike exists in pro-brush-roadmap).
5. **Stroke Blend Mode** (multiply/screen per brush) + Burnt Edges + Luminance Blending + Alpha Threshold.
6. **Dynamics speed/jitter as plain sliders** — capability exists via curves; one-tap sliders not round-trippable to CurveOptions yet (pointer rows for now).

**Medium:**
7. Motion Filtering (Amount/Expression) — different algorithm from our Gaussian stabilization.
8. Taper Size/Tip/Tip Animation/Link Tip Sizes/Pressure toggle/Classic; Touch (finger) taper split.
9. Tilt: trigger angle graph, Gradation, Bleed, Size Compression; Pressure graph + Bleed.
10. Color: Darkness jitters, per-stamp/stroke Secondary jitter, Color Pressure H/S/B, Color Tilt group.
11. Randomized (per-stroke tip rotation), Roundness vert/horiz jitter, tip Filtering modes.
12. Grain Movement (drag vs paint-roller), Brightness/Contrast.
13. Wet Mix: Dilution (deliberately folded into Attack+Opacity — decision 2026-07-16), Grade, Blur Jitter.
14. Per-brush Max/Min Size + Opacity slider bounds; Use Stamp Preview / Orient to Screen.

**Not planned:** Barrel roll (Pencil Pro), hover/cursor UI, Materials (3D), Preview tab (live pad replaces it).

## Screenshot requests for Donald (only where handbook text under-specifies behavior)

1. **Rendering modes**: same stroke (mid-opacity, self-crossing) in all 6 modes — what exactly do the Glaze tiers change (per-dab build-up? ceiling? edge)?
2. **Wet Edges** slider at 0 / 50 / 100 on a plain round brush — edge profile + does it darken or blur.
3. **Taper "Size" and "Tip"** sliders at extremes — what shape does the taper profile take.
4. **Motion Filtering vs Stabilization** on the same shaky stroke — how the line differs.
5. **Grain "Movement"** at 0 vs 100 with a coarse grain — drag/smear vs roller.
6. **Wet Mix "Grade" and "Dilution"** sweeps on a wet brush over a colored patch.
7. **Color Dynamics "Darkness" jitter** vs Lightness jitter on one stroke.

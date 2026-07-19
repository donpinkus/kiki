# 15 — Studio ⇄ Procreate gap audit (updated 2026-07-19; first pass 2026-07-17)

Ledger of gaps between Kiki's Brush Studio/engine and Procreate's Brush Studio
(`14-procreate-brush-studio-inventory.md`), ranked by likely impact on brush cloning.

**UI note (2026-07-19):** the Studio no longer shows gap rows or "via curves" pointers —
panes contain only live controls, organized exactly like Procreate's (owner decision).
This doc is now the ONLY ledger of what's missing; keep it current when closing gaps.

## Bound (Procreate name → Kiki knob)

| Procreate | Kiki |
|---|---|
| Stroke Path: Spacing / Spacing Jitter / Fall Off | toolSpacing / toolSpacingJitter / toolFallOff |
| Stroke Path: Jitter Lateral / Jitter Linear | dyn.scatterLateral / scatterLinear strength (CurveAmountSlider) |
| StreamLine Amount / Pressure | toolStreamline / toolPressureSmoothing |
| Stabilization Amount | toolStabilization |
| Taper: dual ends / Opacity | toolTaperStart + toolTaperEnd / toolTaperOpacity |
| Shape: Rotation / Azimuth / Scatter / Count / Count Jitter / Randomized / Flip X/Y / Roundness / Pressure Roundness | toolRotationFollow / dyn.rotation+tiltDirection / toolRotationJitter / toolStampCount / toolStampCountJitter / toolRandomizedRotation / toolFlipX/Y / toolAspect / dyn.ratio minValue |
| Grain: Moving–Texturized / Movement / Scale / Zoom / Rotation / Depth / Depth Minimum / Depth Jitter / Offset Jitter / Brightness / Contrast | toolGrainMoving / toolGrainMovement / toolGrainScale / toolGrainZoom / toolGrainRotation / toolGrainDepth / toolGrainDepthMinimum / toolGrainDepthJitter / toolGrainOffsetJitter / toolGrainBrightness / toolGrainContrast — **full moving/texturized system shipped 2026-07-18/19** |
| Shape + Grain import from image (Photo/File/Paste) | BrushAssetStore user assets (2026-07-17) |
| Rendering: Flow (mode ≈ Light Glaze) | toolFlow (+ toolOpacity as the stroke ceiling — ≈ Procreate brush-limit Max Opacity) |
| Wet Mix: Charge / Attack / Pull / Blur / Wetness Jitter / Smudge Pull | toolWetCharge / toolWetStrength / toolWetPickup / toolWetBlur / toolWetJitter / (Attack+Pull in smudge mode) |
| Color Dynamics: Stamp/Stroke Color Jitter (Hue/Sat/Lightness≈Brightness/Darkness) / Color-Pressure Secondary | dyn.dabColorJitter / dyn.colorJitter (+ .darkness) / dyn.secondary |
| Dynamics: Speed → Size/Opacity/Spacing; Jitter → Size/Opacity | **sensor sliders 2026-07-19** — 2-point-line channels on dyn.size/flow/spacing (speed anchorLow; fuzzyPerDab) |
| Apple Pencil: Pressure → Size/Flow; Tilt → Size/Opacity | **sensor sliders 2026-07-19** — pressure/tiltElevation channels on dyn.size/flow |
| (superset) any sensor → any parameter, editable curve | Developer → Advanced curves (10 CurveToggleSections) |

## Gaps, ranked

**Likely to block cloning specific popular brushes:**
1. **Rendering modes beyond Light Glaze** (Uniformed/Intense/Heavy Glaze, Uniform/Intense Blending) — many Procreate brushes lean on Heavy Glaze / the Blending (wet) tiers. Our wet engine is a separate toggle, not a rendering tier. *(Screenshot ask #1 below still open.)*
2. **Wet Edges** — pigment-bleed edges (roadmap spike exists in pro-brush-roadmap). Old Beach's signature gap.
3. **Stroke Blend Mode** (multiply/screen per brush) + **Burnt Edges** (+mode) + **Luminance Blending** + **Alpha Threshold** — strokes are source-over only.
4. **Grain Blend Mode** — our grain is multiplicative carve only. The ONLY remaining grain gap; needs its own design round (ideally screenshots of one grain under two blend modes).

**Medium:**
5. **Motion Filtering** (Amount/Expression) — different algorithm from our distance-Gaussian stabilization.
6. **Taper refinements** — Size (severity) / Tip (fine↔chunky) / Tip Animation / Link Tip Sizes / Pressure toggle / Classic Taper / separate Touch (finger) taper. Our taper profile is fixed; one taper for all input.
7. **Apple Pencil pressure/tilt extras** — Pressure→Opacity (engine has no per-input opacity target; Flow covers the shading use), the multi-node pressure graph (per-parameter curves in Developer cover most of this, but Procreate's graph is a global input remap), Bleed (pressure- and tilt-driven), tilt trigger-angle graph, Gradation, Size Compression.
8. **Shape roundness extras** — Tilt Roundness (capability EXISTS via Advanced curves: Roundness + TiltElevation; no simple slider), Roundness vert/horiz jitter, tip Filtering modes (No/Classic/Improved — we mipmap only).
9. **Color Dynamics remainder** — per-stamp/per-stroke Secondary jitter, Color Pressure Hue/Sat/Brightness (Darkness curve approximates B), the whole Color Tilt group (tilt sensors exist; color targets don't).
10. **Wet Mix** — Dilution (deliberately folded into Attack+Opacity, decision 2026-07-16), Grade, Blur Jitter.
11. **Properties / brush limits** — per-brush Max/Min Size + Opacity sidebar bounds, Use Stamp Preview, Orient to Screen, Preview Size. (Properties tab removed from our Studio 2026-07-19 — nothing there was live.)
12. **Grain source editor tools** — Auto Repeat seamless-tiling suite (Grain Scale/Rotate/Border Overlap/Mask Hardness/Mirror Overlap/Pyramid Blending), two-finger invert. Our import applies a fixed convention (invert + autocontrast offline).

**Not planned:** Barrel roll (Pencil Pro) anywhere it appears, hover/cursor UI, Materials (3D), Preview tab (live Drawing Pad replaces it), 3D grain-follows-camera.

## Screenshot requests for Donald (only where handbook text under-specifies behavior)

1. **Rendering modes**: same stroke (mid-opacity, self-crossing) in all 6 modes — what exactly do the Glaze tiers change (per-dab build-up? ceiling? edge)?
2. **Wet Edges** slider at 0 / 50 / 100 on a plain round brush — edge profile + does it darken or blur.
3. **Taper "Size" and "Tip"** sliders at extremes — what shape does the taper profile take.
4. **Motion Filtering vs Stabilization** on the same shaky stroke — how the line differs.
5. **Wet Mix "Grade" and "Dilution"** sweeps on a wet brush over a colored patch.
6. **Grain Blend Mode**: one coarse grain, same stroke, Multiply vs 2–3 other modes.

*(Closed since 2026-07-17: grain Movement 0↔100 — shipped and validated against the Stucco target; Darkness-vs-Lightness jitter — shipped with offline asserts.)*

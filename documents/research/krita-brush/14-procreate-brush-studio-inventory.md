# 14 — Procreate Brush Studio: complete parameter inventory (handbook-crawled 2026-07-15)

**Sources:** All section content is on a single handbook page, `https://help.procreate.com/procreate/handbook/brushes/brush-studio-settings` (linked from `.../brushes` and `.../brushes/brush-studio`). Brush Studio has three components — Attributes, Settings, Drawing Pad — and 14 attributes: Stroke Path, Stabilization, Taper, Shape, Grain, Rendering, Wet Mix, Color Dynamics, Dynamics, Apple Pencil, Properties, Materials, Preview, About this Brush. Descriptions are handbook quotes or close paraphrases.

## Stroke Path
Purpose: Procreate creates strokes by plotting points along the drawn path; these settings control how the shape stamps along that path.

- **Spacing** (0–100%) — "Sets how many times your brush shape 'stamps' itself along the path."
- **Spacing Jitter** (0–100%) — Randomizes gaps between stamps; can be tied to Apple Pencil pressure.
- **Jitter Lateral** (0–100%) — "Controls how much the brush stamps will shift perpendicular to your stroke." Controllable by pressure, tilt, and barrel roll (Pencil Pro).
- **Jitter Linear** (0–100%) — Same, but in the stroke's own direction. Same modulation options.
- **Fall Off** (off → max) — "Start your stroke at full opacity and then fade it away as it goes on."

## Stabilization
- **StreamLine → Amount** — smooths wobbles/shakes; especially for inking and calligraphy.
- **StreamLine → Pressure** — higher values extend smoother pressure application; lower makes pressure activate faster.
- **Stabilization → Amount** (%) — moving average of the stroke; speed-dependent (faster strokes smooth more).
- **Motion Filtering → Amount** (%) — deletes wobble extremities without averaging; smooth/straight at any speed.
- **Motion Filtering → Expression** (%) — puts expressive feeling back to counteract over-smoothing.

## Taper
**Pressure Taper** (Pencil): dual-ended taper slider (per-end lengths), **Link Tip Sizes**, **Size** (severity of thick→thin), **Opacity** (fade transparency), **Pressure** toggle, **Tip** (low = fine tip, high = chunky), **Tip Animation**.
**Touch Taper** (finger): same minus pressure.
**Properties:** **Classic Taper** (legacy behavior).

## Shape
**Shape Source / Editor** — import via Photo/File/Source Library/Paste.
**Behavior:** input style = **Touch only** (Rotation setting governs) / **Azimuth** (tilt direction orients tip) / **Azimuth and barrel roll** (Pencil Pro; + Relative-to-stroke toggle). **Rotation** (−100%…+100%): 0 = static stamp, 100 = follows stroke direction, −100 = inverse.
**Properties:** **Scatter** (random stamp rotation), **Count** (≤16 stamps per plotted point), **Count Jitter**, **Randomized** (random rotation per stroke), **Flip X / Flip Y**, **Roundness graph** (squash the shape), **Pressure Roundness**, **Tilt Roundness**, **Roundness Vertical/Horizontal Jitter** (pressure-controllable).
**Filtering:** No Filtering / Classic Filtering / Improved Filtering.

## Grain
**Grain Source / Editor** — import via Photo/File/Source Library (100+)/Paste; **Auto Repeat** seamless-tiling tools (Grain Scale, Rotate, Border Overlap, Mask Hardness, Mirror Overlap, Pyramid Blending); two-finger tap inverts.
**Behavior mode:** **Moving** (grain travels with the stroke — streaky, traditional paint) vs **Texturized** (static behind the stroke, stencil-like). Zoom/Rotation/Depth Jitter/Offset Jitter are Moving-only.
**Settings:** **Movement** (low = drag/smear, high = paint-roller), **Scale**, **Zoom** (Cropped vs Follow Size), **Rotation** (vs stroke direction), **Depth** (texture strength/contrast), **Depth Minimum**, **Depth Jitter**, **Offset Jitter**, **Blend Mode**, **Brightness / Contrast**.
**Filtering:** No/Classic/Improved. **3D:** Grain follows camera toggle.

## Rendering
**Modes (exact spellings):** **Light Glaze** (standard, lightest) · **Uniformed Glaze** ("similar to Adobe® Photoshop®") · **Intense Glaze** (slightly heavier) · **Heavy Glaze** (strong; maintains opacity when mixing) · **Uniform Blending** (Photoshop style + caustic color; pronounced Wet Mix) · **Intense Blending** (heaviest; full-flow Wet Mix).
**Blending controls:** **Flow**, **Wet Edges** (soften/blur edges — pigment bleeding into paper), **Burnt Edges** (+ **Burnt Edges Mode** blend mode; color-burn where strokes overlap), **Blend Mode** (whole stroke), **Luminance Blending** toggle, **Alpha Threshold** toggle+slider, **Classic Normal Combine Mode** (dual-brush legacy).

## Wet Mix
- **Dilution** — how much water mixes with the paint (higher = more transparent).
- **Charge** — how much paint is on the brush at stroke start; runs out over the stroke.
- **Attack** — how much paint sticks to the canvas.
- **Pull** — strength of pulling/dragging paint already on the canvas (mixing).
- **Grade** — chunkiness/contrast of the brush texture.
- **Blur** — blur applied to canvas paint and its spread during a stroke.
- **Blur Jitter** — randomized per-stamp blur.
- **Wetness Jitter** — randomized water amount along the stroke.

## Color Dynamics
- **Stamp Color Jitter** (per stamp, random): Hue, Saturation, Lightness, Darkness, Secondary Color.
- **Stroke Color Jitter** (per stroke, random): same five.
- **Color Pressure** (pressure-driven): Hue, Saturation, Brightness, Secondary Color.
- **Color Tilt** (tilt-driven): Hue, Saturation, Lightness, Secondary Color.
- **Color Barrel Roll** (Pencil Pro): Hue, Saturation, Lightness, Secondary Color.

## Dynamics
Speed- and randomness-driven (explicitly not pressure/tilt — works for finger painting).
- **Speed → Size** (−100…+100%), **Speed → Opacity** (−100…+100%), **Speed → Spacing**.
- **Jitter → Size**, **Jitter → Opacity**.
(Only Speed and Jitter subsections exist; no Fade in current handbook.)

## Apple Pencil
**Pressure:** pressure graph (customizable, up to 4 extra nodes; respects global curve); **Size**, **Opacity**, **Flow**, **Bleed** ("how much your brush bleeds around the edges under varying pressure").
**Tilt:** tilt graph / trigger angle (0–90°; effective 30–90°); **Opacity**, **Gradation** ("softening effect when shading on an angle"), **Bleed**, **Size**, **Size Compression** toggle.
**Barrel Roll (Pencil Pro):** **Size**, **Opacity**, **Bleed**, **Relative to stroke** toggle.
**Cursor Outline:** None / Contrast / Active color. **Hover:** preview opacity, Estimated pressure, Hover fill (None/Shape/All).

## Properties
**Use Stamp Preview**, **Orient to Screen**, **Preview Size**, **Smudge Pull** (how much the brush smudges when used as the Smudge tool), **Maximum/Minimum Size**, **Maximum/Minimum Opacity** (sidebar slider bounds).

## Materials (3D painting)
**Metallic → Amount / Metallic Source** (greyscale texture + Auto Repeat tools + Scale), **Roughness → Amount / Roughness Source**. (Skip for Kiki: 3D-only, img2img discards.)

## Preview
**Use stamp preview**, **Size**, **Pressure Minimum**, **Pressure Scale**, **Wet Mix** toggle, **Tilt Angle**.

## About this Brush
Author picture, Made by, Date Created, Signature, **Create New Reset Point**, **Reset brush**.

## Input-modulation summary (per the handbook)
- **Pressure** → Size/Opacity/Flow/Bleed (Pencil section), Pressure Taper, StreamLine Pressure, Spacing/Lateral/Linear Jitter, Pressure Roundness + roundness jitters, Color Pressure group, grain Depth.
- **Tilt** → Opacity/Gradation/Bleed/Size (+trigger angle, Size Compression), Lateral/Linear Jitter, Azimuth shape orientation, Tilt Roundness, Color Tilt group.
- **Barrel roll (Pencil Pro)** → Size/Opacity/Bleed, Lateral/Linear Jitter, shape orientation, Color Barrel Roll group.
- **Speed** → Dynamics (Size/Opacity/Spacing); Stabilization amount is speed-dependent.
- **Random** → Spacing/Lateral/Linear Jitter, Count Jitter, Scatter, Randomized, roundness jitters, Depth/Offset/Blur/Wetness Jitter, Stamp/Stroke Color Jitter, Dynamics Jitter.

**Crawl caveats:** all 14 sections live on the single `brush-studio-settings` page; nothing failed to fetch. Rendering-mode spellings, Wet Mix slider names, Stroke Path names, and Dynamics contents were verbatim re-verified in a second pass. Exact numeric ranges beyond those shown are not stated in the handbook. The Dual Brush page exists outside Brush Studio and was not inventoried.

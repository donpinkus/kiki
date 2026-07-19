# 16 — Procreate brush clones (target sessions)

Ledger of cloned brushes: target → identified Procreate brush → Kiki recipe + tip
provenance + approximation gaps. Attempts live in Insights → Brushes; presets in
`CuratedPresetCatalog`; tips in `Resources/BrushShapes/`.

## Session 2026-07-18 — targets A/B/C (attempt 1 published for each)

Donald's Desktop "brush shapes" folder = 33 distinct Procreate Shape-Editor captures
(black-on-white; invert on extraction) + 9 Source-Library name grids. Conversion tool:
scratchpad `convert-asset.py` (crop chrome → invert → autocontrast → optional gamma).
Editor-panel crop that worked for all captures: `--crop 0.3825,0.2522,0.20,0.1895`.

### Brush B = "Stucco" (target 3) — preset `stucco`, tip `stucco.png`
Spec (from settings panes): spacing 7%, speckle-spatter tip Touch-only/upright,
photographic plaster grain Moving/Rolling Scale 39% Depth Max Blend **Multiply**,
Intense Glaze, Flow Max, AP Flow Max, max opacity 88%, taper both ends ~15%.
Kiki: tip from the target's own fullscreen Shape Editor screenshot (gamma 0.55 to
densify the soft dots); `rotationJitter 1.0` decorrelates the repeating spatter
(without it: moiré "rails"); spacing 0.05; pressure→flow floor 0.85; speckle grain
moving 0.5/0.6 approximates the plaster. **Gaps:** real plaster grain (need Grain
Editor fullscreen), Multiply grain blend, Intense Glaze (ours ≈ Light) — target is
still denser/pittier than attempt 1.

### Brush C = "Nightjar" (target 4) — preset `nightjar`, tip `nightjar.png`
Spec: solid organic blob tip, Rotation Follow-stroke max, spacing 27% + spacing
jitter 10% + Jitter Lateral 7% + Jitter **Linear 40%**, Pressure Roundness 65%,
Roundness V-jitter 50%, Flip X+Y, Intense Blending + Wet Mix (Charge 50%, Pull 75%),
Dynamics Jitter Size 30%, AP pressure size Max, right-end taper, max size 40%.
Kiki: ribbon continuity needed spacing 0.18 + size floor 0.55 (27%+deep size range →
dab chains); splatter satellites via stampCount 2 + countJitter 0.7 + scatter 0.5.
**Gaps:** wet mix on shaped tips (our wet path is round-tip-only — the real brush
smears), roundness jitter.

### Brush A = "Old Beach" (target 2) — preset `oldbeach`, tip `oldbeach.png`
Spec: palette-knife paint-smear tip (matched to Desktop IMG_0271), Azimuth input
style, plaster grain **Texturized** Scale 21% Depth 16% Blend Height, **Uniformed
Glaze**, Flow 30%/AP 14%, **Wet Edges Max, Burnt Edges 23% Hard Mix**, AP Size 26%
Opacity 70%, stamp color jitter 2% H/S/L/D, Smudge Pull 75%.
Kiki: tip lightness 0.85 leverages the tip's internal striations; texturized paper
grain 0.7/0.7; low flow build; azimuth via rotation+TiltDirection; dab jitter 0.02⁴.
**Gaps:** Wet Edges + Burnt Edges are THE signature (bright ragged edge, gray wash
interior) — biggest engine gap this session surfaced; Height grain blend.

## Standing asks for Donald
1. **Grain Editor fullscreen screenshots** for Stucco + Old Beach (plaster textures) —
   the shape captures worked perfectly; grains are the missing half.
2. Rendering-mode comparison screenshots (one stroke in all 6 modes) — needed to model
   Intense/Uniformed Glaze density correctly.
3. Wet Edges 0/50/100 sweep — to spec the edge effect before building it.

## Shape-tip source — STATUS (2026-07-18)

**Current shipped state:** the 32-tip stock library + the 3 clone tips are Donald's
Procreate Shape captures used **directly** (the extracted uploads). Owner call after
reviewing the generated set: the Flux Kontext variations were "either identical or too
messed up" — close matches were barely changed (still derivative), and the ones that
changed enough drifted into a different look. So we ship the uploads **"for now."**

**OPEN IP follow-up:** these are direct captures of Procreate's proprietary shapes and
must be replaced with true originals before any public/App Store release. Options still
on the table: a better image-editing model / settings, hand/Gemini-authored variations,
or original hand-drawn tips. The generation pipeline below works and is committed
(`BrushHarness/gen-shape-kontext.py`) — it's the tuning/quality that wasn't good enough.

## Original-shape generation (2026-07-18) — exploration log

Owner decision: the shipped tips must not be direct pixel copies of Procreate's
proprietary shapes (IP). Two approaches tried:

- **Procedural synthesis** (`scratchpad/gen-shapes.py`, numpy): rounds/halftone/
  spatter/charcoal render fine, but organic tips (ink blot, palette knife, smear)
  look artificial. **Rejected** by owner — quality bar not met.
- **fal.ai `fal-ai/flux-2` img2img** (NOT our H100 — klein is reference-mode-only,
  can't do strength-based partial-denoise). Endpoint: `POST https://fal.run/fal-ai/
  flux-2` with `image_url` (data URI) + `strength`, sync, ~4-6 s/image, `FAL_KEY`
  from `backend/.env.local`. Produces genuinely original, high-quality ink/paint
  textures. Findings: (1) flux reads "black shape on white" as a PHOTO of paint on
  paper — must prompt out paper texture / torn edges / border / shadow or the mask
  gets a solid-rectangle rim; (2) it reinterprets the silhouette rather than closely
  copying — good for originality, weaker for matching a specific target shape;
  strength ~0.3 keeps shape, ~0.6+ reimagines it. Scripts: `scratchpad/fal-sweep.py`,
  `fal-refine.py`. **This is the promising path** — tune strength + prompt, then
  clean+threshold outputs to masks.

## Unused tip library (ready to mine)
30 more extracted-ready Shape Editor captures on Desktop: ink blots (0234–0240),
splashes (0258/0259), dry-brush streaks (0241–0243), hardness ramp (0244–0250),
halftone (0251), charcoal set (0252–0256), cloud (0257), acrylics (0260, 0271–0274),
ridge print (0273), leaves (0277), rocks (0278). Names in grids 0261–0267/0275/0276.
Batch-convert when we want a bigger stock tip library.

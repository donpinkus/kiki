# Generation → editable sketch → regeneration ("pull the image onto the canvas")

**Status (2026-07-18): ✅ Shipped** as the "Edit" button (commit `54316c2` — backend
`POST /v1/sketchify` + iOS Edit capsule), built on the winning method below.
Earlier status (2026-07-17): methodology evaluated end-to-end on H100 (9B-KV pipeline,
Donald's real angel drawing, ~$1.50 of the $20 budget) — feature viable, clear
winning method, no app changes yet at that point.

## The feature

User likes a generation → taps "pull onto canvas" → the generated image becomes an
*editable sketch* (line art + basic flat colors, like something drawn with Kiki
brushes) → user keeps drawing on it → new generations track the edited sketch and
stay close to the original image where unedited.

## Methods tested (image → sketch)

| Method | Sketch quality (editability) | Round-trip fidelity G′ vs G |
|---|---|---|
| CV line art (DoG threshold) | clean, very editable, B/W only | composition preserved; **palette lost** (red robe → brown/white) |
| CV flat (k-means posterize + lines) | looks posterized, busy bg fills | **excellent** — near identity ceiling |
| CV marker (accents only) | moderate | composition good, colors partially lost |
| **Model-based: klein sketchifies its own output** | **best — clean colored line drawing, genuinely hand-drawn look** | **excellent — near identity ceiling** |
| identity control (G as its own ref) | — | ceiling: close but visible drift |

Grid: `scratchpad/roundtrip/roundtrip-grid.jpg` (session-local; copies worth
committing if this ships). Key experimental facts:

- **Color must ride in the sketch.** Any colorless sketch loses the palette on
  regeneration. Line art alone is not enough.
- **Winning method: one extra klein generation.** `pipe(prompt="simple clean line
  art drawing with flat marker colors on white paper, minimal children's coloring
  book style", image=G, seed=fixed)` produces exactly the target artifact — clean
  outlines + flat colors on white, preserving figure, pose, scythe, skull, red robe.
  Feeding it back with the original prompt+seed reproduces G at ≈ the identity
  ceiling. Cost: one generation (~0.7 s on H100, same pipeline, no extra models).
- Reproducibility ceiling exists: even G→G (identity) drifts slightly under
  reference-mode. G′ ≈ G, never pixel-equal. Fine for the product story (the user
  is about to edit it anyway).
- The sketch prompt whitens the background (paper look); the round-trip re-invents
  a matching background from the text prompt. If background editability matters,
  tune the sketchify prompt to retain background shapes (CV-flat proves bg fills
  round-trip fine).

## Recommended methodology

1. **Sketchify = one klein generation with a fixed "sketch style" prompt + fixed
   seed** (deterministic per source image). Runs on the same Lambda instance /
   pipeline as normal generation — no new infra, no new model.
2. Composite the result onto the canvas as editable content (app-side design TBD —
   e.g., background-image layer or rasterized into the canvas texture; Drawing
   already supports a background image blob).
3. Optionally blend CV line art on top if stroke-crispness matters after import.

## Generalization + Form-vs-Colors modes (2026-07-17, 5 real drawings)

Tested across five of Donald's real drawings (spaceship, floating island + fox,
Pixar cat, halo man, Halo structure — each with its REAL session prompt), two
sketchify modes each. Master grid: `scratchpad/rt2-grid.jpg`. Results:

- **Sketchify generalizes: 5/5.** Clean coloring-book sketches for every subject
  type, backgrounds included (the angel's white-bg result was subject-specific,
  not a limitation).
- **Form-only mode** (`"...uncolored coloring book outline style, no shading,
  no color"`, seed 7): composition locked; palette re-derived from the prompt on
  regeneration — recovers the original look when the prompt names colors (gray
  cat, cherry blossom), plausible otherwise. The "I want the shape, I'll do the
  colors" mode.
- **Form+Colors mode** (the original colored-flat prompt): round-trips near-
  identically — AND the sketch's colors STEER the regeneration (spaceship went
  white/blue where the sketch fills were light; the man gained the sketch's red
  vest). That's the editability contract working: recolor the sketch → the
  generation follows. If stricter color fidelity to the source is wanted, add
  "using the exact same colors as the image" to the sketchify prompt (untested).

**Recommended user control: a two-option import choice** — "Lines only" vs
"Lines + colors" — mapping 1:1 to the two sketchify prompts. Same pipeline,
same cost (one generation either way).

## Open items before building

- ~~n=1~~ RESOLVED: generalization confirmed on 5 real drawings (section above).
- Sketch-prompt tuning: strict color fidelity variant ("using the exact same
  colors as the image"), line weight, color count.
- App-side: import mechanics (layer vs flatten), resolution (sketchify at 768²,
  canvas is 2048² — upscale strategy for import), undo semantics.
- Latency UX: one generation (~1 s incl. overhead) — fine as a tap action.

## Layer-splitting expansion (ON HOLD — awaiting SAM 3 gated access, 2026-07-17)

Next evolution: import splits into layers per object-SUBJECT (all falling leaves =
one layer), toggle one-layer vs multi-layer, plus tap/text selection of specific
objects. Chosen tool: **SAM 3** (facebook/sam3 + sam3.1, HF, transformers
Sam3Model/Sam3Processor) — its promptable CONCEPT segmentation returns all
instances of a text concept (union = one layer), and point prompts cover
tap-to-import. Access requested by Donald (gated, pending approval; token got 403).

Designed experiment (ready to run on one H100 session, images already staged from
the round-trip work):
1. Concept→layer grouping on the island image (petals/clouds = multi-instance test).
2. Auto-layering vocabularies (easy UX, no user selection):
   (a) prompt-noun concepts (sessions name their subjects; residual → background
   layer) — recommended first; (b) SAM everything-mode + embedding/spatial
   clustering (fully automatic; grouping quality is the risk); (c) VLM captioner
   → concepts (only if (a)'s residual behavior disappoints). Plan: (a) with (b)
   as residual fallback, layer-count cap of 3-8.
3. Tap-prompt demo (point → object mask → single-object import).
4. Mask-transfer check: masks from generated image G applied to sketchified S
   (geometry shifts slightly between generations — measure, maybe dilate; or
   segment S directly).
5. Note: layered import leaves holes behind lifted objects — options: transparent
   holes (Procreate-like), cheap inpaint (cv2/LaMa) on background layer.
Fallback if SAM 3 disappoints: GroundingDINO + SAM 2.1 (both ungated).
Use a SEPARATE venv on the instance (latest transformers) — do not touch the
shared NFS venv (pinned transformers 4.57 for klein).

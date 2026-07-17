# Generation → editable sketch → regeneration ("pull the image onto the canvas")

**Status (2026-07-17):** methodology evaluated end-to-end on H100 (9B-KV pipeline,
Donald's real angel drawing, ~$1.50 of the $20 budget). **Feature is viable; a clear
winning method exists.** No app changes made (per scope).

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

## Open items before building

- n=1 subject/style — repeat on 3–5 diverse generations (portrait, object, scene;
  other style suffixes) to confirm the sketch prompt generalizes.
- Sketch-prompt tuning: background retention, line weight, color count.
- App-side: import mechanics (layer vs flatten), resolution (sketchify at 768²,
  canvas is 2048² — upscale strategy for import), undo semantics.
- Latency UX: one generation (~1 s incl. overhead) — fine as a tap action.

# FLUX.2-klein Capability Notebook

Running notebook of things FLUX.2-klein-4B can do that Kiki isn't currently using, and how each could map to a Kiki feature. **Not a plan, not a decision log.** Each entry is a potential direction that may or may not turn into work. Add entries as we learn; do not remove entries when they're superseded — mark them as closed instead.

## Current stack (as of 2026-04-24)

- Model: `black-forest-labs/FLUX.2-klein-4B` (step-wise distilled, 4-step, ignores `guidance_scale`)
- Quantization: BFL's NVFP4 transformer on top of BF16 pipeline
- Pipeline: diffusers `Flux2KleinPipeline`
- Mode in use: single-reference img2img (sketch VAE-encoded, concatenated as reference tokens)
- LoRAs: none
- Hardware: RTX 5090 spot (Blackwell, SM 10+)

## Architectural facts about klein (shared between 4B and 9B)

These are the structural facts the capability ideas lean on. Verified against the `capitan01R/ComfyUI-Flux2Klein-Enhancer` forward-pass trace; **not** yet verified against our loaded `Flux2KleinPipeline.transformer` — do that before committing code to any of these.

- Dual-stream architecture: `double_blocks` process text + image streams separately, `single_blocks` process them concatenated. Repo reports 8 × double + 24 × single for 9B; 4B block counts not yet verified on our model.
- Reference latent is a **separate** `[1, 128, H_lat, W_lat]` tensor in conditioning metadata — **not** merged into text conditioning. Concatenated pre-`img_in` with the noisy latent.
- Token layout in attention: `[txt | main_img | ref_0 | ref_1 | ... | ref_N]`. `reference_image_num_tokens` metadata gives the exact per-reference token count.
- Multi-reference: up to ~8 references, each stamped with its own temporal coordinate (`t=10`, `t=20`, …) so RoPE encodes strong separation.
- Text conditioning: Qwen3 8B encoder → `[1, 512, 12288]`, with ~67 active tokens detected from attention mask.
- VAE latent channel segregation (empirical claim from the repo, NOT BFL-confirmed): channels 0–63 ≈ structure/layout, channels 64–127 ≈ texture/detail.
- Klein cannot do noise-based img2img with a `strength` slider. It uses in-context conditioning instead. True partial-denoise would require switching to `klein-base-4B` (~17s on 5090, kills real-time).
- Klein ignores `guidance_scale`. No CFG-style tricks.

## Capability ideas

### 1. Attention-level reference strength (k/v scaling)

**What:** Hook the transformer's attention blocks; scale `k` and `v` tensors for the reference-token range by a user-controlled factor. `1.0` = normal, `>1.0` = stronger sketch adherence, `<1.0` = looser. Works because it directly controls how much the generation "listens" to the reference.

**How it maps to Kiki:** The "follow my sketch ↔ follow my prompt" slider you've been wanting. Replacement for the partial-denoise strength slider that klein can't support.

**Source:** `capitan01R/ComfyUI-Flux2Klein-Enhancer`, specifically the `Flux2KleinRefLatentController` and `Flux2KleinTextRefBalance` nodes. Uses `attn1_patch` hooks + `reference_image_num_tokens` metadata for per-reference indexing.

**Caveats:**
- ComfyUI-specific patching; porting to diffusers means hooking `transformer.forward` or individual attention layers.
- Per-block indexing ranges in the repo assume 9B block counts — verify 4B layout.
- Untested on the NVFP4 checkpoint. Quantized attention may interact oddly with k/v scaling.

**Status:** Not started. Highest-leverage short-term experiment.

---

### 2. Spatial reference-latent masking (NOT inpainting)

**What:** Multiply the `[1, 128, H_lat, W_lat]` reference latent by a spatial mask *at conditioning build time*, before sampling. White regions preserve reference structure; black regions attenuate it so the prompt dominates. Runs once, zero runtime cost during sampling. Compatible with distillation because it doesn't touch the sampling loop.

**Why it's not inpainting:** There's no mask-aware sampler. The mask just makes parts of the reference latent carry near-zero signal, so attention has nothing meaningful to pull from in those regions.

**How it maps to Kiki:**
- **Auto-mask from stroke density:** dense sketch → protected; empty canvas → prompt-driven. No UI required.
- **User-painted "free-form" region:** reuse the Phase-2 lasso infrastructure to mark "AI, reimagine this area."
- **Channel-mode default:** attenuating only `high` channels (64–127) in the edit region would give a "sketch controls composition, prompt controls style" feel.

**Source:** `flux2_klein_mask_ref_controller.py` in the Enhancer repo.

**Implementation notes:**
- Mask is bilinear-resized to latent resolution; Gaussian feather via inline separable conv2d for smooth edges (hard masks produce visible square artifacts at latent resolution).
- Multiplier formula: `multiplier = 1.0 - strength * (1.0 - mask)`. `strength=1.0` fully zeros masked regions; `strength=0.5` half-attenuates.
- Channel-selective modes: `all`, `low` (ch 0–63), `high` (ch 64–127).
- In diffusers we need to either pre-encode the reference ourselves or monkey-patch the pipeline to intercept post-VAE-encode, pre-transformer.

**Caveats:**
- Channel-split claim (low=structure, high=texture) is empirical from the repo author, not BFL-confirmed. Validate with a 10-minute A/B before committing UX to it.

**Status:** Not started. Best fit for a sketch app of any of these ideas.

---

### 3. Multi-reference conditioning (style/subject references)

**What:** Klein natively accepts up to ~8 reference images. Each gets its own temporal positional stamp (`t=10`, `t=20`, …) and the model attends to all of them during generation.

**How it maps to Kiki:**
- **Style reference:** pair the sketch with a style image ("my sketch in the style of this painting"). `PromptStyle` could optionally carry an image blob instead of just a text suffix.
- **Subject/identity reference:** keep a consistent character across multiple drawings.
- **Palette reference:** color-match a target image without changing composition.

**Source:** Native klein capability. Documented in fal's klein user guide and the Enhancer repo's architecture trace.

**Caveats:**
- Diffusers' `Flux2KleinPipeline` may or may not expose a clean multi-reference API today — verify. If not, we'd wire the extra reference into conditioning ourselves.
- Each reference adds tokens to the attention sequence; small throughput cost per extra reference.
- Per-reference strength control (idea #1) pairs well with this — "sketch at 1.2, style ref at 0.7."

**Status:** Not started. Medium effort, high product value (real feature users would ask for).

---

### 4. Text-conditioning magnitude/contrast

**What:** Scale or sharpen the text embedding tensor before it enters `txt_in`. Magnitude >1 amplifies prompt influence; contrast >0 sharpens concept separation between tokens; normalize balances per-token magnitudes.

**How it maps to Kiki:** Minor quality/style lever. Could be a "prompt strength" setting or baked into style presets. Lower priority than reference-side controls.

**Source:** Enhancer repo, `flux2_klein_enhancer.py` and `flux2_klein_text_enhancer.py`.

**Caveats:**
- Reference-mode generation is primarily sketch-driven; text tweaks matter less than in pure T2I.
- Klein is distilled — quality deltas from text-conditioning manipulation may be smaller than on the base model.

**Status:** Not started. Low priority.

---

### 5. LoRA trained on klein-base-4B

**What:** Fine-tune a LoRA on `klein-base-4B` (the undistilled sibling) using paired sketch→image data. Could teach the model what Kiki users' sketches look like and what good outputs should be.

**How it maps to Kiki:** Long-term quality play. Specifically valuable once we have real user-sketch data.

**Source:** BFL official training docs.

**Caveats:**
- BFL docs **do not explicitly state** that base-trained LoRAs load cleanly on the distilled klein-4B we actually run. Community workflows sometimes apply them; reliable only by testing.
- Requires a curated paired dataset (weeks of effort, plus labeling).
- 1–3 hrs training per LoRA on a 5090. Training infra isn't set up.

**Status:** Not started. Weeks-scale effort; revisit once we have user data from TestFlight.

---

### 6. Switch to klein-base-4B for true img2img strength

**What:** Drop the distilled klein-4B and run `klein-base-4B` with standard diffusers img2img and a real `strength` parameter.

**How it maps to Kiki:** Direct answer to "I want a partial-denoise slider."

**Caveats:**
- ~17s/image on 5090 at 50 steps. Kills the ~1 FPS streaming UX that's the product's core.
- Would need to rebuild the streaming architecture around slower generation.

**Status:** Closed. Real-time UX is non-negotiable.

---

## What doesn't exist yet (worth rechecking periodically)

- Public FLUX.2-klein ControlNet (canny/scribble/depth). Would be a natural fit for a sketch app if it shows up. FLUX.1 has Union-Pro; FLUX.2-dev has alibaba-pai's Controlnet Union; klein has nothing.
- Official klein inpaint pipeline (would give us real mask-aware generation instead of the attenuation trick in idea #2).
- BFL-confirmed documentation of the latent-channel segregation claim.

## Sources

- [capitan01R/ComfyUI-Flux2Klein-Enhancer](https://github.com/capitan01R/ComfyUI-Flux2Klein-Enhancer) — architecture trace + reference node implementations
- [FLUX.2-klein-4B model card](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B)
- [FLUX.2-klein-base-4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-base-4B) — undistilled, LoRA target
- [BFL klein training docs](https://docs.bfl.ml/flux_2/flux2_klein_training)
- [fal klein user guide](https://fal.ai/learn/devs/flux-2-klein-user-guide) — in-context conditioning explanation
- [Rundiffusion klein base vs distilled](https://learn.rundiffusion.com/flux-2-klein-three-new-models/)

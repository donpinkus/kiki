# ControlNet Provider Evaluation

**Status:** In Progress — Step 1 (model testing)
**Date:** 2026-03-09

## Problem

The original model (`fal-ai/fast-sdxl/image-to-image`) is a generic img2img pipeline. It treats the sketch as a starting image and mostly ignores it, producing "hallucinated" results that don't follow what the user drew. We need a ControlNet model that uses sketch lines as structural conditioning.

## Current Implementation

**Model:** `fal-ai/scribble` (SD 1.5 + ControlNet v1.1 scribble by lllyasviel)
**Endpoint:** `POST https://fal.run/fal-ai/scribble`
**Pricing:** $0 per compute-second (free tier)
**Warm latency:** ~4s
**Cold start:** ~40s

### Accepted Parameters (only 4)

| Parameter | Type | Default | Range |
|---|---|---|---|
| `image_url` | string | required | Hosted URL only (data URIs return 422) |
| `prompt` | string | required | — |
| `num_inference_steps` | integer | 20 | 1–40 |
| `seed` | integer | random | — |

**Not accepted** (silently ignored): `negative_prompt`, `guidance_scale`, `controlnet_conditioning_scale`, `image_size`, `enable_safety_checker`, `a_prompt`, `n_prompt`.

### Response Format

```json
{
  "image": { "url": "...", "width": 512, "height": 512 },
  "control_image": { "url": "..." },
  "seed": 1234567
}
```

### Known Issue: Over-Styled Prompts

The current prompt chain appends multiple style modifiers before reaching fal:
1. `generate.ts` `buildPrompt()` appends style preset (e.g. "photorealistic, high detail, professional photography")
2. `fal.ts` appends ", colorful, vibrant, detailed"

Result: a simple "cat" prompt becomes "cat, photorealistic, high detail, professional photography, colorful, vibrant, detailed" — too many competing keywords that push the model toward elaborate/abstract output. Since this model has no conditioning scale parameter, prompt is the primary lever for sketch fidelity.

### Requirement: Hosted URLs

ControlNet models on fal.ai reject base64 data URIs. The backend uploads sketches to fal storage first:
1. `POST https://rest.alpha.fal.ai/storage/upload/initiate` → returns `{ file_url, upload_url }`
2. `PUT <upload_url>` with raw JPEG bytes
3. Pass `file_url` (on `v3b.fal.media`) as `image_url`

Upload adds ~200ms overhead.

---

## Models Evaluated

### Tier 1: Tested

| Model | Quality | Latency | Cost | Sketch Input | Conditioning Control | Status |
|---|---|---|---|---|---|---|
| **fal-ai/scribble** | SD 1.5 | ~4s warm | Free | `image_url` (hosted) | None (hardcoded) | **Active** — works, but no fine-tuning of sketch adherence |
| **fal-ai/fast-sdxl/image-to-image** | SDXL | ~1s warm | ~$0.01 | `image_url` (data URI ok) | `strength` (0–1) | **Rejected** — ignores sketch structure entirely |
| **fal-ai/fast-sdxl-controlnet-canny** | SDXL | ~2s warm, ~85s cold | ~$0.01 | `control_image_url` (hosted) | `controlnet_conditioning_scale` (0–1, default 0.5) | **Tested** — works with hosted URLs, produced valid output. High cold start. |

### Tier 2: Not Yet Tested

| Model | Quality | Latency | Cost | Key Differentiator |
|---|---|---|---|---|
| **fal-ai/sdxl-controlnet-union** | SDXL | TBD | TBD | Exposes `controlnet_conditioning_scale` (default 0.5), supports canny/depth/teed/pose. No dedicated scribble input — would use `teed_image_url` or `canny_image_url`. |
| **fal-ai/flux-general** | FLUX.1 dev | ~5–8s | ~$0.075 | Highest quality. Full ControlNet control: `conditioning_scale`, `start_percentage`, `end_percentage`. Supports `hedsketch` mode. 10x more expensive. |
| **fal-ai/z-image/turbo/controlnet** | Z-Image | TBD | TBD | Fast (8 steps max). `control_scale` (default 0.75), `control_start`/`control_end`. Preprocess modes: none, canny, depth, pose. |
| **Replicate jagilley/controlnet-scribble** | SD 1.5 | ~6s | $0.0074 | 38M+ runs. Classic ControlNet params: `a_prompt`, `n_prompt`, `scale` (guidance), `ddim_steps`. Requires Replicate API token (not yet configured). |
| **Replicate t2i-adapter-sketch-sdxl** | SDXL | ~6s | $0.0057 | T2I-Adapter (3x faster than ControlNet). Native sketch input. |

---

## Detailed Parameter Comparison

### fal-ai/scribble (current)

Only 4 params. No conditioning scale. Prompt is the only lever for output style.

### fal-ai/sdxl-controlnet-union

| Parameter | Default | Range | Notes |
|---|---|---|---|
| `prompt` | required | — | |
| `negative_prompt` | "" | — | |
| `controlnet_conditioning_scale` | 0.5 | 0–1 | **Sketch adherence knob** |
| `guidance_scale` | 7.5 | 0–20 | Prompt adherence |
| `num_inference_steps` | 35 | 1–70 | |
| `image_size` | auto | enum or {w,h} | |
| `num_images` | 1 | 1–8 | |
| `seed` | random | — | |
| `enable_safety_checker` | true | — | |

Control inputs: `canny_image_url`, `depth_image_url`, `teed_image_url`, `openpose_image_url`, `normal_image_url`, `segmentation_image_url` — each with a `_preprocess` toggle.

### fal-ai/flux-general

| Parameter | Default | Range | Notes |
|---|---|---|---|
| `prompt` | required | — | |
| `negative_prompt` | "" | — | Via NAG |
| `guidance_scale` | 3.5 | 0–20 | |
| `num_inference_steps` | 28 | — | |
| `controlnets[].path` | required | — | URL to ControlNet weights |
| `controlnets[].control_image_url` | required | — | Hosted URL |
| `controlnets[].conditioning_scale` | 1.0 | — | **Sketch adherence** |
| `controlnets[].start_percentage` | 0 | 0–1 | When to start applying |
| `controlnets[].end_percentage` | 1 | 0–1 | When to stop applying |

Also supports EasyControl with `hedsketch` method.

### Replicate jagilley/controlnet-scribble (classic)

| Parameter | Default | Notes |
|---|---|---|
| `a_prompt` | "best quality, extremely detailed" | Appended to prompt |
| `n_prompt` | "longbody, lowres, bad anatomy..." | Negative prompt |
| `ddim_steps` | 20 | |
| `scale` | 8 | Guidance scale |
| `image_resolution` | 512 | |
| `seed` | random | |

Requires `REPLICATE_API_TOKEN` (not configured).

---

## Playground Links

- **fal-ai/scribble:** https://fal.ai/models/fal-ai/scribble
- **fal-ai/sdxl-controlnet-union:** https://fal.ai/models/fal-ai/sdxl-controlnet-union
- **fal-ai/flux-general:** https://fal.ai/models/fal-ai/flux-general
- **Replicate controlnet-scribble:** https://replicate.com/jagilley/controlnet-scribble
- **Community workflow:** https://fal.ai/workflows/jfischoff/scribble-controlnet

---

## Next Steps

1. **Simplify prompts** — Strip style modifiers from fal.ts and reduce prompt chain in generate.ts. Prompt is the only lever on fal-ai/scribble.
2. **Test in playground** — Use https://fal.ai/models/fal-ai/scribble with minimal prompts to establish baseline quality.
3. **Evaluate sdxl-controlnet-union** — If scribble quality is insufficient even with clean prompts, test the SDXL union model which exposes `controlnet_conditioning_scale`.
4. **Consider flux-general** — If SDXL quality is needed, test FLUX with hedsketch. 10x cost increase.
5. **Add Replicate fallback** — Get API token, build ReplicateAdapter, test jagilley/controlnet-scribble as cross-provider fallback.

## Decision Log

| Date | Decision | Rationale |
|---|---|---|
| 2026-03-09 | Switched from `fal-ai/fast-sdxl/image-to-image` to `fal-ai/scribble` | img2img ignores sketch structure; ControlNet scribble uses it as conditioning |
| 2026-03-09 | Added fal storage upload step | ControlNet models reject base64 data URIs |
| 2026-03-09 | Identified prompt over-styling as likely cause of "trippy" output | Model only accepts 4 params; prompt is the only quality lever |

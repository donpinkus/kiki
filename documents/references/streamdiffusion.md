# StreamDiffusion Reference

## Overview

StreamDiffusion is a real-time image generation pipeline that wraps Stable Diffusion for continuous frame-by-frame processing. We use it for the "Stream" mode in Kiki — the user draws on the iPad and sees AI-generated results update live.

**Our setup:** SD 1.5 base model (Lykon/dreamshaper-8) + LCM-LoRA for fast inference. Runs on the RunPod H100 pod alongside ComfyUI.

## Architecture

```
iPad → WebSocket → Fastify backend (relay) → StreamDiffusion server (RunPod)
                                             ↓
iPad ← WebSocket ← Fastify backend ←——————— generated JPEG
```

- iPad captures canvas at ~7 FPS, sends JPEG over WebSocket
- Backend at `/v1/stream` relays to the Python StreamDiffusion server on port 8765
- Server runs img2img on each frame and returns the result
- Images are sent as base64 JSON text frames (not binary) due to iOS `URLSessionWebSocketTask` compatibility issues with binary frames through Railway's edge proxy

## `t_index_list` — The Key Parameter

`t_index_list` is the most important configuration parameter. It controls **how much your input image influences the output** vs how much the prompt drives generation.

### What it is

The diffusion scheduler has ~50 noise levels, indexed 0 to 49. Index 0 = maximum noise, index 49 = zero noise. `t_index_list` picks which noise levels to use when processing your input image.

Each value is a **denoising step**. With `[20, 30]`, the model runs 2 denoising passes on each frame.

### How it affects output

```
Index 0         10         20         30         40         49
|————————————|————————————|————————————|————————————|————————————|
Heavy noise                                              No noise
Input destroyed                                    Input unchanged
Prompt drives output                          Input drives output
```

| `t_index_list` | Behavior | Use case |
|---|---|---|
| `[0,1,2,3]` | Input image completely ignored. Output driven by prompt only. | Basically txt2img. |
| `[10,20]` | Input loosely guides composition. Prompt has strong influence. | Creative transformation. |
| `[20,30]` | Balanced. Input structure preserved, prompt adds style. | **Our default.** |
| `[32,45]` | Output nearly identical to input. Prompt barely matters. | Screen capture / filter. |

### How multiple values work (stream batching)

Each value in the list is a separate denoising step. With `[20, 30]`:

1. **Step 1 (index 20)**: Input sketch gets noised to level 20, model predicts the clean image
2. **Step 2 (index 30)**: That prediction gets lightly re-noised to level 30, then refined

StreamDiffusion's optimization: in batched mode, it processes Frame N at step 1 **and** Frame N-1 at step 2 **in a single GPU call**. So 2-step quality at 1-step speed.

```
Time →    Call 1           Call 2           Call 3
          ┌──────────┐     ┌──────────┐     ┌──────────┐
Step 1:   │ Frame 1  │     │ Frame 2  │     │ Frame 3  │
Step 2:   │ (warmup) │     │ Frame 1  │     │ Frame 2  │
          └──────────┘     └──────────┘     └──────────┘
                            ↑ outputs        ↑ outputs
                            Frame 1          Frame 2
```

This is why the first few frames are gray/blank — the pipeline needs warmup frames to fill before producing output.

### Configuring without redeploying

Set the `SD_T_INDEX_LIST` environment variable on the pod:

```bash
SD_T_INDEX_LIST=15,25 python server.py  # More creative
SD_T_INDEX_LIST=30,40 python server.py  # More faithful to input
```

## Other Parameters

| Parameter | Env var | Default | Notes |
|---|---|---|---|
| Base model | `SD_BASE_MODEL` | `Lykon/dreamshaper-8` | Any SD 1.5 model works |
| LCM LoRA | `SD_LCM_LORA` | `latent-consistency/lcm-lora-sdv1-5` | Required for fast inference |
| Guidance scale | `SD_GUIDANCE_SCALE` | `1.0` | LCM works best at 1.0 (no CFG) |
| Output JPEG quality | `SD_OUTPUT_JPEG_QUALITY` | `85` | |
| Similarity filter | `SD_SIMILARITY_FILTER` | `true` | Skips GPU work when input hasn't changed |
| Similarity threshold | `SD_SIMILARITY_THRESHOLD` | `0.98` | Higher = more frames skipped |
| Resolution | `SD_DEFAULT_WIDTH/HEIGHT` | `512` | Standard SD 1.5 resolution |

### Parameters that DON'T do what you'd expect

- **`delta` in `prepare()`**: NOT a denoising strength. It's a CFG noise scaling factor only relevant when `cfg_type` is "self" or "initialize". With our `cfg_type="none"`, it does nothing.
- **`t_index_list` is the ONLY control** for input influence. There is no separate "strength" or "denoising" parameter in StreamDiffusion's img2img mode.

### UI Controls

In the iOS app's Advanced Parameters (stream mode):
- **t_index_list text field**: Type values directly (e.g. `10,20`). Press Return to stage the change, then tap "Update" in the toolbar to apply.
- **Capture FPS slider**: Controls how many frames per second are sent to the server.
- **Update button**: Appears in the toolbar when prompt or t_index_list has been changed. Sends all pending changes to the server at once.

## Server Files

```
streamdiffusion-server/
  server.py          # FastAPI + WebSocket endpoint (/health, /ws)
  pipeline.py        # StreamDiffusion wrapper
  config.py          # All config via env vars
  test_client.py     # CLI test tool
  Dockerfile         # For containerized deployment
```

## Deployment

StreamDiffusion runs on the same RunPod pod as ComfyUI. Deployed via the **"Deploy StreamDiffusion"** GitHub Action which:
1. Finds the running `kiki-comfyui` pod
2. SSHes in, installs deps in a venv (isolated from ComfyUI's packages)
3. Downloads models to network volume (cached across pod restarts)
4. Starts the server on port 8765
5. Updates Railway's `STREAMDIFFUSION_URL` env var

The venv is necessary because StreamDiffusion pins `diffusers==0.24.0` which conflicts with ComfyUI's newer `transformers`/`huggingface_hub`.

## Testing

```bash
# Single frame test
python test_client.py --url wss://<pod>-8765.proxy.runpod.net/ws \
  --image sketch.png --prompt "a cat, watercolor" --t-index-list 10,20

# Burst test (10 frames, measures throughput)
python test_client.py --url wss://<pod>-8765.proxy.runpod.net/ws \
  --image sketch.png --prompt "a cat" --burst 10

# More creative transformation
python test_client.py --url wss://<pod>-8765.proxy.runpod.net/ws \
  --image sketch.png --prompt "a cat" --t-index-list 5,15 --burst 10

# Through the backend relay
python test_client.py --url wss://kiki-backend-production-eb81.up.railway.app/v1/stream \
  --image sketch.png --prompt "a cat" --burst 10
```

Note: first 2-3 frames in a burst will be gray (pipeline warmup). This is normal.

## Known Issues & Lessons Learned

1. **iOS binary frame issue**: `URLSessionWebSocketTask` misinterprets binary WebSocket frames through Railway's edge proxy as text, causing "invalid utf-8 sequence" errors. Workaround: backend wraps JPEG in JSON text frames (`{"type":"frame","data":"<base64>"}`).

2. **Dependency conflicts**: StreamDiffusion pins `diffusers==0.24.0` which needs `huggingface_hub<0.25`. ComfyUI's base image has `transformers 5.x` which needs `huggingface_hub>=1.3`. Solution: venv with `--system-site-packages` (gets PyTorch/CUDA from base image, isolates Python packages).

3. **Warmup frames**: The stream batch pipeline needs `len(t_index_list)` warmup frames before producing meaningful output. First frames will be gray/blank.

4. **`t_index_list` is everything**: This single parameter controls the creativity-vs-fidelity tradeoff. Getting it wrong makes the system appear broken (either ignoring input or ignoring prompt). There is no separate "strength" parameter for img2img in StreamDiffusion.

5. **Don't call `fuse_lora()` if you need to reinitialize**: `fuse_lora()` permanently bakes the LoRA adapter matrices into the base model's weights in place. It's a ~10% inference speedup. But if you reinitialize the `StreamDiffusion` wrapper around the same underlying `pipe` (as we do when the user changes `t_index_list` from the UI), calling `fuse_lora()` a second time **double-fuses** the weights and corrupts the model. The corrupted pipeline produces garbage or silently hangs. Our fix: skip `fuse_lora()` entirely. The ~10% speed penalty is acceptable, and reinit now works correctly. Alternatives would be calling `unfuse_lora()` before re-fusing, or reloading the base pipe from disk on each reinit — both more fragile.

6. **More denoising steps is NOT always better**: We briefly tried `[5,15,25,35]` (4 steps) thinking it would improve quality. It was slower (halved FPS) AND less faithful to the input, because starting at index 5 adds heavy noise to the input image before the model processes it — destroying the sketch structure. `[20,30]` (2 steps starting at index 20) is a better balance for sketch-to-image. With SD 1.5 + LCM-LoRA, the model is already heavily distilled, so extra steps give diminishing returns.

7. **Default LCM guidance scale is 1.0 with `cfg_type="none"`**: The `guidance_scale` parameter has no effect when `cfg_type="none"` because classifier-free guidance isn't being computed. LCM was trained without CFG so this is the recommended setup. If you want the prompt to have stronger influence, you'd need `cfg_type="self"` AND `guidance_scale>1.0`, at roughly 2x the compute cost per step.

8. **Don't use local `@State` for values that outlive a SwiftUI popover**: Our first attempt at the t_index_list UI used `@State private var tIndexListDraft` with an `onSubmit` handler to commit. When the popover closed, the `@State` was destroyed — so if the user tapped outside the field without pressing Return, their typed value vanished silently. Fix: bind the TextField directly to the observable coordinator property (`$coordinator.streamTIndexListText`). Every keystroke is captured immediately. The "when to send" question is handled by a separate explicit "Update" button in the toolbar.

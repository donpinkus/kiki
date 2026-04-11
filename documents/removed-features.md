# Removed Features

Reference for features removed during the FLUX.2-klein simplification. To recover any of these, check out commit `6fbe8b3` (the last commit before removal).

```bash
git diff 6fbe8b3..HEAD -- <file-path>   # see what was removed
git show 6fbe8b3:<file-path>             # view the old version
```

---

## Standard Generation Mode (ComfyUI / Qwen-Image)

**What it did**: REST-based image generation. User draws on canvas, taps "Generate", sketch is sent to ComfyUI running Qwen-Image with InstantX ControlNet Union on a RunPod H100 pod. Results returned as URLs. Supported advanced parameters (ControlNet strength, CFG scale, steps, denoise, AuraFlow shift, LoRA strength, negative prompt, seed). Had auto-trigger mode (generate on every stroke change) and manual mode.

**Key files removed**:
- `ios/Kiki/App/GenerationPipeline.swift` — orchestrated REST generation requests
- `ios/Kiki/App/GenerationTriggerMode.swift` — auto/manual trigger enum
- `ios/Packages/NetworkModule/Sources/NetworkModule/GenerateRequest.swift` — REST request model
- `ios/Packages/NetworkModule/Sources/NetworkModule/GenerateResponse.swift` — REST response model
- `ios/Packages/NetworkModule/Sources/NetworkModule/AdvancedParameters.swift` — ComfyUI parameter struct (controlnet, CFG, steps, denoise, etc.)
- `ios/Packages/NetworkModule/Sources/NetworkModule/GenerationMode.swift` — preview/refine enum
- `ios/Packages/NetworkModule/Sources/NetworkModule/APIClient.swift` — REST HTTP client
- `ios/Kiki/Views/DebugComparisonModal.swift` — side-by-side comparison (with/without ControlNet)
- `backend/src/routes/generate.ts` — POST /v1/generate endpoint
- `backend/src/modules/providers/comfyui.ts` — ComfyUI API adapter
- `backend/src/modules/providers/comfyui-workflow-api.json` — Qwen-Image workflow template
- `scripts/setup-pod.sh` — ComfyUI pod initialization (model download, symlinks, warmup)
- `.github/workflows/deploy-pod.yml` — ComfyUI pod creation and deployment

**Model details** (for future reference):
- Base model: `qwen_image_fp8_e4m3fn.safetensors`
- LoRA: `Qwen-Image-Lightning-8steps-V2.0.safetensors`
- ControlNet: `Qwen-Image-InstantX-ControlNet-Union.safetensors`
- CLIP: `qwen_2.5_vl_7b_fp8_scaled.safetensors`
- VAE: `qwen_image_vae.safetensors`

---

## StreamDiffusion (SD 1.5 Stream Engine)

**What it did**: Real-time img2img streaming using StreamDiffusion with SD 1.5 (Dreamshaper-8) + LCM-LoRA. Canvas captured at ~7 FPS, sent over WebSocket, generated images returned in real-time. Ran on the same RunPod pod as ComfyUI. Controlled via `t_index_list` parameter (lower = more creative, higher = more faithful).

**Key files removed**:
- `streamdiffusion-server/` — entire directory (server.py, pipeline.py, config.py, Dockerfile, test_client.py)
- `ios/Packages/NetworkModule/Sources/NetworkModule/StreamConfig.swift` — SD-specific WebSocket config (tIndexList)
- `backend/src/modules/providers/streamdiffusion.ts` — WebSocket relay class
- `scripts/setup-streamdiffusion.sh` — StreamDiffusion pod setup (venv, model download, server launch)
- `.github/workflows/deploy-streamdiffusion.yml` — deployment workflow
- `documents/references/streamdiffusion.md` — reference documentation

**Model details**:
- Base model: `Lykon/dreamshaper-8` (SD 1.5)
- Acceleration: `latent-consistency/lcm-lora-sdv1-5`
- Resolution: 512x512
- Config: t_index_list `[20, 30]`, guidance_scale 1.0, similarity filter threshold 0.98

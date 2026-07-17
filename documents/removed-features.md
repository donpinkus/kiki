# Removed Features

Reference for removed features. Each entry names the last commit that contained the feature.

For the two oldest entries (ComfyUI, StreamDiffusion), that commit is `6fbe8b3`.

```bash
git diff 6fbe8b3..HEAD -- <file-path>   # see what was removed
git show 6fbe8b3:<file-path>             # view the old version
```

---

## RunPod Pod Orchestration (image + video pods)

**Removed:** 2026-07-17, commit `b0fede2` (recover from its parent `d9e3c43`).

**What it did**: Provisioned per-session GPU pods on RunPod — RTX 5090 spot
pods running FLUX.2-klein (the pre-fal image path, dormant since 2026-06-06)
and H100 SXM pods running LTX-2.3 for the video idle-state animation. Redis
session registry (sessions survived deploys), DC placement + spot/on-demand
fallback, boot watchdog + DC reroll, idle reaper, orphan reconcile, cost
monitor with Discord alerts, provision rate limiter, per-DC network volumes
holding weights + venv + app code (volume-entrypoint deploys via
sync-flux-app.ts), and the /v1/ops cost endpoints.

**Why removed**: fal.ai replaced the image path in production; the Lambda
Cloud path (fixed VMs, no pod orchestration) is the in-progress self-hosted
alternative; video was off. The orchestration layer (Redis included) existed
to manage pod lifecycles — with no pods there was nothing to orchestrate.

**Key deletions**: `backend/src/modules/orchestrator/` (12 files),
`backend/src/modules/redis/`, `backend/src/modules/auth/rateLimiter.ts`,
`backend/src/routes/ops.ts`, RunPod scripts (populate/sync/test-pod/probe),
`.github/workflows/{build-flux-image,stop-pods}.yml`,
`model-servers/Dockerfile`, the video relay path in `routes/stream.ts`.

**Still alive**: the LTX video *serving* code is archived (not deleted) in
`archive/video-ltx/` for the planned Lambda video port, and the iOS video
render path (`VideoEvent`, `ResultState.videoStreaming/.videoLooping`,
`LoopingVideoView`) is intact — it's inert until a backend sends `video_*`
messages again. The RunPod network volumes + any Railway env vars
(RUNPOD_API_KEY, NETWORK_VOLUMES_*, REDIS_URL, COST_*, OPS_API_KEY) are now
unused — delete the volumes/addon to stop the ~$49/mo storage spend.

---

## PostHog Product Analytics

**Removed:** 2026-07-17, commit `0805dfe`.

**What it did**: Product-event analytics (funnels, cohorts) via posthog-node
on the backend and posthog-ios on the iPad, with typed `track*()` wrappers.

**Why removed**: Kiki Insights (analytics/) replaced it as the analytics
store — same events, per-user timelines, session replay, owned data. Events
were already dual-written; removal just dropped the PostHog leg. Sentry stays
for errors/logs.

**Note**: the PostHog cloud project still holds historical events (project
389365); the account can be closed whenever the history stops being useful.

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

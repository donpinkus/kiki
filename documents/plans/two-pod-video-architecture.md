# Two-Pod Video Architecture — Implementation Context

> GitHub Issue: #25
> Status: Blocked on stabilizing single-pod FLUX flow first
>
> Video code was fully implemented and working (except OOM) in commits
> `e00a1e2..89908a6` on main (2026-04-19). All video code was then removed
> in a cleanup commit to stabilize the image-only flow. Use `git log --oneline
> e00a1e2..89908a6` to see the full video implementation history and
> `git show <sha>` to recover any specific file.

## Why This Exists

We tried running FLUX.2-klein (img2img, ~29GB VRAM) and LTXV 2B 0.9.8 distilled (video, ~25GB VRAM) on the same RTX 5090 (32GB). Every approach failed:
- `.to("cuda")` for both: OOM immediately
- `enable_model_cpu_offload()` for LTXV: OOM — FLUX already uses 29GB, and the T5 text encoder alone is ~19GB
- Shared `gpu_lock` for serialization: doesn't help with VRAM, only prevents concurrent CUDA kernel execution

The solution: two separate 5090 pods per user session. Full plan is in the GitHub issue.

## Learnings from the Failed Single-Pod Attempt (2026-04-19)

These are specific gotchas we hit that will be relevant when implementing the two-pod approach.

### Model & Pipeline

- **LTXV 0.9.8 distilled** is the right model. The originally proposed `LTX-Video-2B-v0.9.1-distilled` is a **gated HuggingFace repo** — requires auth. We switched to the public 0.9.8 distilled.
- The 2B 0.9.8 checkpoint is a **single safetensors file** (`ltxv-2b-0.9.8-distilled-fp8.safetensors`, 4.46GB) inside the `Lightricks/LTX-Video` repo. It is NOT a standalone repo.
- Must load via `LTXVideoTransformer3DModel.from_single_file()`, NOT `AutoModel.from_single_file()` — the latter doesn't exist in the diffusers version on the pod.
- The base pipeline (VAE, text encoder T5-XXL ~19GB, scheduler) comes from `Lightricks/LTX-Video-0.9.5` repo.
- Uses `LTXConditionPipeline` API (not the older `LTXImageToVideoPipeline`). Image conditioning via `LTXVideoCondition(video=video_cond, frame_index=0)`.
- The conditioning requires video-codec-compressed input: `export_to_video([keyframe], tmp.mp4)` → `load_video(tmp.mp4)`. This requires `imageio[ffmpeg]`.
- Distilled timestep schedule: `[1000, 993, 987, 981, 975, 909, 725]` (7 steps). `guidance_scale=1.0`. `decode_timestep=0.05`, `decode_noise_scale=0.025`.
- FP8 layerwise casting: `transformer.enable_layerwise_casting(storage_dtype=torch.float8_e4m3fn, compute_dtype=torch.bfloat16)` — stores weights in FP8, computes in BF16.

### Docker / Deployment

- The base image `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` uses **Python 3.12**. The `X | None` union type syntax in type hints fails at class-definition time. All Python files need `from __future__ import annotations`.
- `FLUX_IMAGE` on Railway should use the `:latest` tag, NOT SHA-pinned. GitHub Actions' `github.sha` is the **merge commit SHA** (created by GitHub), which differs from the local git commit SHA. This caused `manifest unknown` errors when we pinned to the wrong SHA.
- The GH Actions workflow pushes both `:latest` and `:sha-<merge_commit>`. SHA tags exist for rollback.
- Docker image builds take ~3-5 minutes on GH Actions. The `pip install diffusers` from git is the slow step.

### Network Volumes

- All 5 DC volumes were resized from 50GB → 75GB to fit both FLUX + LTXV weights (~52GB total).
- Volumes: EUR-NO-1 (`49n6i3twuw`), EU-RO-1 (`xbiu29htvu`), EU-CZ-1 (`hhmat30tzx`), US-IL-1 (`59plfch67d`), US-NC-1 (`5vz7ubospw`).
- EU volumes (3/5) are populated with LTXV weights. US volumes need population when 5090 capacity is available.
- LTXV weights on volumes: `Lightricks/LTX-Video-0.9.5` (base, ~22GB sans transformer) + `ltxv-2b-0.9.8-distilled-fp8.safetensors` (~4.5GB).
- Both FLUX and LTXV pods can mount the same volume simultaneously (RunPod read-shared).
- The populate script is `backend/scripts/populate-volume.ts`. It downloads FLUX + LTXV weights. Idempotent.

### iOS Video Handling (Already Implemented)

The iOS client-side video support is already built and working:
- `StreamWebSocketClient.VideoEvent` enum: `.frame(Data)`, `.complete(Data)`, `.cancelled`
- `ResultState.videoStreaming(baseImage:, latestFrame:, framesReceived:)` and `.videoLooping(mp4URL:, fallbackImage:)`
- `LoopingVideoView` (UIViewRepresentable wrapping AVQueuePlayer + AVPlayerLooper) with deinit cleanup
- `AppCoordinator.handleVideoEvent()` writes MP4 to NSTemporaryDirectory, manages lifecycle
- `videoAvailable: Bool?` property on AppCoordinator, surfaced from server `video_ready` status
- "Video animation unavailable" badge in DrawingView when `videoAvailable == false`
- "ANIMATING" purple badge during frame streaming
- `FloatingResultPanel` handles `.videoStreaming` and `.videoLooping` cases

All of this stays unchanged in the two-pod architecture — the backend relay forwards video events in the same JSON format.

### Orchestrator Edge Cases Documented

The orchestrator header (`backend/src/modules/orchestrator/orchestrator.ts`) has a 10-row edge case matrix covering all known pod lifecycle scenarios. When implementing the two-pod architecture, this matrix needs to be updated to cover:
- FLUX pod preempted, video pod stays
- Video pod preempted, FLUX pod stays
- Both pods preempted
- Video pod OOM or crash (shouldn't affect FLUX)
- Video pod provisioning failure

### Current Bugs / Known Issues (as of 2026-04-19)

1. **Reconnect after provisioning failure is fragile** — we increased attempts to 5 with proper backoff and added `reconnectAttempts = 0` reset on server-sent errors. May still need testing.
2. **Capture loop runs on gallery page** — `StreamSession.startCaptureLoop()` fires as soon as the WebSocket connects, even before the user enters a drawing. Spams logs with "canvas empty". Should be decoupled from connection lifecycle.
3. **`waitForRuntime` detects vanished pods** — throws immediately if `getPod()` returns null. But a pod that exists but has a stuck container pull still waits the full 10 minutes.
4. **US-IL-1 and US-NC-1 volumes** need LTXV weight population (no 5090 on-demand capacity was available on 2026-04-19).

### Key File Locations

| What | Path |
|------|------|
| FLUX pod server | `flux-klein-server/server.py` |
| FLUX pod pipeline | `flux-klein-server/pipeline.py` |
| Video pipeline (to be moved) | `flux-klein-server/video_pipeline.py` |
| FLUX pod Dockerfile | `flux-klein-server/Dockerfile` |
| FLUX image workflow | `.github/workflows/build-flux-image.yml` |
| Backend stream route | `backend/src/routes/stream.ts` |
| Backend orchestrator | `backend/src/modules/orchestrator/orchestrator.ts` |
| Backend StreamRelay | `backend/src/modules/relay/streamRelay.ts` |
| Backend config | `backend/src/config/index.ts` |
| iOS StreamSession | `ios/Kiki/App/StreamSession.swift` |
| iOS AppCoordinator | `ios/Kiki/App/AppCoordinator.swift` |
| iOS WS client | `ios/Packages/NetworkModule/Sources/NetworkModule/StreamWebSocketClient.swift` |
| iOS ResultState | `ios/Packages/ResultModule/Sources/ResultModule/ResultState.swift` |
| iOS ResultView + LoopingVideoView | `ios/Packages/ResultModule/Sources/ResultModule/ResultView.swift` |
| Volume populate script | `backend/scripts/populate-volume.ts` |
| Edge case matrix | `backend/src/modules/orchestrator/orchestrator.ts` (file header) |

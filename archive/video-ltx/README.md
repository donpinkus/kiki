# Archive: LTX video idle-state animation (for future Lambda port)

Archived 2026-07-17 when the RunPod pod-orchestration system was removed from
the backend. The video idle-state feature (generate a short animation from the
user's drawing when they pause) is **planned to return on Lambda Cloud** — this
directory holds everything reusable for that port.

## What's here

| File | What it is | Provider coupling |
|---|---|---|
| `video/pipeline.py` | `Ltx23VideoPipeline` — LTX-2.3 22B distilled FP8 via Lightricks' `ltx-pipelines.DistilledPipeline` (two-stage: half-res + 2× upsample), persistent-model build (transformer + Gemma-3-12B held resident), warmup, tensor→JPEG conversion, audio decode, per-substage timing | Mostly agnostic. RunPod-coupled bits: `_resolve_hf_cache_path`/`_resolve_hf_snapshot_path` assume weights at `/workspace/huggingface` with `HF_HUB_OFFLINE=1`; `.version.json` stamp reads `/workspace/app` |
| `video/server.py` | FastAPI WS server. Protocol in the module docstring: `video_request`/`video_cancel` in; `status`, `video_frame`+binary JPEG, `video_complete`+binary MP4, `video_cancelled` out. One-in-flight-per-connection cancellation; ffmpeg MP4 mux via `imageio_ffmpeg` | Agnostic (binds 0.0.0.0:8766). Imports `shared/` modules that still live in `model-servers/shared/` |
| `video_client.py` | CLI WS test client exercising the exact protocol | Agnostic |
| `ltx_config_extract.py` | The LTX section removed from `model-servers/shared/config.py` — model repos/files, Gemma text-encoder repo (gated, needs HF_TOKEN), resolution/frame constraints (%64 / (n-1)%8 rules), FP8 notes | Agnostic except the `/workspace` comments |
| `requirements-video.txt` | Video-only deps (ltx-core, ltx-pipelines pinned SHA, imageio-ffmpeg) split out of `model-servers/requirements.txt` | — |
| `docs/two-pod-video-architecture.md` | Design + context for the image/video pod split, single-pod OOM learnings | RunPod-era but the reasoning carries |
| `docs/drawing-animation.md` | Original idle-state animation plan (trigger semantics, silent-fallback, `video_*` protocol decisions) | Mostly agnostic |
| `docs/runpod-model-serving-playbook.md` | Persistent-model serving playbook (OOM/perf diagnosis, dev iteration loop) distilled from the LTX work | GPU-level, portable |
| `docs/perf-investigations/` | torch-profiler traces, torch.compile experiments, attribution scripts | GPU-level, portable |

## What was deleted (recover from git history)

The backend orchestration + relay for video pods was deleted, not archived —
it was RunPod-shaped (GraphQL provisioning, proxy URLs, network volumes) and a
Lambda port will look like the image dev-pool instead. If you need it:

- Last commit containing it: `d9e3c43` (the parent of the removal commit
  `b0fede2`, 2026-07-17).
- Key deleted pieces: `backend/src/modules/orchestrator/` (video quartet in
  `orchestrator.ts`, `POD_CONFIGS.video` in `provisioner.ts`,
  `BOOT_DOCKER_ARGS_VIDEO` in `podBoot.ts`), the video relay block in
  `backend/src/routes/stream.ts` (`wireVideoRelay`, `handleVideoUpstreamClose`,
  queueEmpty→`video_request` trigger), and scripts `launch-test-pod.ts` /
  `debug-video-load.ts` / `populate-volume.ts` (LTX weights populate).

## What still lives in the repo (intentionally)

- **iOS video handling is intact**: `StreamWebSocketClient.VideoEvent`
  (`video_frame_data`/`video_complete_data`/`video_cancelled` parsing),
  `AppCoordinator.handleVideoEvent`, `ResultState.videoStreaming/.videoLooping`,
  `LoopingVideoView`. The client is purely message-driven — if the backend
  never sends `video_*`, nothing triggers. Reviving video = backend sends the
  same wrapped messages again; no client change needed.
- `model-servers/shared/` (config, sentry_init, preparing_heartbeat) — still
  used by the image server on Lambda; `video/server.py` imports these.
- The `queueEmpty` semantics: the fal image relay still synthesizes
  `frame_meta{queueEmpty}` before each frame (kept for exactly this revival).

## Porting notes for Lambda

- Follow the image path's pattern: `backend/scripts/lambda/setup-lambda.ts`
  populates a VM (it previously `--exclude`d `video/` from the rsync — include
  it), `backend/src/modules/lambda/devPool.ts` keeps a warm instance,
  `KIKI_WS_TOKEN` (see `model-servers/image/server.py`) is the auth seam for
  raw VMs instead of RunPod's unguessable proxy hostnames.
- H100 = Hopper: FP8 via scaled_mm may differ from the RunPod config —
  `ltx_config_extract.py` documents the LTX_FP8_MODE notes.
- Weights: Gemma-3-12B text encoder is gated behind Google's Gemma terms —
  populate needs an `HF_TOKEN` that accepted them.
- **License**: LTX-2 Community License Agreement (NOT Apache-2.0; restricts
  commercial use ≥ $10M revenue). Verify before App Store submission.

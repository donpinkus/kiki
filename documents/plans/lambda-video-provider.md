# Lambda Cloud video provider (LTX-2.3 idle-state animation) — POC

**Status (2026-07-18):** POC BUILT, not yet live-tested on an H100. All backend
logic verified end-to-end against a mock video server speaking the exact wire
protocol (`backend/src/modules/video/videoSession.test.ts`, 7 tests). The live
H100 test needs `LAMBDA_API_KEY` + `HF_TOKEN` (see Runbook below) — neither is
available in the remote session that built this.

This revives the RunPod-era idle-state animation (archived 2026-07-17 in
`archive/video-ltx/`) on Lambda Cloud, per the launch decision "revisit as an
LTX-on-Lambda port later."

## What it does

3 seconds after the user's **last sketch frame** (i.e. they stopped drawing),
the backend sends the **latest generated image** + prompt to a dedicated
LTX-2.3 H100, which animates it into a ~6 s MP4 (512², 145 frames @ 24 fps,
with audio) streamed back to the iPad. iOS's video render path
(`VideoEvent` parsing, `ResultState.videoStreaming/.videoLooping`,
`LoopingVideoView`) was never removed — the render-path wire contract
(`video_frame_data` / `video_complete_data` / `video_cancelled`) is
byte-identical to the RunPod era.

**Manual trigger (added same day):** an **Animate** button in the drawing
top bar (`DrawingTopBar`) sends `{type:'animate'}` up the stream WS; the
backend fires the video immediately (bypassing the idle window), reusing the
same pipeline. Two small additions to the wire contract: the backend emits
`{type:'video_started', requestId}` whenever a video_request fires (auto OR
manual) — the button flips to a disabled "Animating…" until
`video_complete_data`/`video_cancelled` — and a manual request that can't
run (video disabled, no image yet, dead relay) gets a synthesized
`video_cancelled` with an `error` reason so the button always resets.
iOS state: `AppCoordinator.isAnimating` / `requestAnimate()`,
`StreamSession.requestAnimate()`, `VideoEvent.started` parsing.

## Architecture decisions (POC)

- **Dedicated video H100 — never shared with the image pool.** Not just for
  priority: it physically can't share. LTX-2.3 22B FP8 + Gemma-3-12B hold
  ~46 GiB resident; the image server's 9B-KV path holds ~37 GiB — over 80 GB
  combined. Consequence: image-generation latency is structurally unaffected
  by video (Donald's constraint: "image generation should always have
  priority"). The video fleet scales independently (and much more slowly —
  one instance serves many users since videos are one-shot ~15-30 s jobs,
  serialized by the pipeline lock with fair per-connection cancellation).
- **Trigger = backend-side 3 s idle timer** (`VIDEO_IDLE_TRIGGER_MS`),
  replacing the RunPod-era pod-side `queueEmpty` signal. Provider-agnostic:
  works whether the image path is fal or lambda (the old trigger only worked
  on our own image server). The timer arms on every sketch frame from the
  iPad; when it fires, the video request uses the newest generated image —
  and if the final generation is still in flight at fire time, the trigger
  waits and fires the moment that image lands (freshness tracked by sequence
  counter, so the video always animates the finished drawing). One video per
  idle period; drawing again cancels any in-flight video (`video_cancel`)
  and re-arms.
- **Best-effort everywhere.** Video session wiring failure, instance death,
  reconnect failure — all degrade to image-only with a log line, never an
  iPad-visible error. Mirrors the RunPod-era policy.
- **Production topology (2026-07-18, launch-blocking): a managed video pool
  sharing the image pool's orchestration.** `devPool.ts`'s machinery was
  factored into `modules/lambda/instancePool.ts` (launch-with-retry,
  boot-watch on OUR /health, redeploy adoption by name prefix + HMAC token,
  suspect marking, 3-strike health kills, pressure autoscale, idle reap,
  `lambda_pool_events` telemetry — now with a `pool` column separating
  fleets) and instantiated twice: the image pool (`devPool.ts`, behavior
  unchanged) and the video pool (`videoPool.ts`, `kiki-video-*` on
  `kiki-video-<region>`). **Video scales deliberately slowly**: a video
  "stream" is a connected drawing session that only occasionally generates a
  one-shot ~15-30s job, so `LAMBDA_VIDEO_POOL_TARGET_STREAMS=8` (vs the
  image pool's 4) and `LAMBDA_VIDEO_POOL_MAX=1` by default — overload just
  queues/lates/cancels videos (best-effort by design), so the ceiling only
  rises when trigger→complete latency shows real queueing. Floor 0 +
  interest-based warm-up: app-open (`/v1/dev/lambda/ensure` side-effect) and
  every stream open touch the pool; the next 60s tick launches an instance;
  30-min idle reaps it. Sessions that start before the pool warms are
  image-only and **lazily upgrade mid-session** (VideoSession re-acquires a
  slot on each fire attempt). There is no fal-style video fallback — "no
  video" IS the fallback. `LAMBDA_VIDEO_URL` remains as a static dev
  override that takes precedence over the pool (mirrors LAMBDA_IMAGE_URL).
- **Same TLS + auth scheme as the image fleet.** `/ws?token=` gate
  (HMAC(LAMBDA_API_KEY, instance-name)) + the shared self-signed fleet cert
  (`~/.kiki/lambda-tls` → `$FS/kiki/tls/`), pinned by the backend's existing
  `LAMBDA_TLS_CA_B64`. One pin covers both fleets.
- **No metering in the POC.** Lambda video frames are not billed to
  `monthly_usage` yet — the gate is env-presence and the tester is Donald.
  Decide $/video before non-test users (a ~20 s H100 generation ≈ $0.024 raw).

## What was built (2026-07-18)

| Piece | Where |
|---|---|
| Video server, Lambda-ified (token gate on /ws + wss support added to the archived RunPod server) | `model-servers/video/{server,pipeline}.py` |
| LTX config restored (was archived) | `model-servers/shared/config.py` |
| Video venv requirements (separate from image venv) | `model-servers/requirements-video.txt` |
| Idle-trigger + video relay (per-stream state machine) | `backend/src/modules/video/videoSession.ts` |
| Stream wiring: 5 hooks (create/start, sketch, config, generated, close) | `backend/src/routes/stream.ts` |
| Config: `LAMBDA_VIDEO_URL`, `VIDEO_IDLE_TRIGGER_MS` | `backend/src/config/index.ts` |
| Region filesystem populate (weights + venv + boot.sh + TLS) | `backend/scripts/lambda/setup-lambda-video.ts` |
| Serving-instance launch / list / terminate | `backend/scripts/lambda/launch-video.ts` |
| Protocol test client (now with `--insecure` for the fleet cert) | `model-servers/dev/video_client.py` |
| Mock-server e2e tests of trigger semantics + iPad contract | `backend/src/modules/video/videoSession.test.ts` |

Sizing note (from the RunPod era, unverified on Lambda): filesystem holds
venv (~8 GB) + LTX 22B checkpoint (~45 GB) + upscaler (~1 GB) + Gemma-3-12B
(~24 GB) ≈ **~80 GB ≈ $16/mo** at $0.20/GiB-mo.

## Runbook — live H100 test (needs Donald's credentials)

Prereqs in repo-root `.env.local`: `LAMBDA_API_KEY`, `HF_TOKEN` (must have
accepted Google's Gemma license for `google/gemma-3-12b-it-qat-q4_0-unquantized`
— the same token used for the RunPod populate works). All commands from
`backend/`.

```bash
# 0. Capacity check (H100 SXM flaps minute-scale in us-south-2 — retry loops built in)
tsx scripts/lambda/capacity.ts --filter h100

# 1. One-time per region: create + populate kiki-video-<region> (~30-60 min,
#    ~70 GB downloads; ends with an on-instance pipeline load + warmup smoke test)
tsx scripts/lambda/setup-lambda-video.ts --region us-south-2 --retry-mins 30

# 2. Launch the serving instance; polls /health until the model is loaded,
#    then prints the backend env line:
#      LAMBDA_VIDEO_URL=wss://<ip>:8766/ws?token=<hex>
tsx scripts/lambda/launch-video.ts --region us-south-2 --retry-mins 30

# 3a. Protocol test WITHOUT the backend/iPad (from repo root):
python3 model-servers/dev/video_client.py --url '<LAMBDA_VIDEO_URL>' \
  --image backend/scripts/lambda/test-sketch.jpg --prompt "gentle wind, subtle motion" --insecure
#     → saves output.mp4 + video_last_frame.jpg

# 3b. Full-path test, static instance: set LAMBDA_VIDEO_URL for the backend
#     (local `npm run dev` env or Railway + `npm run deploy`), open a drawing
#     on the iPad, draw, stop for 3 s → the result pane should morph into a
#     looping animation. Nothing else needs enabling; iOS is message-driven.
#
# 3c. PRODUCTION path (managed pool): skip launch-video.ts entirely — set on
#     Railway:  LAMBDA_VIDEO_POOL_ENABLED=true   (leave LAMBDA_VIDEO_URL unset)
#     optional: LAMBDA_VIDEO_REGION / LAMBDA_VIDEO_POOL_MIN|MAX|TARGET_STREAMS
#     then `npm run deploy`. Opening the app / starting a stream is pool
#     interest → an instance launches within ~1 tick (60s) + ~5-10 min boot;
#     sessions upgrade to video mid-session when it's ready; 30 min idle
#     reaps it. A launch-video.ts instance left running gets ADOPTED by the
#     pool at the next backend deploy (same name prefix + token scheme).

# 4. When done — nothing left billing ($4.29/hr!)
tsx scripts/lambda/launch-video.ts --terminate
```

Budget guide: setup ~1 h + a test session ~1-2 h on one H100 SXM ≈ **$10-15**,
well inside the $50 POC budget. The filesystem (~$16/mo) persists so later
launches skip the populate.

### What to check on the live run

1. `launch-video.ts` reaches READY (watch for `/health` `status:error` — it
   surfaces the load traceback; `ssh ubuntu@<ip>` + `journalctl -u kiki` for
   the rest). First boot per region pays full model load; note the time.
2. `video_client.py` returns a playable `output.mp4` (~15-30 s generation
   expected per the RunPod-era steady state; H100 SXM should be ≥ RunPod).
3. iPad end-to-end: draw → pause 3 s → animation appears; draw again →
   animation cancels back to live frames (backend logs `video_trigger`,
   `video_cancel_sent`, `video_relay_wired` under the session's `user_id`).
4. GPU sharing sanity: two simultaneous test sessions → both get videos
   (serialized, second one just waits; server-side lock + cancellation was
   verified fair in the RunPod era).

## Known gaps / next steps (post-POC)

- **Metering decision** — per-video charge into `monthly_usage`?
- **Sentry on the instance** — `SENTRY_DSN_POD` isn't set by boot.sh yet
  (same gap as the image fleet; wire both together).
- **`archive/video-ltx/` docs** (two-pod architecture, perf investigations,
  playbook) remain the deep reference; the archive's serving code is now
  live again under `model-servers/video/`.
- **License**: LTX-2 Community License (NOT Apache-2.0, restricts commercial
  use ≥ $10M revenue) — verify before App Store submission. Unchanged.
- Prompt shaping for animation (the image prompt is reused verbatim; the
  RunPod era had a `videoPromptSuffix` passthrough, still supported).

# Plan: Drawing-stopped Video Animation (LTXV, separate pod)

## Context

When the user pauses drawing, Kiki's img2img pipeline is idle — the FLUX
pod has nothing useful to do. We want to fill that idle time with a short
video animation of the latest generated image (LTXV i2v), shown in the
right pane until the user resumes drawing.

A previous attempt co-loaded LTXV onto the FLUX pod. That branch
(`claude/add-drawing-animation-cWJBV`, local) had memory and concurrency
issues. **Decision: run video on a dedicated second pod per session.**
This plan is written to be implemented fresh against `origin/main`.

User-confirmed decisions:
1. **Separate video pod**, provisioned alongside the image pod.
2. **iPad protocol unchanged at the WS-level discriminator layer** (single
   WS to backend); only adds new inbound `video_*` message types.
3. **Silent fallback**: if the video pod fails to provision, image gen
   continues normally. No error surfaced to the iPad.
4. **Stream frames as they decode, then loop the final MP4** for smooth
   playback.
5. **Trigger logic**: pod-side `queueEmpty` flag on the image pod's
   `frame_meta` preamble (rejected: backend counter — desyncs on
   reconnects/drops; image hash — fragile to JPEG re-encode noise).

## Architecture

```
iPad ──single WS──► Backend ──relay 1──► Image pod (FLUX, unchanged except
                                          frame_meta gains queueEmpty flag)
                       │              ◄── frame_meta{queueEmpty} + JPEG
                       │
                       └──relay 2──► Video pod (LTXV, NEW)
                                  ◄── video_frame + JPEG (streaming),
                                      then video_complete + MP4
                       │
                  iPad ◄──── relay 1 JPEG (img2img)
                  iPad ◄──── relay 2 video_frame / _complete / _cancelled
```

Trigger flow:
- iPad has dirty check (strokeCount unchanged → skip send). When user
  stops drawing, the image pod's single-slot `latest_frame` buffer drains.
- On the response immediately following a drained buffer, the image pod
  sets `queueEmpty:true` in its `frame_meta` preamble.
- Backend, seeing `queueEmpty:true`, captures that JPEG and forwards it
  to the video pod as `{type:"video_request", image_b64, prompt}`.
- Video pod streams frames + MP4 back. Backend forwards to iPad.
- Any new sketch from the iPad → backend sends `{type:"video_cancel"}` to
  the video pod, which aborts via `callback_on_step_end` and emits
  `video_cancelled`. iPad swaps state back to `.streaming`.

## Pod side

### `flux-klein-server/server.py` (image pod — minimal change)
- Extend `frame_meta` preamble to include `queueEmpty: latest_frame is None`
  evaluated at frame-completion time. Single-line change in the existing
  `frame_meta` JSON construction (~line 191 on origin/main).
- Send `frame_meta` for *every* generated frame (currently only when
  `requestId` is set). Backend needs the flag on every frame.

### `flux-klein-server/video_server.py` (NEW)
- FastAPI WS server, mirrors the structure of `server.py`.
- Lifespan: load `LTXImageToVideoPipeline` (BF16, CUDA) once.
- `/health` returns `{video_ready, model_id, vram_free_gb}`.
- `/ws` per-connection state machine:
  - On `{type:"video_request", image_b64, prompt, seed?}`:
    1. Decode image → PIL.
    2. Run pipeline with `callback_on_step_end` checking
       `cancel_event.is_set()`. Emit each decoded frame as
       `{type:"video_frame"}` + JPEG.
    3. After generation: ffmpeg-encode frames → MP4 (H.264 yuv420p
       CRF 28 ~24fps), send `{type:"video_complete"}` + MP4 bytes.
  - On `{type:"video_cancel"}`: set `cancel_event`. Loop emits
    `{type:"video_cancelled"}` and resets state.

### `flux-klein-server/video_pipeline.py` (NEW)
- `LtxvVideoPipeline` class: `load()`, `generate(image, prompt, seed,
  cancel_event) -> Iterator[PIL.Image]`. Mirrors `FluxKleinPipeline` shape.

### `flux-klein-server/requirements.txt`
- `imageio[ffmpeg]`, `numpy`. Diffusers from git already pulled in.

### Network volume / setup script
- `backend/scripts/populate-volume.ts` — add LTXV model snapshot
  download (~4GB).
- Volume setup script — `apt-get install -y ffmpeg`.

## Backend side

### `backend/src/modules/orchestrator/orchestrator.ts`
- Add `BOOT_DOCKER_ARGS_VIDEO` constant pointing at `video_server.py`
  (mirrors `BOOT_DOCKER_ARGS` ~line 184).
- Add `videoSessionKey(sessionId)` helper paralleling `sessionKey()`
  (~line 224). Redis key suffix `:video`.
- Add `provisionVideoPod(userId)` mirroring `provision()` but using
  `BOOT_DOCKER_ARGS_VIDEO` and the video session key. Reuses the same
  semaphore, reroll logic, error classification.
- Add `getOrProvisionSession(userId)` that calls `getOrProvisionPod` and
  `getOrProvisionVideoPod` in parallel. Returns
  `{imagePodUrl, videoPodUrl?}`. **Video pod is best-effort**: if its
  promise rejects, log + Sentry capture, return `videoPodUrl: null`.
- Reaper iterates over both key prefixes; both pods terminate on idle.
- Reconcile (boot) cleans `kiki-session-*` for both shapes.
- **Quota/entitlement**: only the image-pod provision counts against the
  user's quota. Video provisioning bypasses entitlement/rate-limit (it's
  a side-effect of an already-allowed session).

### `backend/src/routes/stream.ts`
- After identity + quota, call `getOrProvisionSession(userId)`.
- Open `StreamRelay` for the image pod (existing flow).
- If `videoPodUrl != null`, open a second `StreamRelay` for the video pod.
- Wire the trigger:
  - On image-pod text frame: parse `frame_meta`. Stash
    `nextBinaryQueueEmpty = parsed.queueEmpty`.
  - On image-pod binary frame: forward to iPad as today. If
    `nextBinaryQueueEmpty` was true AND video relay is connected,
    forward the JPEG to the video pod as `video_request` with the
    last-known prompt from the iPad's most recent `config` message.
  - On iPad sketch frame: if a video request is in flight, send
    `{type:"video_cancel"}` to the video pod.
  - On video-pod text/binary: forward to iPad unchanged (as
    `{type:"video_frame"}` / `{type:"video_complete"}` /
    `{type:"video_cancelled"}` JSON-wrapped binaries to fit the
    existing iOS WS workaround).
- Both relays call `touch()` on activity.
- Video relay close is silent: log + try once to reprovision lazily on
  next `queueEmpty:true`. No iPad-visible error.

### Config
- Cache the latest `prompt` per-connection in stream.ts (it already
  arrives on `config` messages from the iPad). Used to populate the
  `video_request`.

## iPad side

### `ios/Kiki/App/StreamSession.swift`
- Capture loop adds dirty check: track `lastSentStrokeCount`. Skip the
  send when `snapshot.strokeCount == lastSentStrokeCount` and config is
  unchanged. On config change, reset `lastSentStrokeCount = nil`.
  (Reuses existing `SketchSnapshot.strokeCount` already incremented in
  `MetalCanvasView` on stroke/erase/undo/redo/clear/background-change.)

### `ios/Packages/NetworkModule/.../StreamWebSocketClient.swift`
- Add `type` discriminators: `video_frame`, `video_complete`,
  `video_cancelled`.
- Expose `videoEvents: AsyncStream<VideoEvent>` alongside the existing
  frame stream. `VideoEvent` cases: `frame(UIImage)`,
  `complete(mp4Data: Data)`, `cancelled`.

### `ios/Packages/ResultModule/.../ResultState.swift`
- Add cases:
  - `videoStreaming(latestFrame: UIImage, fallback: UIImage)`
  - `videoLooping(mp4URL: URL, fallback: UIImage)`
- `fallback` keeps Constraint #2 (never clear the right pane) if anything
  goes wrong mid-video.

### `ios/Packages/ResultModule/.../ResultView.swift`
- Render `videoStreaming` like `.streaming` but pinned to `latestFrame`.
- For `videoLooping`, embed a `LoopingVideoView` (UIViewRepresentable
  wrapping `AVQueuePlayer` + `AVPlayerLooper` with a local MP4 URL,
  `videoGravity = .resizeAspect`).

### `ios/Kiki/App/AppCoordinator.swift`
- Subscribe to `session.videoEvents`:
  - `.frame(img)` → set `resultState = .videoStreaming(img, fallback: lastStill)`
  - `.complete(data)` → write MP4 to `FileManager.default.temporaryDirectory`,
    set `resultState = .videoLooping(url, fallback: lastStill)`
  - `.cancelled` → revert to `.streaming(lastStill, frameCount: ...)`
- On any new img2img frame received while in a video state → revert to
  `.streaming` and (if previously `.videoLooping`) delete the temp MP4.
- On `stopStream()`: clean up temp MP4 files.

## Files to modify / create

| File | Change |
|------|--------|
| `flux-klein-server/server.py` | add `queueEmpty` to `frame_meta`; emit on every frame |
| `flux-klein-server/video_server.py` | NEW — LTXV WebSocket server |
| `flux-klein-server/video_pipeline.py` | NEW — LTXV pipeline wrapper |
| `flux-klein-server/requirements.txt` | + `imageio[ffmpeg]`, `numpy` |
| `backend/scripts/populate-volume.ts` (or equiv.) | + LTXV weights |
| Volume setup script | + `apt install ffmpeg` |
| `backend/src/modules/orchestrator/orchestrator.ts` | `BOOT_DOCKER_ARGS_VIDEO`, `provisionVideoPod`, `getOrProvisionSession`, dual-key reaper/reconcile |
| `backend/src/routes/stream.ts` | second relay; `frame_meta.queueEmpty`-driven video trigger; cache prompt; cancel on new sketch |
| `ios/Kiki/App/StreamSession.swift` | dirty check on `strokeCount`; expose `videoEvents` |
| `ios/Packages/NetworkModule/.../StreamWebSocketClient.swift` | parse `video_*` types |
| `ios/Packages/ResultModule/.../ResultState.swift` | `.videoStreaming`, `.videoLooping` |
| `ios/Packages/ResultModule/.../ResultView.swift` | `LoopingVideoView` (AVPlayerLooper) |
| `ios/Kiki/App/AppCoordinator.swift` | wire video events; revert on new still; temp file cleanup |

## Existing utilities to reuse

- `SketchSnapshot.strokeCount` (`ios/Packages/CanvasModule/.../SketchSnapshot.swift`) — dirty signal.
- `latest_frame` single-slot buffer (`flux-klein-server/server.py`) — exact "no new sketch" signal.
- `StreamRelay` (`backend/src/modules/relay/streamRelay.ts`) — second relay reuses it as-is.
- `provision()` and provisioning machinery (`orchestrator.ts`) — `provisionVideoPod` parallels it.
- `pipeline.get_info()` health pattern — mirror for LTXV.
- `ResultState`'s `previousImage` convention — extend with `fallback`.

## Verification

1. **Both pods warm**: provision a session, hit each pod's `/health`.
   Image returns `quantization:"nvfp4"`, video returns `video_ready:true`.
2. **Trigger fires**: draw, stop. Backend log shows
   `frame_meta queueEmpty:true → video_request`. iPad swaps to
   `.videoStreaming` within ~1s of stopping (LTXV first frame), then
   `.videoLooping` once MP4 lands.
3. **Cancellation**: start drawing during video playback. iPad immediately
   reverts to `.streaming`. Video pod log shows `cancelled`.
4. **Once-per-still**: stop drawing; one video plays + loops; no second
   video kicks off (no new `queueEmpty:true` until a new image is
   generated).
5. **Silent fallback**: force `provisionVideoPod` to fail (bad model ID).
   Image gen still works end-to-end. Backend logs the failure once;
   iPad sees no error.
6. **Dirty check**: simulator log shows frame counter plateaus when
   user stops drawing. Changing the prompt or style forces one resend.
7. **Resource cleanup**: end session, both pods terminate via reaper.
   Redis keys for both suffixes deleted. Temp MP4 files removed on iPad.
8. **Existing test suites pass**: `xcodebuild test`,
   `swift test --package-path ios/Packages/CanvasModule`,
   `cd backend && npm test`.

## Diagnostics & Logging

A correlation ID flows through every video request so we can grep one ID
across all four log streams (iPad → backend → image pod → video pod).
Source it from the iPad's `config.requestId` (already supported); the
image pod echoes it in `frame_meta`; backend stamps the same ID onto the
`video_request`; video pod echoes it on every `video_frame` /
`video_complete` / `video_cancelled`.

### Image pod (`server.py`)
- Per generated frame, one INFO line including the new flag:
  `frame: req=<id> queueEmpty=<bool> gen_ms=<ms> dropped_since_last=<n>`.
- One INFO line on the false→true edge:
  `queue drained: req=<id> last_generated_set=true`. Confirms the
  trigger boundary cleanly.
- On disconnect, summary: `session: frames=<n> queue_drained_count=<n>`.

### Video pod (`video_server.py`, `video_pipeline.py`)
- Pipeline load: `loaded LTXV: model=<id> dtype=<bf16> vram_used_gb=<n>
  load_ms=<n>`.
- Connection: `client connected: in_flight=<n>` /
  `client disconnected: reason=<...>`.
- Request: `video_request: req=<id> prompt='<truncated 60ch>'
  image=<WxH> seed=<n>`.
- Per decoded frame (every Nth, INFO):
  `frame <i>/<total> decoded elapsed_ms=<ms>`.
- Per step (DEBUG, gated on `LTXV_DEBUG=1` env so prod stays quiet):
  `step <i>/<N> took_ms=<n>`.
- Cancellation: `cancelled: req=<id> at_step=<i> elapsed_ms=<ms>`.
- Completion: `complete: req=<id> frames=<N> gen_ms=<ms>
  encode_ms=<ms> mp4_bytes=<n>`.
- Pipeline error: full traceback + `req=<id>` so we can correlate.

### Backend orchestrator
- Distinct log prefixes for the two provisions: `[provision/image]` and
  `[provision/video]`. Existing structured logger already includes
  sessionKey — add a `pod_kind: 'image' | 'video'` field for filtering.
- Image-pod provision failures stay `level=error` (fatal). Video-pod
  failures `level=warn` (non-fatal) with a Sentry **breadcrumb**, not a
  capture (would be too noisy).
- Reaper: `[reaper] terminating session=<id> kind=<image|video>
  idle_min=<n>`.
- Reconcile on boot: `[reconcile] orphans found: image=<n> video=<n>`.

### Backend `stream.ts`
- One structured log per trigger:
  `video_trigger: user=<id> req=<id> prompt_cached=<bool>
   video_relay_connected=<bool>`.
- Drop reasons logged distinctly:
  - `video_skipped: reason=prompt_not_cached` (queueEmpty before iPad
    sent its first `config` — bug-prone edge case worth alerting on).
  - `video_skipped: reason=relay_disconnected`.
  - `video_skipped: reason=already_in_flight` (defensive — should not
    happen given queueEmpty semantics, but log if it does).
- Cancel: `video_cancel_sent: user=<id> req=<id> elapsed_since_request_ms=<n>`.
- Video relay close (uninitiated):
  `video_relay_closed: user=<id> reason=<code> session_disabled=<bool>`.
- Per-session counters emitted at WS close:
  `session_close: user=<id> frames_relayed=<n> videos_triggered=<n>
   videos_completed=<n> videos_cancelled=<n> videos_failed=<n>
   duration_s=<n>`.

### iPad
- `StreamSession.captureLoop` — rate-limited (max 1/s) DEBUG line:
  `frame skipped (strokeCount=<n> unchanged)` so we can verify the
  dirty check without log spam.
- `StreamSession` — INFO on every `video_*` event with bytes:
  `[video] req=<id> type=<t> bytes=<n>`.
- `AppCoordinator` — INFO on every `ResultState` transition:
  `[result] <prev> → <next> req=<id>`. Lets us confirm the
  `.streaming` ↔ `.videoStreaming` ↔ `.videoLooping` cycle.
- `LoopingVideoView` — log `AVPlayerItem.status` changes,
  `failedToPlayToEndTime` notifications, and any `AVPlayerLooper`
  error. These are the only sources of "video shows but doesn't
  loop" bugs.

### Health endpoints (prod observability)
- Image pod `/health` — add: `frames_total`, `queue_drained_count`,
  `last_queue_empty_at` (ISO ts), `last_frame_gen_ms`.
- Video pod `/health` — add: `videos_total`, `videos_cancelled`,
  `videos_failed`, `last_gen_ms`, `last_encode_ms`, `vram_free_gb`.
- Both surfaced via the orchestrator's existing health-poll path so
  they show up in cost-monitor breadcrumbs.

### Triage cookbook (paste into PR description)
- **Trigger not firing**: grep image pod for `queue drained`. Absent =
  iPad still sending; verify dirty check via the `frame skipped` line.
- **Trigger firing, video not requested**: grep `stream.ts` for
  `video_skipped`. The `reason=` says why.
- **video_request sent, video pod silent**: hit video pod `/health`
  directly; check `video_ready`. If false, model still loading.
- **Generation starts, no MP4**: search video pod for `complete` for
  that req=<id>. If only `cancelled`, look at backend for the
  preceding `video_cancel_sent`. If neither, search for traceback.
- **Looping playback stutters**: re-encode with `-movflags +faststart`
  in the ffmpeg call, and check `LoopingVideoView` logs for buffering
  events.
- **iPad swaps to video too aggressively**: filter
  `[result] streaming → videoStreaming` and verify each lines up with
  exactly one `queue drained` on the image pod.

## Open risks / follow-ups

- LTXV streaming-decode in current diffusers may not yield per-frame; if
  not, time-to-first-playback degrades from "first decoded frame" to
  "after generation completes". Plausibly still <3–4s on a 5090 at small
  resolutions and few steps. Acceptable for v1; revisit if not.
- ffmpeg subprocess adds ~200–500ms encode. Acceptable.
- Two pods per session ~2× the spot-cost. Idle reaper at 10min still
  bounds cost.
- Content safety: video output must pass NSFW filter before external
  TestFlight (Constraint #5). Out of scope here, follow-up PR.
- Video-specific prompt suffix: deferred. Easy to add later in the
  `video_request` builder in stream.ts.

# Kiki — iPad Sketch-to-Image App

iPad-native drawing app. User sketches on left pane, AI-generated image appears on right pane via real-time FLUX.2-klein streaming.
- **Target:** iPadOS 17+, landscape only (v1)
- **Current Phase:** Phase 1 — Prototype

## Quick Commands

### iOS
```bash
# Build
xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build
# Test all
xcodebuild -scheme Kiki -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' test
# Test single module
swift test --package-path ios/Packages/CanvasModule
# Lint & format
swiftlint --path ios/
swiftformat ios/
```

### Backend
```bash
cd backend && npm install          # Install deps
cd backend && npm run dev          # Dev server
cd backend && npm run build        # Build
cd backend && npm test             # Run tests
cd backend && npm run lint         # Lint
cd backend && npm run deploy       # Deploy backend + pod app code (see documents/references/pod-operations.md)
```

## Architecture Decisions (Decided — Do Not Propose Alternatives)

**iOS:** SwiftUI for UI. **Metal for drawing** (CAMetalLayer + CADisplayLink, instanced stamp-based brush engine — see Canvas Engine below). Swift Concurrency (actors, async/await) — no Combine. URLSession for networking — no third-party HTTP libs. SwiftData for persistence. 3 local Swift packages via SPM. AppCoordinator (@Observable) injected via environment.

**Backend:** TypeScript + Fastify — no Express. Railway for hosting. Backend is both a WebSocket relay AND a pod orchestrator: it provisions per-session pods (JWT-authenticated), relays frames to them, and terminates pods idle > 30 min. Two pod kinds, different GPUs: **image pods on RTX 5090** (FLUX.2-klein, NVFP4) and **video pods on H100 SXM 80 GB** (LTX-2.3 22B distilled FP8 + Gemma encoder). Two separate per-DC volume sets — image volumes in 5090-stocked DCs, video volumes in H100-SXM-stocked DCs (the GPU SKUs sit in disjoint DCs, so volumes can't be shared). Redis-backed session registry (survives deploys), semaphore caps concurrent cold starts. See `documents/references/provider-config.md` for the full ops picture.

**Generation:** FLUX.2-klein-4B on RunPod RTX 5090 spot for the live img2img path, with BFL's NVFP4 transformer checkpoint loaded on top of the BF16 pipeline. Real-time img2img streaming over WebSocket. Canvas captured at ~2 FPS, sent as JPEG, generated images returned ~1 FPS. Reference-mode only: the sketch is VAE-encoded and concatenated with generation latents as conditioning tokens. Server uses frame dropping (single-slot buffer) to prevent queue buildup. ~96s avg cold start (p95 ~157s) — pods boot from stock `runpod/pytorch` and read app code + venv off pre-populated network volumes that also hold the FLUX weights.

**Video idle-state animation:** LTX-2.3 22B distilled FP8 on H100 SXM 80 GB via Lightricks' official `ltx-pipelines.DistilledPipeline` (two-stage: half-res stage 1 + 2× upsample stage 2, 8+4 sigmas). Triggered when the image pod's `frame_meta.queueEmpty` flag fires (user paused drawing). Gemma-3-12B is the text encoder (gated — populate requires `HF_TOKEN` with Gemma terms accepted at huggingface.co). License is the **LTX-2 Community License Agreement** (NOT Apache-2.0, restricts commercial use ≥$10M revenue) — verify before App Store submission.

## Navigation & Persistence

State-based navigation via `AppCoordinator.currentScreen` (`.gallery` | `.drawing`). No NavigationStack.

- **Gallery view** (`GalleryView`) — root screen when drawings exist. 2-column grid of tiles. Uses `@Query` to observe SwiftData directly.
- **Drawing view** (`DrawingView`) — canvas + result split pane. Gallery button top-left navigates back. Stream starts automatically when entering a drawing.
- **Style picker** — `PromptStyle` model defines available styles. Selected style's `promptSuffix` is appended to the user's prompt client-side before sending to backend.
- **Drawing model** (`Drawing.swift`) — SwiftData `@Model` with `@Attribute(.externalStorage)` for image blobs (drawing data, background image, generated image, canvas thumbnail). Settings: prompt, style ID.
- **Auto-save** — debounced 1s on stroke/prompt changes.
- **Pending-state pattern** — `CanvasViewModel.setPendingState()` queues canvas data before navigation; `attach()` applies it when the canvas view is created.
- **Empty drawing cleanup** — `navigateToGallery()` deletes drawings with no content.

## Canvas Engine (Metal)

The drawing canvas uses a custom Metal-based rendering engine (`MetalCanvasView` + `CanvasRenderer`) for GPU-accelerated painting at 120 Hz. Key architecture:

- **Display**: `CAMetalLayer` (double-buffered, `.bgra8Unorm_srgb`) driven by `CADisplayLink`. Only renders when dirty.
- **Canvas texture**: `.shared` storage — GPU and CPU access the same unified memory. No CPU↔GPU copies per frame.
- **Brush rendering**: instanced stamp quads. Touch points → arc-length resampled positions → `StampInstance` buffer → single instanced draw call per frame. Adaptive spacing (stamp gap = 30% of pressure-modulated width) keeps strokes dense at all pressures.
- **Eraser**: stamps applied directly to canvas texture with destination-out blend, per touchesMoved. Undo snapshot taken at touchesBegan.
- **Active stroke**: rendered into a scratch texture (ephemeral), composited onto the canvas each frame. Flattened into the canvas texture on touchesEnded.
- **Undo**: full-texture CPU snapshots (`texture.getBytes()` → `Data`), depth 30. Restore via `texture.replace()`.
- **Stream capture**: reads canvas texture via `persistentImageSnapshot` (CGImage from `.shared` texture). **Never** uses `drawHierarchy` — that forces a synchronous GPU drain.
- **Lasso**: Phase 2 (path drawing works, selection extraction not yet implemented).
- **Smudge**: not yet implemented on Metal (reverted from a CPU attempt that hit <1 fps). Will be a ping-pong texture fragment-shader pass. See `documents/plans/metal-canvas-rewrite.md`.

### Performance invariants
- `applyEraserStamps` creates a temporary `MTLBuffer` per batch (no shared-buffer races) and commits **without** `waitUntilCompleted`.
- `flattenScratchIntoCanvas` is the only `waitUntilCompleted` on the drawing hot path — runs once per stroke end, not per frame.
- `clearTexture` uses `waitUntilCompleted` but only runs during canvas resize (not interactive).

## Module Dependencies

```
CanvasModule       → (none)
NetworkModule      → (none)
ResultModule       → (none)
AppCoordinator     → all 3 modules + SwiftData
```
Data flows one direction: Canvas → Network → Result. Modules communicate through AppCoordinator. No circular dependencies. No module imports the main app target.

## Critical Constraints (NEVER Violate)

1. **Canvas responsiveness is sacred.** Metal rendering NEVER depends on network/generation state. Target <8ms stroke latency at 120 Hz. NEVER call `drawHierarchy(afterScreenUpdates: true)` or `waitUntilCompleted()` on the main-thread hot path — use `texture.getBytes()` on `.shared` storage for CPU reads, and async command buffer commits for GPU writes.
2. **Never clear the right pane.** Always keep last successful image visible. Never show blank after first successful generation.
3. **No secrets on client.** Provider API keys and URLs backend only. Client NEVER calls inference providers directly.
4. **Code is private.** The GitHub repo is private. Never make Docker images, packages, or artifacts public — our source code is embedded in them. Never recommend exposing code publicly as a workaround for infrastructure problems.
5. **Content safety before external testing.** NSFW output filter + prompt input filter must be operational before any external TestFlight build.
6. **Privacy by design.** Sketch data is ephemeral on server — deleted after generation response.
7. **App Store compliance.** Must include: first-launch AI disclosure consent (guideline 5.1.2(i)), age gate (1.2.1(a)), content filtering, "Report this image" button.

## Cost during dev/testing

We do not optimize for cost during development, profiling, or one-off experiments. **Anything under $100 is negligible.** Don't waste time saving a few dollars by tearing down test pods between iterations, picking cheaper GPU SKUs that complicate debugging, or skipping a clean re-test because "we already paid for the data once." User-revenue scale dominates GPU spend by orders of magnitude; iteration speed is the real constraint. This applies to RunPod test pods, Railway redeploys, repeat profiler captures, and any other dev-time GPU/infra spend.

## Debugging rigor (applies to every diagnosis)

When diagnosing a failure, separate observations from inferences. Do not collapse multiple distinct failure modes into a single tidy narrative — cleaner stories mislead remediation.

- **List each failure mode on its own line with the specific evidence that supports it.** If two failures happened at different pipeline stages, they are almost certainly distinct root causes even if both produce the same user-visible symptom.
- **A step that completed had whatever precondition it needed, by definition.** A pod that was successfully created had capacity. A container that started had a working image. Don't count later failures as evidence against earlier conditions that were already proven.
- **Label claim strength.** Distinguish between "proven by event X", "consistent with but not proven", and "inferred from behavior Y". Weak and strong evidence must not share the same confident voice.
- **A punchy one-liner root cause is a warning sign.** If you catch yourself writing "everything is X" or "the whole thing is broken because Y", reopen the evidence — don't close it. The clean story usually dropped something that matters.

## Observability

**Three Sentry projects, one per platform:**

| Project | Covers | DSN env var | Notes |
|---|---|---|---|
| `kiki-ios` | Swift app | (in iOS app config) | iOS app errors + crashes |
| `kiki-backend` | Node/Fastify on Railway | `SENTRY_DSN` (Railway) | Backend orchestrator errors + structured logs |
| `kiki-pod` | Python image+video pods | `SENTRY_DSN_POD` (Railway → forwarded to pod env by orchestrator) | Forwarded by `orchestrator.ts` BOOT_ENV when set |

Pods log via stdlib `logging` → `LoggingIntegration` ships `INFO+` lines into Sentry's Logs product. Init lives in `flux-klein-server/sentry_init.py`, called from `server.py` (image) and `video_server.py` (video). `pod_kind:image|video` and `pod_id:<RUNPOD_POD_ID>` are attached **two ways**: as scope tags (covers errors/spans/transactions) and as log attributes via a `before_send_log` hook (covers the Logs product — scope tags don't propagate there, found out the hard way). No-op when `SENTRY_DSN_POD` is unset (local runs stay quiet).

**Pod logging conventions** — apply to every new `logger.X(...)` call in `flux-klein-server/`:

- **Use f-string body + `extra={...}`. Never positional `%s`/`%d`.** Positional args become opaque `message.parameter.0..N` indices in Sentry's Logs UI. f-strings render the body literally so the expanded view is human-readable, and `extra` keys auto-promote to top-level queryable attributes (Sentry SDK's `_extra_from_record` does this — same path used by `code.*` / `thread.*` / `process.*`).
- **Use `extra={}` for fields you'd want to filter or aggregate on** (e.g. `gen_ms`, `frames`, `client_id`). Skip it for throwaway diagnostics — no value in indexing every transient string.
- **Don't manually set `pod_kind` / `pod_id`.** The `before_send_log` hook in `sentry_init.py` injects them on every log. If you want pod-scoped attributes added globally, extend that hook — don't sprinkle them per-call.
- **Avoid stdlib LogRecord-reserved keys in `extra={}`** — `name`, `msg`, `args`, `levelname`, `levelno`, `pathname`, `filename`, `module`, `exc_info`, `exc_text`, `stack_info`, `lineno`, `funcName`, `created`, `msecs`, `relativeCreated`, `thread`, `threadName`, `processName`, `process`, `message`. Python's logging raises `KeyError` on collision. Prefix domain keys (`pod_id`, `client_id`, `gen_ms`) and you'll be fine.
- **`sentry_sdk.set_tag()` ≠ log attribute.** Tags propagate to errors/spans only, not to the Logs product. To attach something to log entries, use `before_send_log` (global) or `extra={}` (per-call).
- **Reading logs back via Sentry MCP `search_events`:** the MCP's query agent silently drops unrecognized attribute names from `fields=[...]` — if a field is missing from the response but visible in the Sentry UI, the data is fine, the MCP agent just didn't surface it. Cross-check in `donki.sentry.io` → Logs before chasing it as a code bug.

**Cross-stack `phase` attribute** — for filtering "what user-journey moment is this log from" across iOS / backend / pods. Single shared vocabulary; the layer dimension is filterable independently via Sentry project + `pod_kind`.

| `phase` value | When |
|---|---|
| `session_starting` | Fresh launch through "able to draw". Pod: model load + warmup. Backend: orchestrator provisioning. iOS: loading state. |
| `drawing` | Active drawing, image stream live. Pod: per-frame generation. Backend: WS relay. iOS: stroke handling + preview. |
| `animating` | User paused, video idle-state running. Pod: LTX inference + encode + stream (one block). Backend: WS relay. iOS: video preview. |
| `reconnecting` | Recovering from a mid-session disconnect. Set by iOS + backend only; pod stays on `session_starting` for any boot since it can't tell fresh-vs-reconnect. Cross-layer correlation via `trace_id`. |
| `session_ending` | Session winding down. |

**Pod-side mechanism:** `flux-klein-server/sentry_init.py` exports a `phase()` context manager backed by `contextvars.ContextVar`. Set with `with sentry_init.phase("drawing"):` and the value propagates through `asyncio.create_task` and `asyncio.to_thread` into all logs emitted within (verified — Python 3.9+ copies the contextvars snapshot into spawned tasks/threads). The `before_send_log` hook injects the active value as a top-level `phase` log attribute. Logs outside any phase block have no `phase` attribute (filterable as `!has:phase`).

**Don't introduce pod-internal sub-phases** like `video_generate` / `video_encode` as separate top-level values — fold those into the user-journey phase (`animating`) and rely on existing structured fields (`gen_ms`, `encode_ms`) and `code.function.name` (auto-attached) for sub-stage discrimination. If a real cross-stack debugging need requires finer granularity, add a `subphase` attribute alongside.

**Backend (TS) and iOS (Swift) rollout — vocabulary above is shared, mechanisms when implemented:** Backend uses `AsyncLocalStorage` + a `withPhase("...", () => { ... })` helper, injecting via the `beforeSendLog` equivalent. iOS uses `@TaskLocal` on a static, same context-manager-ish pattern via Swift Concurrency.

**Cross-project search:** Sentry's UI page-filter handles "all projects" or any subset. To stitch a single user action across iOS → backend → pod: use trace_id propagation (auto over HTTP, manual over WS) plus `session_id` tagged on every event. Project boundary is *not* a data silo — it's just for permissions, alert routing, and quotas.

**PostHog** stays in its lane: product analytics events only (per `feedback_single_observability.md`). Errors and stdout/stderr go to Sentry exclusively.

**Querying logs programmatically** (e.g. for analysis without copy-pasting): use the Sentry MCP server (`https://mcp.sentry.dev/mcp`) — registered at user scope on Donald's Claude Code config, exposes `search_events` / `search_issues` / `search_spans`. Avoids the manual "paste logs into chat" workflow.

## Key References

| When | Read |
|------|------|
| Content safety / App Store compliance | `documents/references/content-safety.md` |
| **Pod operations — deploy / iterate / SSH / experiment / terminate** (decision tree, self-contained) | `documents/references/pod-operations.md` |
| Provider/orchestration architecture, network volumes, costs | `documents/references/provider-config.md` |
| Getting a model performant on RunPod (persistent-model architecture, OOM/perf diagnosis, dev iteration loop, lessons from LTX-2.3) | `documents/references/runpod-model-serving-playbook.md` |
| Pod lifecycle edge cases (MUST-handle matrix)          | `backend/src/modules/orchestrator/orchestrator.ts` (file header) |
| Two-pod video architecture (LTXV split) plan + context | `documents/plans/two-pod-video-architecture.md` + GitHub #25 |
| UX test cases (must-pass manual checklist)              | `documents/test-cases.md` |
| Cost monitoring, Discord alerts, pod lifecycle threads | `backend/src/modules/orchestrator/costMonitor.ts` |
| Scale-to-100-users roadmap + workstream status | `documents/plans/scale-to-100-users.md` |
| Metal canvas architecture plan (layers, smudge, etc.) | `documents/plans/metal-canvas-rewrite.md` |
| FLUX.2-klein capability notebook (potential features, not committed) | `documents/ideas/flux-klein-capabilities.md` |
| Implementation decisions log | `documents/decisions.md` |
| Removed features (ComfyUI, StreamDiffusion) | `documents/removed-features.md` |
| Product requirements | `PRD.md` |
| System architecture | `TECHNICAL_ARCHITECTURE.md` |

## Deploy Process

For the full decision tree of pod operations (deploy / iterate / SSH / experiment / terminate), see `documents/references/pod-operations.md`. The deploy process below is one branch of that tree — included here for the architecture context.

**`cd backend && npm run deploy`** — single command. The script (`scripts/deploy.ts`) handles both pod app code and backend together:

1. Reads `backend/.flux-app-version` (= flux-klein-server tree hash from the last successful deploy).
2. Compares to current `git rev-parse HEAD:flux-klein-server`.
3. **If they differ** → fans out `sync-flux-app.ts` to all configured DCs in parallel (`npm run sync-all`). Aborts deploy if any DC fails — fix and re-run.
4. **If same** → skips the sync step (backend-only iteration; ~1 min total).
5. Writes `backend/.flux-app-version` and `backend/.git-sha` (baked into the image so the orchestrator's drift check has its expected version), then runs `railway up`.

The two `.git-sha` / `.flux-app-version` files appear as untracked in `git status` after each deploy — that's expected (Railway CLI honors `.gitignore` during upload, so we deliberately keep them out of `.gitignore`; see `backend/.gitignore` comment).

`npm run sync-all` is also exposed for ad-hoc syncs (e.g., recovering after a DC was skipped due to capacity exhaustion, without redeploying backend).

Plain `railway up` still works but bypasses the auto-sync — drift can occur if `flux-klein-server/` changed. The orchestrator's drift check (Sentry warning + PostHog `volume_status`) catches this on the next pod boot, so it's not silent — but `npm run deploy` is the canonical path.

**Pod boot model:** Pods launch from stock `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (hardcoded as `BASE_IMAGE` in `orchestrator.ts`) and read `/workspace/app/server.py` plus `/workspace/venv/` off the attached network volume. Existing running pods keep the old in-memory copy after a sync; new pods pick up changes on next provision. To force a user onto the new code, terminate their pod and let the orchestrator reprovision.

Bumping `BASE_IMAGE` (e.g. CUDA / PyTorch upgrade) is not just a constant flip — the new image's Python/CUDA ABI must match `/workspace/venv/`, so the venv has to be rebuilt by deleting it and re-running `sync-flux-app.ts`.

**Rollback to GHCR custom-image flow:** The pre-2026-04-23 architecture (custom image at `ghcr.io/donpinkus/kiki-flux-klein`, built by `.github/workflows/build-flux-image.yml`) is retained as inactive code for emergency rollback only. Procedure documented in `documents/decisions.md` 2026-04-23 entry.

## SSHing into a running pod (dev iteration only)

Pre-launch only: SSH on serving pods is gated behind the `PUBLIC_KEY` env var on Railway. When set, orchestrator forwards it into the pod's `BOOT_ENV` and an inline bootstrap in `BOOT_DOCKER_ARGS` writes `authorized_keys`, runs `ssh-keygen -A`, and starts sshd before exec'ing the python server. When `PUBLIC_KEY` is unset (prod default), the bootstrap is a no-op.

**Why we bootstrap manually:** RunPod's stock `runpod/pytorch` image has a `start.sh` entrypoint that does SSH setup itself, but `BOOT_DOCKER_ARGS` overrides the entrypoint to launch the python server directly, so the image's setup never runs. Confirmed: setting `startSsh: true` in the GraphQL `podFindAndDeployOnDemand` call is *not* sufficient on its own — without the inline bootstrap, port 22 is exposed but sshd isn't running and direct TCP gets `Connection refused`.

**Enable SSH for a session:**
```bash
# One-time
PUB="$(cat ~/.ssh/id_ed25519.pub)"
railway variable set "PUBLIC_KEY=$PUB"
cd backend && npm run deploy   # backend-only change → fast path (~30s)
# Existing pods keep the no-SSH path; terminate them to refresh
```

**Connect:** RunPod web console → pod → Connect tab → "**SSH over exposed TCP**" gives `ssh root@<ip> -p <port> -i ~/.ssh/id_ed25519`. **Use this form, not `ssh.runpod.io`.** The proxy form connects but rejects non-interactive commands ("Your SSH client doesn't support PTY") and doesn't support SCP/SFTP.

**Iteration loop on a production pod is unsafe.** Doing `pkill + restart` on a `kiki-vsession-*` or `kiki-session-*` pod triggers the orchestrator's reaper: during the ~30s python restart, `/health` returns 502, the reaper detects the pod as unhealthy after 60s and terminates it. We hit this on 2026-04-30. **For iterating on pod code, use the test pod workflow instead — see `documents/references/pod-operations.md` Task 3.** Test pods use the `kiki-vtest-*` prefix which the reaper filters out.

**If SSH refuses connection:** check `/tmp/ssh-bootstrap.log` on the pod (via RunPod web terminal — enable it from the Connect tab). The log captures all bootstrap output and tells you whether `ssh-keygen -A` failed, whether `service ssh start` worked, etc.

**Disable SSH for prod:** unset `PUBLIC_KEY` in Railway env (no code change needed). Newly-spawned pods skip the bootstrap. Existing pods retain whichever path was active when they booted.

## Completion reporting

At the end of any task that touches code, config, or infra, finish with a short status block so Donald knows whether he can test next or whether something else is gating him. Skip the block on read-only/research turns where nothing changed.

Format:

- **Code state:** one of — `uncommitted` (working tree only) / `committed on main (local)` / `pushed to origin/main`.
- **Ready to test?** `yes` or `no`. If `no`, list every step that remains before Donald can exercise the change. Common gates in this repo:
  - **Backend (Railway) redeploy** — `cd backend && npm run deploy`. Required for any change under `backend/src/**`. If `flux-klein-server/` also changed, this same command fans out `sync-flux-app.ts` to all DCs; call that out.
  - **Pod sync only** — `cd backend && npm run sync-all`. Required for `flux-klein-server/` or `ltx-server/` changes when backend itself didn't change.
  - **Existing pods keep the old code in memory after a sync.** If Donald is mid-session, his pod must be terminated (or he must start a fresh session) to pick up the change. Say so when relevant.
  - **iOS rebuild + reinstall** — Swift changes don't hot-reload. Note simulator vs. device. Flag if SwiftData schema changed (state reset needed).
  - **Env var / secret / third-party config** — name it explicitly (e.g. "set `PUBLIC_KEY` in Railway", "accept Gemma terms on HF").
- **What to test:** one or two sentences on the golden path that verifies the change.

If a step is something Donald has to run himself (e.g. RunPod web console click, App Store Connect change, anything requiring his credentials/2FA), say so explicitly rather than leaving it ambiguous.

## Git Conventions

- When Donald asks to commit and push work from the current conversation, commit directly on `main` and push `origin main`. Do not create a feature branch or PR unless explicitly requested. Stage only changes that belong to the current conversation/task; leave unrelated dirty worktree changes untouched.
- **Branches:** `feature/module-short-desc`, `fix/module-short-desc`, `chore/desc`
- **Commits:** Conventional format — `feat(canvas): add snapshot export`, `fix(scheduler): discard stale preview`
- One logical change per commit. Prefix with module name when scoped.

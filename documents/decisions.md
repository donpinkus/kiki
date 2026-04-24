# Decision Log

Record implementation decisions here as they are made. Newest first. This prevents re-debating the same choices across sessions.

## Format

```
### YYYY-MM-DD — Decision Title
**Context:** Why this decision was needed
**Decision:** What was decided
**Alternatives considered:** What else was evaluated
**Consequences:** What this means for the codebase
```

---

### 2026-04-24 — Idle-timeout reap: user-visible "Session Paused" UX with tap / draw to resume
**Context:** The 30-min idle reaper (`orchestrator.ts:runReaper`) used to terminate a user's pod silently from the iPad's perspective: the Redis row was deleted, the upstream WS closed, the new always-recover path attempted `replaceSession`, which threw `"No session to replace"` and bounced the iPad with a generic 1011 close. User had no idea what happened.
**Decision:** Reaper emits a `terminated` state through the broker with a new `failureCategory='idle_timeout'` BEFORE killing the pod. Stream.ts's broker subscriber closes the iPad WS cleanly with code 1000 on `state='terminated'`, setting the `clientDisconnected` flag so the upstream-close recovery path exits early (no fallback `replaceSession` attempt). iOS `StreamReadiness` gains an `.idleTimeout` case; `ResultState.idleTimeout(previousImage:)` renders a semi-transparent overlay on top of the last-generated image with an SF Symbol moon-zzz icon and "Session Paused - Draw to Resume" title in a teal→purple gradient with Apple-style layered drop shadows. Two resume paths — both wired to a new public `coordinator.resumeStream()`:
1. Tap anywhere on the overlay (button).
2. Start drawing — new `CanvasViewModel.onUserActivity` callback (fired from the existing `MetalCanvasView.onInteractionBegan` → `handleInteractionBegan`) notifies AppCoordinator, which auto-resumes if readiness is `.idleTimeout`.

`StreamSession.stop()` gained an optional `finalReadiness` parameter so the idle-timeout path can tear down without passing through `.disconnected` first.

Other `state='terminated'` paths (manual abort, `replaceSession` cleanup of the old pod) carry no `failureCategory` → iOS routes those to `.disconnected` as before. `idle_timeout` is the only category that triggers the new overlay.

**Alternatives considered:**
- **Leave the overlay generic / re-use `.failed`**: failure UI is red/alarming; idle timeout is routine and deserves calm visual tone.
- **Auto-resume silently on next stroke without a message**: tested poorly conceptually — user sees their session flip to "Finding GPU..." with no explanation for the interruption. Explicit acknowledgment is clearer.
- **Require page navigation to resume** (gallery → back to drawing): annoying friction; user explicitly pushed back on this path.
- **Carry a backend-authored message through to the overlay**: considered, but the UI hardcodes "Session Paused - Draw to Resume" so the message string is unused. Trimmed `message` out of `StreamReadiness.idleTimeout` and `ResultState.idleTimeout`; backend still emits a `failureCategory` which iOS maps locally. Less data, same result.

**Consequences:**
- Backend changes: add `idle_timeout` to `FailureCategory`; reaper calls `emitState(sessionId, 'terminated', 'idle_timeout')` before `terminatePod`; stream.ts broker subscriber closes iPad WS on `state='terminated'`.
- iOS changes: `FailureCategory.idleTimeout`, `StreamReadiness.idleTimeout`, `ResultState.idleTimeout(previousImage:)`. New `idleTimeoutView` in ResultView. Badge handling in DrawingView. `AppCoordinator.resumeStream()` public; `handleUserActivity()` bridges canvas strokes to it. `CanvasViewModel.onUserActivity` callback fires from `handleInteractionBegan`.
- Wire protocol unchanged — `failureCategory='idle_timeout'` is a new string value in an existing field. An old iOS build receiving it maps to `.unknown` and shows the generic "Something went wrong" message (graceful degradation, no crash).
- Testing: because the reaper only fires on 30 min of zero frame activity AND the capture loop touches `lastActivityAt` on every frame (~5 Hz), triggering this naturally while a session is live is near-impossible. Added `POST /v1/ops/test/idle-timeout/:userId` (gated by existing `X-Ops-Key` preHandler) that directly calls `emitState` to simulate the reaper event for UX testing. Future ops test-simulators land in the same file under `/v1/ops/test/*`.

---

### 2026-04-24 — Always recover the iPad session when upstream WS drops (delete classifyClose)
**Context:** Backend proxies `iPad ↔ Railway ↔ RunPod pod`. When the upstream (backend↔pod) WS closed mid-stream, the old `classifyClose` function decided whether to (a) replace the pod, (b) mark the close as `'crashed'` and replace, or (c) classify as `'voluntary'` and tell iPad the session is over. The `voluntary` branch checked only pod health: if `/health` returned 200, it assumed the close was client-initiated. Observed failure on 2026-04-24 07:56 UTC: upstream WS closed with code 1006 after ~10 min of no drawing — almost certainly a RunPod proxy idle timeout — pod was fine, classifier returned `voluntary`, backend closed iPad with code 1000 (clean close), iOS reconnect logic (which only retries on abnormal closures) did nothing. App stuck on "Connecting…" with no retry.
**Decision:** Delete `classifyClose` + `CloseClassification` entirely. Invariant: **if the iPad WS is still open when upstream closes, the user expects frames**. Always recover — there is no legitimate "voluntary upstream close while iPad is connected" case, because the user-left-the-app flow closes the iPad WS first and is already filtered by the `clientDisconnected || socket.readyState !== socket.OPEN` check at the top of `relay.onClose`. New flow:
1. Try reconnecting to the same `podUrl` first (~1–2 s if pod is still healthy — common for transient RunPod proxy idle timeouts and network blips; no full re-provision needed).
2. If that connect fails, call `replaceSession` (existing flow — provisions a fresh pod, ~90 s "Replacing — …" UX).

Extracted shared relay-wiring into a single `wireRelay(podUrl)` helper inside the `/v1/stream` route handler, used for the initial connect, same-pod reconnects, and replacement pods. Eliminated the duplicated-with-slight-variations code blocks.

**Alternatives considered:**
- **Fix at the transport layer** (WS keep-alive pings on the upstream): would reduce how often drops happen, but drops still happen on real network issues and cold hosts. Recovery at the handler level is needed regardless; keep-alive is a separate optimization.
- **Keep `classifyClose` but fix the `voluntary` branch** (e.g., inspect the close code): the upstream WS close code is 1006 for both "client abrupt disconnect → upstream sees abnormal" and "transport-level drop with pod alive." Not actually distinguishable. Simpler to always recover.
- **Tear down and restart after one failed replacement** (non-recursive onClose for the replacement relay): kept previously as belt-and-suspenders. `replaceSession`'s `MAX_SESSION_REPLACEMENTS` cap is the real protection against flapping pods — it throws when exhausted and the outer `try/catch` bounces iPad with a real error. Deleted the redundant non-recursive handler.

**Consequences:**
- `orchestrator.ts` loses `classifyClose` (~25 lines) + the `CloseClassification` type. `stream.ts` shrinks from ~290 lines of relay setup + onClose logic to ~150 lines with a shared `wireRelay` helper. Net: +112 insertions / -158 deletions across the commit.
- Transient WS drops (common: RunPod proxy idle timeout, brief network blips) now recover transparently in ~2–5 s with no "Replacing — …" UX flash. Real pod preemption still goes through the existing `replaceSession` flow unchanged.
- No Redis schema changes, no wire protocol changes. Single-commit rollback restores the `classifyClose` flow.

---

### 2026-04-23 — Deploy Python deps + app code via network volume (eliminate custom GHCR image)
**Context:** Each user session's pod was built from a slim `ghcr.io/donpinkus/kiki-flux-klein:<sha>` image layered on top of `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404`. PostHog data over the last 7 days showed ~38 % of provisions hit a GHCR pull stall: `pod.runtime` stayed null past the 120 s watchdog deadline on a specific subset of RunPod hosts unable to pull reliably from ghcr.io. Each stall added ~120 s of user-visible wait before the orchestrator rerolled to a different DC; real user wait on affected provisions was 200–310 s vs. the p50 of 83 s. Per-phase timing breakdown showed `fetching_image` = 18–28 s clean, `warming_model` = ~55 s; model load (not image pull) was the dominant chunk. 23 stall events / week (16 in EUR-NO-1). The custom image was originally introduced to avoid runtime `pip install` + HF weight downloads; weights moved onto network volumes shortly after (the image couldn't fit ~28 GB), but deps + app code stayed baked.
**Decision:** Remove the custom image entirely. Pods launch directly from the stock `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (publicly cached on most RunPod hosts). Python deps + app code live on the attached network volume at `/workspace/venv/` (created via `python3 -m venv --system-site-packages` — base-image torch/CUDA visible so pip skips reinstalling them) and `/workspace/app/` (rsynced server code). Pod boot uses RunPod's `dockerArgs` to override CMD with `bash -lc 'source /workspace/venv/bin/activate && cd /workspace/app && exec python3 -u server.py'`, plus create-time `env:[]` for `HF_HOME`, `HF_HUB_OFFLINE`, `FLUX_*`. Deploy flow: `npx tsx backend/scripts/sync-flux-app.ts --dc <X> --volume-id <Y>` once per DC; idempotent (rsync/pip skip unchanged). Watchdog renamed `ImagePullStallError` → `PodBootStallError` (covers NFS mount stalls and cold-host stock-image pulls that can still occur, just much rarer); budget lowered 120 s → 45 s.
**Alternatives considered:**
- **`pip install --target /workspace/pydeps` (no venv)** — tested in POC, FAILS: pip treats target as a fresh env, installs a default `torch 2.11.0` + `nvidia-cublas-13.1.0.3` (CUDA 13) alongside base image's torch 2.9.1+cu128, breaking CUDA. The `--system-site-packages` flag on venv is what makes pip see base's torch as satisfied and skip reinstalling.
- **Keep GHCR but switch registry to Docker Hub / ECR** — doesn't address the GHCR-host stall, just shifts it.
- **Pre-warmed pod pool (standby pods always hot)** — directly addresses cold-start UX but costs ~$14/day per standby. Orthogonal to this decision; can stack on top later.
- **Versioned dirs `pydeps-<sha>/` + atomic symlink flip** — considered for partial-sync failure handling. Cut as overengineering for single-user scale; `git revert && railway up` is a valid rollback, and partial sync = re-run that DC's sync.
- **`FLUX_BOOT_MODE` dual-mode flag for gradual cutover** — cut for the same reason. Rollback via revert is fast enough; a compat flag adds permanent code surface.
**Consequences:**
- Backend code changes (one commit): `runpodClient.ts` (add `dockerArgs?`/`env?` fields), `orchestrator.ts` (pass `BASE_IMAGE`/`BOOT_DOCKER_ARGS`/`BOOT_ENV`; rename watchdog + error class), `errorClassification.ts` (rename `ImagePullStallError` → `PodBootStallError`, `image_pull_stall`/`fetch_image_timeout` categories → `pod_boot_stall`), `config/index.ts` (remove `FLUX_IMAGE`, `RUNPOD_GHCR_AUTH_ID`; rename `CONTAINER_PULL_*` → `POD_BOOT_*` with 45 s default), `vitest.setup.ts` (drop `FLUX_IMAGE` dummy). New: `backend/scripts/sync-flux-app.ts`. iOS: `ProvisionState.swift` drops `imagePullStall`/`fetchImageTimeout` failure categories, adds `podBootStall`.
- Clean-path cold-start comparable to today (~15 s gained from no custom-layer pull, ~30 s lost to NFS imports of diffusers/transformers on cold pod). Real win is tail-latency elimination — the 38 % of provisions that previously stalled 120–240 s now take a normal cold start.
- GHCR image build workflow (`.github/workflows/build-flux-image.yml`), `flux-klein-server/Dockerfile`, and `backend/scripts/probe-dc-pulls.ts` are dead code after cutover. **Not deleted yet** — retained through the bake period for easy rollback; scheduled for stage-3 cleanup after 2–5 days of passing metrics (p95 ≤ 90 s, stall events ≤ 2 per 24 h).
- Railway env vars `FLUX_IMAGE`, `RUNPOD_GHCR_AUTH_ID`, `CONTAINER_PULL_*` still present — also removed at stage-3 cleanup. The base image tag is hardcoded (`BASE_IMAGE` const in orchestrator.ts) rather than env-driven, because bumping the base image requires a coordinated `/workspace/venv/` resync against the new Python/CUDA ABI, not just a config flip.
- **Rollback procedure (valid until stage-3 cleanup):**
  1. `git revert <cutover-commit>` — brings back the orchestrator + iOS changes + config fields.
  2. On Railway: set `FLUX_IMAGE` and `RUNPOD_GHCR_AUTH_ID` again. Last known-good tag: `ghcr.io/donpinkus/kiki-flux-klein:<sha>` for whichever commit precedes the cutover on main. GHCR retains old tags indefinitely; no rebuild needed.
  3. `cd backend && railway up`.
  4. Rebuild iOS in Xcode, reconnect.
  5. `/workspace/venv/` and `/workspace/app/` dirs on the volumes are harmless to leave; old path ignores them.
  - After stage-3 cleanup, rollback additionally requires: restoring the Dockerfile + GHA workflow from history, and possibly rebuilding the GHCR image (~10 min) if the `:sha-<commit>` tag has been pruned.
- **When bumping the base image tag later:** delete `/workspace/venv/` on each DC first (SSH in or sync-script variant), then re-run `sync-flux-app.ts`. Python ABI in the old venv's `.so` files would otherwise conflict with a new base Python version.

---

### 2026-04-23 — Structured state machine for provisioning (replaces free-form status strings)
**Context:** Backend emitted 14 free-form status strings ("Pulling container image...", "Pod is starting up...", etc.) over the iOS WebSocket; iOS displayed them verbatim. Three problems: (1) iOS joiners reconnecting mid-provision got a one-shot "Pod is starting up..." and silence because `onStatus` was bound to the original caller's WS — joiner's callback was never wired in. (2) Display text crossed the wire, conflating state (backend's concern) with presentation (iOS's concern). (3) Redis had `SessionStatus` and the orchestrator had a separate `ProvisionPhase` type — two state machines at different granularities.
**Decision:** Single flat `State` enum (9 values: `queued | finding_gpu | creating_pod | fetching_image | warming_model | connecting | ready | failed | terminated`). Wire format is structured: `{ type: 'state', state, stateEnteredAt, replacementCount, failureCategory? }`. Backend never emits display strings; iOS maps state codes → user-facing text locally. In-memory broker (`subscribe` + `emitState`) fans out transitions to every WS connection for the session, so fresh callers and joiners share one mechanism. Redis stays the source of truth; broker owns subscriber sets only.
**Alternatives considered:**
- **Merge `status` and `phase` internally but keep free-form strings on the wire** — preserves the joiner bug and the layering violation; didn't solve either root cause.
- **Polling-based "last status" field in Redis** — simpler, but 1s latency is visible and reintroduces "display text in Redis" which the layering cleanup was trying to eliminate.
- **Fold the `connecting` state into `warming_model`** — lose explicit visibility into a distinct phase (pod `/health` ok but relay not yet connected). This gap caused silent frame drops when iOS thought "Ready" but the backend's `socket.on('message')` handler wasn't registered yet.
- **Don't separate `ready` from pod-ok vs relay-ready** — same silent-drop issue; "Ready" must mean iOS can actually stream, not just "pod is alive."
- **Emit separate `pod.state.exited` events for analytics** — doubles event volume for the same information. Instead, each `pod.state.entered` event carries `previous_state` + `previous_state_duration_ms`.
**Consequences:**
- `replacementCount` stays incremented through a session's life (doesn't reset on successful replacement). Required for the `MAX_SESSION_REPLACEMENTS` cap to protect against flapping pods. Tradeoff: after one preemption, reconnect flows briefly flash "Replacing — ..." until the session fully retires. Acceptable at current scale.
- `waitForReplacement` (polling helper) deleted — broker subscribers handle mid-replacement connects natively.
- `PodVanishedError.phase` renamed to `.state`; `FailureCategory` renamed (`runtime_up_timeout` → `fetch_image_timeout`, `health_timeout` → `warm_model_timeout`) to match.
- Rate limiter's `ACTIVE_SESSION_STATUSES` set moved to `ACTIVE_STATES` with new values — easy to forget when adding states; see `backend/src/modules/auth/rateLimiter.ts`.
- Adding new states in the future: update (1) backend `State` union, (2) iOS `ProvisionState` enum, (3) iOS `displayText()`, (4) rate limiter `ACTIVE_STATES` if non-terminal, (5) `ACTIVE_PROVISION_STATES` in orchestrator.ts.
- Wire protocol change: atomic swap across backend + iOS. Dev build only — single user rebuilds iOS and deploys backend in lockstep. TestFlight would require a dual-send compat layer.

---

### 2026-03-25 — Gallery home page with SwiftData local persistence
**Context:** App was single-screen with no persistence. Drawings were lost on app close. Needed a way to save, browse, and resume multiple drawings.
**Decision:** Add a gallery home page as the app root (state-based navigation, no NavigationStack). Each drawing is a SwiftData `@Model` with `@Attribute(.externalStorage)` for all image blobs. Auto-save on change (debounced 1s for UI events, immediate after generation). CanvasViewModel uses a pending-state pattern for save/restore: `setPendingState()` queues data before navigation, `attach()` applies it before the PKCanvasView delegate is set to avoid spurious change events. Gallery uses `@Query` for automatic SwiftData observation. Empty drawings are cleaned up on gallery navigation.
**Alternatives considered:**
- NavigationStack — adds push/pop semantics but the drawing view is heavy and we don't want it in the back stack; state-switching is simpler
- File-based storage (PKDrawing files + metadata JSON) — more manual, SwiftData is mandated by architecture decisions
- Drawing model as source of truth (bind views directly to `@Model`) — would require restructuring AppCoordinator; deferred to v2
- Separate GalleryModule SPM package — unnecessary complexity for v1; gallery views live in main app target
**Consequences:**
- ContentView renamed to DrawingView; RootView added as navigation root
- AppCoordinator now accepts `ModelContext` in init; `KikiApp` creates `ModelContainer`
- Gallery button (top-left of DrawingView) and "New" button (top-right of GalleryView) for navigation
- Long-press delete mode on gallery tiles with X badge overlay
- Canvas thumbnail pre-rendered at save time (256px max) since PKDrawing can't be rendered without a live PKCanvasView
- Generated image loaded at full resolution in gallery tiles (SwiftUI handles downscaling)

---

### 2026-03-17 — Use drawHierarchy for canvas snapshot capture (not PKDrawing.image)
**Context:** Sketch images uploaded to ComfyUI were blank white despite PKDrawing containing valid strokes at valid coordinates within canvas bounds. Root cause: `PKDrawing.image(from:scale:)` returns a blank image when the PKCanvasView is inside a transformed parent view (RotatableCanvasContainer). This broke ControlNet sketch adherence entirely — generations were prompt-only with no sketch conditioning.
**Decision:** Use `canvasView.drawHierarchy(in:afterScreenUpdates:)` inside a `UIGraphicsImageRenderer` to capture the live rendered view content instead of re-rendering from PKDrawing data.
**Alternatives considered:**
- `PKDrawing.image(from:scale:)` — blank output, likely PencilKit bug with ancestor transforms
- Moving `PKDrawing.image()` outside the renderer block — not tested, drawHierarchy is more reliable
- `canvasView.snapshotView(afterScreenUpdates:)` — returns a UIView, not a UIImage
**Consequences:**
- Snapshot captures exactly what's on screen (WYSIWYG)
- Requires canvasView to be in the window hierarchy and visible (always true for our use case)
- Corrects the previous decision's note about switching TO `PKDrawing.image(from:scale:)` — that approach is broken

---

### 2026-03-17 — Canvas zoom and rotation via RotatableCanvasContainer
**Context:** Users need to zoom in for detail work and rotate the canvas to draw at comfortable angles.
**Decision:** Wrap PKCanvasView in a RotatableCanvasContainer with a three-level view hierarchy: container (SwiftUI-managed, no transform) → transformView (receives combined CGAffineTransform for scale + rotation) → PKCanvasView (drawing only). Zoom and rotation are handled by UIPinchGestureRecognizer and UIRotationGestureRecognizer on the container, applied as a single combined transform on the intermediate view. UIKit automatically translates touch coordinates through the parent's transform, so drawing works at any scale/rotation.
**Alternatives considered:**
- SwiftUI `.rotationEffect()` — breaks touch coordinate mapping for UIViewRepresentable
- Transform on the UIViewRepresentable root view — SwiftUI re-layouts fight the transform, squishing the canvas
- PKCanvasView's built-in UIScrollView zoom — zooms content inside a fixed frame with scroll bars, not the whole canvas visually
- CALayer transform3D — undocumented interaction with PencilKit touch handling
**Consequences:**
- ~~Snapshot capture switched from `drawHierarchy` to `PKDrawing.image(from:scale:)` to capture full drawing regardless of visual transform~~ **REVERTED** — `PKDrawing.image()` produces blank output with transformed ancestors; switched back to `drawHierarchy` (see 2026-03-17 decision above)
- New file: `RotatableCanvasContainer.swift` in CanvasModule
- Rotation snaps to 90° increments when released within ~8° threshold; scale clamped to 0.5x–5x
- Reset button appears in toolbar when canvas is zoomed or rotated

---

### 2026-03-15 — Replace fal.ai with ComfyUI (Qwen-Image) on RunPod
**Context:** fal-ai/scribble (SD 1.5 ControlNet) produced low-fidelity results with limited control. Needed higher quality generation with better sketch adherence and a model that supports more control types.
**Decision:** Switch to Qwen-Image 20B (FP8) + InstantX ControlNet Union running on ComfyUI, hosted on a RunPod H100 80GB SXM GPU pod. Use AnyLine Lineart preprocessor for soft edge control from PencilKit sketches. Lightning LoRA V2.0 for 8-step generation.
**Alternatives considered:**
- Union DiffSynth LoRA (supports lineart/softedge but is a LoRA hack, less stable)
- DiffSynth Model Patches (only canny/depth/inpaint, no lineart)
- Keeping fal.ai with different models (limited model selection)
**Consequences:**
- Generation latency increased from ~4s to ~6-8s (but quality is dramatically higher)
- Backend now depends on RunPod pod availability (no auto-scaling yet)
- Workflow params (strength, steps, models) changed via ComfyUI web UI + re-export of API format template
- Cost model changed from per-image API pricing to per-hour GPU rental ($2.69/hr H100 SXM)

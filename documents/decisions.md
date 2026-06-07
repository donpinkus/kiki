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

### 2026-06-06 — Apple StoreKit 2 subscription flow (Stage 3)

**Context:** Stages 1–2 (Postgres accounts + the $10/mo fal-spend cap) left a non-exempt user who hit the cap with no way out — `subscription_status` was permanently `'none'` because no purchase flow existed. Stage 3 builds the auto-renewable subscription so a capped user can subscribe and keep drawing.

**Decision:** One auto-renewable product `com.don.Kiki.pro.monthly` (~$4/mo → App Store tier $3.99, monthly only, no trial). **Verification uses Apple's official `@apple/app-store-server-library`** (not hand-rolled `jose` x5c logic — payment trust boundary). Two backend routes: JWT-authed `POST /v1/subscription/verify` (iOS posts a verified `Transaction.jwsRepresentation` on purchase, on each launch for `currentEntitlements`, and for Restore) and a public `POST /v1/app-store/notify` (App Store Server Notifications V2; the JWS signature is the auth). **No P8 key / App Store Server API** — we only *verify* signed payloads, which needs only the committed Apple Root CA - G3 (embedded base64 in `modules/appstore/verifier.ts`). Subscription state is **derived from the transaction** — one `applyTransaction(userId, tx)` sets `active` iff `revocationDate==null && expiresDate>now`, replacing a per-notificationType mapping table (more robust as Apple adds types). Ordering/dedup via a `subscription_last_signed_ms` monotonic guard (apply only if incoming `signedDate >= stored`). `original_transaction_id` (partial-unique) binds a sub to one Kiki user so the unauthenticated webhook can resolve it. The fal-cap exemption gained an **expiry check** (`subscription_status='active' AND subscription_expires_at > now()`) so a missed webhook self-heals. iOS: `App/SubscriptionManager.swift` (StoreKit 2, app-lifetime `Transaction.updates` listener) + `Views/PaywallView.swift` (presented as a `fullScreenCover` on the existing `free_limit_reached` error path, now threaded with a machine-readable `code` on `ServerStatus`). `.storekit` test config at `ios/Kiki.storekit`. **No iOS entitlements change** — In-App Purchase needs none (unlike Sign in with Apple).

**Alternatives considered:** Hand-rolled JWS x5c verification with `jose` + `node:crypto` (rejected — re-implements the cert-chain trust logic most likely to be subtly wrong on a payment boundary). Client-verify only / no webhook (rejected — cancellations would only reflect on the client's next launch). A per-notificationType action table (rejected — the derive-from-transaction formula is equivalent and drift-proof). A separate `subscriptions` table (rejected — over-engineering for one product / one sub per user at launch scale; columns on `users` suffice).

**Consequences:** Schema gained `users.original_transaction_id` (partial-unique) + `users.subscription_last_signed_ms` (both idempotent `ALTER … ADD COLUMN IF NOT EXISTS`). New backend dep `@apple/app-store-server-library`. New optional env `APPLE_APP_APPLE_ID` (numeric App Store app id) — **required before *production* StoreKit verification works**; Sandbox/TestFlight verifies without it (the production verifier stays null and rejects prod payloads with a clear error until set). In non-production, XCODE/LOCAL_TESTING StoreKit environments verify (signature-skipped, per Apple's lib) so a local `.storekit` simulator purchase exercises the full backend path; production rejects those environments. Donald-side before live: create the App Store Connect product, set the V2 notification URL (Sandbox + Production) to `/v1/app-store/notify`, and select the `.storekit` config in the Run scheme for simulator testing. Verified: backend integration test against local Postgres (purchase→active, duplicate idempotent, stale-order rejected, renewal advances, refund→expired, expiry self-heal, OTID unique) + iOS build succeeds.

**Follow-up (same day) — in-app usage meter:** a tappable bar on the Gallery + Drawing screens that fills toward the $10 cap and opens the paywall on tap. Backend `GET /v1/usage` (`routes/usage.ts`) + a live `{type:'usage',spendUsd,capUsd}` WS push from the `routes/stream.ts` metering tick (~10s) so it ticks up while drawing; iOS `Views/UsageMeterView.swift` + `AppCoordinator` usage state (`refreshUsage()` on screen appear / after stop; `StreamSession.onUsageUpdate` for the live push). Hidden for exempt users (test accounts / active subscribers).

### 2026-06-06 — Postgres durable accounts + per-user monthly fal-spend cap

**Context:** Approaching launch, identity/subscription state needed a durable system-of-record (Redis is ephemeral), and an unsubscribed user had no cost ceiling on the now-fal image path. Done in two stages.

**Decision (Stage 1 — Postgres + accounts):** Added a managed Postgres (Railway addon → `DATABASE_URL`), raw `pg` + idempotent `schema.sql` + `migrate.ts` run at boot, mirroring the `analytics/` service. New `users` table (`user_id` UUID PK, `apple_sub` UNIQUE, `email`, `is_test_account`, `subscription_status`, `subscription_expires_at`) is the durable account record. `routes/auth.ts` `upsertUserByAppleSub` (atomic `ON CONFLICT (apple_sub)`) + `getUserEmail` now hit Postgres; the Redis `user:`/`apple-sub:` keys are retired. Code: `backend/src/postgres/` (client/schema/migrate/users). Sign-in requests Apple's `.email` scope (`SignInView.swift`) so the email is captured (first-auth only; private-relay possible).

**Decision (Stage 2 — fal-spend cap):** Unsubscribed users get `FREE_TIER_FAL_USD` ($10) of fal drawing spend per calendar month (UTC); test accounts (`is_test_account`) + active subscribers are exempt. Hard mid-session stop on crossing (~$0.20 overshoot tolerance). Spend metered PG-direct into `monthly_usage` (PK `user_id,month`) via atomic `INSERT … ON CONFLICT … RETURNING` — no Redis. `falImageRelay.cumulativeOpenMs()` + an `onUsage` hook (on close + ~10s throttle, no timer) report open-time; `routes/stream.ts` runs a per-connection `checkFalBudget` gate (incl. reconnects, so a 2nd device can't bypass) and a mid-session `enforceCut` (sends `{code:'free_limit_reached'}`, `abortSession` so reconnect re-denies, then closes). Fail-open if the budget DB errors (gate + mid-session). New `backend/src/modules/falBudget/`; the dead in-memory `entitlement` module + `FREE_TIER_SECONDS` removed. Backend-only — the existing failure UI shows the message. **Apple StoreKit/purchase + paywall UI + usage meter deferred** (testers stay unlimited via the test flag until then).

**Consequences:** Postgres is now a required dependency (backend fail-fasts without `DATABASE_URL`). Test/owner accounts are flagged via `UPDATE users SET is_test_account=true`. Tune/disable the cap via `FREE_TIER_FAL_USD` (0 ≈ off). Verified in prod: mid-session cut, gate-deny-on-reconnect, owner-exempt, spend recorded.

**Follow-up (same day):** with Postgres now available, moved **refresh-token revocation** from an in-memory Set (which reset every deploy → silently un-revoked tokens, a replay window up to the 30d refresh TTL) to a durable `revoked_refresh_tokens` table (`backend/src/modules/auth/jwt.ts`). Only the refresh endpoint hits the DB; the hot `verifyAccess` path stays pure-crypto. A doc sweep updated `.env.example` (added `DATABASE_URL`/`FAL_KEY`/`IMAGE_PROVIDER`/`FREE_TIER_FAL_USD`/`FAL_IDLE_CLOSE_MS`), `CLAUDE.md` (accounts/billing section), `README.md`, the WS1/5/8 + scale-to-100 plan banners, and the SignInView caption (removed a false "1 free hour, then $5/month").

### 2026-06-06 — Live image path moved from RunPod FLUX.2-klein to fal.ai hosted realtime

**Context:** The live img2img path ran FLUX.2-klein-4B (NVFP4, reference-mode VAE-concat) on per-session RunPod RTX 5090 spot pods — ~96s cold start (p95 ~157s), recurring spot-capacity fragility across DCs, and full ownership of the serving stack. A spike (`fal-spike/`) measured fal.ai's hosted `fal-ai/flux-2/klein/realtime`: ~1.5s to first frame, ~250ms/frame at 3 steps, 0% drop at 2 FPS, no pod provisioning.

**Decision:** Default the live image path to fal via `IMAGE_PROVIDER=fal` (set on Railway). The backend relays each canvas JPEG over a per-session fal realtime WebSocket — msgpack frames, server-side `Authorization: Key $FAL_KEY` (no secret on the client) — in `backend/src/modules/fal/falImageRelay.ts`, a drop-in for the RunPod `StreamRelay`. fal emits no `queueEmpty`, so the relay synthesizes a `frame_meta{queueEmpty}` (mirroring `model-servers/image/server.py`) to keep the video idle-state trigger working unchanged.

**Alternatives considered:** Deploy our own klein pipeline on fal Serverless (blocked on serverless access; more ops). Stay on RunPod (cold start + capacity). Direct iPad→fal (breaks the backend-computed video trigger and "no secrets on client" — needs the relay anyway).

**Consequences:**
- RunPod image pods (5090, klein NVFP4) are **DORMANT but intact** — config default is `IMAGE_PROVIDER=runpod`, so flipping the Railway var (or unsetting it) reverts instantly. Not deleted.
- **VIDEO idle-state animation (LTX-2.3 on RunPod H100 SXM) is UNCHANGED** — still RunPod. The orchestrator / provisioner / reaper / cost-monitor now serve video (+ the dormant image fallback) only; they are NOT on the live image path.
- fal's conditioning is its img2img feedback loop (`output_feedback_strength` / `schedule_mu`), not our reference-mode VAE-concat — different look, tuned via params (optionally surfaced in the iPad SettingsPanel).
- **Billing is by connection DURATION** (`ceil(open_seconds) × $0.00194`, ~2s floor, no fixed 30s minimum), charged per connection-open. Two cost levers shipped (commit f6f89793): **lazy-connect** (no socket until the first stroke → opening a drawing without drawing costs $0) and **`FAL_IDLE_CLOSE_MS`** (close the WS N ms after the last frame; reopen lazily on the next stroke). Measured billing details in `documents/references/provider-config.md`.
- NSFW *output* filter requirement dropped (see `content-safety.md`); prompt *input* filter still gates external TestFlight.

### 2026-05-09 — Removed `too_many_active_pods` quota check; surface raw deny reasons to iOS

**Context:** During heavy iteration (Xcode rebuilds in tight succession), backend started rejecting WS connections with `too_many_active_pods` and the iOS toast read "Unable to connect. Please restart the app." with no indication of the actual cause. Two problems compounded:
1. `rateLimiter.checkProvisionQuota` had a binary "any active session exists" guard before the hourly/daily windows. It read the same Redis row that `hasReadySession` had just consulted at `routes/stream.ts:348`, but ms apart and after one synchronous `checkEntitlement` call. Concurrent WS handlers (or a previous provision from the same user mid-flight) could race past `hasReadySession=false` and then see the row in `getActiveSessionCount` — false-positive `too_many_active_pods`.
2. iOS's `StreamWebSocketClient.connect()` swallowed `{type:"error"}` JSON arriving during the WS handshake — wrapped the full text in a generic `URLError`, and after the reconnect loop exhausted, fell back to a hardcoded "Unable to connect. Please restart the app." string that discarded the server's `message` field. Backend's entitlement and quota paths additionally fabricated UX-friendly strings ("Subscription required to continue", "Too many sessions — try again shortly"), so even the wire-level message was a friendly placeholder rather than the raw enum reason.

**Decision:**
- Deleted the active-pod check (`getActiveSessionCount`, `MAX_ACTIVE_PODS_PER_USER`, `'too_many_active_pods'` reason) from `backend/src/modules/auth/rateLimiter.ts`. Hourly (20/h) + daily (100/d) sliding windows unchanged. Concurrent-pod protection was always redundant: `getOrProvisionPod` already serializes via `inFlightProvisions` and reuses existing rows via `getReusableFromRow`.
- Backend now sends the raw enum reason as the `message` field for both entitlement (`message: entitlement.reason`) and quota (`message: quota.reason ?? 'rate_limited'`) denies. Auth deny was already raw.
- iOS gained `ServerRejectedError` (public, in `NetworkModule`). `StreamWebSocketClient.connect()` now decodes the initial WS message as `ServerStatus` and throws `ServerRejectedError(message:)` for `type:"error"` — no more URLError-wrapping. `StreamSession.runReconnect` catches this, calls `setReadiness(.failed(message: serverError.message))`, and exits the loop. Generic transport errors still fall through to the existing back-off-and-retry path. Net: red toast renders the verbatim server message (e.g. literally `hourly_rate_exceeded` / `free_exhausted` / `invalid_token`).

**Alternatives considered:**
- **Keep the active-pod check, raise `MAX_ACTIVE_PODS_PER_USER` to 2.** Would reduce false-positive frequency but doesn't address the underlying redundancy or the read-read race. Removal is cleaner.
- **Tighten the race window with a Redis lock or atomic SETNX.** Adds complexity for a guard that wasn't pulling weight.
- **Map enum reasons to friendlier UX strings on iOS** ("hourly_rate_exceeded" → "You've hit the per-hour limit, try again at HH:MM"). Useful for production but premature: today these denies fire on us during dev, and the raw reason is more debug-friendly than any mapping. Layer this in when we have real users.

**Consequences:**
- The `'too_many_active_pods'` value disappears from the wire protocol's `code` field. Any old iOS build that hard-coded a UI mapping for it now falls through to the generic toast (which would render "Server error" since no `message` carries that string anymore — the value is just gone). Not a problem in dev; would be a wire-compat consideration if we shipped a broader release.
- The hourly cap of 20 still bounds heavy retry-storm cost. At ~$0.55/hr per RTX 5090, the worst-case extra provisioning during a debug session is bounded.
- `ACTIVE_STATES` set is gone from `rateLimiter.ts` — the "step (4) update rate limiter `ACTIVE_STATES`" reminder in the 2026-04-23 entry below no longer applies. Adding new states only requires updating the orchestrator's `State` union, iOS `ProvisionState`, iOS `displayText()`, and `ACTIVE_PROVISION_STATES` in `orchestrator.ts`.

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
- GHCR image build workflow (`.github/workflows/build-flux-image.yml`), `model-servers/Dockerfile`, and `backend/scripts/probe-dc-pulls.ts` are dead code after cutover. **Not deleted yet** — retained through the bake period for easy rollback; scheduled for stage-3 cleanup after 2–5 days of passing metrics (p95 ≤ 90 s, stall events ≤ 2 per 24 h).
- Railway env vars `FLUX_IMAGE`, `RUNPOD_GHCR_AUTH_ID`, `CONTAINER_PULL_*` still present — also removed at stage-3 cleanup. The base image tag is hardcoded (`BASE_IMAGE` const in orchestrator.ts) rather than env-driven, because bumping the base image requires a coordinated `/workspace/venv/` resync against the new Python/CUDA ABI, not just a config flip.
- **Rollback procedure (valid until stage-3 cleanup):**
  1. `git revert 332bcad` — the cutover commit (`refactor(provisioning): launch pods from stock runpod/pytorch + volume-entrypoint`). Brings back the orchestrator + iOS changes + config fields.
  2. On Railway: set `FLUX_IMAGE` and `RUNPOD_GHCR_AUTH_ID` again. Last known-good tag: `ghcr.io/donpinkus/kiki-flux-klein:sha-<commit>` where `<commit>` is `git rev-parse 332bcad^` (the commit immediately before the cutover). GHCR retains old tags indefinitely; no rebuild needed.
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
- Rate limiter's `ACTIVE_SESSION_STATUSES` set moved to `ACTIVE_STATES` with new values — easy to forget when adding states; see `backend/src/modules/auth/rateLimiter.ts`. *(Superseded 2026-05-09: `ACTIVE_STATES` was removed from `rateLimiter.ts` along with the `too_many_active_pods` check. Adding new states no longer requires touching the rate limiter.)*
- Adding new states in the future: update (1) backend `State` union, (2) iOS `ProvisionState` enum, (3) iOS `displayText()`, (4) `ACTIVE_PROVISION_STATES` in orchestrator.ts.
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

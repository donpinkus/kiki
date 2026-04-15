# Workstream 7: Graceful spot-preemption handling

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md).

## 1. Context

At today's scale (5–20 concurrent users) spot preemptions are rare enough that the "client sees error → retries → backend provisions fresh pod" loop is tolerable for the affected user. The roadmap target of 100 concurrent users changes this in two ways:

- **Rate rises with N.** If a single pod has ~1% hourly preemption probability, 100 concurrent pods yield roughly one preemption per minute across the fleet. Even with WS3's baked image cutting replacement to ~90s, that's one user per minute seeing a large visible gap.
- **User composition shifts.** Early testers tolerate jank; TestFlight users at 100-scale quit on first "connection lost" error. Preemption drops feel like app bugs, not infrastructure.

Goal: a flow where mid-session preemption is either invisible (client holds WS open, backend swaps upstream pod transparently) or reduced to short "Replacing GPU..." blip — never an error dialog plus full reconnect.

## 2. Current state

**Backend `stream.ts` lines 150–158:** `onClose` for upstream WS is indiscriminate. Every close — preemption, voluntary shutdown, network flap, pod crash — funnels through:

```ts
relay.onClose((code, reason) => {
  request.log.info({ sessionId, code, reason }, 'Upstream closed');
  if (socket.readyState === socket.OPEN) {
    socket.send(JSON.stringify({ type: 'error', message: 'Pod terminated (possible spot preemption)' }));
    socket.close(1001, 'Upstream closed');
  }
});
```

Client WS closes with 1001 immediately. No attempt to distinguish cause and no replacement kicked off.

**Registry state on close:** nothing in `orchestrator.ts` reacts. `Session` record stays `ready` with stale `podUrl` pointing at dead pod. Reaper only considers `lastActivityAt`; eventually reaps after 10 min silence, but until then registry is lying.

**Client-side `StreamSession.swift`:**
- Receives `{type: error, ...}`, transitions to `.error(...)` via `statusTask`.
- `receiveTask` hits end-of-stream, triggers `attemptReconnect()`.
- `attemptReconnect()` uses exponential backoff (1s, 2s, 4s), max 3 attempts.
- Each reconnect opens fresh `StreamWebSocketClient` to same URL. Backend sees new WS, looks up sessionId, finds `ready` with stale `podUrl`, tries relay to dead pod, cascades to error.

So today: client's 3 retries over ~7s fail against stale registry; user in `.error("Connection lost after 3 retries")`. To recover, kill and relaunch app — registry entry has typically expired, fresh provision starts (3–5 min cold start).

## 3. Preemption detection

Need to classify upstream close into four buckets:

| Bucket | Signal | Action |
|---|---|---|
| A. Spot preemption | RunPod terminated pod; `getPod` returns `desiredStatus: "EXITED"` or null, substantial uptime | Replace transparently |
| B. Pod crash (OOM, server.py died) | `desiredStatus: "RUNNING"` but WS closed; `/health` fails | Replace but log as crash, not preemption |
| C. Voluntary close | Backend called `terminatePod` (reaper, future `sessionClosed`) | Do nothing — session is over |
| D. Network blip | WS closed but `getPod` shows alive and `/health` succeeds | Retry upstream WS connect without reprovisioning |

**Primary signal: `getPod(podId)` on close.**

```
onClose → getPod(session.podId) within 5s of close
  - pod null / desiredStatus EXITED / TERMINATED → bucket A
  - desiredStatus RUNNING → probe /health
    - /health 200 → bucket D (reconnect upstream WS)
    - /health fails → bucket B
```

**Secondary signals (nice-to-have):**

- **Close code patterns.** RunPod's proxy terminates preempted WS with `1006` (abnormal, no FIN) or `1011`. Voluntary shutdowns may produce `1000`. Too unreliable alone but useful prior.
- **Timing.** Preemption is time-of-day / capacity-driven. Close within 30s of `/health` passing is more likely handshake issue (bucket D).
- **`lastActivityAt` vs close time.** Useful for replacement urgency — if user just stopped drawing, we can be lazier.

**Distinguishing voluntary close (bucket C):** before reaper or internal code calls `terminatePod`, mark session internally (`status: 'terminated'` at `orchestrator.ts:220` already does this). Close handler checks flag first — if `terminated`, short-circuit.

## 4. Detailed design

### 4.1 State machine

New status: `'replacing'`. Full set: `'provisioning' | 'ready' | 'replacing' | 'terminated'`.

Transitions:
```
provisioning → ready        (successful first provision, today)
ready → replacing           (preemption detected)
replacing → ready           (replacement pod healthy, podUrl swapped)
replacing → terminated      (replacement failed past retry bound)
ready → terminated          (reaper idle timeout, today)
provisioning → (deleted)    (provision failed, today — registry.delete)
```

### 4.2 New orchestrator API

```ts
replaceSession(sessionId, onStatus): Promise<{ podUrl: string }>
```

Behavior:
1. Look up session in registry. If not `ready`, throw.
2. Mark `session.status = 'replacing'`, store `session.replacementPromise` (parallel to `provisionPromise`; lives through replace only).
3. Capture `oldPodId`. Fire-and-forget `terminatePod(oldPodId)` with error suppression (may already be gone).
4. Call existing `provision(sessionId, onStatus)` (same function used for first provision; unchanged).
5. On success: atomically update `session.podId = newPodId; session.podUrl = newPodUrl; session.status = 'ready'; session.replacementPromise = null; lastActivityAt = Date.now()`.
6. On failure past retry bound: `status = 'terminated'`, `registry.delete(sessionId)`, throw.

`replaceSession` goes through same semaphore (`acquireSemaphore`) as fresh provisions. At 100 users load-bearing — mass preemption event (10 pods in a minute) must not burst our cold-start concurrency budget. Queue them.

### 4.3 New close handler in `stream.ts`

Replace lines 150–158 with handler that:

1. Logs the close.
2. Checks `session.status` via new `getSessionStatus(sessionId)` export — if `terminated`, do nothing (bucket C).
3. Immediately sends `{"type":"status","status":"reprovisioning","message":"Your GPU was preempted — replacing..."}` to client.
4. **Holds client socket open** (key behavior change).
5. Calls new orchestrator helper `classifyClose(sessionId, closeCode)` running `getPod` + `/health` logic above. Returns `'preempted' | 'crashed' | 'network_blip' | 'voluntary'`.
6. Dispatches:
   - `'voluntary'` → close client socket (existing behavior).
   - `'network_blip'` → new `reconnectUpstream(sessionId, relay)`: redial same podUrl; if succeeds within 10s resume relaying, else fall through to replacement.
   - `'preempted'` or `'crashed'` → `replaceSession(sessionId, statusForwarder)`. On success, build fresh `StreamRelay(newPodUrl)`, wire handlers, send `{"type":"status","status":"ready"}`, resume relaying. On failure, send error + close.

Status forwarder inside this handler reuses lambda pattern from original provision path but with `status: "reprovisioning"` so client can present different UI (continuous in-session "replacing..." banner vs first-launch full-screen provisioning).

### 4.4 Hold client WS open vs reconnect — trade-off

**Option X — Hold client WS open during replacement (recommended).**
- Pros: zero client-visible churn beyond status banner. No re-open TCP/TLS. `StreamSession.swift` already has `.provisioning(message:)` state we can extend with `.reprovisioning(message:)` — no new view code strictly needed.
- Pros: avoids race — during reconnect client may choose new sessionId or lose config.
- Pros: preserves `lastActivityAt` and server-side identity.
- Cons: Railway edge pins WS to specific backend instance. In Redis-registry world (WS5), concurrent deploy mid-replacement cycles backend and loses held WS. But client reconnects on WS drop — degrades to today's behavior, not worse.
- Cons: 90s hold on a zombie WS. Memory negligible; Railway doesn't bill on connection duration. User sees live status stream, better than blank reconnecting state.

**Option Y — Close client WS, let it reconnect.**
- Pros: simpler; matches today's model.
- Cons: client-visible blip (`.connecting` → `.provisioning` → `.connected`). At 100 users generates support questions.
- Cons: client reconnect has 3 retries over ~7s. 90s replacement = client gives up before pod ready. Require bumping `maxReconnectAttempts` and backoff to ~5 over 120s.

**DECIDED: Option X.** Hold WS open, dispatch `reprovisioning` status, swap upstream relay in place. Option Y remains the fallback if X fails for transport reasons.

### 4.5 Retry bound — DECIDED: 2 attempts

If replacement pod itself preempted or fails to become healthy, session re-enters `replacing`. Cap at **2 replacement attempts per session lifetime** (env `MAX_SESSION_REPLACEMENTS=2`). Past cap, close client with error and let client do its own reconnect path. Track via `session.replacementCount: number` on `Session`.

Rationale: three preemptions in a row = hostile capacity pool (carve-out or zone issue). Escalate to user rather than retry indefinitely.

## 5. Cost implications

Preempted pod typically up long enough to incur RunPod billing minimum (~1 min) + provisioning cost (~3–5 min at bid rate, billed). Replacement restarts clock. No RunPod refund for preempted spot pods. With WS3's baked image driving provision to ~90s, replacement cost per preemption ≈ **$0.53/hr × 90/3600 ≈ $0.013 + ~60s wasted on old pod ≈ $0.009 = $0.022 per event**. At 100 users with ~1%/hr preemption over 8h day = ~80 events/day × $0.022 ≈ **$1.76/day** replacement overhead. Negligible vs UX gain.

Subtlety: pod preempted within first billing minute may still bill a minute. Replacing immediately could double-bill a minute. Not worth gating on.

## 6. Edge cases

- **Replacement itself preempted immediately.** Hit retry bound on second failure; close client with error. Log with distinct event tag to distinguish "bad luck" from "capacity exhaustion" in metrics review.
- **User disconnects during replacement.** `socket.on('close')` fires, calls `sessionClosed(sessionId)`. Today no-op log. New behavior: if `status === 'replacing'`, (a) let replacement finish for reconnection, or (b) cancel. **Recommend (a)**: replacement already through semaphore; canceling mid-provision messy (partial state, orphan risk) and reaper picks up in 10 min if user never returns. Client can reconnect mid-replacement; orchestrator returns shared `replacementPromise` same as `provisionPromise`.
- **Parallel `provisionPromise` vs `replacementPromise`.** Mutually exclusive by state (`provisioning` first-time only; `replacing` post-`ready` only). Can unify as `inFlightProvisionPromise: Promise<{podUrl}> | null` with status enum discriminating path. Unifying keeps `getOrProvisionPod` join simple: if either set, await it.
- **Two clients (same sessionId) during replacement.** Rare today (same device), common post-auth (WS1; one userId, two devices). Both join same `replacementPromise`. No special handling.
- **Reaper fires during replacement.** Reaper acts only on `status === 'ready'`. `replacing` distinct so naturally excluded. Safety guard: skip reap if `replacementPromise != null`.
- **`touch()` during replacement.** `lastActivityAt` keeps updating as client sends frames (buffered nowhere — don't attempt buffer-and-replay; drop). Frames received while `status === 'replacing'` silently dropped in relay; once new relay wired up, fresh frames from canvas arrive. Kiki's streaming stateless per-frame — safe.
- **Reprovisioning while `getPod` API itself down.** RunPod GraphQL outage would hang `classifyClose`. Bound at 5s with `AbortSignal.timeout`; on timeout assume preemption and replace.

## 7. Test plan

Manual simulation sufficient for v1:

1. **Happy-path preemption.** Start session; once `.connected`, from another terminal call `podTerminate(podId)` via small `ts-node` script using `runpodClient.terminatePod`. Verify:
   - Server logs `classifyClose → preempted`.
   - Client receives `{status: "reprovisioning"}` and UI shows banner.
   - Client WS stays open (observable via `socket.readyState` log).
   - Within ~90s (baked image) client receives `{status: "ready"}` and streaming resumes without canvas reset.
2. **Voluntary close.** Trigger reaper manually (idle timeout to 10s via env override); verify close handler takes bucket-C short-circuit, no replacement.
3. **Network blip.** Kill/restart flux-klein server process on pod (not pod itself). Verify bucket-D detection (`RUNNING`, `/health` transiently fails then recovers), upstream WS reconnect succeeds without replacement.
4. **Crash bucket.** SSH into pod, `kill -9` server. Verify bucket B → replace.
5. **Replacement preempted.** Hard to reproduce deliberately; simulate by immediately `podTerminate`-ing replacement pod as soon as it's ready. Verify second replacement kicks in, if terminated again retry bound triggers.
6. **Client disconnects during replacement.** Start replacement; kill client app. Verify replacement completes, pod lives until reaper.
7. **Two concurrent preemptions.** Start two sessions, `podTerminate` both within 1s. Verify semaphore queues cleanly, both recover.

Add `/v1/ops/preempt-test` dev-only endpoint (env-gated) that calls `terminatePod(session.podId)` for given sessionId. Makes tests scriptable.

## 8. Metrics

Aligns with WS6's structured-event model. Emit:

- `session.preempted`: `{sessionId, podId, podUptimeSeconds, closeCode}` on entering bucket A.
- `session.crashed`: `{sessionId, podId, podUptimeSeconds}` on entering bucket B.
- `session.replacement_started`: `{sessionId, attempt, reason}`.
- `session.replacement_succeeded`: `{sessionId, oldPodId, newPodId, replacementTimeMs}`.
- `session.replacement_failed`: `{sessionId, attempt, reason}`.
- `session.replacement_exhausted`: retry bound hit.

Also gauge `session.replacing_count` that WS6's `/v1/ops/metrics` returns for in-flight replacement storms.

## 9. Rollout

Gate behind `PREEMPTION_REPLACEMENT_ENABLED` env flag, default `false` initially. Flag off = close handler falls back to today's error-and-close. Enable in Railway staging first (small user base), run ~3 days watching metrics, then enable in production.

Change is additive in orchestrator (new state, new function) and conditional in stream.ts (feature-flagged branch) — revert is one-line env change, not rollback.

## 10. Open questions

### DECIDED
- **Hold WS open vs reconnect:** hold open (Option X in §4.4).
- **Max replacement attempts:** 2.

### Still open
1. **Buffer canvas frames during replacement, or drop?** Recommend drop — stateless generation, nothing lost, buffering adds complexity.
2. **Distinct "replacing" client state, or reuse existing `.provisioning(message:)`?** Latter reduces iOS changes to zero but message is all user sees. Recommend new case for clarity.
3. **Bucket-D (network blip) reconnect in v1, or punt to v2?** Detection cost small (one `/health` probe) but reconnect-upstream path is new code. Could ship §4 without D, treat blips as preemptions (one unnecessary replacement per blip); cleaner first PR.
4. **Client needs to learn new status string `reprovisioning`, or reuse `provisioning`?** Reuse means iOS doesn't ship in lockstep. Plan recommends new string for metrics clarity + letting iOS render different UI when ready.

## 11. Dependencies and sequencing

**Order: 5 → 6 → 7.** Three workstreams all modify orchestrator's registry and lifecycle; wrong order = merge churn and regressions.

- **WS5 (Redis registry)** rewrites `orchestrator.ts:49` (`registry = new Map`) into Redis ops. Every touch point where WS7 reads/writes session state needs to go through Redis helpers WS5 introduces. Doing WS7 first = rewrite immediately after WS5.
- **WS6 (observability)** introduces event emitter WS7's §8 metrics depend on. Doing WS7 first ships without metrics, no data on whether it's actually working.
- **WS7** cleanly slots in after both.

**Specific lines in `orchestrator.ts` all three touch:**

- Line 49 (`registry = new Map`): WS5 replaces wholesale.
- Lines 100–160 (`getOrProvisionPod`): WS5 async/Redis; WS6 adds `provision.start`/`ssh_ready`/`health_ready`/`failed` events; WS7 adds `replacement_*` + `inFlightProvisionPromise` unification.
- Lines 138–140 (state mutation on provision success): WS5 Redis writes; WS7 adds `status: 'ready'` re-entry path on replacement success here.
- Lines 150–154 (cleanup on provision failure): WS5 Redis delete; WS7 considers clearing `replacementPromise`.
- Lines 162–165 (`touch`): WS5 Redis HSET + TTL reset; WS6 activity counter; WS7 adds state check (no-op if `replacing`).
- Lines 213–227 (`runReaper`): WS5 `SCAN` instead of Map iteration; WS6 emits `session.reaped`; WS7 adds `replacing`-state skip.

All touched by WS5 first (Redis establishes new idioms), then WS6 adds events as instrumentation over new code, then WS7 slots in `replaceSession` + state machine using both primitives.

**Additionally:** WS3 (baked image) not hard dep but strong multiplier. With today's 3–5 min cold start, even transparent replacement is 3–5 min visible banner. With WS3's ~90s, replacement feels like brief blip. Recommend WS7 ships chronologically after WS3 as well, though code changes independent.

## Critical files

- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/orchestrator.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/routes/stream.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/runpodClient.ts`
- `/Users/donald/Desktop/kiki_root/ios/Kiki/App/StreamSession.swift`
- `/Users/donald/Desktop/kiki_root/documents/plans/scale-to-100-users.md`

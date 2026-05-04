# Workstream 5: Redis-backed session registry

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md). Replace the in-memory `Map<sessionId, Session>` with Redis so backend deploys no longer drop active sessions and we can horizontally scale later.

## 1. Context

Today's orchestrator keeps the entire session registry in a single `Map<string, Session>` in `backend/src/modules/orchestrator/orchestrator.ts`. Fine for ~20–50 users on one Railway instance, but two concrete failure modes at 100 concurrent users:

1. **Every deploy drops every active user.** Railway redeploys = process restart. Boot-time `reconcileOrphanPods()` currently terminates every `kiki-session-*` pod — a cost-leak guard that also mass-evicts anyone mid-session. At 100 users that is a visible outage we cause ourselves.

2. **Cannot horizontally scale.** If a single Railway instance saturates on CPU / event loop / file descriptors, we can't add a replica — two replicas with independent maps would double-provision and fight over reconcile.

Redis resolves both. Railway's Redis add-on is ~$5/mo — cheap vs a single minute of a leaked RTX 5090. Moving registry state to Redis:

- **Deploys become safe.** New process boots, reads registry from Redis, adopts still-running pods instead of killing them.
- **Horizontal scale becomes possible.** Two replicas can coexist; work is idempotent, state shared.
- **Restart-during-provision is also survivable** (with care around `provisionPromise`).

This is a refactor of internal storage only — orchestrator's public surface (`getOrProvisionPod`, `touch`, `sessionClosed`, `start`) stays byte-for-byte identical so `stream.ts` doesn't notice.

## 2. Current state

Everything in one file:

```ts
const registry = new Map<string, Session>();

interface Session {
  sessionId: string;
  podId: string | null;
  podUrl: string | null;
  status: 'provisioning' | 'ready' | 'terminated';
  createdAt: number;
  lastActivityAt: number;
  provisionPromise: Promise<{ podUrl: string }> | null;
}
```

Public entry points:

- **`getOrProvisionPod(sessionId, onStatus)`** — reads `registry.get`. If `ready` → returns cached `podUrl`. If `provisionPromise` non-null → awaits the in-process Promise. The hard part of migration: a `Promise` is not serializable and meaningful only inside the process that owns it.
- **`touch(sessionId)`** — `registry.get(sessionId).lastActivityAt = Date.now()`. Called on every relayed frame.
- **`sessionClosed(sessionId)`** — pure logging. Doesn't remove from registry (user may reconnect).
- **`runReaper()`** — `for (const session of registry.values())` → if `ready` + idle > 10 min, mutate `status = 'terminated'`, `terminatePod`, `registry.delete`.
- **`reconcileOrphanPods()`** — lists `kiki-session-*` pods, terminates all. Ignorant of whether any are still in use — why deploys drop users.

**In-memory assumptions that leak** (each needs a Redis plan):

1. **`provisionPromise`** field — not serializable; pinned to the process. Same-process concurrent callers share it; cross-process or post-restart callers cannot.
2. **`session.status = 'terminated'`** mutation before async `terminatePod()` — poor-man's lock. Same process won't re-reap. Across processes, two reapers can both read `ready` simultaneously and both decide to terminate.
3. **`activeProvisions` counter + `semaphoreWaiters` array** — pure in-memory. Two replicas = each has cap of 5; combined 10. Acceptable for WS5; revisit later.
4. **`registry.delete(sessionId)` on provision failure** — atomic with outer try/catch. Redis `DEL` might race with a new `getOrProvisionPod` for same session.
5. **`reconcileOrphanPods()` terminates every `kiki-session-*`** — assumes nothing else owns them. With Redis, we can be smarter: adopt pods still claimed.
6. **Reaper iterates full Map in one pass.** `SCAN` is cursor-based async; reaper becomes async, handles partial views.
7. **`sshKeyWritten` flag** — process-local. Fine to keep process-local.

No public caller in `stream.ts` depends on anything except the return shape of `getOrProvisionPod` (`{ podUrl }`) and void `touch` / `sessionClosed`. That surface stays identical.

## 3. Detailed design

### 3.1 Client choice: `ioredis`

Two candidates:
- **`ioredis`** — mature, built-in reconnection with exponential backoff, cluster-aware (free), connection pool of one multiplexed socket, first-class TS types, native Lua `defineCommand`, `scanStream` iterator.
- **`redis`** (node-redis v4+) — official, actively maintained, Promise-first. Reconnection improved but slightly less forgiving. Smaller Lua surface.

**Recommendation: `ioredis`.** Reasons: (1) reconnection battle-tested — we need it on single-instance Railway where Redis add-on can blip, (2) `scanStream` makes reaper a clean async iterator, (3) `defineCommand` lets us express "compare-and-reap" atomically via Lua, the thing we need most for multi-replica safety.

Add to `backend/package.json`: `"ioredis": "^5"`.

### 3.2 Key schema

One hash per session:

```
session:<sessionId>
```

(After WS1 lands, becomes `session:<userId>`. Refactor here parameterizes key prefix via single `sessionKey(id)` helper so WS1 is a one-line change.)

Fields (all strings; hash fields are strings, cast at boundary):

| Field            | Type in TS      | Encoding                      | Notes |
|------------------|-----------------|-------------------------------|-------|
| `sessionId`      | `string`        | utf-8                         | Denormalized; also in key |
| `podId`          | `string \| null`| utf-8 or field absent         | Use `HDEL` not `"null"` |
| `podUrl`         | `string \| null`| utf-8 or field absent         | Same |
| `status`         | `SessionStatus` | `'provisioning' \| 'ready' \| 'terminated'` | |
| `createdAt`      | `number`        | decimal ms since epoch        | `Number(str)` on read |
| `lastActivityAt` | `number`        | decimal ms since epoch        | |
| `ownerInstance`  | `string`        | Railway replica id / UUID     | Who kicked off provision. Used for in-flight map (§3.3) |
| `schemaVersion`  | `number`        | `"1"`                         | Future-proofing |

**TTL.** Key TTL = `IDLE_TIMEOUT_MS + GRACE_MS` (e.g. 10 min + 5 min = 900s). `touch` resets via `EXPIRE`. Belt-and-suspenders fallback: even if reaper dies, dead sessions evaporate. Pod itself won't auto-terminate on TTL — that's reaper's job — but missed-reap + TTL expiry → next restart's reconcile picks up orphan pod.

**Secondary index.** Not strictly required. `SCAN` with `MATCH session:*` is fine at our scale (≤ few hundred keys). WS7 might want `pod:<podId> → sessionId` reverse key for preemption handling; add then.

### 3.3 In-flight provisions: hybrid local map + Redis state machine

Hard problem: `provisionPromise` is a live in-process Promise. Can't put in Redis. Two cases:

1. **Same-process join:** second `getOrProvisionPod` call for session whose provision is in flight on this replica.
2. **Cross-process or post-restart:** second replica receives reconnect, or same replica restarted mid-provision.

**Hybrid solution:**

- Keep process-local `Map<sessionId, Promise<{podUrl: string}>>` strictly for same-process join. Pure dedup cache; truth in Redis.
- Redis authoritative for *session existence and state*. A row with `status: 'provisioning'` + `ownerInstance: <this-replica>` + fresh `createdAt` = "someone, probably me, is actively provisioning."
- On `getOrProvisionPod`:
  1. `HGETALL session:<id>` → parse.
  2. If `status === 'ready' && podUrl` → return immediately.
  3. If `status === 'provisioning'`:
     - If `ownerInstance === this process's id` and local in-flight Map has entry → await it (same-process join).
     - Else (remote owner, or local owner but restart) → **poll Redis** with short interval (2s up to 8 min) waiting for flip to `ready` or disappearance. Acceptable because provisions take 3–5 min.
     - If record stale (`createdAt + PROVISION_TIMEOUT_MS < now` and still `provisioning`) — assume owner died; delete row, fall through to fresh provision.
  4. If no row → atomic claim:
     ```
     SET session:<id> <placeholder> NX EX <provision-timeout-seconds>
     ```
     If NX succeeded, we own. Replace placeholder with full hash via `HSET`, stash Promise locally, kick off `provision()`.
     If NX failed, another replica beat us; re-read, handle as case 3.

NX SET + HSET is *not* strictly atomic; another replica could SET-NX after us, then HSET, then we overwrite. Two solutions:
- **(a)** Lua script that does NX-check + HSET in one round-trip.
- **(b)** `HSETNX` on `schemaVersion` first, then fill rest only if we got NX slot.

Pick **(a)** — `claim_session.lua` via `redis.defineCommand('claimSession', ...)`. Cleanest expression of "only one replica transitions NONE → provisioning for a given session."

### 3.4 `touch`

```ts
export function touch(sessionId: string): void {
  // Fire-and-forget; don't block frame-relay hot path on Redis
  void redis.multi()
    .hset(`session:${sessionId}`, 'lastActivityAt', String(Date.now()))
    .expire(`session:${sessionId}`, IDLE_TIMEOUT_SECONDS + GRACE_SECONDS)
    .exec()
    .catch((err) => log.warn({ err, sessionId }, 'touch failed'));
}
```

Fire-and-forget critical. `touch` on hot path — every relayed frame. Can't afford Redis round-trip per frame into awaited path. `.catch` prevents unhandled rejection on Redis blip; worst case we briefly under-touch and reaper mis-reaps one session (user recovers by reconnecting).

**Future optimization:** in-process debounce (Redis once per 5s per session). Adds complexity; defer until metrics say it matters.

### 3.5 Reaper via `SCAN`

```ts
async function runReaper(): Promise<void> {
  const now = Date.now();
  const stream = redis.scanStream({ match: 'session:*', count: 100 });
  for await (const keys of stream) {
    for (const key of keys) {
      await reapOneIfIdle(key, now);
    }
  }
}
```

`reapOneIfIdle` is Lua **atomic compare-and-delete**:

```lua
-- KEYS[1]=session:<id>, ARGV[1]=now, ARGV[2]=idleTimeoutMs
local lastActivity = tonumber(redis.call('HGET', KEYS[1], 'lastActivityAt'))
local status = redis.call('HGET', KEYS[1], 'status')
local podId = redis.call('HGET', KEYS[1], 'podId')
if status ~= 'ready' or not lastActivity then return nil end
if (tonumber(ARGV[1]) - lastActivity) <= tonumber(ARGV[2]) then return nil end
redis.call('HSET', KEYS[1], 'status', 'terminated')
return podId
```

If non-nil `podId` → `terminatePod` then `DEL`. Safe across replicas because Lua runs atomically — only one reaper gets the podId back.

### 3.6 Reconcile — adopt, don't nuke

**New behavior:**

```
startup:
  1. HGETALL every session:* → set of (sessionId, podId, podUrl)
  2. listPodsByPrefix('kiki-session-') → RunPod pods
  3. For each RunPod pod:
       - referenced by some session:* row → leave alone ("adopted")
       - not referenced → terminate (genuine orphan)
  4. For each session:* row:
       - podId not in RunPod set OR unhealthy → delete row (stale bookkeeping)
       - else: row live, do nothing
```

Deploys become safe: sessions with live pod survive restart. New process adopts; next `getOrProvisionPod` on client reconnect reads hash, sees `status: ready`, relays to adopted pod.

Edge case: pod was provisioning when backend restarted. Row says `status: provisioning`. No live Promise. Resolution: step 4 treats `provisioning` rows older than `PROVISION_TIMEOUT_MS` as dead — delete row and (if podId exists) terminate. Newer rows left; if owner was another up-replica, resolves normally. Otherwise client eventual retry/timeout flushes.

### 3.7 Rollout — DECIDED: Redis default from first deploy

**No feature flag.** Ship Redis-only code. First deploy with this change makes Redis authoritative immediately.

Rationale (per product decision): simpler code (one path), faster iteration on the new design. Accepts that any Redis-plugin hiccup on deploy day is a full outage with no instant rollback. Railway's Redis plugin is stable; we've validated it works in staging before merging.

Pre-deploy checklist (MUST verify before merge):
- Redis plugin provisioned on Railway, `REDIS_URL` env var set.
- Local `docker-compose` Redis ran green through all integration tests (§7).
- Staging Railway has Redis + backend deployed together and confirmed working for ≥2 hours under a single-user smoke test.

Rollback: revert the merge commit and deploy. No env flag gives instant recovery; code revert + redeploy is the path.

## 4. Failure modes

**Redis briefly unavailable.** ioredis reports `offline`:

- `getOrProvisionPod`: **fail closed**. Return 503-like error rather than falling through to in-memory (can't see other replicas, risks double-provisioning). At two replicas with Redis down, fail-closed = user sees "try again"; fail-open = $0.55/hr duplicate pod. Fail-closed cheaper + more honest.
- `touch`: fire-and-forget, silently drops on error. Brief blip = stale `lastActivityAt` during blip, absorbed by 5-min TTL grace.
- Reaper: `scanStream` errors → log, retry next 60s tick. Skipping one cycle fine.
- Reconcile: if Redis down at boot, no registry to adopt. Fall back to current "terminate all" (cost-safe); log loudly; exit. Railway restarts us.

**`ioredis` reconnection.** Default exponential backoff up to 2s. Set `maxRetriesPerRequest: null` so queued commands don't fail immediately — buffer and retry. `enableOfflineQueue: true` (default). Add 5s hard cap per command via `.call()` wrappers so hung connection doesn't wedge hot path.

**Redis data loss.** Railway Redis is persistent by default (AOF). Worst case (corrupted AOF, restore to empty) → every session row vanishes; reconcile terminates every live pod (fallback path). Bad but not catastrophic — one round of reconnects.

## 5. Connection management

Single shared `ioredis` client at module load:

```ts
const redis = new Redis(config.REDIS_URL, {
  maxRetriesPerRequest: null,
  enableReadyCheck: true,
  lazyConnect: false,
  connectTimeout: 10_000,
  keepAlive: 30_000,
});
```

Exposed via `backend/src/modules/redis/client.ts` (new) so importable from orchestrator and later observability (WS6). Single client multiplexes over one TCP; no pool needed at our throughput.

Event logging:
```ts
redis.on('error', (err) => log.error({ err }, 'Redis error'));
redis.on('reconnecting', (ms) => log.warn({ ms }, 'Redis reconnecting'));
redis.on('ready', () => log.info('Redis ready'));
```

Backend `index.ts`: `await redis.ping()` before `startOrchestrator` — fail fast on broken config.

## 6. Horizontal-scale implications

At two replicas behind Railway LB, both reading/writing same Redis:

- **Provision race** — two clients for same sessionId land on two replicas. Both read "no row." Solved by `SET ... NX` claim: only one wins, loser sees winner's row and polls.
- **Reaper race** — two reapers tick same second, both scan same key. Solved by Lua script: HSET-to-`terminated` inside Lua is atomic; only one gets non-nil podId.
- **Reconcile race** — two replicas boot within seconds (paired-replica deploy). Both run reconcile. Risk: A sees row X live, leaves pod A; B has stale view, terminates pod A. Mitigation: global Redis lock `SET reconcile:lock <owner> NX EX 60`. Replicas without lock skip reconcile.
- **Semaphore** — intentionally per-process for this WS. Two replicas = 10 system-wide cap. Global Redis token bucket when we need; WS7 or follow-up.

`ownerInstance` field useful for WS6 ("which replica owns session") and WS7 (preemption replacement candidate).

## 7. Test plan

**Local harness** — `docker-compose.yml` with Redis:

```yaml
services:
  redis:
    image: redis:7-alpine
    ports: ["6379:6379"]
```

Local `.env`: `REDIS_URL=redis://localhost:6379`.

**Integration tests** (vitest against compose Redis):

1. `getOrProvisionPod` — fresh session writes `status: provisioning` row, flips to `ready` on success.
2. Two concurrent `getOrProvisionPod` same sessionId → one provision, both resolve with same `podUrl`.
3. `touch` updates `lastActivityAt`, resets TTL.
4. Reaper Lua — seed session with stale `lastActivityAt`, run reaper; assert `HSET status=terminated` and podId returned; second call returns nil.
5. Reconcile with mix of (live row, live pod), (stale row, no pod), (no row, live pod) → correct adoption/deletion/termination.

**Manual end-to-end:**

- **Redeploy while session active.** Open iPad, wait `ready`, let frame go through, `railway up`. Client reconnects automatically, hits same pod. Logs: "Reusing existing session pod" — no new `createSpotPod`.
- **Restart mid-provision.** Trigger fresh provision, kill backend at 30s. Boot: reconcile deletes stale `provisioning` row, terminates half-configured pod. Client retry provisions fresh pod.
- **Redis blip.** `docker compose stop redis` for 10s while session active. `touch` logs warnings but doesn't crash; when Redis returns, normal; session's pod wasn't reaped.
- **Two backend replicas locally.** Two processes, different ports, same Redis, same RunPod account. Spam `getOrProvisionPod` for same sessionId through both. Exactly one pod created.

## 8. Rollout

1. **Provision Redis on Railway.** Dashboard → plugin → Redis. Grab `REDIS_URL`.
2. **Deploy code with flag off.** `SESSION_REGISTRY=memory` default. Code on disk but inert. Verify `redis.ping()` succeeds at boot.
3. **Test in staging.** If no staging, local docker-compose + single-user smoke against Railway with flag flipped for just our iPad.
4. **Flip flag in production.** `railway variable set "SESSION_REGISTRY=redis"` + redeploy. One destructive deploy; pick quiet hour. In-memory sessions lost once.
5. **Observe one week.** Watch for Redis connection churn, reaper errors, double-provisions.
6. **Remove `memory` path** after stable week. Delete flag. Orchestrator Redis-only.

## 9. Open questions

### DECIDED
- **Rollout:** Redis default from first deploy (no feature flag).
- **Key schema:** key by `userId` immediately (since WS1 auth is confirmed). `session:<userId>` is the schema from day one; no migration later.

### Still open
1. **Railway region for Redis.** Backend `us-west`. Put Redis same region — ~1ms RTT vs 70ms cross-region. Railway should co-locate; confirm.
2. **Post-crash adoption vs just post-deploy?** Graceful deploy easy; hard crash depends on Redis persistence. Railway's Redis is AOF default; confirm. If RDB-only, lose up to 60s of registry on crash — not terrible.
3. **Lua vs JS round-trips.** Two Lua scripts proposed (`claimSession`, `reapOneIfIdle`). Keep JS-only with weaker atomicity? Strong recommend Lua — 20 lines total, atomicity is the whole point.

## 10. Dependencies and sequencing

`orchestrator.ts` is hot spot for three workstreams:

- **WS5 (this doc)** rewrites *storage layer* of `getOrProvisionPod`, `touch`, `sessionClosed`, `runReaper`, `reconcileOrphanPods`. Essentially every function except `provision()` (SCP/setup dance) and semaphore helpers.
- **WS6 (observability)** adds instrumentation: counters on `acquireSemaphore`/`releaseSemaphore`, histograms around `provision()` phases, failure-reason taxonomy in catch, new `/v1/ops/metrics` data sourced from session state.
- **WS7 (graceful preemption)** modifies upstream close handler in `stream.ts` + adds "prepare replacement pod while holding client WS open" path in orchestrator. New public function (`replacePodForSession`); touches reaper to not reap mid-replacement. Needs reverse `pod:<podId> → sessionId` index (cheap in Redis).

**Conflict map (functions each WS edits):**

| Function | WS5 | WS6 | WS7 |
|---|---|---|---|
| `getOrProvisionPod` | rewrite | wrap with metrics | add replacement path |
| `touch` | rewrite | counter | — |
| `sessionClosed` | rewrite | event | maybe (cancel replacement) |
| `runReaper` | rewrite | counter | "don't reap mid-replacement" |
| `reconcileOrphanPods` | rewrite | event | — |
| `provision()` (SCP/setup) | untouched | heavy instrumentation | untouched |
| `acquireSemaphore` | untouched | counter | maybe move to Redis |
| stream.ts upstream close | untouched | event | major rewrite |

**Serialization: land 5 → 6 → 7.**

- **WS5 first** — biggest structural change; everything else builds on top. Doing WS6/WS7 first means re-doing their work after WS5, or saddling WS5 with their changes. Refactor also gives WS7 natural place to stash reverse index (Redis).
- **WS6 second** — mostly additive (wrap functions, new route); doesn't change semantics. Low merge-risk.
- **WS7 last** — needs WS5's Redis reverse index + WS6's metrics to tell us whether "replacement within 90s" holds. Also touches `stream.ts` non-trivially — better on stable orchestrator base.

No concurrent work on orchestrator.ts across these. One workstream at a time; WS6/WS7 can develop off-main while WS5 ships.

## Critical files

- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/orchestrator.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/routes/stream.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/index.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/config/index.ts` (new `REDIS_URL` + `SESSION_REGISTRY` flag)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/redis/client.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/package.json` (add `ioredis` dep)

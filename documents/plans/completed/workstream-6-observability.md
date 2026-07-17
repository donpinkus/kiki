# Workstream 6: Observability

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md). Structured metrics + events for the per-session pod orchestrator, exposed at `/v1/ops/metrics`. In-process counters/histograms + JSON-lines events. No hosted service, no OpenTelemetry.

## 1. Context — why unstructured logs won't cut it at 100 users

Today every provision lifecycle step produces a Pino `log.info` line on Railway. At 5 testers that's greppable; at 100 concurrent users with 3–5 min cold starts, each active minute produces hundreds of interleaved lines across concurrent provisions. The questions we need to answer in that regime are distributional:

- What's p50/p95/p99 time-to-ready right now? Trending up/down after last deploy?
- What fraction of provisions fail? What category dominates (spot capacity? SSH timeout? health timeout?)?
- How many sessions active? How many stuck in `provisioning` vs `ready`?
- How deep is the semaphore queue?

None answerable by `grep` in Railway's log viewer. Need in-process aggregation + single HTTP surface returning current snapshot. Stay small: half-day work, not Datadog.

## 2. Current state — inventory

### `orchestrator.ts`

| Line | Log call | Carries |
|---|---|---|
| reuse branch | `'Reusing existing session pod'` | `sessionId, podId` |
| join branch | `'Waiting for in-flight provision'` | `sessionId` |
| catch | `'Provision failed'` | `sessionId, err` — raw Error, no category |
| `sessionClosed` | `'Client disconnected; pod stays alive pending reconnect'` | `sessionId, podId, idleAfterMs` |
| `start` | `'Orchestrator started'` | `idleTimeoutMs, maxConcurrent` |
| `acquireSemaphore` wait | `'Provision queued'` | `active, cap` — no `sessionId`, no queue depth |
| `runReaper` | `'Reaping idle pod'` | `sessionId, podId, idleMs` |
| reap error | `'Reap failed'` | `sessionId, podId, err` |
| `reconcileOrphanPods` | `'Reconcile: no orphan pods found'` or `'terminating orphan pods'` | `count` |
| `provision` step 1 | `'Spot bid discovered'` | `sessionId, minBid, bid` — missing `stockStatus` |
| step 2 | `'Pod created'` | `sessionId, podId, authenticated` |
| step 3 | `'Pod SSH ready'` | `sessionId, podId, ssh` — no elapsed time |
| step 6 | `'Pod ready'` | `sessionId, podId, podUrl` — no total elapsed time |

### `stream.ts`

| Line | Log call | Carries |
|---|---|---|
| On connect | `'Stream client connected'` | `sessionId` |
| Disconnect during provisioning | `'Client disconnected during provisioning'` | `sessionId` |
| Upstream close | `'Upstream closed'` | `sessionId, code, reason` — only signal for preemption detection |
| Upstream error | `'Upstream error'` | `sessionId, err` |
| Relay ready | `'Upstream connected, relaying'` | `sessionId` |
| Client disconnect | `'Stream client disconnected'` | `sessionId` |
| Provisioning catch | `'Provisioning or relay failed'` | `sessionId, err` |

**Gaps:**
- No durations computed — `createdAt` exists but never diffed into `timeToReady`.
- No failure categorization — every error through same `log.error` as raw `Error.message`.
- No counters. "How many provisions succeeded today" requires log aggregation.
- Semaphore queue depth never recorded (only `active` vs `cap` at log time).

## 3. Event taxonomy

Every event emitted via metrics module as both (a) counter increment / histogram observation and (b) structured JSON log line (`log.info` with stable `event` field). `sessionId` implicit everywhere.

| Event | Fields | Counter | Histogram |
|---|---|---|---|
| `provision.start` | `sessionId` | `provision_start_total` | — |
| `provision.spot_bid_discovered` | `minBid`, `bid`, `stockStatus` | — | — |
| `provision.pod_created` | `podId`, `authenticated`, `elapsedMs` (since `provision.start`) | `pod_created_total{auth}` | `pod_creation_ms` |
| `provision.ssh_ready` | `podId`, `elapsedMs` | — | `ssh_ready_ms` |
| `provision.setup_started` | `podId`, `elapsedMs` | — | — |
| `provision.health_ready` | `podId`, `elapsedMs` = total time-to-ready | `provision_success_total` | `provision_total_ms` |
| `provision.failed` | `podId` (nullable), `category`, `elapsedMs`, `message` (200 char trunc) | `provision_failed_total{category}` | `provision_failed_ms{category}` |
| `session.reaped` | `podId`, `idleMs`, `lifetimeMs` | `session_reaped_total` | `session_lifetime_ms` |
| `session.preempted` | `podId`, `closeCode`, `lifetimeMs` | `session_preempted_total` | — |
| `session.client_disconnected` | `podId`, `sessionPhase` (`provisioning` \| `ready`) | `session_client_disconnect_total{phase}` | — |
| `semaphore.waited` | `queueDepth` (at enqueue), `waitedMs` | `semaphore_wait_total` | `semaphore_wait_ms` |

**Failure categories** (enum, assigned at throw site):
- `spot_capacity` — `stockStatus` is `None` or `Low` at bid discovery
- `pod_create_failed` — `createSpotPod` GraphQL error
- `ssh_timeout` — `waitForSsh` deadline
- `scp_failed` — `scpFiles` child process non-zero
- `setup_failed` — `runSetup` non-zero
- `health_timeout` — `waitForHealth` deadline
- `unknown` — catch-all

**Gauges** (point-in-time, not counters):
- `sessions_active{status}` — count by status in registry (`provisioning`, `ready`, `terminated`)
- `semaphore_active` — current `activeProvisions`
- `semaphore_queue_depth` — current `semaphoreWaiters.length`

Gauges computed on-demand at metrics endpoint read (iterate `registry.values()` once per scrape). No background state.

## 4. Detailed design

### 4.1 New file: `backend/src/modules/orchestrator/metrics.ts`

Pure module, no external deps. Exports:

```ts
record(event: EventName, fields: object): void
observeHistogram(name: HistogramName, ms: number): void
incrementCounter(name: CounterName, labels?: object): void
snapshot(): MetricsSnapshot      // called by /v1/ops/metrics handler
resetForTest(): void              // unit tests only
```

Internal state:
```ts
const counters = new Map<string, number>()     // key: "name{k=v,k=v}"
const histograms = new Map<string, HistState>()
type HistState = { buckets: number[], counts: number[], sum: number, count: number }
```

- Counters: flat map from label-serialized key to integer. Label serialization deterministic (sorted keys) so `{a=1,b=2}` and `{b=2,a=1}` collide correctly.
- Histograms: fixed-bucket, plus running `sum` and `count` for `avg`. No reservoir sampling, no t-digest. Bucket counts sufficient for percentile estimates within bucket granularity.
- No per-sample storage. O(buckets) memory per histogram forever. Footprint: ~14 buckets × 4 histograms × 8 bytes = negligible.
- No reset/rotation. Since-boot counters. Railway redeploys ~daily during dev; acceptable for v1. Windowing is rewrite, not v1 feature.

### 4.2 Histogram bucket choice

Fixed powers-of-two-ish, tuned to actual latency ranges. Units = milliseconds. Cumulative counts (Prometheus-style) — trivial percentile computation.

| Histogram | Buckets (ms) | Rationale |
|---|---|---|
| `provision_total_ms` | 30000, 60000, 90000, 120000, 180000, 240000, 300000, 420000, 600000, 900000, +Inf | Current 180–300s; post-WS3 should be 60–90s. Buckets straddle both. |
| `ssh_ready_ms` | 10000, 20000, 30000, 45000, 60000, 90000, 120000, 180000, 300000, +Inf | Typical 15–45s; tail to minutes. |
| `pod_creation_ms` | 2000, 5000, 10000, 15000, 30000, 60000, +Inf | Just `createSpotPod` GraphQL. |
| `semaphore_wait_ms` | 0, 1000, 5000, 15000, 60000, 180000, 600000, +Inf | `0` captures "no wait"; long tails = full queue. |
| `session_lifetime_ms` | 60000, 300000, 600000, 900000, 1800000, 3600000, +Inf | Cluster near 600000 (idle timeout). >3600000 = heavy users. |
| `provision_failed_ms` | 5000, 30000, 60000, 180000, 600000, +Inf | Fast failures (spot capacity, pod create) vs slow (SSH/health timeout). |

Percentile at snapshot time: linear interpolation within bucket containing target rank. For v1 report exact-bucket: `p50/p95/p99` = upper boundary of bucket where cumulative count first crosses target. Cheaper, less code; precision matches bucket choice.

**Library recommendation: none.** Write ~80 lines in-house. `prom-client` exists but pulls in label-exploder logic we don't need + adds locked dependency. In-house easier to review, trivially portable later.

### 4.3 Endpoint: `/v1/ops/metrics`

Fastify route plugin at `backend/src/routes/ops.ts` (shared with WS4's `/v1/ops/cost` — both belong in same file for auth colocation).

**Format: JSON, not Prometheus text.**

- No Prometheus scraper in this stack; adding text format is speculative build.
- JSON directly consumable by `curl | jq` — the v1 use case.
- Migration path: later add `/v1/ops/metrics.prom` rendering same internal snapshot as text. No disruption.

Response shape:

```json
{
  "uptimeSeconds": 14023,
  "snapshotAt": "2026-04-12T14:30:11Z",
  "gauges": {
    "sessions_active": { "provisioning": 3, "ready": 42, "terminated": 0 },
    "semaphore_active": 5,
    "semaphore_queue_depth": 2
  },
  "counters": {
    "provision_start_total": 187,
    "provision_success_total": 164,
    "provision_failed_total": { "spot_capacity": 9, "ssh_timeout": 2, "setup_failed": 1, "health_timeout": 11, "unknown": 0 },
    "pod_created_total": { "authenticated": 173, "unauthenticated": 3 },
    "session_reaped_total": 101,
    "session_preempted_total": 18,
    "session_client_disconnect_total": { "provisioning": 4, "ready": 99 },
    "semaphore_wait_total": 62
  },
  "histograms": {
    "provision_total_ms": { "p50": 180000, "p95": 300000, "p99": 420000, "avg": 201340, "count": 164 },
    "ssh_ready_ms": { "p50": 30000, "p95": 90000, "p99": 180000, "avg": 41200, "count": 164 },
    "pod_creation_ms": { "p50": 5000, "p95": 15000, "p99": 30000, "avg": 6410, "count": 176 },
    "semaphore_wait_ms": { "p50": 0, "p95": 15000, "p99": 180000, "avg": 3200, "count": 187 },
    "session_lifetime_ms": { "p50": 600000, "p95": 1800000, "p99": 3600000, "avg": 780000, "count": 101 },
    "provision_failed_ms": { "p50": 30000, "p95": 600000, "p99": 600000, "avg": 120000, "count": 23 }
  }
}
```

### 4.4 Auth: shared-secret header

Same scheme as WS4's `/v1/ops/cost`:

- `Authorization: Bearer <OPS_SECRET>` header. `OPS_SECRET` is Railway env var.
- Shared plugin `backend/src/modules/ops-auth/index.ts` (new) decorating Fastify preHandler. Both `/v1/ops/metrics` and `/v1/ops/cost` register it.
- 401 on missing/mismatch. No body on failure.
- Constant-time compare via `crypto.timingSafeEqual`.

Does NOT integrate with user-facing JWT auth from WS1. These are operator-only. Keeps ops secret rotation independent of user tokens.

### 4.5 Structured logs: JSON lines with `event` field

Every metrics call also emits Pino log:

```ts
log.info({ event: 'provision.health_ready', sessionId, podId, elapsedMs, /* ... */ }, 'provision.health_ready')
```

- `event` field sortable/filterable key for future log-drain parser.
- Human string = `event` for consistency. No free-form messages.
- Level: `info` for successes/lifecycle; `warn` for degraded (queue depth > cap); `error` only for `provision.failed{category: unknown}`. `spot_capacity` is `warn` — expected externally-caused failure.
- Remove/refactor existing log.info lines listed in §2 so orchestrator has ONE emission path per lifecycle transition. No double-logging.

### 4.6 Integration into orchestrator.ts

Surgical:

1. Import `metrics` at top.
2. Add `provisionStartedAt: number` to `Session` interface — set at `provision.start`, referenced at every subsequent step for `elapsedMs`.
3. At each of 6 steps in `provision()`, replace `log.info(...)` with `metrics.record('provision.<step>', { sessionId, elapsedMs: Date.now() - session.provisionStartedAt, ... })`.
4. In `provision()` catch site, classify error before `metrics.record('provision.failed', { category, message, elapsedMs })`. Small `classifyProvisionError(err): FailureCategory` helper, pattern-matching `err.message` prefixes. Add typed `ProvisionError` class with `category` field at known throw sites so classification is deterministic.
5. In `acquireSemaphore`, measure `waitedMs = Date.now() - queuedAt`; emit `semaphore.waited` with `queueDepth: semaphoreWaiters.length` at enqueue time.
6. In `runReaper`, emit `session.reaped` with `idleMs` and `lifetimeMs = now - session.createdAt`.
7. Export `snapshotSessionGauges()` returning `{ provisioning, ready, terminated }` counts. `/v1/ops/metrics` handler calls at read time.

### 4.7 Integration into stream.ts

Two emissions:

1. On upstream `close`, classify: `code` is `1006` (abnormal), `1011` (internal error), or `1000` with reason matching `preempt` → emit `session.preempted`. Else `session.client_disconnected` NOT triggered here (emitted from client-side `socket.on('close')`).
2. On client-side `socket.on('close')`, emit `session.client_disconnected` with `sessionPhase` = current `session.status`.

Preemption heuristic for v1: upstream close where pod still marked `ready` in registry AND close code `1006`/`1011`/`1012`/`1013`/`1014` assumed preempted. False positives (blip closed upstream cleanly) show up as preemption events; fine for counter — tune by watching ratio to actual RunPod terminations. WS7 replaces heuristic with real probe.

## 5. What NOT to do in v1

Explicit non-goals:

- **No Grafana / Datadog / Honeycomb.** JSON endpoint + Railway logs = complete surface.
- **No OpenTelemetry.** Tracing across services doesn't apply — one backend + opaque pod.
- **No dashboards.** If needed, `curl | jq` + build in 10 min.
- **No alerting from this WS.** WS4 owns alerts; reads `/v1/ops/metrics` + `/v1/ops/cost`.
- **No metric persistence.** Counters reset on restart. Accepted. If persistence needed, write snapshots to Redis (after WS5).
- **No per-user labels.** Bounded-cardinality only (`category`, `phase`, `auth`). `userId` label would explode counter map. Per-user attribution via logs.
- **No histogram rotation / sliding windows.** Since-boot sufficient.
- **No Prometheus text format.** Add when scraper wants it.

## 6. Test plan

Manual verification against Railway:

- `curl -H "Authorization: Bearer $OPS_SECRET" https://.../v1/ops/metrics` returns 200 + shape from §4.3.
- Omit auth → 401.
- Kick fresh WS session (`wscat -c wss://.../v1/stream?session=<uuid>`); poll `/v1/ops/metrics` every 30s:
  - `sessions_active.provisioning` rises to 1, then falls to 0 as `ready` rises to 1.
  - `provision_start_total` increments exactly once.
  - After `provision.health_ready` fires, `provision_total_ms.count` = 1, `p50` populated.
- Force each failure category, verify counter bumps:
  - `spot_capacity`: bogus GPU type in dev branch; confirm `provision_failed_total.spot_capacity` increments.
  - `ssh_timeout`: shrink `waitForSsh` timeout to 1000ms in test harness; confirm.
  - `health_timeout`: block port 8766 on pod; confirm after deadline.
- Semaphore: open 7 concurrent sessions with `MAX_CONCURRENT_PROVISIONS=5`; verify `semaphore_wait_total` increments to 2 and `semaphore_queue_depth` peaks at 2 then drains.
- Reaper: shrink idle timeout to 10s locally; confirm `session_reaped_total` increments and `session_lifetime_ms.count` on clean disconnect + wait.

Unit tests (Vitest) for `metrics.ts`:
- `observeHistogram` puts value in correct bucket; `snapshot()` returns expected percentiles.
- `incrementCounter` with labels produces correct serialized key (order-insensitive).
- `classifyProvisionError` returns right category for each typed `ProvisionError`.

## 7. Rollout

Low risk — adds no user-visible behavior, doesn't alter provision control flow.

1. Land metrics.ts + ops route + auth plugin in one PR. No orchestrator.ts changes yet — proves endpoint returns empty snapshot.
2. Second PR wires orchestrator emissions (replacing log.info lines). Explicit diff-by-diff so reviewer confirms one-for-one replacement.
3. Third PR wires stream.ts emissions (preemption heuristic + client disconnect).
4. Each PR independently revertable.

No DB migration. No env-var changes beyond adding `OPS_SECRET`. Default `OPS_SECRET` to empty string; plugin refuses all ops requests when unset — fail-closed.

Recommended deploy: after WS5 (Redis registry) so orchestrator touch is done on post-Redis shape — avoids rebase fight.

## 8. Open questions

1. **JSON vs Prometheus text format?** Recommend JSON-only for v1. Revisit when Prometheus scraper stands up. If someone wants Grafana Cloud Free *now*, extra `.prom` handler is half hour.
2. **Histogram bucket choices.** Educated guesses. Review after week of production data and re-tune. Document in module header that buckets tunable.
3. **Counter reset on deploy — acceptable?** For v1 yes. If ops team uses since-boot counters for "what happened last week," need persistence — Redis move fits naturally after WS5.
4. **Preemption heuristic false-positive rate.** Won't know until we run. Accept noise in v1; WS7 makes it precise.
5. **Should `session.client_disconnected` distinguish clean (1000 from client) vs network blip (1006)?** Probably yes. Adds third label value `clean | abrupt`. Cheap; include unless hurried.
6. **Okay with ONE shared `OPS_SECRET` for both `/v1/ops/metrics` and `/v1/ops/cost`?** Yes for v1. If later want separate audit trails, split into `OPS_METRICS_SECRET` + `OPS_COST_SECRET`. Trivial.

## 9. Dependencies and sequencing

### Conflicts with WS5 (Redis registry)

Both modify `orchestrator.ts`. WS5 is larger refactor (swap Map for Redis hash, `SCAN` reaper, `reconcile` against Redis). WS6 adds instrumentation at every step.

**Recommendation: WS5 first, then WS6.**

- Rebasing instrumentation onto refactored registry is mechanical — replay each `metrics.record` at new site. Straightforward.
- Rebasing refactor on instrumentation means re-reviewing every instrumented touchpoint. Slower, more conflicts.
- `snapshotSessionGauges` needs to work whether registry is Map or Redis hash. After WS5, gauges become async-ish scan; make `/v1/ops/metrics` async (fine — route handlers already async) or cache gauges with 5s TTL. Recommend async, no cache, since scrapes rare.

### Conflicts with WS7 (preemption)

WS7 replaces heuristic in §4.7 with real probe. WS7 emits:
- `session.preempted` (already in taxonomy)
- `session.replaced` — new event for "preempted + successfully replaced before client noticed" — add to taxonomy when WS7 lands

**Recommendation: WS6 first, WS7 second.** WS7 benefits from counters in place — we want to measure "did graceful preemption reduce user-visible failures?" which requires baseline from WS6.

### Overlaps with WS4 (cost monitoring)

Both expose ops endpoints under `/v1/ops/*` with shared-secret auth. Ship `ops-auth` plugin + `routes/ops.ts` together — whichever lands first owns scaffolding, other extends.

`OPS_SECRET` env + auth plugin are shared.

### Final recommended order

**5 (Redis) → 4 (cost) → 6 (observability) → 7 (preemption).**

Rationale: 5 unblocks safe deploys. 4 establishes ops scaffolding + starts catching cost spikes. 6 layers metrics on top so 7 has baseline numbers to show improvement against.

## Critical files

- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/metrics.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/ops-auth/index.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/routes/ops.ts` (shared with WS4)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/orchestrator.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/routes/stream.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/index.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/config/index.ts`

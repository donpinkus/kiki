# Workstream 4: Cost monitoring + alerting

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md). In-backend cost visibility so we don't learn about cost spikes via RunPod's billing page after the fact.

## 1. Context

At 100 concurrent users, one bad day can be four figures. Scenarios we want to catch in minutes, not days:

- Leaked session UUID gets into a crawler/group chat — pods provisioned faster than 10-min reaper can terminate.
- Orchestrator bug leaves pods past idle window (reaper crashes, reconcile skipped, `touch()` looped).
- RunPod stock shifts us onto on-demand (WS2) at ~2× hourly rate, nobody notices until month-end.
- 100 users × $0.55/hr = $55/hr = $1,320/day saturated. A single stuck pod for 24h ≈ $13.

Today: zero in-backend signal. Only cost view is RunPod's billing page (15–60 min lag). Want:
- A number we can `curl` at any time: current $/hr burn.
- Daily log line for graphing last 30 days from Railway log drain.
- Webhook nagging within ~1 hour when something is wrong.

Scope deliberately small: just enough not to go broke. Not a full observability platform — that's WS6.

## 2. Current state

RunPod GraphQL gives us what we need without new integrations:

- `myself.pods` returns all account pods. `listPodsByPrefix('kiki-session-')` in `runpodClient.ts` already filters to ours.
- `podRentInterruptable` returns `costPerHr` at creation; we receive it but don't store anywhere.
- `getPod(podId)` returns `runtime.uptimeInSeconds` — direct pod-age proxy.

What we don't have:
- `costPerHr` not in `PodSummary` shape returned by `listPodsByPrefix` — extend the GraphQL query.
- No persistent record of terminated-pod costs. Sums are live-only.
- No creation timestamp outside orchestrator's `Session.createdAt` (in-memory; lost on deploy).

Implication: cost monitor reads live pod state from RunPod each tick rather than trusting orchestrator state. Makes it resilient to registry drift — bonus safety net.

## 3. Detailed design

### 3.1 New module: `backend/src/modules/orchestrator/costMonitor.ts`

Single file, mirrors orchestrator's module-scoped-state pattern. Exports `start(logger)`.

Responsibilities:

1. **Periodic tick** (every `COST_MONITOR_INTERVAL_MS`, default 5 min — short enough to catch blowouts, long enough to avoid RunPod API pressure). Each tick:
   - Call extended `listPodsByPrefix` returning `costPerHr` + `runtime.uptimeInSeconds`.
   - Compute: `activePodCount`, `currentBurnPerHr = sum(costPerHr)`, `oldestPodAgeSeconds = max(uptimeInSeconds)`.
   - Per-pod breakdown: `{ podId, name, costPerHr, ageSeconds, podType: 'spot' | 'onDemand' | 'unknown' }`.
   - Append `{ timestamp, burnPerHr, activePodCount }` to in-memory ring buffer (24h at 5-min cadence = ~288 entries).
   - Emit structured info log (see 3.5).
   - Update `getSnapshot()` return value.
   - Run threshold checks — fire webhook if breached.

2. **Daily rollup at midnight UTC**: sum `burnPerHr * intervalHours` across ticks for prior UTC day → emit `kiki.cost.daily` log with `{ dayUtc, totalDollars, peakBurnPerHr, peakActivePodCount }`. Implemented as second `setInterval` with drift correction (check wall clock each tick; roll over when `getUTCDate()` advances).

3. **In-memory snapshot** exposed via `getSnapshot()`:

```ts
interface CostSnapshot {
  capturedAt: string;
  activePodCount: number;
  currentBurnPerHr: number;    // USD/hr, 4 decimals
  rolling24hTotal: number;     // trapezoidal integration over ring buffer
  oldestPodAgeSeconds: number;
  pods: Array<{
    podId: string;
    name: string;
    costPerHr: number;
    ageSeconds: number;
    podType: 'spot' | 'onDemand' | 'unknown';
  }>;
  thresholds: {
    maxActivePods: number;
    max24hSpend: number;
    maxPodAgeSeconds: number;
  };
  lastAlertAt: string | null;
}
```

4. **GraphQL extension.** Add to `runpodClient.ts`:

```ts
export interface PodCostInfo {
  id: string;
  name: string;
  desiredStatus: string;
  costPerHr: number;
  runtime: { uptimeInSeconds: number } | null;
}
export async function listPodsWithCost(prefix: string): Promise<PodCostInfo[]>;
```

Query: `myself { pods { id name desiredStatus costPerHr runtime { uptimeInSeconds } } }`. Keep existing `listPodsByPrefix` intact.

5. **Failure posture.** Cost monitor errors logged at `warn` and swallowed — a failing RunPod API call must never crash backend. On repeated (>3 consecutive) failures, fire one-shot `cost_monitor_unhealthy` webhook.

### 3.2 New route: `backend/src/routes/ops.ts`

Register after `healthRoute`. Endpoints:

- `GET /v1/ops/cost` → returns `CostSnapshot` JSON
- `GET /v1/ops/cost/history` → 24h ring buffer as `Array<{ timestamp, burnPerHr, activePodCount }>` for `curl | jq` trend plotting

Both require `X-Ops-Key: <OPS_API_KEY>` header. Missing/wrong → 401. Auth check via tiny shared preHandler; don't extend `authPlugin` (that's for user auth, changes under WS1).

### 3.3 Auth: shared-secret header

v1 intentionally crude:

- `OPS_API_KEY` env var. Generate with `openssl rand -hex 32`; Railway env.
- Single `preHandler` checks `request.headers['x-ops-key'] === config.OPS_API_KEY`. Constant-time compare via `crypto.timingSafeEqual` on equal-length buffers; length mismatch → false.
- If unset at boot, log warning and **refuse to register ops routes** (fail closed). Backend still starts; ops unreachable.
- **Upgrade path:** once WS1 lands, ops endpoints gate on `userId in config.OPS_ADMINS` (JSON array env var). Shared secret goes away.

### 3.4 Webhook alerts

Env vars:
- `COST_ALERT_WEBHOOK_URL` — Slack-compatible incoming webhook (Discord also accepts Slack shape)
- `COST_ALERT_MAX_ACTIVE_PODS` — default 50
- `COST_ALERT_MAX_24H_SPEND` — USD, default 50
- `COST_ALERT_MAX_POD_AGE_SECONDS` — default 3600 (1h)
- `COST_ALERT_COOLDOWN_SECONDS` — default 1800 (30 min)

POST body (Slack format):

```json
{
  "text": "[kiki] cost alert: max_active_pods breached (58 > 50). 24h spend: $41.23. Oldest pod: 0h37m.",
  "attachments": [
    {
      "color": "warning",
      "fields": [
        { "title": "activePods", "value": "58", "short": true },
        { "title": "burnPerHr", "value": "$31.90", "short": true },
        { "title": "rolling24hTotal", "value": "$41.23", "short": true },
        { "title": "oldestPodAge", "value": "37m", "short": true }
      ]
    }
  ]
}
```

State: `Map<BreachKey, lastAlertAtMs>`. Keys: `'max_active_pods' | 'max_24h_spend' | 'max_pod_age' | 'monitor_unhealthy'`. Each tick: if condition true AND `Date.now() - lastAlertAtMs > cooldownMs`, fire webhook. Fire-and-forget `fetch` with 5s timeout; log failures, don't throw.

No webhook URL → log at `warn`, move on.

### 3.5 Daily log-line format

Grep-friendly, stable key order:

```
kiki.cost.daily dayUtc=2026-04-11 totalDollars=23.41 peakBurnPerHr=4.95 peakActivePodCount=9 sampleCount=288
kiki.cost.tick burnPerHr=2.15 activePods=4 oldestPodAgeSec=842 rolling24h=18.73
```

Plain k=v over JSON because Railway's log viewer makes space-copy painful; composes with `grep | awk`. Pino structured JSON still goes to log drain at info-level with same fields.

## 4. Data retention

**Start with logs only. No database.**

- Ring buffer in memory: 24h tick data (~288 samples). Lost on deploy — acceptable; each tick is logged so post-hoc recovery via `railway logs --filter kiki.cost.tick`.
- Daily totals live forever in Railway log drain (retention per Railway plan).

**When to add TSDB:** when (1) per-user cost attribution for billing, (2) weekly/monthly trend dashboards without grepping, (3) Railway log retention shortens. First candidate: Grafana Cloud Free (10k series, 14-day retention) with Prometheus format from WS6 — already on roadmap, piggyback rather than stand up new.

## 5. Alert thresholds

Starting defaults, all env-overridable:

| Threshold | Default | Rationale |
|---|---|---|
| `COST_ALERT_MAX_ACTIVE_PODS` | 50 | Half the 100-user target. Earlier signal = more reaction time. |
| `COST_ALERT_MAX_24H_SPEND` | 200 | USD. Roughly linear with 100-user target × 8h active × $0.55/hr ≈ $440; half = worry line. |
| `COST_ALERT_MAX_MONTHLY_SPEND` | 5000 | USD. Hard cap from product. When hit, alert loudly AND return errors to new provisions (circuit-break) so we don't overshoot. Env-adjustable so you can raise as growth justifies. |
| `COST_ALERT_MAX_POD_AGE_SECONDS` | 3600 | Normal idle-reap at 10 min; past 1h is a stuck pod. |
| `COST_ALERT_COOLDOWN_SECONDS` | 1800 | 30 min between same-breach alerts. |
| `COST_MONITOR_INTERVAL_MS` | 300000 | 5 min. Sub-1-hour detection budget on all three breaches. |

The `MAX_MONTHLY_SPEND` threshold is unique because it's a **hard cap** (per product decision: $5k/mo during beta). When breached, the cost monitor:
1. Fires the webhook alert (one-time, not rate-limited — the whole point is urgency).
2. Flips an in-memory `costGateOpen=false` flag that `getOrProvisionPod` checks *before* acquiring the semaphore.
3. New provisions fail with `{ type: 'error', code: 'monthly_cap_reached', message: '...' }`; client shows a "Kiki is full for the month" state.
4. Flag stays tripped until you manually raise the cap via `railway variables --set COST_ALERT_MAX_MONTHLY_SPEND=<new>` (or wait for the month to roll over).

Tuning is operational chore; ship and adjust on first false alarm.

## 6. Integration with WS2 (on-demand fallback)

When WS2 lands, `costPerHr` alone won't tell us spot vs on-demand. Changes:

- Orchestrator stashes `podType: 'spot' | 'onDemand'` where monitor can read. Simplest: extend pod *name* suffix (`kiki-session-<id>-sp` / `-od`) so monitor derives from `listPodsWithCost` without cross-module coupling.
- Cost monitor infers from suffix. Unknown → `'unknown'`. Per-pod breakdown includes it.
- Daily log gets extra fields: `spotDollars=X.YZ onDemandDollars=A.BC`.
- Separate per-type thresholds deferred — aggregate OK until we see actual split.

WS4 ships first with `'unknown'` tag; WS2's PR adds name-suffix.

## 7. Integration with WS6 (observability)

Cost is a metric. Both workstreams want `/v1/ops/*` with authenticated JSON.

**Decision: same ops route module, separate endpoints, shared auth preHandler.**

- `backend/src/routes/ops.ts` registers `/v1/ops/cost`, `/v1/ops/cost/history` (this WS) and later `/v1/ops/metrics` (WS6). Single preHandler, single auth env var.
- Data sources in own modules: `costMonitor.ts` and (future) `metrics.ts`. Route file imports snapshot getters.
- When WS6 adds Prometheus format, `/v1/ops/metrics` can optionally include cost metrics (`kiki_active_pods`, `kiki_burn_per_hr_usd`, `kiki_pod_age_seconds_max`) by importing from `costMonitor`.

Don't merge modules. Cost is about RunPod API state; metrics are about in-process counters. Different lifecycle, different failure modes.

## 8. Test plan

Manual-first, no new test deps:

1. Deploy to Railway with `OPS_API_KEY` set, no webhook.
2. Unauth: `curl /v1/ops/cost` → 401.
3. Auth: `curl -H "X-Ops-Key: $KEY" /v1/ops/cost` → JSON with `activePodCount` matching `myself.pods`.
4. History: wait 15 min, hit `/v1/ops/cost/history` → 3 entries.
5. Tick logging: `railway logs | grep kiki.cost.tick` → one per 5 min.
6. Webhook: set `COST_ALERT_WEBHOOK_URL=https://webhook.site/<uuid>`; lower `COST_ALERT_MAX_ACTIVE_PODS=0`; redeploy; confirm one alert with sane payload.
7. Cooldown: threshold at 0, wait two ticks → second does NOT re-fire.
8. Stuck-pod: create session, suppress `touch()`; watch for `max_pod_age` at 1h mark.
9. Daily rollup: set `COST_MONITOR_INTERVAL_MS=10000` + fake clock (or wait a day first time).
10. Monitor failure: invalidate `RUNPOD_API_KEY` briefly; confirm 3 consecutive warns then one `cost_monitor_unhealthy` webhook; restore.

No unit tests in v1 — thin module, most risk is RunPod API shape (integration only). Revisit if it grows.

## 9. Rollout

**New env vars (Railway):**

| Env | Required | Default | Notes |
|---|---|---|---|
| `OPS_API_KEY` | yes | — | `openssl rand -hex 32`; unset → ops disabled |
| `COST_ALERT_WEBHOOK_URL` | no | — | Slack-format; unset → log-only |
| `COST_ALERT_MAX_ACTIVE_PODS` | no | 50 | |
| `COST_ALERT_MAX_24H_SPEND` | no | 50 | USD |
| `COST_ALERT_MAX_POD_AGE_SECONDS` | no | 3600 | |
| `COST_ALERT_COOLDOWN_SECONDS` | no | 1800 | |
| `COST_MONITOR_INTERVAL_MS` | no | 300000 | |

Add validation to `config/index.ts`.

**Deploy order:**
1. PR 1: `runpodClient.ts` gains `listPodsWithCost`. No behavior change. Review GraphQL shape.
2. PR 2: `costMonitor.ts` + `ops.ts` + `index.ts` wiring + config extensions. Ship webhook unset (log-only).
3. After 24h clean ticks in Railway logs, set `COST_ALERT_WEBHOOK_URL` → alerts live.
4. Lower thresholds temporarily to provoke real alert; confirm delivery; restore.

No client changes. No migration. No downtime.

## 10. Open questions

### DECIDED
- **Alert destination:** Discord webhook (Slack-compatible format, same payload shape).
- **Monthly cap circuit breaker:** YES — $5k/mo hard cap trips a provision gate (product decision). Implemented in §5 above.

### Still open
1. **Starting 24h threshold.** $200/24h is a guess informed by the $5k/mo cap (~$167/day steady). First real alert we recalibrate.
2. **Ops auth scheme post-WS1.** Shared secret fine for two people. Once WS1 lands, gate on admin-user list, or keep ops key for machines (cron/monitors)? Lean: both. `OPS_API_KEY` stays for machines; admin userIds unlock same endpoints for humans.
3. **Per-pod vs account-total.** Are there non-`kiki-session-*` pods we should count? Today: no. Add startup warning if `myself.pods` has non-matching pods.

## 11. Dependencies

- **WS1 (auth).** Replaces `OPS_API_KEY` shared secret with admin-userId gating. Deferred; ships standalone.
- **WS2 (on-demand fallback).** Adds `-sp`/`-od` suffix to pod names for split reporting. Graceful degradation: before WS2, everything `'unknown'`.
- **WS6 (observability).** Shares `/v1/ops/*` route module + auth preHandler. `/v1/ops/metrics` can pull cost metrics from this module's `getSnapshot()`. No blocking coupling.
- **RunPod GraphQL API stability.** `myself.pods { costPerHr runtime.uptimeInSeconds }` is relied on. Add startup smoke-call that fails loudly if shape changes.

## Critical files

- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/costMonitor.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/routes/ops.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/runpodClient.ts` (add `listPodsWithCost`)
- `/Users/donald/Desktop/kiki_root/backend/src/index.ts` (wire start + route)
- `/Users/donald/Desktop/kiki_root/backend/src/config/index.ts` (new env vars)

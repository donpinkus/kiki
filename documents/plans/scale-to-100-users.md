# Scale to 100 concurrent users

Roadmap for going from today's "per-session orchestration, safe for ~20–50 users" state to **100 concurrent active users** with good UX, cost control, and operational visibility.

This doc captures the bottlenecks and the work to clear them. Each workstream is sized for a single focused PR (or small stack of PRs). Sequenced by impact — do them in order unless something upstream deprioritizes it.

## Baseline (current state)

As of WS7 completion (2026-04-18) — **all 7 workstreams shipped:**

- Railway backend orchestrator provisions a dedicated RTX 5090 pod per user and terminates it after 30 min of inactivity. See `documents/references/provider-config.md` for ops.
- **Authentication (WS1 done):** Apple Sign In → JWT. Session registry keyed by `userId`. Per-user rate limiter (1 active pod, 5/hr, 30/day).
- **On-demand fallback (WS2 done):** Spot first; if capacity exhausted, falls back to on-demand ($0.99/hr) in the same DC.
- **Fast cold start (WS3 done):** Slim GHCR image (~2-3 GB) + pre-populated network volumes in 5 DCs. ~110–150s cold start (down from 3-5 min). DC-aware placement probes spot stock across all volume-DCs.
- In-memory session registry (`Map<userId, Session>`) on a single Railway instance.
- Semaphore caps concurrent cold-start provisions at 5 (env-tunable).
- Observability = Railway logs. No metrics, no dashboards, no cost tracking beyond the RunPod billing page.

## Bottlenecks at 100 concurrent users

Ranked by impact, worst first:

| # | Bottleneck | Why it breaks at 100 users |
|---|---|---|
| 1 | **Cost blowout from unauthenticated sessions** | Anyone with a UUID can burn a $0.55/hr GPU. Leaked/guessed session IDs at beta scale = uncapped spend. Also a pre-TestFlight compliance blocker (age gate + AI-disclosure consent assume a user identity). |
| 2 | **Spot capacity exhaustion** | RunPod secure-cloud 5090 stock shows "High" right now but fluctuates. At 50+ concurrent provisions we'll see intermittent "Low"/"None" and user-visible failures. |
| 3 | **Cold-start UX** | 3–5 min from "tap draw" to first image. Tolerable at 5 testers; the app feels broken at 100 where churn is higher. |
| 4 | **No cost observability** | We'll learn about runaway spend via credit card statement. No in-app dashboard, no alerts. |
| 5 | **In-memory session registry** | Single Railway instance. Any deploy or crash drops all active sessions. Orphan reconcile prevents leaks but the UX hit is bad. |
| 6 | **No structured observability on provisioning** | Log lines exist; metrics do not. Debugging at 100 users will be guesswork without time-to-ready distributions, success rates, failure taxonomy, active-session counts. |
| 7 | **Spot preemption = 3–5 min reconnect wait** | Client's reconnect logic triggers a fresh provision on preemption. At 100 users the rate of preemptions rises; each one is a bad user experience. |

## Workstreams (recommended order)

### 1. Authentication

**Why:** Blocker for cost control (session IDs are currently free GPU vouchers) and for App Store TestFlight (age gate + AI-disclosure consent keyed on a user identity per `CLAUDE.md`).

**Approach:**
- Apple Sign In (iOS-native, zero friction) as the default. Fall back to anonymous device attestation (Apple's `DeviceCheck`/`AppAttest`) if Apple ID isn't available.
- Issue short-lived JWTs from the backend (sign with HS256, secret in Railway env).
- Client sends `Authorization: Bearer <jwt>` on the WebSocket handshake. Backend validates on every connect and extracts a stable `userId`.
- Session registry keys by `userId`, not `sessionId`. Same user across devices → same pod (debatable — see Open Questions below). Simplest v1: one-pod-per-userId.
- Per-user rate limit: no more than 1 active pod per user; X provisions per hour to prevent abuse.

**Effort:** Medium (~1–2 days for v1). iOS: Sign-in-with-Apple flow + JWT storage in Keychain. Backend: JWT middleware, userId extraction, registry key change.

**Success criteria:**
- Unauthenticated clients get `401` and never provision a pod.
- Same user on two devices shares one pod (or gets rejected — decide before shipping).
- Per-user provision rate limiter surfaces a clean error to the client.

### 2. On-demand fallback for spot capacity

**Why:** At 100 users with variable RunPod stock, `stockStatus: None` responses will be routine. Currently we fail-fast; users see "provisioning failed" and quit.

**Approach:**
- Wrap `createSpotPod` call with a fallback: on capacity error or `stockStatus: None/Low`, call `podFindAndDeployOnDemand` instead.
- On-demand costs ~$0.69/hr (community) / $0.99/hr (secure), vs $0.53/hr spot. Still much cheaper than H100.
- Per-user policy: default allow on-demand; if we add paid tiers later, free users might be spot-only.
- Surface to the user via a status message: `"Spot unavailable — using on-demand (+$0.50/hr)"` so we're honest.

**Effort:** Small (~half day). One new mutation wrapper + a couple of log lines + the status message.

**Success criteria:**
- When spot returns "None", a pod still provisions within 5 min.
- On-demand usage is distinguishable from spot in logs (`podType: "spot" | "onDemand"`).

### 3. Fast cold start (network volumes) — DONE

**Shipped:** Slim GHCR image (~2-3 GB, deps only) + pre-populated RunPod network volumes (5 DCs, 50 GB each) holding FLUX.2-klein BF16 + NVFP4 weights. Orchestrator's `selectPlacement()` probes all volume-DCs in parallel, pins pod to best-stocked DC with volume attached at `/workspace`. Originally planned as baked-weights image (28 GB) but pivoted to network volumes after the large image exceeded RunPod's 10-min pull timeout.

**Result:** ~110-150s cold start (down from 3-5 min). Faster on hosts with cached images.

### 4. Cost monitoring + alerting — DONE

**Shipped:** `costMonitor.ts` with 5-min periodic tick, `/v1/ops/cost` + `/v1/ops/cost/history` endpoints (X-Ops-Key auth), Discord webhook alerts (threshold breaches + $5k/mo hard cap circuit breaker), hourly cost digest, and per-pod lifecycle threads in a Discord Forum channel showing stage-by-stage progress (image pull → container up → model loading → ready → terminated).

### 5. Redis-backed session registry — DONE

**Shipped:** Session registry moved from in-memory `Map` to Redis hashes (`session:<userId>`). Deploys no longer drop active sessions — new process adopts pods from Redis instead of killing everything. Reaper uses `SCAN` + atomic `MULTI`. `touch()` is fire-and-forget HSET + EXPIRE (~2/sec per active user). TTL = idle timeout + 5 min grace. Uses `ioredis` with auto-reconnection. Also unblocks horizontal scaling (multiple replicas sharing one Redis).

### 6. Observability — DONE (consolidated to Sentry)

**Shipped:** Sentry Performance is the single analytics system across backend and iOS. No separate metrics module — the earlier in-process `metrics.ts` and `/v1/ops/metrics` endpoint were removed once Sentry's span/tag model covered the same questions with better UX (dashboards, tag-grouping, retention, alerting).

**Backend instrumentation** (`orchestrator.ts` + `stream.ts`):
- Parent transaction `pod.provision` wraps every `provision()` call. Child spans per phase: `pod.create`, `pod.container_pull`, `pod.setup` (ssh mode only), `pod.health_check`. Attributes (`dc`, `podType`, `attempt`, `outcome`, `mode`) attached to parent span for tag-based slicing.
- Span `pod.semaphore_wait` wraps queued provision attempts.
- `Sentry.captureException` on every provision failure, tagged with `category` (from `classifyProvisionError`), `phase`, `attempt`, `dc`.
- `Sentry.captureMessage` for lifecycle events that aren't errors but matter (image pull stalls, session preemptions, session replacement exhausted).
- `Sentry.addBreadcrumb` at each phase transition inside the transaction for context on any captured event.

**iOS instrumentation** (`AppCoordinator`, `StreamSession`, `StreamWebSocketClient`, `AuthService`):
- Parent transaction `app.stream.startup` wraps user-perceived spin-up (tap → first generated image).
- Transaction `auth.signIn` for Apple → backend JWT exchange.
- Standalone transactions `stream.connection` and `stream.reconnect` for WebSocket connect/retry attempts. Reconnect carries `attempt` and `backoffSec` as attributes.
- Breadcrumbs replaced every `print()` call in stream/ws layers. Categories: `stream.lifecycle`, `stream.connection`, `stream.config`, `stream.frame_sent`/`frame_received`, `stream.retry`, `stream.status`, `ws.*`, `error.*`.
- `SentrySDK.capture(error:)` on: frame send failure, receive-loop error, unexpected disconnect, server-sent error status, reconnect exhausted, auth token failure, sign-in POST failure, refresh rejection.

**Success criteria — met:**
- "What's the p95 time-to-ready over the last hour?" — Sentry Performance → `pod.provision` transaction → filter by time, read p95 from the chart.
- "Which failure reasons are dominating?" — Sentry Issues → group by `tags.category`.
- "Which DCs stall most?" — Sentry Issues → search `Image pull stalled` → group by `tags.dc`.
- "How long do iOS users wait from tap to first image?" — Sentry Performance → `app.stream.startup` transaction percentiles.

**Retained (not consolidated to Sentry):**
- `costMonitor.ts` + Discord webhooks — ops-team alerting channel, different concern from analytics.
- Pino structured logs → Railway — free grep-friendly log search, zero Sentry quota impact.

### 7. Graceful preemption handling — DONE

**Shipped:** On upstream WS close, `classifyClose()` probes RunPod API to distinguish preemption/crash/voluntary. On preemption: holds client WS open, sends `reprovisioning` status, provisions replacement pod through same placement + semaphore flow, swaps relay transparently, re-sends config. Gated behind `PREEMPTION_REPLACEMENT_ENABLED` env flag. Max 2 replacement attempts per session. Pods are terminated on provision failure to prevent cost leaks.

**Known limitation:** GHCR image pulls stall on some RunPod hosts (stuck at "still fetching image" indefinitely). Root cause is RunPod host-level — some hosts can't reach GHCR reliably. Successful pulls take ~3.5 min; stalled pulls time out at 10 min. Not fixable from our side.

## Also worth naming (not in the main 7)

- **iOS session ID / JWT in Keychain.** Today's UserDefaults storage is fine pre-auth; after Workstream 1 we should store the JWT in Keychain. ~1 hour of work.
- **Session release endpoint.** Client sends `{"type": "release"}` when navigating away from the drawing canvas → backend immediately terminates the pod. Cuts the 30-min idle tail for users who are explicitly done. ~1 hour.
- **Content safety (NSFW output + prompt input filters).** Already flagged as a pre-TestFlight blocker in `CLAUDE.md`. Adjacent to scale; should ship before any public beta regardless of user count.
- **Idle timeout tuning.** Currently 30 min (was 10 min — bumped after early testing showed users dropped pods mid-session). After more real traffic we'll learn the `p50/p95` of "time between sessions for the same user" and can tune further. Easy code-constant change.

## Out of scope for 100 users

These are real concerns at 1000+ users but overkill for 100:

- Horizontal backend scaling across multiple Railway instances (Workstream 5 unblocks this but we don't have to do it until we see CPU/memory pressure on a single instance).
- Multi-region deployment for latency.
- Per-region pod affinity (e.g. US users get US pods for lower RTT).
- A customer-support tool for session inspection / reset.

## Open questions (answered during cross-plan review)

### Product decisions (answered)

1. **Monthly cost cap during beta**: **$5,000/mo hard cap**, easily adjustable via env var. Cost monitor trips a provision gate when hit (WS4).
2. **Monetization model**: **1 free hour per user, then $5/mo subscription via Apple IAP**. Adds Workstream 8 (billing + entitlements).
3. **Same user on two devices**: **one pod, last-connect wins**. Device B takeover closes device A's socket with a polite banner.
4. **Is 100 concurrent a hard KPI or aspirational?**: **hard KPI with a deadline**. Sequence aggressively.
5. **Age gate**: **17+** (standard for generative AI apps).
6. **Auth scope**: **Apple Sign In only**, hard require. No anonymous fallback for v1.
7. **Docker registry**: **`ghcr.io/donpinkus`** (personal account).
8. **Cost alert destination**: **Discord webhook**.
9. **Redis rollout**: **no feature flag** — Redis default from first deploy (accepts deploy-day risk for simpler code).
10. **On-demand fallback message**: **silent** — user sees normal "Ready" path.
11. **On-demand cloud**: **secure only** for v1. Don't risk NVFP4 compat on community hosts.
12. **Preemption recovery**: **hold WS open** + "Replacing GPU…" banner during replacement.
13. **Max replacement attempts**: **2** before escalating to user.

### Per-workstream open questions remain

Each plan doc's "Still open" section lists narrower decisions (thresholds, copy, optional-flag defaults) that are either recommended-with-reasoning or surfaced for the respective implementation PR.

## Rough effort sizing

| Workstream | Effort | Unblocks |
|---|---|---|
| 1. Authentication | 1–2 days | Cost control, TestFlight, entitlement gate for WS8 |
| 2. On-demand fallback | 0.5 day | 50+ user stability |
| 3. Pre-baked Docker image | 1–2 days | Fast cold starts |
| 4. Cost monitoring | 0.5 day | Operational safety, $5k/mo hard cap circuit breaker |
| 5. Redis registry | 1 day | Deploy-safe sessions, horizontal scale, durable hour ledger |
| 6. Observability | 0.5 day | Debuggability at scale |
| 7. Graceful preemption | 1 day | Seamless mid-session recovery |
| 8. Paid tier + billing (Apple IAP) | 2–3 days | Monetization, free-hour enforcement |

**Total: ~8–11 focused engineering days** to get cleanly to 100 concurrent users with good UX, cost visibility, and subscription revenue.

# Scale to 100 concurrent users

Roadmap for going from today's "per-session orchestration, safe for ~20–50 users" state to **100 concurrent active users** with good UX, cost control, and operational visibility.

This doc captures the bottlenecks and the work to clear them. Each workstream is sized for a single focused PR (or small stack of PRs). Sequenced by impact — do them in order unless something upstream deprioritizes it.

## Baseline (current state)

As of commit `31cfc9f`:

- Railway backend orchestrator provisions a dedicated RTX 5090 spot pod per session and terminates it after 10 min of inactivity. See `documents/references/provider-config.md` for ops.
- In-memory session registry (`Map<sessionId, Session>`) on a single Railway instance.
- Semaphore caps concurrent cold-start provisions at 5 (env-tunable).
- Session identity: UUID generated on first app launch, stored in `UserDefaults`, sent as `?session=<uuid>` query param on the WebSocket. **Unauthenticated.**
- ~3–5 min cold start per fresh session: Docker pull from `runpod/pytorch` (authenticated via `RUNPOD_REGISTRY_AUTH_ID`, so no Docker Hub rate-limit anymore) → `setup-flux-klein.sh` (pip install + HuggingFace model download) → warmup.
- Spot-only; no on-demand fallback. Provisioning fails fast if `stockStatus` is `Low`/`None`.
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

### 3. Pre-baked Docker image with model

**Why:** Today's 3–5 min cold start is dominated by pip install (~30s) + model download (~2–3 min). Both can be baked into a custom image.

**Approach:**
- Write a proper `Dockerfile` in `flux-klein-server/` (the old one was deleted — obsolete — so start fresh):
  - Base `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404`.
  - `pip install diffusers@git transformers accelerate sentencepiece safetensors`.
  - `python -c "from diffusers import Flux2KleinPipeline; Flux2KleinPipeline.from_pretrained('black-forest-labs/FLUX.2-klein-4B')"` to bake the BF16 checkpoint (~13 GB) into a layer.
  - Similarly cache the NVFP4 safetensors via `huggingface_hub.hf_hub_download` at build time.
  - `COPY` the server code, set `ENTRYPOINT` to launch it.
- Push to GHCR (`ghcr.io/donpinkus/kiki-flux-klein:latest`) via a GH Action on push to `main` when `flux-klein-server/**` changes.
- Orchestrator swaps `imageName` to the GHCR image. Authenticated pulls via a GHCR credential (same pattern as Docker Hub).
- Skip setup-flux-klein.sh entirely for new pods — the server starts automatically on container boot.

**Target cold start:** 60–90s (Docker pull of ~20 GB image + warmup). Actual image size will dominate; aggressive squashing helps.

**Effort:** Medium (~1–2 days). Dockerfile iteration + GH Action for builds + orchestrator swap + test.

**Success criteria:**
- Fresh pod → `/health` returns `ok` in under 90s at p50.
- No pip install during provision; no HF model download during provision.

### 4. Cost monitoring + alerting

**Why:** Without visibility we'll catch cost spikes after the fact. At 100 users * $0.55/hr * bad day, we could be looking at 4-figure losses in hours.

**Approach:**
- Hourly cron-like job on the backend: list all `kiki-session-*` pods via `myself.pods`, sum `costPerHr` → current burn rate.
- Expose at `/v1/ops/cost` (auth-protected once Workstream 1 is done; for now, a secret env-based check).
- Log daily totals at midnight UTC.
- Webhook alert (Slack incoming webhook or sendgrid/email) when:
  - Active pod count > 50
  - 24h rolling spend > $X (configurable; $50 starting threshold)
  - Single session's pod age > 1 hour (stuck state indicator)

**Effort:** Small-to-medium (~half day). setInterval + fetch + webhook call.

**Success criteria:**
- `/v1/ops/cost` returns accurate current-burn JSON.
- Trigger a test alert by temporarily lowering the threshold; confirm message delivery.

### 5. Redis-backed session registry

**Why:** Single Railway instance + in-memory Map means any deploy or crash drops all active users. At 100 users, that's a very visible outage. Also unlocks horizontal backend scaling when we need it.

**Approach:**
- Provision Redis on Railway (one-click plugin, ~$5/mo).
- Replace `const registry = new Map<...>()` with a Redis hash. Keys: `session:<userId>`. Fields: podId, podUrl, status, createdAt, lastActivityAt.
- TTL on the Redis key = idle timeout + a grace period so the reaper has room to work.
- `touch()` → `HSET lastActivityAt` + reset TTL.
- Reaper scans with `SCAN` instead of iterating a local Map.
- On backend boot, reconcile orphan pods against the Redis registry (rather than blindly terminating all `kiki-session-*` pods — which would drop users mid-session during a deploy).

**Effort:** Medium (~1 day). Straightforward refactor; Redis client for Node.

**Success criteria:**
- Redeploy the backend while a session is active → user reconnects and resumes the same pod.
- Two backend instances run concurrently behind Railway's load balancer → sessions still work, no double-provision.

### 6. Observability

**Why:** At 100 users, "I looked at the logs" stops scaling. Structured metrics let us see trends (provision p50 time, success rate over 24h, failure reasons by category).

**Approach:**
- Add a lightweight in-process counter/histogram module (no deps; just `Map<string, number[]>`).
- Emit structured events on provision lifecycle: `provision.start`, `provision.ssh_ready`, `provision.health_ready`, `provision.failed(reason)`, `session.reaped`, `session.preempted`.
- Expose at `/v1/ops/metrics` (JSON for our own tooling, or Prometheus-text format if we want to pipe to Grafana Cloud Free later).
- Log same events as structured JSON lines for long-term retention via Railway's log drain.

**Effort:** Small (~half day for basics).

**Success criteria:**
- Can answer "what's the p95 time-to-ready over the last hour?" with a single curl.
- Can answer "which failure reasons are dominating?" without grep-fu.

### 7. Graceful preemption handling

**Why:** At 100 users the preemption rate rises. Currently each preemption is a 3–5 min reconnect wait for the user. If Workstream 3 (baked image) lands, this drops to ~90s — still bad.

**Approach:**
- When the upstream WebSocket closes with a code/pattern suggesting preemption (vs. user-initiated disconnect), don't immediately error the client.
- Start provisioning a replacement pod *before* telling the client to reconnect.
- If replacement is ready within X seconds, transparently reconnect the client to it (client sees a brief blip).
- Fall back to the current "error + reconnect" behavior if replacement takes too long.

**Effort:** Small-to-medium. Requires detecting preemption (may need to query pod state on close to see if it was terminated vs. just disconnected) and holding the client WebSocket open during the replace.

**Success criteria:**
- Simulated preemption mid-session: client continues streaming within 90s on a baked image.

## Also worth naming (not in the main 7)

- **iOS session ID / JWT in Keychain.** Today's UserDefaults storage is fine pre-auth; after Workstream 1 we should store the JWT in Keychain. ~1 hour of work.
- **Session release endpoint.** Client sends `{"type": "release"}` when navigating away from the drawing canvas → backend immediately terminates the pod. Cuts the 10-min idle tail for users who are explicitly done. ~1 hour.
- **Content safety (NSFW output + prompt input filters).** Already flagged as a pre-TestFlight blocker in `CLAUDE.md`. Adjacent to scale; should ship before any public beta regardless of user count.
- **Idle timeout tuning.** 10 min was a guess. After a few weeks of real traffic, we'll learn the `p50/p95` of "time between sessions for the same user" and can tune. Easy env-var change.

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

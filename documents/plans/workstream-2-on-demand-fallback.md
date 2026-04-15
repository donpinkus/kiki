# Workstream 2: On-demand fallback

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md).

## 1. Context

At 50+ concurrent active users, RunPod 5090 spot capacity in secure cloud is no longer reliable. The current orchestrator fails fast when `stockStatus` is `None` or `Low`, and users see a raw error and quit. This is the cheapest blocker to clear on the roadmap (~half day) and the one most likely to cause visible outages during a beta push — spot stock for a single GPU SKU on secure cloud fluctuates on a minutes-to-hours cadence, and we have no headroom to absorb that.

Goal: when spot is exhausted, transparently fall back to `podFindAndDeploy` at on-demand pricing, charge the cost delta silently, and surface an honest status message so we're not hiding the cost shift from beta testers. Pricing: spot ~$0.53/hr, on-demand community ~$0.69/hr, on-demand secure ~$0.99/hr.

## 2. Current state — where spot-only behavior lives

All in `backend/src/modules/orchestrator/`:

- **`orchestrator.ts:258–306`** — `provision()`. Three spot-only failure points:
  - `:262–264`: hard throw on `stockStatus === 'None' | 'Low'`
  - `:272–278`: `createSpotPod(...)` call has no fallback on null
  - `:261`: `getSpotBid(GPU_TYPE_ID)` throws if `minimumBidPrice` is null
- **`runpodClient.ts:87–123`** — `createSpotPod`. `podRentInterruptable` mutation, hard-coded `cloudType: SECURE`. Throws generic message on null response.
- **`orchestrator.ts:52-53`** — `GPU_TYPE_ID` and `IMAGE_NAME` module constants, reused across any pod-creation path.

No retry logic exists. A single spot miss = full provision failure and `registry.delete(sessionId)` at `:153`.

## 3. Detailed design

### 3.1 New function: `createOnDemandPod` in `runpodClient.ts`

Add after `createSpotPod`. Drop `bidPerGpu`, add `cloudType` discriminator:

```ts
export interface CreateOnDemandPodInput {
  name: string;
  imageName: string;
  gpuTypeId: string;
  cloudType: 'SECURE' | 'COMMUNITY';   // default SECURE for Blackwell availability
  ports?: string;
  containerDiskInGb?: number;
  minMemoryInGb?: number;
  minVcpuCount?: number;
  containerRegistryAuthId?: string;
}

export async function createOnDemandPod(input: CreateOnDemandPodInput): Promise<PodCreateResult>
```

GraphQL mutation — `podFindAndDeploy`:

```graphql
mutation {
  podFindAndDeploy(input: {
    name: "...",
    imageName: "...",
    gpuTypeId: "NVIDIA GeForce RTX 5090",
    gpuCount: 1,
    cloudType: SECURE,
    volumeInGb: 0,
    containerDiskInGb: 40,
    minMemoryInGb: 16,
    minVcpuCount: 4,
    ports: "8766/http,22/tcp",
    startSsh: true,
    containerRegistryAuthId: "..."
  }) { id desiredStatus costPerHr }
}
```

Returns same `PodCreateResult { id, costPerHr }`. On null → distinct error message so logs distinguish exhaustion mode.

### 3.2 Fallback logic in `provision()`

Refactor `orchestrator.ts:258–306` as a small state machine:

```
attemptSpot() → on success, record podType='spot', continue
             → on StockLow/None | podRentInterruptable=null | capacity error → fall through
attemptOnDemand() → if fails too, throw combined error
```

Concretely:

1. **Check policy first.** `policy.allowsOnDemand(sessionId)` — if false, keep fail-fast on spot exhaustion.
2. **Try spot** with up to **2 attempts** for transient errors (network, 500). Backoff: 2s, then 5s. Do **not** retry on explicit capacity signals — fall through immediately.
3. **Fall through to on-demand** when:
   - `getSpotBid` throws because `minimumBidPrice` is null, OR
   - `bidInfo.stockStatus === 'None' | 'Low'`, OR
   - `createSpotPod` returns null, OR
   - `createSpotPod` throws and error matches capacity patterns.
4. **Try on-demand** with up to **2 attempts**, 5s backoff. Prefer secure cloud (see 3.4), surface `"Spot unavailable — switching to on-demand"` via `onStatus` the instant we decide to switch.
5. **Record `podType`** on the `Session` object (add `podType: 'spot' | 'onDemand'` field on `Session` at `:35–43`) so logs, reaper, cost accounting can distinguish.

No exponential backoff beyond 2s/5s linear retries. If both spot and on-demand fail, we're in a degenerate state and user retries manually.

### 3.3 Detecting "capacity unavailable"

RunPod's GraphQL errors are unstructured — collapsed to a single `Error.message` string in our `gql()` helper at `runpodClient.ts:16–33`. Pattern-match substrings:

- `"There are no longer any instances available with enough disk space"`
- `"no longer any instances available with the requested specifications"`
- `"no instances available"`
- `"RunPod returned no pod"` (our own throw)
- Any message containing `"stock"` case-insensitive
- `minimumBidPrice == null` from `getSpotBid`

Add exported helper:

```ts
export function isCapacityError(err: unknown): boolean
```

Unmatched errors re-throw untouched — don't mask auth/SSH failures as "capacity" and silently switch.

### 3.4 Community vs secure for on-demand — DECIDED: secure only for v1

**Secure cloud only.** Reasons:

- Blackwell 5090 NVFP4 requires CUDA 12.8+ and current drivers; secure cloud has the broadest newest driver fleet. Community nodes are a long tail — some still on older CUDA where NVFP4 falls back to slow paths or fails.
- Secure networking more predictable for the ~13 GB HF model download during cold start.
- Cost delta: community $0.69/hr vs secure $0.99/hr. At projected on-demand usage (~20% of hours), $0.06/hr average overhead per user. Noise vs cost of a user quitting over a boot failure.

**Optional second attempt on community** if secure on-demand fails. Order configurable via `RUNPOD_ONDEMAND_CLOUD_ORDER=secure,community` (default) or `community,secure`. Don't bother unless secure proves unreliable — YAGNI.

### 3.5 Per-user policy hook

v1 interface takes `sessionId` (ignored); post-WS1 takes `userId`:

```ts
// backend/src/modules/orchestrator/policy.ts (new)
export interface ProvisionPolicy {
  allowsOnDemand(sessionId: string): Promise<boolean>;
}

export const allowAllPolicy: ProvisionPolicy = {
  allowsOnDemand: async () => true,
};
```

Orchestrator imports a module-level `policy: ProvisionPolicy` defaulting to `allowAllPolicy`. Expose `setPolicy()` setter so WS1 can swap in a JWT-backed policy.

Default: **allow** for v1. Rationale: during beta we'd rather spend $0.30/hr extra than lose a user to provisioning failure. Policy hook gives us the knob to tighten later.

### 3.6 Status message copy — DECIDED: silent fallback

No user-facing message during on-demand fallback. Client sees the normal `"Ready"` path. Fall-through is an operational concern, not a user concern — the user pays a flat $5/mo regardless of our provider cost.

Backend **still logs structured event** `provision.fallback.triggered` with reason so we can see the rate in Workstream 4's cost monitoring. Silent to the user, loud in our logs.

## 4. Metrics to emit

Structured log events (parseable now; graduates to WS6 metrics):

- `provision.spot.attempt` / `success` / `capacityMiss` — `sessionId, minBid, stockStatus`
- `provision.onDemand.attempt` / `success` / `failed` — `sessionId, cloudType, costPerHr`
- `provision.fallback.triggered` — `sessionId, reason: stockNone | stockLow | mutationNull | capacityError:<msg>`
- Record `session.podType` on every `Pod ready` log (mutate existing log at `:303`)

Counters we care about during beta:

| Metric | Why |
|---|---|
| `provision.spot.success` / total | Spot success rate — below 80% means heavy on-demand spend |
| `provision.onDemand.success` count | WS4's cost job breaks down spend (spot $/hr × spot-hours + onDemand $/hr × onDemand-hours) |
| `provision.fallback.triggered{reason}` | Which failure dominates — tune `BID_HEADROOM` or escalate GPU type |
| `provision.onDemand.failed` count | Non-zero means losing users outright — alert |

All emitted as `log.info({...}, 'provision.<event>')`. WS6 aggregates. No new deps.

## 5. Test plan

Simulating spot exhaustion in dev is hard. Three approaches, cheapest first:

1. **Unit-test the fallback state machine.** Extract decision logic into a pure-ish function taking a `RunpodClient` interface. Mock client to return null / throw capacity errors. Verify: null `createSpotPod` triggers `createOnDemandPod`; unknown errors don't trigger fallback; `podType` set correctly; both exhausted throws combined error.
2. **Integration test with a dry GPU.** Call `createSpotPod` against RunPod with `gpuTypeId: "NVIDIA H200"` (no secure spot inventory) — reliably returns capacity errors. Budget: ~$1 for one on-demand pod that succeeds.
3. **Live test under natural load.** Ship behind env flag, flip on, watch for first `provision.fallback.triggered` log. If on-demand path works end-to-end, good. If it fails subtle (different SSH init on on-demand? unlikely but possible), flip flag off and debug.

**Additionally: manually invoke `podFindAndDeploy` against RunPod via curl before writing code** to confirm the mutation shape and that it accepts the same `startSsh` + `containerRegistryAuthId` as `podRentInterruptable`.

## 6. Rollout

**Ship behind `ONDEMAND_FALLBACK_ENABLED` env flag (default `false` for first deploy, `true` within 24h).**

Reasoning:
- New mutation in live RunPod account. First prod run should be flag-gated so we can flip off without redeploy.
- Default-false on merge prevents accidental re-enable via unrelated redeploys before verification.

Day-0: Deploy with flag off. Confirm spot-only path unchanged via normal user session.
Day-0 +1h: Flip `ONDEMAND_FALLBACK_ENABLED=true` via `railway variables`. Wait for natural exhaustion or force one via bogus `GPU_TYPE_ID` override for one test session.
Day-7: Metrics clean → remove flag and dead branch. Keep `policy.allowsOnDemand()` hook permanently.

## 7. Open questions

### DECIDED
- **Cost message:** silent fallback, no user-facing message.
- **Community on-demand:** secure-only for v1.

### Still open
1. **Should `BID_HEADROOM` (orchestrator.ts:54) be bumped before shipping?** Currently 0.02. At 100 users, 2-cent headroom gets outbid often and triggers fallback unnecessarily. Bumping to 0.05–0.07 costs ~$0.03/hr × spot-hours, probably less than the on-demand delta we'd otherwise pay. **Recommend: bump to 0.05 in same PR.**
2. **"Prefer on-demand" knob for paying users** (all beta users are on $5/mo). With user's subscription confirmed, there's little reason NOT to prefer on-demand for subscribers to avoid preemption entirely. Trade-off: preemption replacement is now fast (~90s) post-WS3, and on-demand adds ~$0.45/hr. **Lean: keep spot-first for everyone, let WS7 handle preemption transparently.**
3. **Does `5090 spot stock is 'Low'` still warrant fallthrough, or only `'None'`?** "Low" means spot works but may be preempted quickly. **Recommend: fall through on both.**

## 8. Dependencies

- **WS1 (Auth):** Policy interface has `userId?` extension point ready. Once auth lands, policy impl reads user's tier. Today's policy is `allowAllPolicy`. No blocker either direction.
- **WS4 (Cost monitoring):** `session.podType` field is exactly what WS4 needs for burn breakdown. `/v1/ops/cost` should sum `costPerHr` grouped by `podType`. Logs (`provision.spot.success`, `provision.onDemand.success`) feed cost accounting directly. **Don't merge without updating WS4 plan to note `session.podType` is authoritative.**
- **WS6 (Observability):** Structured log events in §4 are the starter set for metrics module. No plan changes; events from here should be first-class in the histogram/counter module.
- **WS7 (Preemption):** When WS7 pre-provisions a replacement on preemption, it should honor the same policy + fallback. Extract the "create pod with spot→on-demand fallback" into a reusable helper (`createPodWithFallback`) so WS7 can reuse it.

## Critical files

- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/runpodClient.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/orchestrator.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/policy.ts` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/config/index.ts` (add `ONDEMAND_FALLBACK_ENABLED`, optional `RUNPOD_ONDEMAND_CLOUD_ORDER`)
- `/Users/donald/Desktop/kiki_root/documents/references/provider-config.md` (document new env vars + fallback behavior)

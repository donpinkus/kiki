# Provider Configuration

## Current Stack

**Each user session gets its own RTX 5090 pod.** The Railway backend (`backend/`) provisions pods on demand when an authenticated client WebSocket opens, and terminates them after 30 minutes of inactivity. FLUX.2-klein-4B runs on the pod with BFL's NVFP4 transformer checkpoint loaded on top of the BF16 pipeline. Custom FastAPI + WebSocket server at `flux-klein-server/`.

- ~1 FPS generation at 768×768 (reference mode, 4 steps, NVFP4)
- ~110–150s cold start per session (image pull + model load + warmup). Faster when the host has the image cached.
- ~$0.53–0.58/hr spot bid in secure-cloud datacenters; $0.99/hr on-demand fallback
- 30-min idle timeout preserves the pod across brief disconnects (reconnect = instant, no cold start)

Server image: `ghcr.io/donpinkus/kiki-flux-klein:<tag>` — a slim (~2–3 GB) image with Python deps only. Model weights live on pre-populated RunPod network volumes mounted at `/workspace`. Built via `.github/workflows/build-flux-image.yml`.

## How pod provisioning works

1. iPad sends Apple Sign In identity token → backend issues JWT. Client opens WebSocket to `wss://kiki-backend.../v1/stream` with `Authorization: Bearer <jwt>`.
2. Backend's `orchestrator.ts` checks its in-memory session registry keyed by `userId`:
   - **Existing ready pod** → relay immediately.
   - **In-flight provision** → await the existing promise, forward status messages.
   - **No record** → acquire semaphore slot (cap 5 concurrent), run placement + provision flow.
3. Placement: `selectPlacement()` probes all configured volume-DCs in parallel for 5090 spot stock, picks the DC with the best stock level.
4. Pod creation: tries spot first in the selected DC with the network volume attached. If spot capacity is exhausted and `ONDEMAND_FALLBACK_ENABLED=true`, falls back to on-demand in the same DC.
5. Boot: polls RunPod API until `runtime` appears (image pull + container start), then polls the pod's `/health` endpoint until the FLUX server reports ready.
6. Every relayed frame calls `touch(sessionId)` to reset the 30-min idle timer.
7. A `setInterval` reaper scans the registry every 60s and terminates pods idle >30 min.
8. On backend restart: `reconcileOrphanPods()` lists all `kiki-session-*` pods and terminates them (prevents cost leaks from crashes).

### Status messages shown to user during provision

1. "Finding available GPU..." — probing DC stock
2. "Provisioning GPU..." — creating the pod
3. "Pulling container image..." — waiting for container runtime (image pull)
4. "Starting server..." — container up, transitioning to health poll
5. "Loading AI model & warming up..." — FLUX server loading weights + warmup inference
6. "Ready"

## Network volumes

Model weights (~25 GB: FLUX.2-klein-4B BF16 + NVFP4) are stored on pre-populated RunPod network volumes, one per datacenter. Pods mount them read-shared at `/workspace` so the server reads weights from `/workspace/huggingface` without downloading.

| DC | Volume ID | Size |
|---|---|---|
| EUR-NO-1 | 49n6i3twuw | 50 GB |
| EU-RO-1 | xbiu29htvu | 50 GB |
| EU-CZ-1 | hhmat30tzx | 50 GB |
| US-IL-1 | 59plfch67d | 50 GB |
| US-NC-1 | 5vz7ubospw | 50 GB |

Fixed storage cost: 250 GB × $0.07/GB/mo = ~$17.50/mo.

### Populating a new volume

Use the one-shot script (from `backend/`):

```bash
RUNPOD_API_KEY=... \
RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
RUNPOD_REGISTRY_AUTH_ID=cmnzebqxw007pl407z8oij1x8 \
  npx tsx scripts/populate-volume.ts --dc <DC> --volume-id <id>
```

This spawns an on-demand pod in the target DC, mounts the volume, downloads weights via `huggingface_hub`, and terminates the pod (~10–15 min, ~$0.20).

## Required env vars (Railway)

Set via `railway variables --set` or the dashboard:

| Env | Source | Purpose |
|---|---|---|
| `RUNPOD_API_KEY` | RunPod Console → Settings → API Keys | GraphQL auth for pod lifecycle |
| `RUNPOD_SSH_PRIVATE_KEY` | Contents of `~/.runpod/ssh/RunPod-Key-Go` | SSH into pods (legacy ssh mode only) |
| `RUNPOD_REGISTRY_AUTH_ID` | ID from `myself.containerRegistryCreds` | Docker Hub auth credential ID |
| `RUNPOD_GHCR_AUTH_ID` | ID from `myself.containerRegistryCreds` | GHCR auth credential ID for pulling the slim image |
| `FLUX_PROVISION_MODE` | `baked` (production) or `ssh` (legacy) | Which provisioning path to use |
| `FLUX_IMAGE` | e.g. `ghcr.io/donpinkus/kiki-flux-klein:sha-...` | GHCR image ref for baked mode |
| `NETWORK_VOLUMES_BY_DC` | JSON: `{"EUR-NO-1":"49n6i3twuw",...}` | DC → volume ID map for weight mounts |
| `ONDEMAND_FALLBACK_ENABLED` | `true` | Allow on-demand when spot exhausted |
| `JWT_ACCESS_SECRET` | ≥32 byte hex | HS256 secret for access tokens |
| `JWT_REFRESH_SECRET` | ≥32 byte hex | HS256 secret for refresh tokens |
| `APPLE_BUNDLE_ID` | iOS bundle ID | Apple identity token audience |
| `AUTH_REQUIRED` | `true` | Reject unauthenticated connections |
| `MAX_CONCURRENT_PROVISIONS` | default 5 | Semaphore cap on concurrent cold starts |

## Operations

### Deploy the backend

```bash
cd backend && railway up
```

Railway builds via `backend/Dockerfile` (includes `openssh-client`). On startup the backend terminates orphan `kiki-session-*` pods and arms the idle reaper.

### Observe

```bash
railway logs    # tail orchestrator activity
```

Key log lines:
- `Orchestrator started idleTimeoutMs=600000 maxConcurrent=5` — boot complete, reaper armed.
- `Reconcile: no orphan pods found` — clean slate at boot.
- `DC placement ranked dcs=[...]` — spot stock probed per DC.
- `Pod created (spot) podId=... dc=... costPerHr=0.58` — provisioning started.
- `Container runtime up podId=... uptimeInSeconds=...` — image pulled, container running.
- `Pod ready podId=... podUrl=wss://... mode=baked` — fully provisioned.
- `Reaping idle pod sessionId=... podId=... idleMs=...` — 30-min timeout hit.

### Kill everything (cost panic button)

**Actions → Stop All RunPod Pods → Run workflow** on GitHub. Terminates every pod on the RunPod account. Use when costs spike unexpectedly or to guarantee a clean state before testing.

### Verify a pod health endpoint directly

```bash
curl https://<POD_ID>-8766.proxy.runpod.net/health
# Expect: status=ok, quantization=nvfp4, gpu="NVIDIA GeForce RTX 5090"
```

Pod IDs can be listed via:
```bash
curl -sS "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query { myself { pods { id name desiredStatus } } }"}' | jq .
```

### Cost

- Spot RTX 5090: ~$0.53/hr bid floor + $0.05 headroom (secure cloud, varies by availability).
- On-demand fallback: $0.99/hr (secure cloud).
- Worst-case idle tail per user: 30 min × $0.99/hr ≈ **$0.50** per session (on-demand only mode).
- Network volumes: ~$17.50/mo fixed (250 GB across 5 DCs).
- Railway backend: ~$5/month flat.

## Key Files

| File | Purpose |
|---|---|
| `backend/src/modules/orchestrator/orchestrator.ts` | Registry, provisioner (placement + pod creation + waitForRuntime + health), reaper, reconcile, semaphore |
| `backend/src/modules/orchestrator/runpodClient.ts` | RunPod GraphQL wrapper (spot, on-demand, volume mount) |
| `backend/src/modules/orchestrator/policy.ts` | Per-user on-demand policy hook |
| `backend/src/modules/auth/` | JWT signing/verification, Apple identity token verification, rate limiter |
| `backend/src/routes/stream.ts` | WebSocket endpoint: extract Bearer JWT, provision, relay |
| `backend/src/routes/auth.ts` | `/v1/auth/apple` and `/v1/auth/refresh` endpoints |
| `backend/scripts/populate-volume.ts` | One-shot network volume populate script |
| `backend/Dockerfile` | Railway image — Node 22 + openssh-client |
| `flux-klein-server/Dockerfile` | Slim GHCR image — PyTorch deps, no weights |
| `flux-klein-server/server.py` | WebSocket server entry point on the pod |
| `flux-klein-server/pipeline.py` | FLUX.2-klein pipeline wrapper (loads BF16 base + NVFP4 transformer) |
| `flux-klein-server/config.py` | Env-var-backed runtime config on the pod |
| `.github/workflows/build-flux-image.yml` | Builds + pushes slim GHCR image on `flux-klein-server/` changes |
| `.github/workflows/stop-pods.yml` | Manual "kill everything" button |

## Known limitations

- **~110–150s cold start** on fresh hosts. Dominated by GHCR image pull (~10 GB base image). Faster on hosts with cached layers.
- **GHCR image pulls stall on some RunPod hosts** — stuck at "still fetching image" indefinitely. Root cause is RunPod host-level (some hosts can't reach GHCR reliably). A watchdog in `waitForRuntime` fast-fails with `ImagePullStallError` after `CONTAINER_PULL_STALL_MS` (default 120s); `provision` then terminates the pod, blacklists the DC, and rerolls onto a different DC up to `CONTAINER_PULL_MAX_REROLLS` times (default 2). Each stall is captured to Sentry with `dc`, `podType`, `attempt`, `elapsedSec` tags for per-DC / per-timing analysis. The legacy 10-min hard timeout remains as a safety net for when the watchdog is disabled (`CONTAINER_PULL_WATCHDOG_ENABLED=false`).

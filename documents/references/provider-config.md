# Provider Configuration

## Current Stack

**Each user session gets its own RTX 5090 spot pod.** The Railway backend (`backend/`) provisions pods on demand when a client WebSocket opens, and terminates them after 10 minutes of inactivity. FLUX.2-klein-4B runs on the pod with BFL's NVFP4 transformer checkpoint loaded on top of the BF16 pipeline. Custom FastAPI + WebSocket server at `flux-klein-server/`.

- ~1 FPS generation at 768×768 (reference mode, 4 steps, NVFP4)
- ~3–5 min cold start per session (pod rent → Docker pull → model download → warmup)
- ~$0.53–0.55/hr spot bid in secure-cloud datacenters
- 10-min idle timeout preserves the pod across brief disconnects (reconnect = instant, no cold start)

Base image: `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (CUDA 12.8 + PyTorch 2.9.1, Blackwell-native with broad driver compatibility). Pulled authenticated via a RunPod registry credential — unauthenticated Docker Hub pulls hit the 100/6hr/IP rate limit shared across RunPod tenants.

## How pod provisioning works

1. iPad opens WebSocket to `wss://kiki-backend.../v1/stream?session=<uuid>`. Session UUID is generated on first app launch and stored in `UserDefaults`.
2. Backend's `orchestrator.ts` checks its in-memory session registry:
   - **Existing ready pod** → relay immediately.
   - **In-flight provision** → await the existing promise, forward status messages.
   - **No record** → acquire semaphore slot (cap 5 concurrent), call RunPod API to discover spot bid, `podRentInterruptable`, wait for SSH, SCP `runtime-assets/` to the pod, run `setup-flux-klein.sh`, poll `/health`, then relay.
3. Every relayed frame calls `touch(sessionId)` to reset the 10-min idle timer.
4. A `setInterval` reaper scans the registry every 60s and terminates pods idle >10 min.
5. On backend restart: `reconcileOrphanPods()` lists all `kiki-session-*` pods and terminates them (prevents cost leaks from crashes).

## Required env vars (Railway)

Set via `railway variables --set` or the dashboard:

| Env | Source | Purpose |
|---|---|---|
| `RUNPOD_API_KEY` | RunPod Console → Settings → API Keys | GraphQL auth for pod lifecycle |
| `RUNPOD_SSH_PRIVATE_KEY` | Contents of `~/.runpod/ssh/RunPod-Key-Go` | SSH into pods to run `setup-flux-klein.sh` |
| `RUNPOD_REGISTRY_AUTH_ID` | ID from `myself.containerRegistryCreds` | Docker Hub auth credential ID — avoids rate-limited anonymous pulls |
| `MAX_CONCURRENT_PROVISIONS` | default 5 | Semaphore cap on concurrent cold starts |

### Setting up Docker Hub auth (one-time)

1. Docker Hub → Account settings → Personal access tokens → generate with "Public Repo Read-only".
2. RunPod Console → Settings → Container Registry Auth → Add credential. Name: `docker-hub`. Username: your Docker Hub username. Password: the token (NOT your DH password).
3. Get the credential ID:
   ```bash
   curl -sS "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
     -H 'Content-Type: application/json' \
     -d '{"query":"query { myself { containerRegistryCreds { id name } } }"}' \
     | jq .
   ```
4. Set on Railway: `railway variables --set RUNPOD_REGISTRY_AUTH_ID=<id>`.

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
- `Spot bid discovered sessionId=... minBid=0.53 bid=0.55` — provisioning started.
- `Pod ready sessionId=... podUrl=wss://...` — fully provisioned.
- `Reaping idle pod sessionId=... podId=... idleMs=...` — 10-min timeout hit.

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

- Spot RTX 5090: ~$0.53/hr bid floor (secure cloud, varies by availability).
- Worst-case idle tail per user: 10 min × $0.55/hr ≈ **$0.09** per session.
- No network volumes — pods are ephemeral, models redownload on each fresh boot.
- Railway backend: ~$5/month flat.

## Key Files

| File | Purpose |
|---|---|
| `backend/src/modules/orchestrator/orchestrator.ts` | Registry, provisioner, reaper, reconcile, semaphore |
| `backend/src/modules/orchestrator/runpodClient.ts` | RunPod GraphQL wrapper |
| `backend/src/routes/stream.ts` | WebSocket endpoint: extract `session` query param, provision, relay |
| `backend/Dockerfile` | Railway image — Node 22 + openssh-client |
| `backend/runtime-assets/` | Committed copy of `flux-klein-server/` + `scripts/setup-flux-klein.sh` for SCP during provision |
| `scripts/setup-flux-klein.sh` | Pod-side setup (venv, deps, model download, server start). Regenerated into `runtime-assets/` via `npm run copy-assets`. |
| `flux-klein-server/server.py` | WebSocket server entry point on the pod |
| `flux-klein-server/pipeline.py` | FLUX.2-klein pipeline wrapper (loads BF16 base + NVFP4 transformer) |
| `flux-klein-server/config.py` | Env-var-backed runtime config on the pod |
| `.github/workflows/stop-pods.yml` | Manual "kill everything" button |

## Known limitations (v1)

- **Unauthenticated session IDs.** Anyone with a session UUID can use its pod. Beta-only — real auth is Phase 2.
- **In-memory registry** — lost on backend restart (orphans get reconciled). At horizontal scale we'll need Redis or similar.
- **~3–5 min cold start per session.** Model download + install is the bottleneck. Future optimization: pre-built Docker image with model baked in.
- **Spot preemption drops sessions.** Client's existing reconnect logic retries; backend will provision a new pod for the retry.

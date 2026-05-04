# Provider Configuration

## Current Stack

**Each user session can use up to two pods, both managed by the same Railway-hosted orchestrator (`backend/`):**

- **Image pod (always)** — RTX 5090, runs `flux-klein-server/server.py` (FLUX.2-klein-4B + NVFP4 transformer). The live img2img path. Name prefix `kiki-session-*`. ~1 FPS at 768×768 (reference mode, 4 steps).
- **Video pod (idle-state animation)** — H100 SXM 80GB, runs `flux-klein-server/video_server.py` (LTX-2.3 22B distilled FP8 + Gemma-3-12B). Provisioned when `frame_meta.queueEmpty` fires (user paused drawing). Name prefix `kiki-vsession-*`.

The orchestrator provisions on demand when a client WebSocket opens (and is JWT-authenticated), relays frames, and terminates pods after 30 min idle. Both pod kinds run a custom FastAPI + WebSocket server.

- ~96s avg image-pod cold start (p95 ~157s), dominated by `warming_model` (~62s FLUX weights to GPU + warmup). Video cold start is similar.
- ~$0.53–0.58/hr spot bid for image pod (secure cloud); ~$2.99/hr on-demand for video pod (no spot for H100 SXM).
- 30-min idle timeout preserves pods across brief disconnects (reconnect = instant, no cold start)

**Pod boot model (volume-entrypoint, since 2026-04-23):** Pods launch from stock `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (hardcoded as `BASE_IMAGE` in `orchestrator.ts`). The attached network volume holds both the FLUX weights (`/workspace/huggingface`) and the FastAPI server code + Python deps (`/workspace/app/`, `/workspace/venv/`). Boot command activates the venv and execs `python3 -u server.py`. No custom image, no registry pull, no GHCR auth. The pre-2026-04-23 GHCR custom-image flow is retained as inactive code in `flux-klein-server/Dockerfile` + `.github/workflows/build-flux-image.yml` for emergency rollback only — see `documents/decisions.md` 2026-04-23 entry for the rollback procedure.

## How pod provisioning works

1. iPad sends Apple Sign In identity token → backend issues JWT. Client opens WebSocket to `wss://kiki-backend.../v1/stream` with `Authorization: Bearer <jwt>`.
2. Backend's `orchestrator.ts` checks Redis for the session + its in-memory `inFlightProvisions` map, both keyed by `userId`:
   - **Existing ready pod** (`state='ready'` + `podUrl`) → relay immediately.
   - **In-flight provision** (any non-terminal state + promise in `inFlightProvisions`) → await the existing promise. The broker (`subscribe`) fans out current + future state events to all WS connections for the session, so joiners see the current phase immediately.
   - **No record** → acquire semaphore slot (cap 5 concurrent), run placement + provision flow.
3. Placement: `selectPlacement()` probes all configured volume-DCs in parallel for 5090 spot stock, picks the DC with the best stock level.
4. Pod creation: tries spot first in the selected DC with the network volume attached. If spot capacity is exhausted and `ONDEMAND_FALLBACK_ENABLED=true`, falls back to on-demand in the same DC.
5. Boot: polls RunPod API until `runtime` appears (image pull + container start), then polls the pod's `/health` endpoint until the FLUX server reports ready.
6. Every relayed frame calls `touch(sessionId)` to reset the 30-min idle timer.
7. A `setInterval` reaper scans the registry every 60s and terminates pods idle >30 min.
8. On backend restart: `reconcileOrphanPods()` lists all `kiki-session-*` pods and terminates them (prevents cost leaks from crashes).

### Provision state machine

Backend tracks the provision lifecycle in a single flat `State` enum (see `backend/src/modules/orchestrator/orchestrator.ts`). The wire format is structured — `{ type: 'state', state, stateEnteredAt, replacementCount, failureCategory? }` — and iOS maps state codes to display text locally (see `ios/Kiki/App/ProvisionState.swift`). Backend never emits display strings.

| State | Meaning |
|---|---|
| `queued` | Held by the process-wide concurrency semaphore (rare; only fires if ≥ `MAX_CONCURRENT_PROVISIONS` provisions in flight) |
| `finding_gpu` | `selectPlacement` iterating DCs for 5090 spot stock |
| `creating_pod` | `createSpotPod` / `createOnDemandPod` RPC in flight |
| `fetching_image` | Pod created; waiting for `pod.runtime` (RunPod pulls the stock `runpod/pytorch` base image — ~22s avg, often cached) |
| `warming_model` | Container up; polling `/health` while FLUX model loads into GPU |
| `connecting` | Pod `/health` ok; backend wiring the iOS↔pod frame relay |
| `ready` | Relay live; iOS can stream |
| `failed` | Unrecoverable error; `failureCategory` attached; WS closes after |
| `terminated` | Session ended (reaped idle / aborted / replaced out) |

`replacementCount` distinguishes fresh provisions (0) from preemption recoveries (1+). iOS prefixes display text with "Replacing — " when `replacementCount > 0`.

Every transition also fires a `pod.state.entered` PostHog event with `previous_state` + `previous_state_duration_ms` — per-stage duration analysis is a one-line HogQL query.

## Network volumes

Model weights are stored on pre-populated RunPod network volumes, one per (kind, datacenter) tuple. Pods mount them read-shared at `/workspace`. Two volume sets diverge by GPU SKU:

**Image volumes** (~20 GB: FLUX.2-klein-4B BF16 + NVFP4) live in DCs that stock RTX 5090. Set via `NETWORK_VOLUMES_BY_DC` JSON env var on Railway.

| DC | Volume ID | Size |
|---|---|---|
| EUR-NO-1 | 49n6i3twuw | 50 GB |
| EU-RO-1 | xbiu29htvu | 50 GB |
| EU-CZ-1 | hhmat30tzx | 50 GB |
| US-IL-1 | 59plfch67d | 50 GB |
| US-NC-1 | 5vz7ubospw | 50 GB |

**Video volumes** (~52 GB: LTX-2.3 22B distilled FP8 + Gemma-3-12B + spatial upscaler) live in DCs that stock H100 SXM 80 GB. Set via `NETWORK_VOLUMES_BY_DC_VIDEO` JSON env var on Railway. Created at 75 GB to leave headroom for venv + app code + future asset growth.

| DC | Volume ID | Size |
|---|---|---|
| US-CA-2 | 4iq4uchi49 | 75 GB |
| US-TX-3 | bhqphgrfen | 75 GB |
| EU-NL-1 | l83rmkz50d | 75 GB |
| EUR-IS-3 | m4ac7szq80 | 75 GB |
| US-MO-1 | qvm9zwa2b8 | 75 GB |
| US-NE-1 | 92a53hbwc1 | 75 GB |

Note: not every DC that stocks H100 SXM supports network volumes — RunPod refuses `createNetworkVolume` for CA-MTL-1, EU-FR-1, and EUR-NO-2 even though those DCs show H100-SXM stock. The 6 DCs above are the intersection of "has H100 SXM" + "supports network volumes" at probe time.

Fixed storage cost: image (250 GB) + video (450 GB) ≈ 700 GB × $0.07/GB/mo = ~$49/mo.

### HF_TOKEN for video volumes

Gemma-3-12B is gated by Google's Gemma terms. Before populating any video volume:

1. Log in to huggingface.co with the account that will run populate-volume.ts
2. Visit https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-unquantized and accept the license
3. Generate an HF token at https://huggingface.co/settings/tokens (any read scope is fine)
4. Add to `.env.local` at the repo root: `HF_TOKEN=hf_...` (gitignored)

The pod itself stays `HF_HUB_OFFLINE=1` at runtime — the token is only used at populate time to download Gemma into the volume cache.

### Populating a new volume

Use the one-shot script (from `backend/`). Pass `--kind image` or `--kind video` — they download different weights and use different GPU SKUs (5090 for image, H100 SXM for video, since the GPU must be in the volume's DC).

**Image volume** (FLUX.2-klein BF16 + NVFP4, ~20 GB):

```bash
RUNPOD_API_KEY=... \
RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
RUNPOD_REGISTRY_AUTH_ID=cmnzebqxw007pl407z8oij1x8 \
  npx tsx scripts/populate-volume.ts --kind image --dc <5090-DC> --volume-id <id>
```

**Video volume** (LTX-2.3 22B FP8 + Gemma-3-12B + spatial upscaler, ~52 GB) — requires `HF_TOKEN` (see above):

```bash
RUNPOD_API_KEY=... \
HF_TOKEN=hf_... \
RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
RUNPOD_REGISTRY_AUTH_ID=cmnzebqxw007pl407z8oij1x8 \
  npx tsx scripts/populate-volume.ts --kind video --dc <H100-DC> --volume-id <id>
```

Both spawn an on-demand pod in the target DC, mount the volume, download weights via `huggingface_hub`, and terminate the pod. Image: ~10–15 min, ~$0.20. Video: ~20–30 min, ~$1 (H100 is pricier and Gemma's 24 GB takes longer to download).

## Required env vars (Railway)

Set via `railway variable set "KEY=value"` (singular subcommand, runs in `backend/` after `railway link`) or the Railway dashboard:

| Env | Source | Purpose |
|---|---|---|
| `RUNPOD_API_KEY` | RunPod Console → Settings → API Keys | GraphQL auth for pod lifecycle |
| `NETWORK_VOLUMES_BY_DC` | JSON: `{"EUR-NO-1":"49n6i3twuw",...}` | Image-pod DC → volume ID map (5090 DCs) |
| `NETWORK_VOLUMES_BY_DC_VIDEO` | JSON: `{"US-CA-2":"4iq4uchi49",...}` | Video-pod DC → volume ID map (H100 SXM DCs) |
| `ONDEMAND_FALLBACK_ENABLED` | `true` | Allow on-demand when spot exhausted |
| `VIDEO_POD_ENABLED` | `true` | Provision video pod alongside image pod when iPad requests it. Off = image-only. |
| `JWT_ACCESS_SECRET` | ≥32 byte hex (`openssl rand -hex 32`) | HS256 secret for access tokens. Required, must differ from refresh. |
| `JWT_REFRESH_SECRET` | ≥32 byte hex (`openssl rand -hex 32`) | HS256 secret for refresh tokens. Required, must differ from access. |
| `APPLE_BUNDLE_ID` | iOS bundle ID | Apple identity token audience. Required. |
| `AUTH_REQUIRED` | `true` | Reject unauthenticated connections. Production must always be `true`. |
| `REDIS_URL` | `redis://...` | Session registry backing store. Required in production; falls back to in-memory if unset (for local dev). |
| `MAX_CONCURRENT_PROVISIONS` | default 5 | Semaphore cap on concurrent cold starts |

`FLUX_IMAGE` and `RUNPOD_GHCR_AUTH_ID` are no longer used by the live provision path. They remain set on Railway for now so the rollback procedure in the 2026-04-23 decision entry is a single env-var flip.

## Operations

For the canonical pod operations decision tree (deploy / iterate / SSH / experiment / terminate / observe pod state), see **`documents/references/pod-operations.md`**. That doc has self-contained step-by-step instructions for every routine task. The remaining sections below describe orchestration architecture details (observability, kill-everything, /health curl, costs) that complement the operational doc.

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
- `Pod ready podId=... podUrl=wss://...` — fully provisioned.
- `Reaping idle pod sessionId=... podId=... idleMs=...` — 30-min timeout hit.

### Kill everything (cost panic button)

`gh workflow run stop-pods.yml` (or **Actions → Stop All RunPod Pods → Run workflow** on GitHub). Terminates every pod on the RunPod account — image, video, AND test pods. Use when costs spike unexpectedly or to guarantee a clean state before testing. (Also covered as Task 7c in `documents/references/pod-operations.md`.)

### Verify a pod health endpoint directly

Image pod:
```bash
curl https://<POD_ID>-8766.proxy.runpod.net/health
# Expect: status=ok, ready=true, quantization=nvfp4, gpu="NVIDIA GeForce RTX 5090"
```

Video pod (different schema — has `video_ready` and `persistent_*_ready` fields, no `quantization`):
```bash
curl https://<POD_ID>-8766.proxy.runpod.net/health
# Expect: status=ok, video_ready=true, persistent_transformer_ready=true,
#         gpu="NVIDIA H100 80GB HBM3"
```

Either kind returns `{"status":"error","load_error":"<traceback>"}` if pipeline load failed — that's the canonical way to read a startup error without SSH.

Pod IDs can be listed via:
```bash
curl -sS "https://api.runpod.io/graphql?api_key=$RUNPOD_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"query":"query { myself { pods { id name desiredStatus } } }"}' | jq .
```

### Cost

- Spot RTX 5090 (image pod): ~$0.53/hr bid floor + $0.05 headroom (secure cloud, varies by availability).
- On-demand RTX 5090 fallback: $0.99/hr (secure cloud).
- On-demand H100 SXM 80GB (video pod): ~$2.99/hr (secure cloud, no spot SKU).
- Worst-case idle tail per user: 30 min × ($0.99 + $2.99)/hr ≈ **$2** per session (image + video on-demand).
- Network volumes: ~$49/mo fixed (250 GB image across 5 DCs + 450 GB video across 6 DCs × $0.07/GB/mo).
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
| `backend/scripts/populate-volume.ts` | One-shot network volume populate script (weights) |
| `backend/scripts/sync-flux-app.ts` | Per-DC sync of `flux-klein-server/*.py` + venv to network volume |
| `backend/Dockerfile` | Railway image — Node 22 slim |
| `flux-klein-server/server.py` | WebSocket server entry point on the pod |
| `flux-klein-server/pipeline.py` | FLUX.2-klein pipeline wrapper (loads BF16 base + NVFP4 transformer) |
| `flux-klein-server/config.py` | Env-var-backed runtime config on the pod |
| `flux-klein-server/Dockerfile` | **INACTIVE** — retained for GHCR rollback only |
| `.github/workflows/build-flux-image.yml` | **INACTIVE** — retained for GHCR rollback only |
| `.github/workflows/stop-pods.yml` | Manual "kill everything" button |

## Known limitations

- **~96s avg cold start** (p95 ~157s). Dominant phase is `warming_model` (~62s — FLUX weights to GPU + first-inference kernel compile). `fetching_image` is now a stock-image pull (~22s avg, often cached). See PostHog `pod.provision.completed` for live numbers.
- **Pod-boot stall safeguard.** A watchdog in `waitForRuntime` fast-fails with `PodBootStallError` after `POD_BOOT_STALL_MS` (default 45s) if the container fails to come up. `provision` then terminates the pod, blacklists the DC, and rerolls onto a different DC up to `POD_BOOT_MAX_REROLLS` times. Each stall is captured to Sentry with `dc`, `podType`, `attempt`, `elapsedSec` tags. (Pre-cutover this was tuned to 120s for GHCR pulls; the lower default suits stock-image boots, which complete in ~20–30s when not stalled.)

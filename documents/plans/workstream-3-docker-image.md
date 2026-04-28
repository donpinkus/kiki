# Workstream 3: Pre-baked Docker image with model weights

> **STATUS: SUPERSEDED (2026-04-23).** This document captures the original GHCR
> custom-image plan. It was shipped, then revised: ~38% of provisions stalled on
> hosts that couldn't reliably pull from ghcr.io. The cutover migrated to a
> volume-entrypoint architecture — pods boot from stock `runpod/pytorch` and
> read app code + Python deps off the network volume that already holds the
> weights. The GHCR image is no longer pulled by any provision path; the
> Dockerfile and build workflow remain in-tree as inactive code for emergency
> rollback only.
>
> Current state: see `documents/decisions.md` 2026-04-23 entry and
> `documents/references/provider-config.md` "Pod boot model" section.
>
> This file is retained as historical context for the original design.

Part of the [scale-to-100-users roadmap](./scale-to-100-users.md).

## 1. Context

Kiki provisions one dedicated RTX 5090 spot pod per iPad session. Time from WebSocket open to first generated frame today is **3–5 minutes** — a pre-TestFlight UX blocker and a cost amplifier (every user pays ~$0.03 of GPU rental just to wait). Target: **60–90s cold start** by baking the Python env + ~20 GB of FLUX.2-klein weights into a custom Docker image so the pod boots straight into a warm server.

Why priority at 100 users:
- Cold-start duration × arrival rate = the denominator on effective concurrency.
- Current SSH+SCP+bash-setup path is the operational fragility surface: sshd race conditions, pip index flakiness, HF 503s. Each removed step = 1-in-N provisioner failure eliminated.
- "Stop All Pods" kill switch means recovery via mass re-provision — amortized pull time matters more than per-session steady-state.

## 2. Current state

`scripts/setup-flux-klein.sh` runs over SSH after pod is up. Observed phases:

| Phase | What happens | Time |
|---|---|---|
| `podRentInterruptable` → container running | Docker pull `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (~8 GB) | 40–70s |
| sshd ready | RunPod proxy wiring + sshd warmup | 15–30s |
| `scpFiles` | ~5 small files | 2–4s |
| setup-flux-klein.sh pip install | diffusers@git + transformers + accelerate + fastapi + uvicorn + websockets + Pillow | **25–40s** |
| `pipeline.load()` HF download | FLUX.2-klein-4B BF16 (~13 GB) + NVFP4 safetensors (~7 GB) = **~20 GB** | **90–180s** |
| CPU→GPU move + NVFP4 load_state_dict | torch memory map + HBM copy | 15–25s |
| Warmup generation | First kernel compile + cache fill | 8–15s |

**Dominant costs:** HF download (90–180s) + pip install (25–40s). Both deterministic and bakeable. Platform time (60s pod pull + 20s sshd) is unavoidable; but we *add* pull time with our bigger image while *removing* sshd wait entirely.

`backend/runtime-assets/` is committed copy of `flux-klein-server/` + `setup-flux-klein.sh`, SCP'd at provision time. All goes away with baked image.

## 3. Detailed design

### 3.1 Base image

Keep `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404`. Reasons:

- Has torch 2.9.1 + CUDA 12.8.1 + cuDNN correctly linked for Blackwell (SM 10.0). Replacing with `nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04` means reinstalling torch (~3 GB wheel), extending build time and NVFP4-compat risk.
- RunPod caches base layers on spot hosts — subsequent pulls reuse them. Our custom layers pull cold each time but the base is usually warm.

### 3.2 Dockerfile layer ordering

```dockerfile
FROM runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404

# Layer 1: OS deps (cheap, rarely changes)
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

# Layer 2: pinned Python deps — flux-klein-server/requirements.txt is NEW
COPY flux-klein-server/requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# Layer 3: FLUX.2-klein BF16 weights (~13 GB). HUGE but rarely invalidates.
ENV HF_HOME=/opt/huggingface
ENV HF_HUB_DISABLE_TELEMETRY=1
ARG FLUX_MODEL_REV=main
RUN python -c "\
from huggingface_hub import snapshot_download; \
snapshot_download('black-forest-labs/FLUX.2-klein-4B', revision='${FLUX_MODEL_REV}', \
    allow_patterns=['*.json','*.safetensors','*.txt','tokenizer*/*','text_encoder*/*','transformer/*','vae/*','scheduler/*'])"

# Layer 4: NVFP4 safetensors (~7 GB).
ARG NVFP4_REV=main
RUN python -c "\
from huggingface_hub import hf_hub_download; \
hf_hub_download('black-forest-labs/FLUX.2-klein-4b-nvfp4', 'flux-2-klein-4b-nvfp4.safetensors', revision='${NVFP4_REV}')"

# Layer 5: server code (thin, changes frequently — keep at top for fast rebuilds)
WORKDIR /app
COPY flux-klein-server/*.py /app/

# Runtime
ENV FLUX_HOST=0.0.0.0
ENV FLUX_PORT=8766
ENV FLUX_USE_NVFP4=1
EXPOSE 8766

CMD ["python", "-u", "/app/server.py"]
```

Key rationale:
- OS → pip → **big weights** → server code. Editing `server.py` only triggers Layer 5's rebuild.
- One weight per `RUN` layer → revision bumps invalidate minimally.
- `snapshot_download` not `from_pretrained`: latter instantiates pipeline (RAM waste, CPU-less CUDA init paths).
- `allow_patterns` critical — FLUX.2-klein-4B repo has multiple transformer variants (fp8, bnb, original); without allowlist we pull all (~40 GB).

### 3.3 `requirements.txt`

New file `flux-klein-server/requirements.txt`:

```
# Torch inherited from base image (2.9.1 + cu128). Do NOT list it.
diffusers @ git+https://github.com/huggingface/diffusers.git@<PIN_COMMIT_SHA>
transformers>=4.40.0,<5
accelerate>=0.28.0,<2
sentencepiece>=0.2.0
safetensors>=0.4.0
fastapi>=0.108.0
uvicorn[standard]>=0.25.0
websockets>=12.0
Pillow>=10.0.0
huggingface-hub>=0.25.0
```

Pinning diffusers commit is load-bearing — NVFP4 `load_state_dict` is sensitive to internal transformer module names, which change across diffusers `main` pushes. Current `setup-flux-klein.sh` uses floating `main` — latent break. Bake a pin.

### 3.4 Image size + optimization

| Layer | Uncompressed | Compressed |
|---|---|---|
| Base | ~22 GB | ~8 GB |
| apt | +100 MB | +30 MB |
| pip | +2.5 GB | +700 MB |
| FLUX-klein BF16 | +13.5 GB | +13 GB |
| NVFP4 | +7 GB | +6.8 GB |
| Server code | +100 KB | +50 KB |
| **Total** | **~45 GB** | **~28.5 GB** |

**Pull time at pod start** (1 Gbit/s to datacenter):
- Floor: 28.5 GB × 8 / 1000 ≈ 228s if full bandwidth.
- Realistically: parallel layers, base cached on RunPod host. Delta ~20 GB new. Observed: **60–100s** for custom 20 GB images per RunPod community reports.
- Worst case (cold host, never-seen image): 3–4 min. Not better than today's 3–5 min. Must monitor.

**Optimization ranking:**
1. **Keep weights uncompressed** — safetensors is binary; gzip wastes CPU. Consider zstd (GHCR supports).
2. **Don't multi-stage** — weights are runtime artifacts; multi-stage gains nothing.
3. **Don't squash** — `--squash` kills per-file layer caching; per-layer parallel pull is better.
4. **Prune pip caches** — `--no-cache-dir` (in requirements step). ~400 MB saved.
5. **`allow_patterns` on snapshot_download** — biggest single saving (avoid pulling fp8/bnb variants we don't use).

### 3.5 Entrypoint + signal handling

`server.py` runs `uvicorn.run("server:app", ...)` at `__main__`. Uvicorn installs SIGTERM/SIGINT handlers that trigger FastAPI lifespan shutdown. **Good** — no change needed with exec-form `CMD`.

Verify: `docker kill --signal=SIGTERM <container>` → expect clean "Shutting down." log within 2s. Live WebSocket during SIGTERM = 10s graceful shutdown timeout, acceptable since RunPod sends SIGKILL after 30s regardless.

Gotcha: `asyncio.to_thread(_process_frame, ...)` holds a CPython thread uninterruptible. SIGTERM during in-flight 4-step generation (~1s) completes before shutdown proceeds. Acceptable.

### 3.6 Runtime env vars

Today exports `HF_HOME=/root/kiki-models/huggingface`. With baked weights:
- `HF_HOME=/opt/huggingface` baked into image. No longer needs writable volume.
- `HF_HUB_OFFLINE=1` defensively — prevent re-download check on DNS blip.
- `FLUX_USE_NVFP4=1`, `FLUX_HOST`, `FLUX_PORT`, `FLUX_STEPS`, `FLUX_WIDTH`, `FLUX_HEIGHT` — overridable per-pod via RunPod's `env` field.

### 3.7 Registry choice: GHCR

| Option | Pros | Cons |
|---|---|---|
| **GHCR** | Free for public, unlimited pulls. Native GH Actions integration. Supports zstd. | Some enterprise networks block ghcr.io; irrelevant here. |
| Docker Hub | Familiar, RunPod already wired. | 100 pulls/6hr/IP anonymous, 200/6hr authenticated. Burns fast at 100 users. Paid tier $15/user/mo. |
| RunPod native | No rate limits within RunPod's network. | Custom push workflow; less tooling; lock-in; undocumented quotas. |

**GHCR chosen.** Auth setup:

1. GHCR image: `ghcr.io/donpinkus/kiki-flux-klein`. Push via `GITHUB_TOKEN` in Actions (`permissions: packages: write`).
2. Pull from RunPod: classic PAT with `read:packages` scope. Add to RunPod Console → Container Registry Auth as new cred. Get ID via `myself.containerRegistryCreds` query. New Railway env var `RUNPOD_GHCR_AUTH_ID`.
3. Keep `RUNPOD_REGISTRY_AUTH_ID` (Docker Hub) for base-image transitive pulls if RunPod accepts two registry creds. Verify empirically — if only one works per pod, GHCR wins (that's where manifest lives); base layers are public and pull anonymously.

### 3.8 GitHub Action: build + push

New `.github/workflows/build-flux-image.yml`:

```yaml
name: Build FLUX.2-klein image
on:
  push:
    branches: [main]
    paths:
      - 'flux-klein-server/**'
      - '.github/workflows/build-flux-image.yml'
  workflow_dispatch:
    inputs:
      flux_model_rev:
        description: 'HF revision for FLUX.2-klein-4B'
        default: 'main'
      nvfp4_rev:
        description: 'HF revision for NVFP4 weights'
        default: 'main'

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Free disk (GH hosted ~50 GB)
        run: |
          sudo rm -rf /usr/share/dotnet /opt/ghc /opt/hostedtoolcache /usr/local/lib/android
          docker system prune -af
      - name: Build & push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: flux-klein-server/Dockerfile
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/kiki-flux-klein:latest
            ghcr.io/${{ github.repository_owner }}/kiki-flux-klein:sha-${{ github.sha }}
          build-args: |
            FLUX_MODEL_REV=${{ inputs.flux_model_rev || 'main' }}
            NVFP4_REV=${{ inputs.nvfp4_rev || 'main' }}
          cache-from: type=registry,ref=ghcr.io/${{ github.repository_owner }}/kiki-flux-klein:buildcache
          cache-to: type=registry,ref=ghcr.io/${{ github.repository_owner }}/kiki-flux-klein:buildcache,mode=max
```

**Tagging:**
- `:sha-<fullsha>` — immutable, every build. Orchestrator pins this.
- `:latest` — rolling, informational only. Orchestrator must NOT use in prod — mid-session builds shouldn't affect next pod until we intentionally roll.
- `:staging` — second mutable tag moved manually for test pods.

**Build time:** First ~40 min (download 20 GB HF + push 28 GB to GHCR). Cached rebuilds: 5–10 min. GH runner disk tight; if OOM, move to self-hosted or larger runner.

### 3.9 Orchestrator changes

`backend/src/modules/orchestrator/orchestrator.ts`:

1. Change `IMAGE_NAME` to read from `config.FLUX_IMAGE` (new env) so image rolls don't require code push.
2. Pass `config.RUNPOD_GHCR_AUTH_ID` as `containerRegistryAuthId` on `createSpotPod`.
3. Delete:
   - `scpFiles` call and function (~30 lines)
   - `runSetup` call and function (~15 lines)
   - `findRuntimeAssets()` + `RUNTIME_ASSETS_DIR` (~15 lines)
   - `ensureSshKey` + `SSH_KEY_PATH` (unless keeping SSH as debug escape — recommend delete)
   - `retryCommand`, `runCommand`, `spawn` imports
4. Replace `waitForSsh` with `waitForProxyHttp`: poll `https://<podId>-8766.proxy.runpod.net/health` directly (proxy goes live within ~15s regardless of sshd). Drops sshd wait from critical path.
5. `provision()` becomes: `getSpotBid` → `createSpotPod` → `waitForHealth`. Four steps from six.
6. After live validation, delete `scripts/setup-flux-klein.sh` + `backend/runtime-assets/` + `backend/package.json` `copy-assets`.

## 4. Migration strategy

Ship without downtime via feature flag `FLUX_PROVISION_MODE` (`ssh` | `baked`, default `ssh`):

1. Ship orchestrator with dual-mode. Both code paths live side-by-side ~1 week.
2. Railway env: `FLUX_PROVISION_MODE=baked` + `FLUX_IMAGE=ghcr.io/.../kiki-flux-klein:sha-<first-good>`. Deploy. New sessions use baked; in-flight sessions (tied to already-provisioned pods) unaffected.
3. Monitor 24h: provision success rate, p50/p95 time-to-ready, health failures.
4. Clean day: flip code default to `baked`. Delete SSH branch, setup script, runtime-assets, copy-assets, `RUNPOD_SSH_PRIVATE_KEY`.
5. Update `documents/references/provider-config.md`.

Rollback during overlap: flip `FLUX_PROVISION_MODE=ssh` (no deploy needed) → next session uses old path. Existing baked pods unaffected (self-contained).

## 5. Cold-start budget (target 60–90s)

Baked image, warm-ish RunPod host:

| Phase | Estimate | Notes |
|---|---|---|
| RunPod API: getSpotBid + podRentInterruptable | 2–5s | Network RTT |
| Scheduler: host assigned, container created | 5–15s | Platform time |
| Image pull (20 GB delta cached, 28 GB cold) | 30–60s / 90–180s | Big unknown |
| Container start → Python imports → `pipeline.load()` from baked `HF_HOME` | 15–20s | Fast disk I/O |
| `pipe.to("cuda")` + NVFP4 load to HBM | 8–15s | ~20 GB host→device |
| Warmup generation | 6–10s | First-call autotune |
| `/health` poll cadence overshoot | 0–5s | Poll every 5s (tighter than current 10s) |
| **p50 (cached)** | **~65–75s** | On target |
| **p95 (cold host)** | **~130–180s** | Still much better than today |

Future levers if needed: prewarm CUDA context via `TORCHINDUCTOR_CACHE_DIR` baked. Don't move warmup into `HEALTHCHECK` — the first real frame pays the cost, worse UX.

## 6. Risks

1. **Image pull time > current provision on cold hosts.** 28 GB pull on never-seen host could take 4+ min. Mitigation: pinned sha so hosts accumulate cached copies; monitor via WS6 metrics; consider host-affinity if RunPod supports. Worst case at 100 users: p95 worse than today but p50 much better — acceptable, must measure.

2. **GHCR rate limits / downtime.** GHCR has soft limits 5000 pulls/hr/user authenticated; no concern at 100 users. Outages block new provisions. Mitigation: cross-push to Docker Hub as secondary.

3. **Baked weights go stale.** FLUX.2-klein-4B unlikely to change often. NVFP4 could re-release. Mitigation: build-args pin revisions; monthly `workflow_dispatch` build to catch drift.

4. **Image size bloat from diffusers deps.** Pin diffusers; PR review for requirements.txt.

5. **RunPod manifest caching hiding bad builds.** Mitigation: never reuse tag; always deploy by new sha.

6. **Two registry auth IDs on one pod.** RunPod's `containerRegistryAuthId` appears single. If daemon needs both GHCR (our image) and Docker Hub (base), one must be public. Verify in test; fall back to squash-like flatten of base if wrong (ugly; avoid).

7. **NVFP4 load_state_dict drift with diffusers main.** Pinning solves. If BFL ships new NVFP4 needing newer diffusers, bump in lockstep.

8. **PID 1 / zombie reaping.** Uvicorn doesn't reap. Unlikely to matter. Add `tini` entrypoint if needed.

## 7. Test plan

Local:
1. `docker buildx build --platform linux/amd64 -f flux-klein-server/Dockerfile -t kiki-flux-klein:local .` on machine with ≥60 GB free. Inspect final size.
2. `docker run --rm -it --network=none kiki-flux-klein:local python -c "from diffusers import Flux2KleinPipeline; p=Flux2KleinPipeline.from_pretrained('black-forest-labs/FLUX.2-klein-4B')"` — verify loads from baked HF_HOME without network.

Staging on RunPod:
3. Push `:staging` tag via `workflow_dispatch`.
4. Manually `podRentInterruptable` a 5090 with `imageName=ghcr.io/.../kiki-flux-klein:staging` + `containerRegistryAuthId=<ghcr-cred-id>`. Time each phase.
5. `curl https://<podId>-8766.proxy.runpod.net/health` until `status=ok`. Record wall-clock.
6. Open WebSocket client, send test frame. Verify JPEG returns with expected latency.
7. `podTerminate`, verify graceful shutdown in logs.

Orchestrator:
8. Staging Railway: `FLUX_PROVISION_MODE=baked` + `FLUX_IMAGE=...:staging`. Provision 5 parallel sessions via iPad or load script. Verify all come up within SLA.
9. Keep one running; force-terminate pod; verify orchestrator recovers.

## 8. Rollout

1. Land `requirements.txt` + `Dockerfile` + `build-flux-image.yml`. Merge.
2. First build runs automatically. Note `:sha-<abc>`.
3. Generate GHCR PAT; add to RunPod registry creds; capture `RUNPOD_GHCR_AUTH_ID`.
4. Land orchestrator change: dual-mode (`FLUX_PROVISION_MODE`), reads `FLUX_IMAGE`, uses `RUNPOD_GHCR_AUTH_ID`. Deploy Railway with mode still `ssh`.
5. Set `RUNPOD_GHCR_AUTH_ID` + `FLUX_IMAGE=ghcr.io/.../kiki-flux-klein:sha-<abc>`.
6. Flip `FLUX_PROVISION_MODE=baked`. Smoke test: iPad open, confirm ready within 90s.
7. Monitor 24h via `railway logs`. Watch for pull failures, health timeouts, NVFP4 load warnings.
8. Flip code default to `baked`; delete SSH branch, setup script, runtime-assets, copy-assets, `RUNPOD_SSH_PRIVATE_KEY`.
9. Update `provider-config.md`.

## 9. Open questions

### DECIDED
- **Registry:** personal account (`ghcr.io/donpinkus`). Can move later if Kiki incorporates / adds collaborators.

### Still open
1. **Self-hosted GH Actions runner?** GH-hosted 50 GB disk + 28 GB image = tight. Mac Studio or `ubuntu-latest-16core` easier. OK with ~$0.08/build on larger runners?
2. **Keep SSH access post-migration for debugging?** RunPod base has `openssh-server`. Retaining `RUNPOD_SSH_PRIVATE_KEY` lets us `ssh` into broken pod. Would delete orchestrator SSH code either way.
3. **Monthly rebuild for weight refresh?** No upstream changes expected, but monthly `workflow_dispatch` catches silent drift. Or: rebuild only on code change.
4. **Docker `HEALTHCHECK` in image?** Adds Docker-level health RunPod can surface. Marginal vs our HTTP proxy polling.

## 10. Dependencies

**Independent of all other workstreams.** No coupling to auth (WS1), on-demand fallback (WS2 composes at `createSpotPod` layer above `IMAGE_NAME`), cost monitoring (WS4), Redis (WS5), observability (WS6), preemption (WS7). Low merge-conflict risk.

Touches one constant (`IMAGE_NAME`) and removes one code path (SSH provisioning) in `orchestrator.ts`.

**Blocks WS7 quality-of-outcome**: preemption-hide needs ≤90s replacement-pod-ready, which requires this.

## Critical files

- `/Users/donald/Desktop/kiki_root/flux-klein-server/Dockerfile` (new)
- `/Users/donald/Desktop/kiki_root/flux-klein-server/requirements.txt` (new)
- `/Users/donald/Desktop/kiki_root/.github/workflows/build-flux-image.yml` (new)
- `/Users/donald/Desktop/kiki_root/backend/src/modules/orchestrator/orchestrator.ts`
- `/Users/donald/Desktop/kiki_root/backend/src/config/index.ts`

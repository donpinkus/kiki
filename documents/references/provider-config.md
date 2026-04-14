# Provider Configuration

## Current Stack

FLUX.2-klein-4B on RunPod RTX 5090 spot, with BFL's NVFP4 transformer checkpoint loaded on top of the BF16 pipeline. Custom FastAPI + WebSocket server (not ComfyUI) at `flux-klein-server/`.

- ~1 FPS generation at 768×768 (reference mode, 4 steps)
- ~3 min fresh-boot cold start (model download + warmup)
- ~$0.53–0.55/hr spot bid in secure-cloud datacenters

Base image: `runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404` (CUDA 12.8 + PyTorch 2.9.1, Blackwell-native with broad driver compatibility).

## Operations — Starting a New Pod

### One-Button Deploy (GitHub Action) — Preferred

**Actions → Deploy FLUX.2-klein → Run workflow** on GitHub.

The workflow (`deploy-flux-klein.yml`):
1. Reuses the existing `kiki-flux-klein` pod if one is still running.
2. Otherwise queries RunPod for the current 5090 spot bid floor, adds a $0.02 headroom buffer, and creates a pod via `podRentInterruptable` in secure cloud.
3. SSHs in, runs `scripts/setup-flux-klein.sh` to install the venv, download model weights, and start the server.
4. Updates Railway `FLUX_KLEIN_URL` to point at the new pod's WebSocket proxy URL and redeploys the backend.
5. Polls `/health` to confirm the server is live.

If spot capacity isn't available, the workflow fails fast — we don't fall back to on-demand. Re-run manually when capacity returns.

**Required GitHub secrets:**

| Secret | Source |
|---|---|
| `RUNPOD_API_KEY` | RunPod Console → Settings → API Keys |
| `RUNPOD_SSH_PRIVATE_KEY` | Contents of `~/.runpod/ssh/RunPod-Key-Go` |
| `RAILWAY_TOKEN` | Railway Dashboard → Account → Tokens |

### Stopping All Pods

**Actions → Stop All RunPod Pods → Run workflow** — stops every pod on the account. Handy when you're done testing for the day, since spot pods bill until terminated.

### Verify

```bash
curl https://<POD_ID>-8766.proxy.runpod.net/health
# Expect: status=ok, quantization=nvfp4, gpu="NVIDIA GeForce RTX 5090"
```

### Cost

- Spot RTX 5090: ~$0.53/hr bid floor (secure cloud, varies by availability). On-demand would be $0.69–0.99/hr but we don't use it.
- No network volumes — spot pods are ephemeral, models redownload on fresh boot.
- Railway backend: ~$5/month.

## Key Files

| File | Purpose |
|---|---|
| `.github/workflows/deploy-flux-klein.yml` | Deploy workflow |
| `.github/workflows/stop-pods.yml` | Stop all pods |
| `scripts/setup-flux-klein.sh` | Pod-side setup (venv, deps, model download, server start) |
| `flux-klein-server/server.py` | WebSocket server entry point |
| `flux-klein-server/pipeline.py` | FLUX.2-klein pipeline wrapper (loads BF16 base + NVFP4 transformer) |
| `flux-klein-server/config.py` | Env-var-backed runtime config |

## Railway Backend

- **Service:** `kiki-backend` on Railway
- **Deploy:** `cd backend && railway up` (NOT via git push — see the auto-memory on this)
- **Logs:** `railway logs`
- **Role:** transparent WebSocket relay between iPad client and the FLUX.2-klein pod. Does not validate or modify the config JSON.

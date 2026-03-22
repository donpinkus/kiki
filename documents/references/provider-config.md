# Provider Configuration

## Current Stack

ComfyUI on RunPod H100 80GB SXM running Qwen-Image 20B (FP8) + InstantX ControlNet Union.

- ~6-8s per generation (including network round-trip)
- ~30-60s first generation after cold start (model loading) — mitigated by automatic warmup in `setup-pod.sh`
- 24GB+ VRAM required (FP8 model uses ~21GB)

Model filenames and pipeline details are in `comfyui-workflow-api.json` (source of truth).

## Workflow Template

Stored at `backend/src/modules/providers/comfyui-workflow-api.json`. The adapter injects only the input image filename and prompt text per request — all other params come from the template.

**To update generation parameters:**
1. Open ComfyUI web UI on the RunPod pod
2. Change parameters as desired
3. Right-click workflow tab → **Export (API)**
4. Replace the JSON file in the repo
5. Commit, push, and redeploy backend

## Operations — Starting a New Pod

### One-Button Deploy (GitHub Action) — Preferred

Go to **Actions → Deploy RunPod → Run workflow** on GitHub (works from phone).

The action automatically:
1. Tries existing network volumes for GPU availability
2. If none available, probes other datacenters and creates a new volume (capped at 10)
3. Creates a pod with GPU fallback (H100 SXM → H100 PCIe → A100 80GB)
4. SSHs in and runs `scripts/setup-pod.sh` (symlinks models, installs deps, restarts ComfyUI, warms up models)
5. On fresh volumes, downloads all models (~30GB, 5-10 min one-time)
6. Updates Railway `COMFYUI_URL` via API
7. Shows pod ID, URL, and datacenter in the Summary tab

**Required GitHub secrets:**

| Secret | Source |
|---|---|
| `RUNPOD_API_KEY` | RunPod Console → Settings → API Keys |
| `RUNPOD_SSH_PRIVATE_KEY` | Contents of `~/.runpod/ssh/RunPod-Key-Go` |
| `RAILWAY_TOKEN` | Railway Dashboard → Account → Tokens |

### Manual Deploy (CLI)

```bash
# Option A: Use the create script
RUNPOD_API_KEY=<key> ./scripts/create-pod.sh

# Option B: Use runpodctl
runpodctl pod list
runpodctl ssh info <POD_ID>
ssh -i ~/.runpod/ssh/RunPod-Key-Go root@<IP> -p <PORT>
# Then run setup-pod.sh on the pod

# Update Railway
railway vars set COMFYUI_URL=https://<POD_ID>-8188.proxy.runpod.net
```

### Verify
```bash
curl https://<POD_ID>-8188.proxy.runpod.net/system_stats
curl https://kiki-backend-production-eb81.up.railway.app/health
```

### Network Volumes

Volumes persist models across pod terminations. The action manages them automatically.
- **Template:** `runpod/comfyui:latest` (do NOT use `aitrepreneur/comfyui`)
- **Model storage:** `/workspace/kiki-models/` (new volumes) or legacy paths on older volumes
- **Max volumes:** 10 (enforced by the GitHub Action)

### Cost
- Network volume: ~$2/month (30GB storage)
- GPU pod: $1.19-2.69/hr depending on GPU type
- Railway backend: ~$5/month

## Railway Backend

- **Service:** `kiki-backend` on Railway
- **Deploy:** `cd backend && railway up` (or auto-deploys on git push if connected)
- **Logs:** `railway logs`

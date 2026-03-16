# Provider Configuration

## Current Provider Stack

| Provider | Role | Model | Infrastructure |
|---|---|---|---|
| ComfyUI (primary) | All generation | Qwen-Image 20B (FP8) + InstantX ControlNet Union | RunPod H100 80GB SXM |

### Previous Providers (replaced)
- fal.ai (`fal-ai/scribble`) — replaced by ComfyUI adapter in March 2026

## ComfyUI Setup

### Model Pipeline
- **Base model:** Qwen-Image FP8 (`qwen_image_fp8_e4m3fn.safetensors`, 20GB)
- **Text encoder:** Qwen 2.5 VL 7B FP8 (`qwen_2.5_vl_7b_fp8_scaled.safetensors`)
- **VAE:** Qwen-Image VAE (`qwen_image_vae.safetensors`)
- **ControlNet:** InstantX ControlNet Union (`Qwen-Image-InstantX-ControlNet-Union.safetensors`)
- **Speed LoRA:** Lightning 8-step V2.0 (`Qwen-Image-Lightning-8steps-V2.0.safetensors`)
- **Preprocessor:** AnyLine Lineart (from `comfyui_controlnet_aux`)

### KSampler Settings
- Steps: 8 (with Lightning LoRA)
- CFG: 1.0
- Sampler: euler
- Scheduler: simple
- Shift (ModelSamplingAuraFlow): 3.1

### Performance
- ~6-8s per generation on H100 80GB SXM (including network round-trip)
- First generation after cold start: ~30-60s (model loading)

## ComfyUI API Integration

### Endpoints Used
| Endpoint | Method | Purpose |
|---|---|---|
| `/upload/image` | POST | Upload sketch PNG (multipart form) |
| `/prompt` | POST | Submit workflow to execution queue |
| `/history/{prompt_id}` | GET | Poll for completed generation |
| `/view` | GET | Retrieve output image |
| `/system_stats` | GET | Health check |

### Workflow Template
The API-format workflow is stored at `backend/src/modules/providers/comfyui-workflow-api.json`. This is the flattened node graph exported from ComfyUI's "Export (API)" function.

**Key node IDs in the template:**
- `71` — LoadImage (sketch input filename)
- `111:6` — CLIPTextEncode (positive prompt text)
- `60` — SaveImage (output to poll)

The adapter modifies only the input image filename and prompt text per request. All other params (strength, steps, models, preprocessor settings) come from the template.

### Updating the Workflow Template
To change generation parameters (strength, steps, models, preprocessor):
1. Open ComfyUI web UI on the RunPod pod
2. Change parameters as desired
3. Right-click workflow tab → **Export (API)**
4. Replace `backend/src/modules/providers/comfyui-workflow-api.json` with the export
5. Redeploy backend

### Reference Workflow (Web UI Format)
A copy of the web UI workflow is saved at `documents/comfyui-workflows/qwen-instantx-softedge.json` for reference. This cannot be submitted to the API directly.

## Provider Adapter Interface

```typescript
interface ProviderAdapter {
  readonly name: string; // 'comfyui'

  generate(request: ProviderRequest): Promise<ProviderResponse>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<boolean>;
}
```

## Operations — Starting a New Pod

### One-Button Deploy (GitHub Action) — Preferred

Go to **Actions → Deploy RunPod → Run workflow** on GitHub (works from phone).

The action automatically:
1. Tries existing network volumes for GPU availability
2. If none available, probes other datacenters and creates a new volume (capped at 10)
3. Creates a pod with GPU fallback (H100 SXM → H100 PCIe → A100 80GB)
4. SSHs in and runs `scripts/setup-pod.sh` (symlinks models, installs deps, restarts ComfyUI)
5. On fresh volumes, downloads all models (~30GB, 5-10 min one-time)
6. Updates Railway `COMFYUI_URL` via API
7. Shows pod ID, URL, and datacenter in the Summary tab

**Required GitHub secrets:**
| Secret | Source |
|---|---|
| `RUNPOD_API_KEY` | RunPod Console → Settings → API Keys |
| `RUNPOD_SSH_PRIVATE_KEY` | Contents of `~/.runpod/ssh/RunPod-Key-Go` |
| `RAILWAY_TOKEN` | Railway Dashboard → Account → Tokens |

**Cost notes:**
- Each new network volume costs ~$2/month (30GB storage)
- GPU pod costs $1.19-2.69/hr depending on GPU type
- Railway backend costs ~$5/month

### Manual Deploy (CLI)

If the GitHub Action isn't available:
```bash
# Option A: Use the create script
RUNPOD_API_KEY=<key> ./scripts/create-pod.sh

# Option B: Use runpodctl
/Users/donald/bin/runpodctl pod list
/Users/donald/bin/runpodctl ssh info <POD_ID>
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
- **GPU requirement:** 24GB+ VRAM (FP8 model uses ~21GB)
- **Model storage:** `/workspace/kiki-models/` (new volumes) or legacy paths on older volumes
- **Max volumes:** 10 (enforced by the GitHub Action)

## Updating the ComfyUI Workflow

To change generation parameters (strength, steps, models, preprocessor):
1. Open ComfyUI web UI at `https://<POD_ID>-8188.proxy.runpod.net`
2. Change parameters as desired
3. Right-click workflow tab → **Export (API)**
4. Replace `backend/src/modules/providers/comfyui-workflow-api.json` with the export
5. Commit, push, and run `cd backend && railway up`

## Environment Variables

```
COMFYUI_URL=          # RunPod proxy URL (e.g., https://<POD_ID>-8188.proxy.runpod.net)
FAL_API_KEY=          # Legacy — fal.ai API key (no longer used)
```

Never in client code. Backend only. Stored in Railway environment variables.

## Railway Backend

- **Service:** `kiki-backend` on Railway
- **Public URL:** `https://kiki-backend-production-eb81.up.railway.app`
- **Deploy:** `cd backend && railway up` (or auto-deploys on git push if connected)
- **Logs:** `railway logs`
- **Cost:** ~$5/month (Hobby plan, minimal idle usage)

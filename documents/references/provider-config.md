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

### 1. Create Pod on RunPod
- **Template:** `runpod/comfyui:latest` (do NOT use `aitrepreneur/comfyui` — missing nodes, port conflicts)
- **GPU:** H100 80GB SXM (or any GPU with 24GB+ VRAM for FP8)
- **Network volume:** Attach the existing volume (EU: `eu-nl-1`, models in `/workspace/madapps/`; US: `us-ga-2`, models in `/workspace/ComfyUI/models/`)

### 2. Set Up Pod (SSH in, ~2 min)
```bash
# Get pod info
/Users/donald/bin/runpodctl pod list
/Users/donald/bin/runpodctl ssh info <POD_ID>

# SSH in
ssh -i ~/.runpod/ssh/RunPod-Key-Go root@<IP> -p <PORT>

# Symlink models (EU volume — models are in /workspace/madapps/)
ln -sf /workspace/madapps/ComfyUI/models/diffusion_models/qwen_image_fp8_e4m3fn.safetensors /workspace/runpod-slim/ComfyUI/models/diffusion_models/
ln -sf /workspace/madapps/ComfyUI/models/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors /workspace/runpod-slim/ComfyUI/models/text_encoders/
ln -sf /workspace/madapps/ComfyUI/models/vae/qwen_image_vae.safetensors /workspace/runpod-slim/ComfyUI/models/vae/
ln -sf /workspace/madapps/ComfyUI/models/controlnet/Qwen-Image-InstantX-ControlNet-Union.safetensors /workspace/runpod-slim/ComfyUI/models/controlnet/
# Lightning LoRA should already be at /workspace/runpod-slim/ComfyUI/models/loras/

# Install custom node pip deps (git repo persists on volume, but pip packages are in the container)
cd /workspace/runpod-slim/ComfyUI/custom_nodes/comfyui_controlnet_aux
/workspace/runpod-slim/ComfyUI/.venv/bin/pip install -r requirements.txt

# Restart ComfyUI to pick up custom nodes
pkill -f "python.*main.py"
sleep 2
cd /workspace/runpod-slim/ComfyUI
source .venv/bin/activate
nohup python main.py --listen 0.0.0.0 --port 8188 > /workspace/runpod-slim/comfyui.log 2>&1 &
```

### 3. Update Railway
```bash
# The proxy URL is always: https://<POD_ID>-8188.proxy.runpod.net
railway vars set COMFYUI_URL=https://<POD_ID>-8188.proxy.runpod.net
# Railway auto-redeploys (~30s). No code push needed.
```

### 4. Verify
```bash
# Check proxy
curl https://<POD_ID>-8188.proxy.runpod.net/system_stats

# Check end-to-end
curl https://kiki-backend-production-eb81.up.railway.app/health
```

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

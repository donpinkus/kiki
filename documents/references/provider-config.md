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

## RunPod Pod Details

- **Pod ID:** `nll2z007pl313s`
- **GPU:** H100 80GB SXM
- **ComfyUI path:** `/workspace/runpod-slim/ComfyUI/`
- **SSH:** `ssh -i ~/.runpod/ssh/RunPod-Key-Go root@91.199.227.82 -p 11364`
- **Proxy URL:** `https://nll2z007pl313s-8188.proxy.runpod.net`

## Environment Variables

```
COMFYUI_URL=          # RunPod proxy URL (e.g., https://nll2z007pl313s-8188.proxy.runpod.net)
FAL_API_KEY=          # Legacy — fal.ai API key (no longer used)
```

Never in client code. Backend only. Stored in Railway environment variables.

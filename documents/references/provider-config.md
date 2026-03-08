# Provider Configuration

## Provider Stack

| Provider | Role | Connection | Cost per Image |
|---|---|---|---|
| fal.ai (primary) | Preview + Refine | REST + WebSocket | Preview ~$0.003, Refine ~$0.02 |
| Replicate (fallback) | Failover for both | REST only | Scribble ~$0.003, FLUX ~$0.03 |

## fal.ai Endpoints

### Preview (LCM Real-Time)
- **REST:** `fal-ai/lcm-sd15-i2i` — SD 1.5 + LCM-LoRA, image-to-image
- **WebSocket:** `wss://...lcm-sd15-i2i` — real-time streaming (preferred for preview)
- 4-6 inference steps, 512x512
- Pricing: ~$0.001/GPU-second

### Refine (SDXL ControlNet)
- **REST:** `fal-ai/stable-diffusion-xl-controlnet`
- ControlNet model: `xinsir/controlnet-scribble-sdxl-1.0` (trained on 10M+ images)
- 20-30 inference steps, 1024x1024
- Queue API: submit → poll for result

### fal.ai API Patterns
- **REST:** Submit job → receive queue ID → poll until complete
- **WebSocket:** Send binary frame (image) + JSON metadata → receive binary frame (result)
- API key in `Authorization: Key <fal_api_key>` header
- Built-in NSFW filtering available (but we add our own layer)

## Replicate Endpoints

### Preview Fallback
- **Model:** `jagilley/controlnet-scribble` — SD 1.5 + ControlNet Scribble
- ~0.6s per image with LCM

### Refine Fallback
- **Model:** `black-forest-labs/flux-canny-pro` — FLUX edge-conditioned generation
- Professional-grade quality, higher cost (~$0.03/image)

### Replicate API Patterns
- Submit prediction → poll for result (webhook optional)
- API key in `Authorization: Bearer <replicate_api_token>` header

## Provider Adapter Interface

```typescript
interface ProviderAdapter {
  readonly name: string; // 'fal' | 'replicate'

  generate(request: ProviderRequest): Promise<ProviderResponse>;
  cancel(jobId: string): Promise<void>;
  healthCheck(): Promise<boolean>;
}

interface ProviderRequest {
  sketchImage: Buffer;          // JPEG bytes
  prompt: string;               // Combined caption + style template
  negativePrompt: string;       // Shared negative prompt
  mode: 'preview' | 'refine';
  adherence: number;            // 0.0-1.0, maps to ControlNet conditioning_scale
  creativity: number;           // 0.0-1.0
  seed?: number;
  width: number;                // 512 (preview) or 1024 (refine)
  height: number;
}

interface ProviderResponse {
  imageUrl: string;             // URL to generated image
  imageBytes?: Buffer;          // Raw bytes (WebSocket path)
  seed: number;
  latencyMs: number;
  jobId: string;
}
```

## Provider Router — Config-Driven Routing

```json
{
  "routing": {
    "preview": "fal",
    "refine": "fal",
    "fallback": "replicate"
  },
  "circuitBreaker": {
    "failureThreshold": 5,
    "latencyThresholdMs": 10000,
    "latencyWindowSeconds": 60,
    "resetTimeoutSeconds": 60
  }
}
```

## Circuit Breaker States

| State | Behavior | Transition |
|---|---|---|
| Closed (normal) | All requests → primary provider (fal.ai) | → Open: 5 consecutive errors OR p95 >10s over 60s window |
| Open (failover) | All requests → fallback provider (Replicate) | → Half-open: after 60s timeout |
| Half-open (probe) | Single probe request → primary | Success → Closed. Failure → Open (another 60s). |

- Circuit state stored in Redis (shared across backend instances)
- Feature flags for A/B testing providers: `{ "preview_provider_override": "replicate" }`

## Cost Modeling

| Scenario | Previews | Refines | Cost |
|---|---|---|---|
| Average session (15 min) | 30 | 8 | ~$0.25 |
| Power user session | 80 | 20 | ~$0.64 |
| Casual monthly (10 sessions) | 300 | 80 | ~$2.50 |
| Power monthly (30 sessions) | 2,400 | 600 | ~$19.20 |

## Environment Variables

```
FAL_API_KEY=          # fal.ai API key
REPLICATE_API_TOKEN=  # Replicate API token
```

Never in client code. Backend only. Stored in Railway environment variables.

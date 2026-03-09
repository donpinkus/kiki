import { config } from '../../config/index.js';
import { ProviderError } from '../../errors.js';
import type {
  ProviderAdapter,
  ProviderRequest,
  ProviderResponse,
} from './types.js';

const FAL_BASE = 'https://fal.run';
const FAL_QUEUE_BASE = 'https://queue.fal.run';
const FAL_MODEL = 'fal-ai/fast-sdxl/image-to-image';

interface FalSyncResponse {
  images: Array<{ url: string; width: number; height: number }>;
  seed: number;
  has_nsfw_concepts?: boolean[];
}

function authHeaders(): Record<string, string> {
  return {
    Authorization: `Key ${config.FAL_API_KEY}`,
    'Content-Type': 'application/json',
  };
}

export class FalAdapter implements ProviderAdapter {
  readonly name = 'fal';

  async generate(request: ProviderRequest): Promise<ProviderResponse> {
    const startTime = Date.now();

    const input: Record<string, unknown> = {
      image_url: `data:image/jpeg;base64,${request.sketchImageBase64}`,
      prompt: `${request.prompt}, colorful, light background, masterpiece`,
      negative_prompt: `${request.negativePrompt}, white, blank, sketch, line art, monochrome, dark`,
      strength: 0.97,
      guidance_scale: 14,
      num_inference_steps: request.mode === 'preview' ? 25 : 35,
      image_size: {
        width: request.width,
        height: request.height,
      },
      enable_safety_checker: true,
    };

    if (request.seed !== undefined) {
      input['seed'] = request.seed;
    }

    const url = `${FAL_BASE}/${FAL_MODEL}`;

    const response = await fetch(url, {
      method: 'POST',
      headers: authHeaders(),
      body: JSON.stringify(input),
    });

    if (!response.ok) {
      const body = await response.text();
      throw new ProviderError(
        'fal',
        `Provider returned ${response.status}: ${body}`,
      );
    }

    const result = (await response.json()) as FalSyncResponse;

    if (!result.images || result.images.length === 0) {
      throw new ProviderError('fal', 'No images returned from provider');
    }

    const latencyMs = Date.now() - startTime;

    return {
      imageUrl: result.images[0]!.url,
      seed: result.seed,
      latencyMs,
    };
  }

  async cancel(jobId: string): Promise<void> {
    const url = `${FAL_QUEUE_BASE}/${FAL_MODEL}/requests/${jobId}/cancel`;

    const response = await fetch(url, {
      method: 'PUT',
      headers: authHeaders(),
    });

    if (!response.ok) {
      const body = await response.text();
      console.warn(`Failed to cancel fal job ${jobId}: ${response.status} ${body}`);
    }
  }

  async healthCheck(): Promise<boolean> {
    try {
      const response = await fetch(`${FAL_BASE}/${FAL_MODEL}`, {
        method: 'OPTIONS',
        headers: authHeaders(),
      });
      return response.ok;
    } catch {
      return false;
    }
  }
}

import { config } from '../../config/index.js';
import { ProviderError } from '../../errors.js';
import type {
  ProviderAdapter,
  ProviderRequest,
  ProviderResponse,
} from './types.js';

const FAL_BASE = 'https://fal.run';
const FAL_QUEUE_BASE = 'https://queue.fal.run';
const FAL_STORAGE_BASE = 'https://rest.alpha.fal.ai';
const FAL_MODEL = 'fal-ai/scribble';

interface FalScribbleResponse {
  image: { url: string; width: number; height: number };
  control_image?: { url: string };
  seed: number;
}

function authHeaders(): Record<string, string> {
  return {
    Authorization: `Key ${config.FAL_API_KEY}`,
    'Content-Type': 'application/json',
  };
}

/**
 * Uploads a base64-encoded JPEG to fal.ai storage and returns a hosted URL.
 * ControlNet models require hosted URLs (data URIs return 422).
 */
async function uploadToFalStorage(base64: string): Promise<string> {
  // Step 1: Initiate upload
  const initResponse = await fetch(`${FAL_STORAGE_BASE}/storage/upload/initiate`, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify({
      content_type: 'image/jpeg',
      file_name: 'sketch.jpg',
    }),
  });

  if (!initResponse.ok) {
    const body = await initResponse.text();
    throw new ProviderError('fal', `Storage initiate failed ${initResponse.status}: ${body}`);
  }

  const { file_url, upload_url } = (await initResponse.json()) as {
    file_url: string;
    upload_url: string;
  };

  // Step 2: Upload raw bytes
  const buffer = Buffer.from(base64, 'base64');
  const putResponse = await fetch(upload_url, {
    method: 'PUT',
    headers: { 'Content-Type': 'image/jpeg' },
    body: buffer,
  });

  if (!putResponse.ok) {
    const body = await putResponse.text();
    throw new ProviderError('fal', `Storage upload failed ${putResponse.status}: ${body}`);
  }

  return file_url;
}

export class FalAdapter implements ProviderAdapter {
  readonly name = 'fal';

  async generate(request: ProviderRequest): Promise<ProviderResponse> {
    const startTime = Date.now();

    // Upload sketch to fal storage (ControlNet models require hosted URLs)
    const imageUrl = await uploadToFalStorage(request.sketchImageBase64);

    const input: Record<string, unknown> = {
      image_url: imageUrl,
      prompt: `${request.prompt}, colorful, vibrant, detailed`,
      negative_prompt: `${request.negativePrompt}, blurry, low quality`,
      guidance_scale: request.mode === 'preview' ? 7.5 : 10,
      num_inference_steps: request.mode === 'preview' ? 25 : 35,
      enable_safety_checker: true,
    };

    if (request.advancedParameters?.seed != null) {
      input['seed'] = request.advancedParameters.seed;
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

    const result = (await response.json()) as FalScribbleResponse;

    if (!result.image || !result.image.url) {
      throw new ProviderError('fal', 'No image returned from provider');
    }

    const latencyMs = Date.now() - startTime;

    return {
      imageUrl: result.image.url,
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

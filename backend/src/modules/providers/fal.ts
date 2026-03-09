import { config } from '../../config/index.js';
import { ProviderError } from '../../errors.js';
import type {
  ProviderAdapter,
  ProviderRequest,
  ProviderResponse,
} from './types.js';

const FAL_QUEUE_BASE = 'https://queue.fal.run';
const FAL_LCM_MODEL = 'fal-ai/lcm-sd15-i2i';

const POLL_INTERVAL_MS = 500;
const MAX_POLL_ATTEMPTS = 60; // 30 seconds max

interface FalQueueResponse {
  request_id: string;
  status: string;
  response_url: string;
}

interface FalStatusResponse {
  status: 'IN_QUEUE' | 'IN_PROGRESS' | 'COMPLETED';
  response_url?: string;
}

interface FalResultResponse {
  images: Array<{ url: string }>;
  seed: number;
}

function authHeaders(): Record<string, string> {
  return {
    Authorization: `Key ${config.FAL_API_KEY}`,
    'Content-Type': 'application/json',
  };
}

async function submitJob(
  model: string,
  input: Record<string, unknown>,
): Promise<FalQueueResponse> {
  const url = `${FAL_QUEUE_BASE}/${model}`;

  const response = await fetch(url, {
    method: 'POST',
    headers: authHeaders(),
    body: JSON.stringify(input),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new ProviderError(
      'fal',
      `Failed to submit job: ${response.status} ${body}`,
    );
  }

  return (await response.json()) as FalQueueResponse;
}

async function pollStatus(
  model: string,
  requestId: string,
): Promise<FalStatusResponse> {
  const url = `${FAL_QUEUE_BASE}/${model}/requests/${requestId}/status`;

  const response = await fetch(url, {
    method: 'GET',
    headers: authHeaders(),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new ProviderError(
      'fal',
      `Failed to poll status: ${response.status} ${body}`,
    );
  }

  return (await response.json()) as FalStatusResponse;
}

async function getResult(
  model: string,
  requestId: string,
): Promise<FalResultResponse> {
  const url = `${FAL_QUEUE_BASE}/${model}/requests/${requestId}`;

  const response = await fetch(url, {
    method: 'GET',
    headers: authHeaders(),
  });

  if (!response.ok) {
    const body = await response.text();
    throw new ProviderError(
      'fal',
      `Failed to get result: ${response.status} ${body}`,
    );
  }

  return (await response.json()) as FalResultResponse;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitForCompletion(
  model: string,
  requestId: string,
): Promise<void> {
  for (let attempt = 0; attempt < MAX_POLL_ATTEMPTS; attempt++) {
    const status = await pollStatus(model, requestId);

    if (status.status === 'COMPLETED') {
      return;
    }

    if (status.status !== 'IN_QUEUE' && status.status !== 'IN_PROGRESS') {
      throw new ProviderError('fal', `Unexpected job status: ${status.status}`);
    }

    await sleep(POLL_INTERVAL_MS);
  }

  throw new ProviderError('fal', 'Job timed out waiting for completion');
}

export class FalAdapter implements ProviderAdapter {
  readonly name = 'fal';

  async generate(request: ProviderRequest): Promise<ProviderResponse> {
    const startTime = Date.now();

    const input: Record<string, unknown> = {
      image_url: `data:image/jpeg;base64,${request.sketchImageBase64}`,
      prompt: request.prompt,
      negative_prompt: request.negativePrompt,
      strength: request.creativity,
      guidance_scale: 1 + request.adherence * 7, // Map 0-1 to 1-8
      num_inference_steps: request.mode === 'preview' ? 4 : 20,
      image_size: {
        width: request.width,
        height: request.height,
      },
      enable_safety_checker: true,
    };

    if (request.seed !== undefined) {
      input['seed'] = request.seed;
    }

    const model = FAL_LCM_MODEL;

    // Submit job to the queue
    const queueResponse = await submitJob(model, input);
    const jobId = queueResponse.request_id;

    // Poll until completion
    await waitForCompletion(model, jobId);

    // Fetch the result
    const result = await getResult(model, jobId);

    if (!result.images || result.images.length === 0) {
      throw new ProviderError('fal', 'No images returned from provider');
    }

    const latencyMs = Date.now() - startTime;

    return {
      imageUrl: result.images[0]!.url,
      seed: result.seed,
      latencyMs,
      jobId,
    };
  }

  async cancel(jobId: string): Promise<void> {
    const url = `${FAL_QUEUE_BASE}/${FAL_LCM_MODEL}/requests/${jobId}/cancel`;

    const response = await fetch(url, {
      method: 'PUT',
      headers: authHeaders(),
    });

    if (!response.ok) {
      // Log but don't throw — cancellation is best-effort
      const body = await response.text();
      console.warn(`Failed to cancel fal job ${jobId}: ${response.status} ${body}`);
    }
  }

  async healthCheck(): Promise<boolean> {
    try {
      const response = await fetch(`${FAL_QUEUE_BASE}/${FAL_LCM_MODEL}`, {
        method: 'OPTIONS',
        headers: authHeaders(),
      });
      return response.ok;
    } catch {
      return false;
    }
  }
}

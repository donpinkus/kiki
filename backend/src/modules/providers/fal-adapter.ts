import { config } from '../../config/index.js';
import { ProviderError } from '../errors.js';
import type { GenerateParams, GenerateResult } from '../orchestrator/index.js';

const FAL_QUEUE_URL = 'https://queue.fal.run/fal-ai/lcm-sd15-i2i';
const FETCH_TIMEOUT_MS = 30_000;
const POLL_TIMEOUT_MS = 10_000;

interface FalQueueResponse {
  request_id: string;
  status: string;
}

interface FalResultResponse {
  images: Array<{ url: string; seed: number }>;
}

function fetchWithTimeout(url: string, init: RequestInit, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), timeoutMs);
  return fetch(url, { ...init, signal: controller.signal }).finally(() =>
    clearTimeout(timeoutId),
  );
}

export async function generateWithFal(params: GenerateParams): Promise<GenerateResult> {
  const apiKey = config.FAL_API_KEY;

  if (!apiKey) {
    // Return a mock response for development without API key
    return {
      status: 'completed',
      imageUrl: null,
      seed: Math.floor(Math.random() * 999999),
      provider: 'fal-mock',
    };
  }

  try {
    // Submit to fal.ai queue
    const submitResponse = await fetchWithTimeout(
      FAL_QUEUE_URL,
      {
        method: 'POST',
        headers: {
          Authorization: `Key ${apiKey}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({
          prompt: params.prompt || 'a sketch',
          image_url: `data:image/jpeg;base64,${params.sketchImageBase64}`,
          strength: 1 - params.adherence,
          num_inference_steps: 4,
          guidance_scale: 1.5,
          seed: null,
        }),
      },
      FETCH_TIMEOUT_MS,
    );

    if (!submitResponse.ok) {
      throw new ProviderError('fal', `Submit failed: ${submitResponse.status}`);
    }

    const submitResult = (await submitResponse.json()) as FalQueueResponse;
    const falRequestId = submitResult.request_id;

    // Poll for result
    const resultUrl = `${FAL_QUEUE_URL}/requests/${falRequestId}`;
    const maxAttempts = 30;

    for (let attempt = 0; attempt < maxAttempts; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 200));

      const statusResponse = await fetchWithTimeout(
        `${resultUrl}/status`,
        { headers: { Authorization: `Key ${apiKey}` } },
        POLL_TIMEOUT_MS,
      );

      if (!statusResponse.ok) continue;

      const statusResult = (await statusResponse.json()) as FalQueueResponse;

      if (statusResult.status === 'COMPLETED') {
        const resultResponse = await fetchWithTimeout(
          resultUrl,
          { headers: { Authorization: `Key ${apiKey}` } },
          POLL_TIMEOUT_MS,
        );

        if (!resultResponse.ok) {
          throw new ProviderError('fal', `Result fetch failed: ${resultResponse.status}`);
        }

        const result = (await resultResponse.json()) as FalResultResponse;
        const image = result.images[0];

        return {
          status: 'completed',
          imageUrl: image?.url ?? null,
          seed: image?.seed ?? null,
          provider: 'fal',
        };
      }

      if (statusResult.status === 'FAILED') {
        throw new ProviderError('fal', 'Generation failed');
      }
    }

    throw new ProviderError('fal', 'Generation timed out');
  } catch (error) {
    if (error instanceof ProviderError) throw error;

    throw new ProviderError('fal', error instanceof Error ? error.message : 'Unknown error');
  }
}

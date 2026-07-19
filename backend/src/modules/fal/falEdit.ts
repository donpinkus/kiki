/**
 * One-shot instruction edit via fal's hosted FLUX.2 [klein] 9B edit endpoint
 * (`fal-ai/flux-2/klein/9b/edit`) — powers POST /v1/edit (the AI Edit /
 * inpaint feature).
 *
 * Unlike the realtime drawing stream (falImageRelay, WS + msgpack), this is a
 * plain synchronous HTTPS call to fal.run: send the flattened drawing as a
 * base64 data URI + an editing instruction, get the edited image back inline
 * (`sync_mode: true` → data URI, no CDN round-trip). Region masking is NOT
 * done here — the endpoint has no mask parameter; the iPad composites the
 * result into the lasso selection client-side, which guarantees pixels
 * outside the selection never change regardless of model behavior.
 *
 * Measured 2026-07-19 (this endpoint, 1536×1024 sketch input): 2.5–4 s per
 * edit at 8 steps, output capped near 1 MP with aspect preserved. Queue
 * billing (per output image), so no warm-idle cost concerns.
 */

import { config } from '../../config/index.js';

const FAL_EDIT_MODEL = 'fal-ai/flux-2/klein/9b/edit';
const TIMEOUT_MS = 120_000;

export interface FalEditParams {
  prompt: string;
  /** Source image as raw bytes (JPEG or PNG). */
  image: Buffer;
  imageContentType: 'image/jpeg' | 'image/png';
  steps?: number;
  seed?: number;
  /** Requested output size; omit to let fal default to input size (~1 MP cap). */
  imageSize?: { width: number; height: number };
}

export interface FalEditResult {
  image: Buffer;
  contentType: string;
  width?: number;
  height?: number;
  seed?: number;
  elapsedMs: number;
}

interface FalEditResponse {
  images?: Array<{ url?: string; width?: number; height?: number }>;
  seed?: number;
  has_nsfw_concepts?: boolean[];
}

export async function falKleinEdit(params: FalEditParams): Promise<FalEditResult> {
  if (!config.FAL_KEY) throw new Error('FAL_KEY not configured');

  const body: Record<string, unknown> = {
    prompt: params.prompt,
    image_urls: [`data:${params.imageContentType};base64,${params.image.toString('base64')}`],
    output_format: 'png',
    sync_mode: true,
  };
  if (params.steps !== undefined) body['num_inference_steps'] = params.steps;
  if (params.seed !== undefined) body['seed'] = params.seed;
  if (params.imageSize) body['image_size'] = params.imageSize;

  const t0 = Date.now();
  const res = await fetch(`https://fal.run/${FAL_EDIT_MODEL}`, {
    method: 'POST',
    headers: {
      Authorization: `Key ${config.FAL_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (!res.ok) {
    const text = (await res.text()).slice(0, 500);
    throw new Error(`fal edit HTTP ${res.status}: ${text}`);
  }
  const json = (await res.json()) as FalEditResponse;
  const img = json.images?.[0];
  if (!img?.url) throw new Error('fal edit returned no image');

  let image: Buffer;
  let contentType = 'image/png';
  if (img.url.startsWith('data:')) {
    const comma = img.url.indexOf(',');
    contentType = img.url.slice(5, img.url.indexOf(';'));
    image = Buffer.from(img.url.slice(comma + 1), 'base64');
  } else {
    // sync_mode should inline the image, but tolerate a CDN URL response.
    const dl = await fetch(img.url, { signal: AbortSignal.timeout(30_000) });
    if (!dl.ok) throw new Error(`fal edit image download HTTP ${dl.status}`);
    contentType = dl.headers.get('content-type') ?? 'image/png';
    image = Buffer.from(await dl.arrayBuffer());
  }

  return {
    image,
    contentType,
    width: img.width,
    height: img.height,
    seed: json.seed,
    elapsedMs: Date.now() - t0,
  };
}

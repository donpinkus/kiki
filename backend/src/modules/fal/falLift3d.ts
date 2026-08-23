/**
 * Image→3D lift via fal's hosted Hunyuan3D v3 (`fal-ai/hunyuan3d-v3/image-to-3d`)
 * — powers POST /v1/lift3d (object library stage 3: lift a drawn object to a
 * canonical 3D model for perfectly consistent placement).
 *
 * Queue API (NOT fal.run sync — generation takes 1-4 min and the sync LB
 * drops the connection; measured 2026-07-19: 89 s for a 100k-face lift).
 * Returns the textured GLB (the endpoint's usdz field is null in practice;
 * the iPad loads GLB via GLTFKit2 → SceneKit) plus the rendered thumbnail.
 */

import { config } from '../../config/index.js';

const MODEL = 'fal-ai/hunyuan3d-v3/image-to-3d';
const SUBMIT_TIMEOUT_MS = 60_000;
const POLL_INTERVAL_MS = 5_000;
const TOTAL_TIMEOUT_MS = 6 * 60_000;

export interface Lift3dResult {
  glb: Buffer;
  thumbnail: Buffer | null;
  elapsedMs: number;
}

interface QueueSubmit {
  status_url?: string;
  response_url?: string;
}

function fileUrl(v: unknown): string | null {
  if (typeof v === 'string') return v;
  if (v && typeof v === 'object' && typeof (v as { url?: unknown }).url === 'string') {
    return (v as { url: string }).url;
  }
  return null;
}

export async function falLift3d(image: Buffer, contentType: string): Promise<Lift3dResult> {
  if (!config.FAL_KEY) throw new Error('FAL_KEY not configured');
  const headers = {
    Authorization: `Key ${config.FAL_KEY}`,
    'Content-Type': 'application/json',
  };
  const t0 = Date.now();

  const submitRes = await fetch(`https://queue.fal.run/${MODEL}`, {
    method: 'POST',
    headers,
    body: JSON.stringify({
      input_image_url: `data:${contentType};base64,${image.toString('base64')}`,
      generate_type: 'Normal',
      face_count: 100_000,
    }),
    signal: AbortSignal.timeout(SUBMIT_TIMEOUT_MS),
  });
  if (!submitRes.ok) {
    throw new Error(`lift3d submit HTTP ${submitRes.status}: ${(await submitRes.text()).slice(0, 300)}`);
  }
  const submit = (await submitRes.json()) as QueueSubmit;
  if (!submit.status_url || !submit.response_url) throw new Error('lift3d submit missing queue urls');

  for (;;) {
    if (Date.now() - t0 > TOTAL_TIMEOUT_MS) throw new Error('lift3d timed out');
    const stRes = await fetch(submit.status_url, { headers, signal: AbortSignal.timeout(30_000) });
    if (stRes.ok) {
      const stText = await stRes.text();
      const st = JSON.parse(stText) as { status?: string };
      if (st.status === 'COMPLETED') break;
      if (st.status === 'FAILED') throw new Error(`lift3d generation failed: ${stText.slice(0, 300)}`);
    }
    await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
  }

  const outRes = await fetch(submit.response_url, { headers, signal: AbortSignal.timeout(60_000) });
  if (!outRes.ok) {
    // fal surfaces generation-side failures as a non-200 on the response
    // fetch after a COMPLETED status — the body says why (e.g. "Image
    // resolution only support [128, 5000]", 2026-08-23), so keep it.
    throw new Error(`lift3d result HTTP ${outRes.status}: ${(await outRes.text()).slice(0, 300)}`);
  }
  const out = (await outRes.json()) as {
    model_urls?: Record<string, unknown>;
    thumbnail?: unknown;
  };

  // The endpoint's schema advertises usdz but returns null (measured
  // 2026-07-19); GLB is the reliable, fully-textured artifact. The iPad
  // loads it via GLTFKit2 -> SceneKit.
  const glbUrl = fileUrl(out.model_urls?.['glb']) ?? fileUrl((out as { model_glb?: unknown }).model_glb);
  if (!glbUrl) throw new Error('lift3d result has no glb');
  const glbRes = await fetch(glbUrl, { signal: AbortSignal.timeout(120_000) });
  if (!glbRes.ok) throw new Error(`lift3d glb download HTTP ${glbRes.status}`);
  const glb = Buffer.from(await glbRes.arrayBuffer());

  let thumbnail: Buffer | null = null;
  const thumbUrl = fileUrl(out.thumbnail);
  if (thumbUrl) {
    const tRes = await fetch(thumbUrl, { signal: AbortSignal.timeout(30_000) }).catch(() => null);
    if (tRes?.ok) thumbnail = Buffer.from(await tRes.arrayBuffer());
  }

  return { glb, thumbnail, elapsedMs: Date.now() - t0 };
}

/**
 * Hosted (fal.ai) video engines for the Animate screen — the "try fal's best
 * model" toggle next to our self-hosted LTX pool (2026-09-10).
 *
 * The iPad's `animate_request` carries `engine`: `ltx` (default — the Lambda
 * H100 LTX-2.5 pool, relayed by AnimateSession) or one of the hosted engines
 * below, which the route runs through fal's QUEUE API (submit → poll →
 * download; never fal.run sync — generations take 30-120 s and the sync LB
 * drops long jobs, same lesson as falLift3d). The result is delivered on the
 * SAME wire shapes the iPad already parses (`video_started` →
 * `video_complete_data`), just without the streamed preview frames.
 *
 * Engine table (Artificial Analysis image-to-video arena, 2026-09):
 *  - `wan3`   Alibaba Wan 3.0 — Elo 1358 without audio (#2 overall), takes a
 *             start AND end frame, native audio toggle. $0.10/s at 720p.
 *  - `h3max`  MiniMax H3 Max (post-trained by fal) — Elo 1200 with audio
 *             (#1 with audio), start + end frame, always audio, minimum 5 s.
 *             $0.08/s at 768P list ($0.30 flat promo until 2026-09-14).
 *
 * Hosted engines map our keyframe contract down to what they accept:
 * position 0 → first frame, position 1 → last frame; any mid-video keyframe
 * is dropped with a log line (only LTX conditions on arbitrary positions).
 * Duration = numFrames / 24 rounded to whole seconds (the presets are
 * 2/4/6 s exactly).
 *
 * Metering: pass-through fal cost (price/s × seconds) into `monthly_usage`,
 * charged in the route on delivery — so the $10 free tier buys ~25 six-second
 * Wan clips vs ~200 LTX clips, which is the honest tradeoff the toggle exists
 * to compare.
 */

import { config } from '../../config/index.js';

export type HostedEngineId = 'wan3' | 'h3max';
export type AnimateEngineId = 'ltx' | HostedEngineId;

export const ANIMATE_ENGINE_IDS: readonly AnimateEngineId[] = ['ltx', 'wan3', 'h3max'];

export function isHostedEngine(id: AnimateEngineId): id is HostedEngineId {
  return id === 'wan3' || id === 'h3max';
}

export function parseEngineId(raw: unknown): AnimateEngineId {
  return typeof raw === 'string' && (ANIMATE_ENGINE_IDS as readonly string[]).includes(raw)
    ? (raw as AnimateEngineId)
    : 'ltx';
}

export interface HostedEngineSpec {
  id: HostedEngineId;
  /** fal endpoint id (queue.fal.run/<model>). */
  model: string;
  /** Human label for logs/Insights. */
  label: string;
  /** Resolution tier sent to fal (env-overridable per engine). */
  resolution: string;
  /** fal list price per generated second at `resolution`. */
  usdPerSecond: number;
  /** Whether the engine honors the audio on/off toggle. */
  audioToggle: boolean;
  /** Allowed duration range in whole seconds. */
  minSeconds: number;
  maxSeconds: number;
}

const WAN_PRICES: Record<string, number> = { '480p': 0.05, '720p': 0.1, '1080p': 0.2 };
const WAN_DEFAULT_USD_PER_SECOND = 0.1;
const H3_PRICES: Record<string, number> = { '480P': 0.05, '768P': 0.08, '1080P': 0.13 };
const H3_DEFAULT_USD_PER_SECOND = 0.08;

export function hostedEngineSpec(id: HostedEngineId): HostedEngineSpec {
  switch (id) {
    case 'wan3': {
      const resolution = process.env['FAL_WAN3_RESOLUTION'] ?? '720p';
      return {
        id,
        model: 'alibaba/wan-3.0/image-to-video',
        label: 'Wan 3.0',
        resolution,
        usdPerSecond: WAN_PRICES[resolution] ?? WAN_DEFAULT_USD_PER_SECOND,
        audioToggle: true,
        minSeconds: 2,
        maxSeconds: 30,
      };
    }
    case 'h3max': {
      const resolution = process.env['FAL_H3MAX_RESOLUTION'] ?? '768P';
      return {
        id,
        model: 'minimax/h3-max/image-to-video',
        label: 'MiniMax H3 Max',
        resolution,
        usdPerSecond: H3_PRICES[resolution] ?? H3_DEFAULT_USD_PER_SECOND,
        audioToggle: false,
        // fal rejects duration < 5 (422 "greater_than_equal", measured
        // 2026-09-10), so the 2 s / 4 s presets round up to a 5 s clip.
        minSeconds: 5,
        maxSeconds: 15,
      };
    }
  }
}

export interface HostedAnimateInput {
  engine: HostedEngineId;
  /** Composed model prompt (motion + optional "Sound: …" clause). */
  prompt: string;
  /** base64 JPEG/PNG, first frame. */
  startImageB64: string;
  /** base64 JPEG/PNG, last frame (optional). */
  endImageB64?: string;
  /** Whole seconds (already clamped to the engine range by the caller). */
  durationSeconds: number;
  enableAudio: boolean;
  seed?: number;
}

export interface HostedAnimateResult {
  mp4: Buffer;
  elapsedMs: number;
  /** Seconds fal reports (Wan) or the requested duration. */
  durationSeconds: number;
  /** Pass-through cost charged for this generation. */
  costUsd: number;
  /** The prompt the provider actually ran, when it rewrites it. */
  actualPrompt: string | null;
}

interface QueueSubmit {
  status_url?: string;
  response_url?: string;
  cancel_url?: string;
}

const SUBMIT_TIMEOUT_MS = 60_000;
const POLL_INTERVAL_MS = 2_500;
const TOTAL_TIMEOUT_MS = 12 * 60_000;

function dataUri(b64: string): string {
  // The iPad sends JPEG (keyframeB64) but a PNG from a dev harness is fine
  // too — sniff the magic so the data URI's media type is honest.
  const head = Buffer.from(b64.slice(0, 16), 'base64');
  const isPng = head.length >= 4 && head[0] === 0x89 && head[1] === 0x50;
  return `data:image/${isPng ? 'png' : 'jpeg'};base64,${b64}`;
}

function fileUrl(v: unknown): string | null {
  if (typeof v === 'string') return v;
  if (v && typeof v === 'object' && typeof (v as { url?: unknown }).url === 'string') {
    return (v as { url: string }).url;
  }
  return null;
}

/** Build the provider-specific request body. Exported for tests. */
export function hostedRequestBody(spec: HostedEngineSpec, input: HostedAnimateInput): Record<string, unknown> {
  const seconds = Math.min(spec.maxSeconds, Math.max(spec.minSeconds, Math.round(input.durationSeconds)));
  switch (spec.id) {
    case 'wan3': {
      const body: Record<string, unknown> = {
        prompt: input.prompt,
        start_image_url: dataUri(input.startImageB64),
        resolution: spec.resolution,
        duration: seconds,
        audio: input.enableAudio,
        // Follow the keyframe's own aspect (our keyframes are square).
        aspect_ratio: 'adaptive',
      };
      if (input.endImageB64) body['end_image_url'] = dataUri(input.endImageB64);
      if (typeof input.seed === 'number') body['seed'] = Math.trunc(input.seed) & 0x7fffffff;
      return body;
    }
    case 'h3max': {
      const body: Record<string, unknown> = {
        prompt: input.prompt,
        image_url: dataUri(input.startImageB64),
        resolution: spec.resolution,
        duration: seconds,
        prompt_expansion_mode: 'balanced',
      };
      if (input.endImageB64) body['end_image_url'] = dataUri(input.endImageB64);
      if (typeof input.seed === 'number') body['seed'] = Math.trunc(input.seed) & 0x7fffffff;
      return body;
    }
  }
}

/**
 * Run one hosted generation end to end. `signal` aborts the poll loop AND
 * asks fal to cancel the queued job (best-effort PUT on cancel_url) so a
 * user who leaves the screen doesn't keep paying for a render nobody sees.
 */
export async function falAnimate(
  input: HostedAnimateInput,
  opts: { signal?: AbortSignal; fetchImpl?: typeof fetch } = {},
): Promise<HostedAnimateResult> {
  if (!config.FAL_KEY) throw new Error('FAL_KEY not configured');
  const fetchImpl = opts.fetchImpl ?? fetch;
  const spec = hostedEngineSpec(input.engine);
  const headers = {
    Authorization: `Key ${config.FAL_KEY}`,
    'Content-Type': 'application/json',
  };
  const t0 = Date.now();
  const body = hostedRequestBody(spec, input);
  const seconds = body['duration'] as number;

  const submitRes = await fetchImpl(`https://queue.fal.run/${spec.model}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.any([AbortSignal.timeout(SUBMIT_TIMEOUT_MS), ...(opts.signal ? [opts.signal] : [])]),
  });
  if (!submitRes.ok) {
    throw new Error(`${spec.label} submit HTTP ${submitRes.status}: ${(await submitRes.text()).slice(0, 300)}`);
  }
  const submit = (await submitRes.json()) as QueueSubmit;
  if (!submit.status_url || !submit.response_url) throw new Error(`${spec.label} submit missing queue urls`);

  const cancelUpstream = (): void => {
    if (!submit.cancel_url) return;
    void fetchImpl(submit.cancel_url, { method: 'PUT', headers, signal: AbortSignal.timeout(10_000) }).catch(
      () => {},
    );
  };

  for (;;) {
    if (opts.signal?.aborted) {
      cancelUpstream();
      throw new Error('cancelled');
    }
    if (Date.now() - t0 > TOTAL_TIMEOUT_MS) {
      cancelUpstream();
      throw new Error(`${spec.label} timed out`);
    }
    const stRes = await fetchImpl(submit.status_url, { headers, signal: AbortSignal.timeout(30_000) }).catch(
      () => null,
    );
    if (stRes?.ok) {
      const stText = await stRes.text();
      const st = JSON.parse(stText) as { status?: string };
      if (st.status === 'COMPLETED') break;
      if (st.status === 'FAILED') throw new Error(`${spec.label} generation failed: ${stText.slice(0, 300)}`);
    }
    await new Promise<void>((resolve) => {
      const timer = setTimeout(resolve, POLL_INTERVAL_MS);
      opts.signal?.addEventListener('abort', () => { clearTimeout(timer); resolve(); }, { once: true });
    });
  }

  const outRes = await fetchImpl(submit.response_url, { headers, signal: AbortSignal.timeout(60_000) });
  if (!outRes.ok) {
    // fal surfaces generation-side failures (safety checker, bad input) as a
    // non-200 on the response fetch after a COMPLETED status — keep the body.
    throw new Error(`${spec.label} result HTTP ${outRes.status}: ${(await outRes.text()).slice(0, 300)}`);
  }
  const out = (await outRes.json()) as {
    video?: unknown;
    duration?: number;
    actual_prompt?: string | null;
    expanded_prompt?: string | null;
  };
  const videoUrl = fileUrl(out.video);
  if (!videoUrl) throw new Error(`${spec.label} result has no video`);
  const vidRes = await fetchImpl(videoUrl, { signal: AbortSignal.timeout(120_000) });
  if (!vidRes.ok) throw new Error(`${spec.label} video download HTTP ${vidRes.status}`);
  const mp4 = Buffer.from(await vidRes.arrayBuffer());

  const durationSeconds = typeof out.duration === 'number' && out.duration > 0 ? out.duration : seconds;
  return {
    mp4,
    elapsedMs: Date.now() - t0,
    durationSeconds,
    costUsd: Number((durationSeconds * spec.usdPerSecond).toFixed(4)),
    actualPrompt: out.actual_prompt ?? out.expanded_prompt ?? null,
  };
}

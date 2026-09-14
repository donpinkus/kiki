/**
 * Unit tests for the hosted (fal) Animate engines: provider request-body
 * mapping (keyframes → first/last frame, duration clamp, audio toggle) and
 * the queue submit → poll → download flow against a fake fetch, including
 * cancel-mid-poll asking fal to cancel the job.
 */
import { afterEach, beforeAll, describe, expect, it } from 'vitest';

process.env['FAL_KEY'] = 'test-fal-key';

const PNG_B64 = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4]).toString('base64');
const JPEG_B64 = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 0, 0x10, 0x4a, 0x46, 0x49, 0x46, 0, 1]).toString('base64');

// Dynamic import so FAL_KEY above lands before the config singleton reads it.
const importFal = () => import('./falAnimate.js');
type FalAnimateModule = Awaited<ReturnType<typeof importFal>>;
let mod: FalAnimateModule;

beforeAll(async () => {
  mod = await importFal();
});

afterEach(() => {
  delete process.env['FAL_WAN3_RESOLUTION'];
});

describe('hostedRequestBody', () => {
  it('maps wan3: start+end data URIs, duration clamp, audio toggle, seed', () => {
    const spec = mod.hostedEngineSpec('wan3');
    const body = mod.hostedRequestBody(spec, {
      engine: 'wan3', prompt: 'p', startImageB64: JPEG_B64, endImageB64: PNG_B64,
      durationSeconds: 1, enableAudio: false, seed: -5,
    });
    expect(body['start_image_url']).toBe(`data:image/jpeg;base64,${JPEG_B64}`);
    expect(body['end_image_url']).toBe(`data:image/png;base64,${PNG_B64}`);
    expect(body['duration']).toBe(2); // clamped up to the engine minimum
    expect(body['audio']).toBe(false);
    expect(body['resolution']).toBe('720p');
    expect(body['seed']).toBeGreaterThanOrEqual(0);
    expect(body['aspect_ratio']).toBe('adaptive');
  });

  it('maps h3max: image_url/end_image_url, prompt_expansion_mode, no audio field, 5 s floor', () => {
    const spec = mod.hostedEngineSpec('h3max');
    const short = mod.hostedRequestBody(spec, {
      engine: 'h3max', prompt: 'p', startImageB64: JPEG_B64, durationSeconds: 2, enableAudio: true,
    });
    expect(short['duration']).toBe(5); // fal 422s below 5 s
    const body = mod.hostedRequestBody(spec, {
      engine: 'h3max', prompt: 'p', startImageB64: JPEG_B64, durationSeconds: 40, enableAudio: true,
    });
    expect(body['image_url']).toMatch(/^data:image\/jpeg;base64,/);
    expect(body['end_image_url']).toBeUndefined();
    expect(body['duration']).toBe(15); // clamped to the engine maximum
    expect(body['prompt_expansion_mode']).toBe('balanced');
    expect(body['audio']).toBeUndefined();
    expect(body['resolution']).toBe('768P');
  });

  it('honours the per-engine resolution env and prices it', () => {
    process.env['FAL_WAN3_RESOLUTION'] = '480p';
    const spec = mod.hostedEngineSpec('wan3');
    expect(spec.resolution).toBe('480p');
    expect(spec.usdPerSecond).toBe(0.05);
  });

  it('parseEngineId falls back to ltx', () => {
    expect(mod.parseEngineId('wan3')).toBe('wan3');
    expect(mod.parseEngineId('h3max')).toBe('h3max');
    expect(mod.parseEngineId('nope')).toBe('ltx');
    expect(mod.parseEngineId(undefined)).toBe('ltx');
  });
});

interface FakeCall { url: string; method: string; body?: unknown }

function fakeFetch(opts: { statuses: string[]; result?: Record<string, unknown>; video?: Buffer }) {
  const calls: FakeCall[] = [];
  let statusIdx = 0;
  const video = opts.video ?? Buffer.from('mp4-bytes');
  const impl = (async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    const method = init?.method ?? 'GET';
    calls.push({ url, method, body: init?.body ? JSON.parse(String(init.body)) : undefined });
    if (url.startsWith('https://queue.fal.run/')) {
      return new Response(JSON.stringify({
        status_url: 'https://q/status', response_url: 'https://q/response', cancel_url: 'https://q/cancel',
      }), { status: 200 });
    }
    if (url === 'https://q/status') {
      const st = opts.statuses[Math.min(statusIdx, opts.statuses.length - 1)] ?? 'COMPLETED';
      statusIdx += 1;
      return new Response(JSON.stringify({ status: st }), { status: 200 });
    }
    if (url === 'https://q/response') {
      return new Response(JSON.stringify(opts.result ?? { video: { url: 'https://cdn/v.mp4' }, duration: 4 }), { status: 200 });
    }
    if (url === 'https://cdn/v.mp4') return new Response(video, { status: 200 });
    if (url === 'https://q/cancel') return new Response('{}', { status: 200 });
    return new Response('nope', { status: 404 });
  }) as typeof fetch;
  return { impl, calls };
}

describe('falAnimate queue flow', () => {
  it('submits, polls to COMPLETED, downloads the MP4 and prices by reported duration', async () => {
    const f = fakeFetch({ statuses: ['IN_QUEUE', 'IN_PROGRESS', 'COMPLETED'] });
    const res = await mod.falAnimate(
      { engine: 'wan3', prompt: 'p', startImageB64: JPEG_B64, durationSeconds: 4, enableAudio: true },
      { fetchImpl: f.impl },
    );
    expect(res.mp4.toString()).toBe('mp4-bytes');
    expect(res.durationSeconds).toBe(4);
    expect(res.costUsd).toBeCloseTo(0.4, 4); // 4 s × $0.10 (720p)
    const submit = f.calls[0];
    expect(submit?.url).toBe('https://queue.fal.run/alibaba/wan-3.0/image-to-video');
    expect((submit?.body as Record<string, unknown>)['duration']).toBe(4);
    expect(f.calls.filter((c) => c.url === 'https://q/status').length).toBe(3);
  }, 20_000);

  it('surfaces a FAILED status as an error', async () => {
    const f = fakeFetch({ statuses: ['FAILED'] });
    await expect(
      mod.falAnimate(
        { engine: 'h3max', prompt: 'p', startImageB64: JPEG_B64, durationSeconds: 4, enableAudio: true },
        { fetchImpl: f.impl },
      ),
    ).rejects.toThrow(/generation failed/);
  });

  it('abort mid-poll rejects with "cancelled" and PUTs the fal cancel_url', async () => {
    const f = fakeFetch({ statuses: ['IN_QUEUE'] });
    const abort = new AbortController();
    const p = mod.falAnimate(
      { engine: 'wan3', prompt: 'p', startImageB64: JPEG_B64, durationSeconds: 4, enableAudio: true },
      { fetchImpl: f.impl, signal: abort.signal },
    );
    // Let the submit + first status round-trip happen, then cancel.
    await new Promise((r) => setTimeout(r, 50));
    abort.abort();
    await expect(p).rejects.toThrow(/cancelled/);
    await new Promise((r) => setTimeout(r, 20));
    expect(f.calls.some((c) => c.url === 'https://q/cancel' && c.method === 'PUT')).toBe(true);
  });
});

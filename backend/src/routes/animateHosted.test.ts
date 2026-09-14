/**
 * Route-level e2e of the hosted-engine branch of /v1/animate: an
 * animate_request with engine=wan3 bypasses the LTX relay entirely, runs the
 * (mocked) fal job, and answers with video_started → video_complete_data
 * carrying the engine + cost meta; cancel mid-flight aborts the job and
 * answers video_cancelled; a fal failure answers video_cancelled(hosted_failed).
 */
import type { AddressInfo } from 'node:net';
import { WebSocket as WsClient } from 'ws';
import { afterAll, beforeAll, describe, expect, it, vi } from 'vitest';

const falAnimate = vi.fn();
vi.mock('../modules/video/falAnimate.js', async (importOriginal) => {
  const actual = (await importOriginal()) as Record<string, unknown>;
  return { ...actual, falAnimate };
});

const KEYFRAME_A = Buffer.from('keyframe-a-jpeg').toString('base64');
const KEYFRAME_B = Buffer.from('keyframe-b-jpeg').toString('base64');

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
async function until(cond: () => boolean, timeoutMs = 10_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error('until() timed out');
    await sleep(10);
  }
}

async function openClient(url: string): Promise<{ client: WsClient; messages: Array<Record<string, unknown>> }> {
  const client = new WsClient(url);
  const messages: Array<Record<string, unknown>> = [];
  client.on('message', (raw) => messages.push(JSON.parse(raw.toString()) as Record<string, unknown>));
  await new Promise<void>((res, rej) => {
    client.on('open', () => res());
    client.on('error', rej);
  });
  return { client, messages };
}

describe('animate route — hosted fal engines', { timeout: 30_000 }, () => {
  let app: { close: () => Promise<void> };
  let appUrl: string;

  beforeAll(async () => {
    // No LTX at all: the hosted branch must not need a video instance/pool.
    delete process.env['LAMBDA_VIDEO_URL'];
    process.env['FAL_KEY'] = 'test-fal-key';
    const { default: Fastify } = await import('fastify');
    const { default: websocket } = await import('@fastify/websocket');
    const { animateRoute } = await import('./animate.js');
    const fastify = Fastify({ logger: false });
    await fastify.register(websocket, { options: { maxPayload: 64 * 1024 * 1024 } });
    await fastify.register(animateRoute);
    await fastify.listen({ port: 0, host: '127.0.0.1' });
    app = fastify as unknown as typeof app;
    const addr = fastify.server.address() as AddressInfo;
    appUrl = `ws://127.0.0.1:${addr.port}/v1/animate?session=test-user`;
  });

  afterAll(async () => {
    await app?.close();
  });

  it('engine=wan3 runs the fal job and delivers video_complete_data with engine + cost meta', async () => {
    falAnimate.mockReset();
    falAnimate.mockImplementation(async (input: Record<string, unknown>) => {
      expect(input['engine']).toBe('wan3');
      expect(input['startImageB64']).toBe(KEYFRAME_A);
      expect(input['endImageB64']).toBe(KEYFRAME_B);
      expect(input['durationSeconds']).toBe(4); // 97 frames / 24 fps
      expect(String(input['prompt'])).toMatch(/Sound: rain/);
      return { mp4: Buffer.from('hosted-mp4'), elapsedMs: 1234, durationSeconds: 4, costUsd: 0.4, actualPrompt: null };
    });
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'h-1', engine: 'wan3', prompt: 'drift', audioPrompt: 'rain',
      enableAudio: true, numFrames: 97,
      keyframes: [{ data: KEYFRAME_A, position: 0 }, { data: KEYFRAME_B, position: 1 }],
    }));
    await until(() => messages.some((m) => m['type'] === 'video_complete_data'));
    expect(messages.some((m) => m['type'] === 'video_started' && m['requestId'] === 'h-1')).toBe(true);
    const complete = messages.find((m) => m['type'] === 'video_complete_data');
    if (!complete) throw new Error('no video_complete_data');
    expect(Buffer.from(String(complete['data']), 'base64').toString()).toBe('hosted-mp4');
    const meta = complete['meta'] as Record<string, unknown>;
    expect(meta['requestId']).toBe('h-1');
    expect(meta['engine']).toBe('wan3');
    expect(meta['costUsd']).toBe(0.4);
    expect(meta['fps']).toBe(24);
    expect(meta['frames']).toBe(96); // 4 s delivered × 24 fps nominal
    // Session-auth (non-JWT) clients aren't metered; the socket stays open.
    expect(messages.some((m) => m['type'] === 'video_cancelled')).toBe(false);
    client.close();
  });

  it('animate_cancel mid-flight aborts the fal job and answers video_cancelled', async () => {
    falAnimate.mockReset();
    let sawAbort = false;
    falAnimate.mockImplementation((_input: unknown, opts: { signal?: AbortSignal }) =>
      new Promise((_resolve, reject) => {
        opts.signal?.addEventListener('abort', () => { sawAbort = true; reject(new Error('cancelled')); });
      }),
    );
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'h-2', engine: 'h3max', prompt: 'x', numFrames: 49,
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    await until(() => messages.some((m) => m['type'] === 'video_started'));
    client.send(JSON.stringify({ type: 'animate_cancel', requestId: 'h-2' }));
    await until(() => messages.some((m) => m['type'] === 'video_cancelled' && m['requestId'] === 'h-2'));
    await until(() => sawAbort);
    expect(messages.filter((m) => m['type'] === 'video_cancelled').length).toBe(1);
    // A follow-up request is accepted (in-flight slot was released).
    falAnimate.mockImplementation(async () => ({
      mp4: Buffer.from('ok'), elapsedMs: 1, durationSeconds: 2, costUsd: 0.16, actualPrompt: null,
    }));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'h-3', engine: 'h3max', prompt: 'x', numFrames: 49,
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    await until(() => messages.some((m) => m['type'] === 'video_complete_data'));
    client.close();
  });

  it('a fal failure answers video_cancelled(hosted_failed) and frees the slot', async () => {
    falAnimate.mockReset();
    falAnimate.mockRejectedValueOnce(new Error('Wan 3.0 generation failed: boom'));
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'h-4', engine: 'wan3', prompt: 'x', numFrames: 49,
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    await until(() => messages.some((m) => m['type'] === 'video_cancelled'));
    const cancelled = messages.find((m) => m['type'] === 'video_cancelled');
    expect(cancelled?.['requestId']).toBe('h-4');
    expect(cancelled?.['error']).toBe('hosted_failed');
    client.close();
  });

  it('engine=ltx with no video instance still answers video_unavailable', async () => {
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'l-1', prompt: 'x', numFrames: 49,
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    await until(() => messages.some((m) => m['type'] === 'video_cancelled'));
    expect(messages.find((m) => m['type'] === 'video_cancelled')?.['error']).toBe('video_unavailable');
    client.close();
  });
});

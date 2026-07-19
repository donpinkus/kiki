/**
 * Route-level e2e of /v1/animate: a real Fastify app, a mock Lambda VIDEO
 * server speaking the model-servers/video/server.py wire protocol (including
 * the new multi-keyframe video_request shape), and a fake iPad client.
 *
 * Env is set BEFORE the dynamic import of the route (config is a singleton
 * validated at first import; vitest runs each file in a fresh module graph).
 */
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, WebSocket as WsClient, type WebSocket as WsSocket } from 'ws';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { DEFAULT_ANIMATION_PROMPT } from '../modules/video/animateSession.js';

const VIDEO_JPEG = Buffer.from('video-frame-jpeg');
const VIDEO_MP4 = Buffer.from('video-mp4-bytes');
const KEYFRAME_A = Buffer.from('keyframe-a-jpeg').toString('base64');
const KEYFRAME_B = Buffer.from('keyframe-b-jpeg').toString('base64');

interface MockUpstream {
  url: string;
  received: Array<Record<string, unknown>>;
  pending: Array<{ ws: WsSocket; requestId: string }>;
  completeRequest: (p: { ws: WsSocket; requestId: string }) => void;
  close: () => Promise<void>;
}

/** Mock of model-servers/video/server.py. */
function startMockVideoServer(opts: { holdCompletion?: boolean } = {}): Promise<MockUpstream> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    const received: Array<Record<string, unknown>> = [];
    const pending: Array<{ ws: WsSocket; requestId: string }> = [];
    const completeRequest = ({ ws, requestId }: { ws: WsSocket; requestId: string }): void => {
      ws.send(JSON.stringify({ type: 'video_frame', requestId, index: 0, total: 1 }));
      ws.send(VIDEO_JPEG);
      ws.send(JSON.stringify({ type: 'video_complete', requestId, fps: 24, frames: 1, genMs: 5 }));
      ws.send(VIDEO_MP4);
    };
    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'status', status: 'ready' }));
      ws.on('message', (raw, isBinary) => {
        if (isBinary) return;
        const msg = JSON.parse(raw.toString()) as Record<string, unknown>;
        received.push(msg);
        if (msg['type'] === 'video_request') {
          const requestId = String(msg['requestId']);
          if (opts.holdCompletion) pending.push({ ws, requestId });
          else completeRequest({ ws, requestId });
        } else if (msg['type'] === 'video_cancel') {
          const requestId = String(msg['requestId']);
          const idx = pending.findIndex((p) => p.requestId === requestId);
          if (idx !== -1) pending.splice(idx, 1);
          ws.send(JSON.stringify({ type: 'video_cancelled', requestId, atStep: 1 }));
        }
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        url: `ws://127.0.0.1:${port}/ws`,
        received,
        pending,
        completeRequest,
        close: () => new Promise<void>((res) => { wss.close(); server.close(() => res()); }),
      });
    });
  });
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

async function until(cond: () => boolean, timeoutMs = 10_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error('until() timed out');
    await sleep(10);
  }
}

async function openClient(url: string): Promise<{
  client: WsClient;
  messages: Array<Record<string, unknown>>;
}> {
  const client = new WsClient(url);
  const messages: Array<Record<string, unknown>> = [];
  client.on('message', (raw) => {
    messages.push(JSON.parse(raw.toString()) as Record<string, unknown>);
  });
  await new Promise<void>((res, rej) => {
    client.on('open', () => res());
    client.on('error', rej);
  });
  return { client, messages };
}

describe('animate route (e2e with mock lambda video server)', { timeout: 30_000 }, () => {
  let mockVideo: MockUpstream;
  let app: { close: () => Promise<void> } & Record<string, unknown>;
  let appUrl: string;

  beforeAll(async () => {
    mockVideo = await startMockVideoServer();

    // Must be set before the config singleton loads (dynamic imports below).
    process.env['LAMBDA_VIDEO_URL'] = mockVideo.url;

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
    await mockVideo?.close();
  });

  it('pushes availability at open (static URL reads ready)', async () => {
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    const avail = messages.find((m) => m['type'] === 'system_availability');
    expect((avail?.['video'] as Record<string, unknown>)['availability']).toBe('ready');
    client.close();
  });

  it('relays a multi-keyframe animate_request and streams the video back', async () => {
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));

    client.send(JSON.stringify({
      type: 'animate_request',
      requestId: 'anim-1',
      prompt: 'the fox runs across the meadow',
      numFrames: 97,
      keyframes: [
        { data: KEYFRAME_A, position: 0 },
        { data: KEYFRAME_B, position: 1, strength: 0.8 },
      ],
    }));

    // Upstream receives the model-server keyframe shape.
    await until(() => mockVideo.received.some((m) => m['type'] === 'video_request'));
    const req = mockVideo.received.find((m) => m['type'] === 'video_request');
    expect(req?.['prompt']).toBe('the fox runs across the meadow');
    expect(req?.['videoFrames']).toBe(97);
    const kfs = req?.['keyframes'] as Array<Record<string, unknown>>;
    expect(kfs).toHaveLength(2);
    expect(kfs[0]).toMatchObject({ image_b64: KEYFRAME_A, position: 0, strength: 1 });
    expect(kfs[1]).toMatchObject({ image_b64: KEYFRAME_B, position: 1, strength: 0.8 });

    // Client contract: started → wrapped frame/complete data.
    await until(() => messages.some((m) => m['type'] === 'video_complete_data'));
    const started = messages.find((m) => m['type'] === 'video_started');
    expect(started?.['requestId']).toBe('anim-1');
    const vFrame = messages.find((m) => m['type'] === 'video_frame_data');
    expect(vFrame?.['data']).toBe(VIDEO_JPEG.toString('base64'));
    const vComplete = messages.find((m) => m['type'] === 'video_complete_data');
    expect(vComplete?.['data']).toBe(VIDEO_MP4.toString('base64'));
    expect((vComplete?.['meta'] as Record<string, unknown>)['requestId']).toBe('anim-1');
    client.close();
  });

  it('empty prompt falls back to the default motion prompt', async () => {
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    const before = mockVideo.received.filter((m) => m['type'] === 'video_request').length;
    client.send(JSON.stringify({
      type: 'animate_request',
      requestId: 'anim-default-prompt',
      prompt: '   ',
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    await until(() => mockVideo.received.filter((m) => m['type'] === 'video_request').length > before);
    const req = mockVideo.received.filter((m) => m['type'] === 'video_request').at(-1);
    expect(req?.['prompt']).toBe(DEFAULT_ANIMATION_PROMPT);
    client.close();
  });

  it('rejects a request with no keyframes via video_cancelled(no_image)', async () => {
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({ type: 'animate_request', requestId: 'anim-2', prompt: 'x', keyframes: [] }));
    await until(() => messages.some((m) => m['type'] === 'video_cancelled'));
    const cancelled = messages.find((m) => m['type'] === 'video_cancelled');
    expect(cancelled?.['requestId']).toBe('anim-2');
    expect(cancelled?.['error']).toBe('no_image');
    expect(mockVideo.received.some((m) => m['requestId'] === 'anim-2')).toBe(false);
    client.close();
  });

  it('rejects oversized keyframe payloads', async () => {
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({
      type: 'animate_request',
      requestId: 'anim-3',
      prompt: 'x',
      keyframes: [{ data: 'a'.repeat(8_000_001), position: 0 }],
    }));
    await until(() => messages.some((m) => m['type'] === 'video_cancelled'));
    expect(messages.find((m) => m['type'] === 'video_cancelled')?.['error']).toBe('keyframe_too_large');
    client.close();
  });

  it('back-to-back requests both get terminal replies (complete or busy-cancel)', async () => {
    // The config singleton pins LAMBDA_VIDEO_URL to the instant-complete
    // mock, so the second request either lands after the first completes or
    // is refused 'busy' — both are valid; the invariant is that every
    // request gets exactly one terminal reply so the iPad button resets.
    // (Strict busy/cancel ordering is covered in animateSession.test.ts
    // with a holding mock.)
    const { client, messages } = await openClient(appUrl);
    await until(() => messages.some((m) => m['type'] === 'system_availability'));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'anim-4a', prompt: 'x',
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    client.send(JSON.stringify({
      type: 'animate_request', requestId: 'anim-4b', prompt: 'x',
      keyframes: [{ data: KEYFRAME_A, position: 0 }],
    }));
    await until(() =>
      ['anim-4a', 'anim-4b'].every((id) =>
        messages.some(
          (m) =>
            (m['type'] === 'video_complete_data' &&
              (m['meta'] as Record<string, unknown>)['requestId'] === id) ||
            (m['type'] === 'video_cancelled' && m['requestId'] === id),
        ),
      ),
    );
    client.close();
  });
});

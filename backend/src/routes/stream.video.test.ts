/**
 * Route-level e2e of the video idle-trigger wiring in stream.ts: a real
 * Fastify app serving /v1/stream, a mock Lambda IMAGE server, a mock Lambda
 * VIDEO server (both speaking the model-servers wire protocols), and a fake
 * iPad client. Proves the full path the POC ships:
 *
 *   iPad sketch → image relay → generated frame → (3s idle, scaled to 150ms)
 *   → video_request(latest generated image + prompt) → video instance
 *   → video_frame_data / video_complete_data back to the iPad.
 *
 * Env is set BEFORE the dynamic import of the route (config is a singleton
 * validated at first import; vitest runs each file in a fresh module graph).
 */
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, WebSocket as WsClient } from 'ws';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';

const GENERATED_JPEG = Buffer.from('generated-jpeg-from-image-server');
const VIDEO_JPEG = Buffer.from('video-frame-jpeg');
const VIDEO_MP4 = Buffer.from('video-mp4-bytes');

interface MockUpstream {
  url: string;
  received: Array<Record<string, unknown>>;
  close: () => Promise<void>;
}

/** Mock of model-servers/image/server.py: every binary sketch frame produces
 * frame_meta + a generated JPEG. */
function startMockImageServer(): Promise<MockUpstream> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    const received: Array<Record<string, unknown>> = [];
    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'status', status: 'ready' }));
      ws.on('message', (raw, isBinary) => {
        if (isBinary) {
          ws.send(JSON.stringify({ type: 'frame_meta', requestId: null, queueEmpty: true }));
          ws.send(GENERATED_JPEG);
        } else {
          received.push(JSON.parse(raw.toString()) as Record<string, unknown>);
        }
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        url: `ws://127.0.0.1:${port}/ws`,
        received,
        close: () => new Promise<void>((res) => { wss.close(); server.close(() => res()); }),
      });
    });
  });
}

/** Mock of model-servers/video/server.py. */
function startMockVideoServer(): Promise<MockUpstream> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    const received: Array<Record<string, unknown>> = [];
    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'status', status: 'ready' }));
      ws.on('message', (raw, isBinary) => {
        if (isBinary) return;
        const msg = JSON.parse(raw.toString()) as Record<string, unknown>;
        received.push(msg);
        if (msg['type'] === 'video_request') {
          const requestId = String(msg['requestId']);
          ws.send(JSON.stringify({ type: 'video_frame', requestId, index: 0, total: 1 }));
          ws.send(VIDEO_JPEG);
          ws.send(JSON.stringify({ type: 'video_complete', requestId, fps: 24, frames: 1 }));
          ws.send(VIDEO_MP4);
        }
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      resolve({
        url: `ws://127.0.0.1:${port}/ws`,
        received,
        close: () => new Promise<void>((res) => { wss.close(); server.close(() => res()); }),
      });
    });
  });
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Generous timeout: container CPU contention can stall the event loop for
 * seconds (source of flaky until() timeouts on otherwise-fast assertions). */
async function until(cond: () => boolean, timeoutMs = 10_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error('until() timed out');
    await sleep(10);
  }
}

describe('stream route video wiring (e2e with mock lambda image + video servers)', { timeout: 30_000 }, () => {
  let mockImage: MockUpstream;
  let mockVideo: MockUpstream;
  // Fastify instance type comes from the dynamic import; kept loose here.
  let app: { listen: (o: { port: number; host: string }) => Promise<string>; close: () => Promise<void>; register: (p: unknown) => unknown } & Record<string, unknown>;
  let appUrl: string;

  beforeAll(async () => {
    mockImage = await startMockImageServer();
    mockVideo = await startMockVideoServer();

    // Must be set before the config singleton loads (dynamic imports below).
    process.env['IMAGE_PROVIDER'] = 'lambda';
    process.env['LAMBDA_IMAGE_URL'] = mockImage.url;
    process.env['LAMBDA_VIDEO_URL'] = mockVideo.url;
    process.env['VIDEO_IDLE_TRIGGER_MS'] = '150';

    const { default: Fastify } = await import('fastify');
    const { default: websocket } = await import('@fastify/websocket');
    const { streamRoute } = await import('./stream.js');

    const fastify = Fastify({ logger: false });
    await fastify.register(websocket);
    await fastify.register(streamRoute);
    await fastify.listen({ port: 0, host: '127.0.0.1' });
    app = fastify as unknown as typeof app;
    const addr = fastify.server.address() as AddressInfo;
    appUrl = `ws://127.0.0.1:${addr.port}/v1/stream?session=test-user`;
  });

  afterAll(async () => {
    await app?.close();
    await mockImage?.close();
    await mockVideo?.close();
  });

  it('relays sketch→image, then fires video_request after idle and streams video back', async () => {
    const client = new WsClient(appUrl);
    const messages: Array<Record<string, unknown>> = [];
    client.on('message', (raw) => {
      messages.push(JSON.parse(raw.toString()) as Record<string, unknown>);
    });
    await new Promise<void>((res, rej) => {
      client.on('open', () => res());
      client.on('error', rej);
    });

    // iPad behavior: config immediately at open, then sketch frames.
    client.send(JSON.stringify({ type: 'config', prompt: 'a dragon over mountains' }));
    await until(() => messages.some((m) => m['type'] === 'state' && m['state'] === 'ready'));
    client.send(Buffer.from('sketch-jpeg-1'));

    // Image path: generated frame comes back base64-wrapped.
    await until(() => messages.some((m) => m['type'] === 'frame'));
    const frame = messages.find((m) => m['type'] === 'frame');
    expect(frame?.['data']).toBe(GENERATED_JPEG.toString('base64'));

    // Idle 150ms → the backend fires video_request with the GENERATED image.
    await until(() => mockVideo.received.some((m) => m['type'] === 'video_request'));
    const req = mockVideo.received.find((m) => m['type'] === 'video_request');
    expect(req?.['prompt']).toBe('a dragon over mountains');
    expect(req?.['image_b64']).toBe(GENERATED_JPEG.toString('base64'));

    // The iPad is told the video started (drives the Animate button state).
    await until(() => messages.some((m) => m['type'] === 'video_started'));

    // Video streams back to the iPad in the wrapped *_data contract.
    await until(() => messages.some((m) => m['type'] === 'video_complete_data'));
    const vFrame = messages.find((m) => m['type'] === 'video_frame_data');
    expect(vFrame?.['data']).toBe(VIDEO_JPEG.toString('base64'));
    const vComplete = messages.find((m) => m['type'] === 'video_complete_data');
    expect(vComplete?.['data']).toBe(VIDEO_MP4.toString('base64'));
    expect((vComplete?.['meta'] as Record<string, unknown>)['fps']).toBe(24);

    // Exactly one video per idle period.
    await sleep(250);
    expect(mockVideo.received.filter((m) => m['type'] === 'video_request')).toHaveLength(1);

    client.close();
    await sleep(50);
  });

  it('a new sketch during generation cancels the in-flight video upstream', async () => {
    const client = new WsClient(appUrl);
    const messages: Array<Record<string, unknown>> = [];
    client.on('message', (raw) => {
      messages.push(JSON.parse(raw.toString()) as Record<string, unknown>);
    });
    await new Promise<void>((res, rej) => {
      client.on('open', () => res());
      client.on('error', rej);
    });
    client.send(JSON.stringify({ type: 'config', prompt: 'a fox' }));
    await until(() => messages.some((m) => m['type'] === 'state' && m['state'] === 'ready'));

    const requestsBefore = mockVideo.received.filter((m) => m['type'] === 'video_request').length;
    client.send(Buffer.from('sketch-jpeg-A'));
    await until(
      () => mockVideo.received.filter((m) => m['type'] === 'video_request').length === requestsBefore + 1,
    );
    // Resume drawing → backend must send video_cancel for the in-flight id
    // (the mock answered instantly, but the cancel-on-sketch send happens
    // before the ack clears the id only if the request is still in flight;
    // either way the trigger re-arms and a second idle fires a NEW request).
    client.send(Buffer.from('sketch-jpeg-B'));
    await until(
      () => mockVideo.received.filter((m) => m['type'] === 'video_request').length === requestsBefore + 2,
    );
    const reqs = mockVideo.received.filter((m) => m['type'] === 'video_request');
    const lastTwo = reqs.slice(-2);
    expect(lastTwo[0]?.['requestId']).not.toBe(lastTwo[1]?.['requestId']);

    client.close();
    await sleep(50);
  });
});

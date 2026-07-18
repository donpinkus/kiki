/**
 * VideoSession e2e against a mock LTX video server speaking the exact wire
 * protocol of model-servers/video/server.py. Verifies the 3s-idle trigger
 * semantics (scaled down to ~60ms for test speed), the preamble→binary
 * wrapping contract the iPad expects, cancel-on-resume, and best-effort
 * failure isolation.
 */
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, type WebSocket as WsSocket } from 'ws';
import { afterEach, describe, expect, it } from 'vitest';

import { VideoSession } from './videoSession.js';

const JPEG = Buffer.from('fake-jpeg-bytes');
const MP4 = Buffer.from('fake-mp4-bytes');

interface MockVideoServer {
  url: string;
  received: Array<Record<string, unknown>>;
  /** Requests the mock is currently sitting on (holdCompletion mode). */
  pending: Array<{ ws: WsSocket; requestId: string }>;
  completeRequest: (p: { ws: WsSocket; requestId: string }) => void;
  close: () => Promise<void>;
}

/** Mock of model-servers/video/server.py's WS side. */
function startMockVideoServer(opts: { holdCompletion?: boolean } = {}): Promise<MockVideoServer> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    const received: Array<Record<string, unknown>> = [];
    const pending: Array<{ ws: WsSocket; requestId: string }> = [];

    const completeRequest = ({ ws, requestId }: { ws: WsSocket; requestId: string }): void => {
      // Exact server.py shape: per-frame preamble + binary JPEG, then
      // video_complete preamble + binary MP4.
      ws.send(JSON.stringify({ type: 'video_frame', requestId, index: 0, total: 1 }));
      ws.send(JPEG);
      ws.send(JSON.stringify({ type: 'video_complete', requestId, fps: 24, frames: 1, genMs: 5, encodeMs: 1 }));
      ws.send(MP4);
    };

    wss.on('connection', (ws) => {
      ws.send(JSON.stringify({ type: 'status', status: 'ready' }));
      ws.on('message', (raw, isBinary) => {
        if (isBinary) return;
        const msg = JSON.parse(raw.toString()) as Record<string, unknown>;
        received.push(msg);
        if (msg['type'] === 'video_request') {
          const requestId = String(msg['requestId']);
          if (opts.holdCompletion) {
            pending.push({ ws, requestId });
          } else {
            completeRequest({ ws, requestId });
          }
        } else if (msg['type'] === 'video_cancel') {
          // Cancel whichever pending request matches (server.py cancels the
          // in-flight generation and acks with video_cancelled).
          const idx = pending.findIndex((p) => p.requestId === msg['requestId']);
          const requestId = String(msg['requestId']);
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
        close: () =>
          new Promise<void>((res) => {
            wss.close();
            server.close(() => res());
          }),
      });
    });
  });
}

const testLog = {
  info: () => {},
  warn: () => {},
  error: () => {},
  debug: () => {},
  trace: () => {},
  fatal: () => {},
  child: () => testLog,
} as never;

function makeSession(url: string, opts: { idleMs?: number } = {}): {
  session: VideoSession;
  clientMessages: Array<Record<string, unknown>>;
} {
  const clientMessages: Array<Record<string, unknown>> = [];
  const session = new VideoSession({
    url,
    tlsCa: null,
    idleMs: opts.idleMs ?? 60,
    sendToClient: (text) => clientMessages.push(JSON.parse(text) as Record<string, unknown>),
    isClientOpen: () => true,
    log: testLog,
    ctx: { userId: 'u-test', connId: 'c-test', streamId: 's-test' },
  });
  return { session, clientMessages };
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** Array lookup that throws instead of returning undefined (lint-clean
 * alternative to non-null assertions in tests). */
function must<T>(value: T | undefined, what: string): T {
  if (value === undefined) throw new Error(`expected ${what}`);
  return value;
}

/** Poll until cond() or timeout. */
async function until(cond: () => boolean, timeoutMs = 2000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error('until() timed out');
    await sleep(10);
  }
}

describe('VideoSession idle trigger', () => {
  const cleanups: Array<() => Promise<void> | void> = [];
  afterEach(async () => {
    while (cleanups.length) await cleanups.pop()?.();
  });

  it('fires one video_request after the idle window and relays frames + mp4 to the client', async () => {
    const mock = await startMockVideoServer();
    cleanups.push(mock.close);
    const { session, clientMessages } = makeSession(mock.url);
    cleanups.push(() => session.close());
    await session.start();

    session.noteConfig({ type: 'config', prompt: 'a dragon' });
    session.noteSketchFrame();
    session.noteGeneratedFrame(JPEG); // final generation lands before idle elapses

    await until(() => mock.received.some((m) => m['type'] === 'video_request'));
    const req = must(mock.received.find((m) => m['type'] === 'video_request'), 'video_request');
    expect(req['prompt']).toBe('a dragon');
    expect(req['image_b64']).toBe(JPEG.toString('base64'));

    // iPad-facing contract: wrapped *_data messages, bare preambles dropped.
    await until(() => clientMessages.some((m) => m['type'] === 'video_complete_data'));
    const frameMsg = must(clientMessages.find((m) => m['type'] === 'video_frame_data'), 'video_frame_data');
    expect(frameMsg['data']).toBe(JPEG.toString('base64'));
    expect((frameMsg['meta'] as Record<string, unknown>)['index']).toBe(0);
    const completeMsg = must(clientMessages.find((m) => m['type'] === 'video_complete_data'), 'video_complete_data');
    expect(completeMsg['data']).toBe(MP4.toString('base64'));
    expect((completeMsg['meta'] as Record<string, unknown>)['fps']).toBe(24);
    expect(clientMessages.some((m) => m['type'] === 'video_frame')).toBe(false);
    expect(clientMessages.some((m) => m['type'] === 'video_complete')).toBe(false);

    // One video per idle period — no further requests without a new sketch.
    await sleep(150);
    expect(mock.received.filter((m) => m['type'] === 'video_request')).toHaveLength(1);
    expect(session.getStats()).toMatchObject({ videoTriggered: 1, videoCompleted: 1 });
  });

  it('waits for a generation newer than the last sketch, then fires on its arrival', async () => {
    const mock = await startMockVideoServer();
    cleanups.push(mock.close);
    const { session } = makeSession(mock.url);
    cleanups.push(() => session.close());
    await session.start();

    session.noteConfig({ type: 'config', prompt: 'a cat' });
    session.noteGeneratedFrame(Buffer.from('stale-image')); // BEFORE the sketch → stale
    session.noteSketchFrame();

    // Idle window elapses but the post-sketch generation hasn't landed.
    await sleep(120);
    expect(mock.received.filter((m) => m['type'] === 'video_request')).toHaveLength(0);

    // The fresh generation arrives late → trigger fires immediately with it.
    session.noteGeneratedFrame(JPEG);
    await until(() => mock.received.some((m) => m['type'] === 'video_request'));
    const req = must(mock.received.find((m) => m['type'] === 'video_request'), 'video_request');
    expect(req['image_b64']).toBe(JPEG.toString('base64'));
  });

  it('does not fire without any sketch activity', async () => {
    const mock = await startMockVideoServer();
    cleanups.push(mock.close);
    const { session } = makeSession(mock.url);
    cleanups.push(() => session.close());
    await session.start();

    session.noteConfig({ type: 'config', prompt: 'a cat' });
    session.noteGeneratedFrame(JPEG);
    await sleep(150);
    expect(mock.received).toHaveLength(0);
  });

  it('cancels the in-flight video when drawing resumes, then fires again on the next idle', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const { session, clientMessages } = makeSession(mock.url);
    cleanups.push(() => session.close());
    await session.start();

    session.noteConfig({ type: 'config', prompt: 'a fox' });
    session.noteSketchFrame();
    session.noteGeneratedFrame(JPEG);
    await until(() => mock.pending.length === 1);
    const firstReqId = must(mock.pending[0], 'pending request').requestId;

    // User resumes drawing → video_cancel goes upstream, ack comes back.
    session.noteSketchFrame();
    await until(() => mock.received.some((m) => m['type'] === 'video_cancel'));
    await until(() => clientMessages.some((m) => m['type'] === 'video_cancelled'));
    expect(session.getStats().videoCancelled).toBe(1);

    // Final generation for the resumed drawing lands; next idle fires anew.
    session.noteGeneratedFrame(Buffer.from('newer-image'));
    await until(() => mock.received.filter((m) => m['type'] === 'video_request').length === 2);
    const second = must(mock.received.filter((m) => m['type'] === 'video_request')[1], 'second video_request');
    expect(second['requestId']).not.toBe(firstReqId);
    expect(second['image_b64']).toBe(Buffer.from('newer-image').toString('base64'));
  });

  it('skips (once per idle period) when no prompt is cached', async () => {
    const mock = await startMockVideoServer();
    cleanups.push(mock.close);
    const { session } = makeSession(mock.url);
    cleanups.push(() => session.close());
    await session.start();

    session.noteSketchFrame();
    session.noteGeneratedFrame(JPEG);
    await sleep(150);
    expect(mock.received).toHaveLength(0);
  });

  it('start() never throws when the instance is unreachable; note* calls are no-ops', async () => {
    const { session } = makeSession('ws://127.0.0.1:1/ws'); // nothing listens
    cleanups.push(() => session.close());
    await expect(session.start()).resolves.toBeUndefined();

    session.noteConfig({ type: 'config', prompt: 'a dog' });
    session.noteSketchFrame();
    session.noteGeneratedFrame(JPEG);
    await sleep(120);
    expect(session.getStats().videoTriggered).toBe(0);
  });

  it('stops sending to the client after close()', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const { session, clientMessages } = makeSession(mock.url);
    await session.start();

    session.noteConfig({ type: 'config', prompt: 'a bird' });
    session.noteSketchFrame();
    session.noteGeneratedFrame(JPEG);
    await until(() => mock.pending.length === 1);

    session.close();
    const countAtClose = clientMessages.length;
    // Server completes after close — nothing should reach the client.
    mock.completeRequest(must(mock.pending[0], 'pending request'));
    await sleep(100);
    expect(clientMessages.length).toBe(countAtClose);
  });
});

/**
 * AnimateSession e2e against a mock LTX video server speaking the exact wire
 * protocol of model-servers/video/server.py. Verifies the request/relay
 * contract the Animate screen depends on: keyframe passthrough, the
 * preamble→binary wrapping, one-in-flight busy refusal, cancel, stale-drop,
 * pool slot lifecycle, and instance-loss reset.
 */
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, type WebSocket as WsSocket } from 'ws';
import { afterEach, describe, expect, it } from 'vitest';

import { AnimateSession, DEFAULT_ANIMATION_PROMPT } from './animateSession.js';

const JPEG = Buffer.from('fake-jpeg-bytes');
const MP4 = Buffer.from('fake-mp4-bytes');
const KF = Buffer.from('keyframe-jpeg').toString('base64');

interface MockVideoServer {
  url: string;
  received: Array<Record<string, unknown>>;
  pending: Array<{ ws: WsSocket; requestId: string }>;
  completeRequest: (p: { ws: WsSocket; requestId: string }) => void;
  close: () => Promise<void>;
}

function startMockVideoServer(opts: { holdCompletion?: boolean } = {}): Promise<MockVideoServer> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    const received: Array<Record<string, unknown>> = [];
    const pending: Array<{ ws: WsSocket; requestId: string }> = [];
    const completeRequest = ({ ws, requestId }: { ws: WsSocket; requestId: string }): void => {
      ws.send(JSON.stringify({ type: 'video_frame', requestId, index: 0, total: 1 }));
      ws.send(JPEG);
      ws.send(JSON.stringify({ type: 'video_complete', requestId, fps: 24, frames: 1, genMs: 5 }));
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

function makeSession(
  url: string,
  opts: {
    acquire?: () => { name?: string; url: string } | null;
    release?: (name: string) => void;
    reportFailure?: (name: string) => void;
    onVideoDelivered?: (mp4: Buffer, meta: Record<string, unknown>, info: { waitMs: number }) => void;
  } = {},
): {
  session: AnimateSession;
  clientMessages: Array<Record<string, unknown>>;
} {
  const clientMessages: Array<Record<string, unknown>> = [];
  const sessionOpts: ConstructorParameters<typeof AnimateSession>[0] = {
    acquire: opts.acquire ?? (() => ({ url })),
    tlsCa: null,
    sendToClient: (text) => clientMessages.push(JSON.parse(text) as Record<string, unknown>),
    isClientOpen: () => true,
    log: testLog,
    ctx: { userId: 'u-test', connId: 'c-test' },
  };
  if (opts.release) sessionOpts.release = opts.release;
  if (opts.reportFailure) sessionOpts.reportFailure = opts.reportFailure;
  if (opts.onVideoDelivered) sessionOpts.onVideoDelivered = opts.onVideoDelivered;
  const session = new AnimateSession(sessionOpts);
  return { session, clientMessages };
}

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

function must<T>(value: T | undefined, what: string): T {
  if (value === undefined) throw new Error(`expected ${what}`);
  return value;
}

async function until(cond: () => boolean, timeoutMs = 10_000): Promise<void> {
  const start = Date.now();
  while (!cond()) {
    if (Date.now() - start > timeoutMs) throw new Error('until() timed out');
    await sleep(10);
  }
}

const request = (id: string, extra: Record<string, unknown> = {}): Parameters<AnimateSession['requestAnimate']>[0] => ({
  requestId: id,
  prompt: 'the scene comes alive',
  keyframes: [{ imageB64: KF, position: 0 }],
  ...extra,
});

describe('AnimateSession', { timeout: 30_000 }, () => {
  const cleanups: Array<() => Promise<void> | void> = [];
  afterEach(async () => {
    while (cleanups.length) await cleanups.pop()?.();
  });

  it('fires a video_request with keyframes and relays started/frames/mp4', async () => {
    const mock = await startMockVideoServer();
    cleanups.push(mock.close);
    const delivered: Buffer[] = [];
    const { session, clientMessages } = makeSession(mock.url, {
      onVideoDelivered: (mp4) => delivered.push(mp4),
    });
    cleanups.push(() => session.close());

    session.requestAnimate({
      requestId: 'r1',
      prompt: 'wings flap slowly',
      keyframes: [
        { imageB64: KF, position: 0 },
        { imageB64: KF, position: 1, strength: 0.7 },
      ],
      numFrames: 145,
      seed: 42,
    });

    await until(() => mock.received.some((m) => m['type'] === 'video_request'));
    const req = must(mock.received.find((m) => m['type'] === 'video_request'), 'video_request');
    expect(req['prompt']).toBe('wings flap slowly');
    expect(req['seed']).toBe(42);
    expect(req['videoFrames']).toBe(145);
    const kfs = req['keyframes'] as Array<Record<string, unknown>>;
    expect(kfs).toHaveLength(2);
    expect(kfs[1]).toMatchObject({ image_b64: KF, position: 1, strength: 0.7 });

    expect(clientMessages.some((m) => m['type'] === 'video_started' && m['requestId'] === 'r1')).toBe(true);
    await until(() => clientMessages.some((m) => m['type'] === 'video_complete_data'));
    const frameMsg = must(clientMessages.find((m) => m['type'] === 'video_frame_data'), 'video_frame_data');
    expect(frameMsg['data']).toBe(JPEG.toString('base64'));
    const completeMsg = must(clientMessages.find((m) => m['type'] === 'video_complete_data'), 'video_complete_data');
    expect(completeMsg['data']).toBe(MP4.toString('base64'));
    expect(delivered).toHaveLength(1);
    expect(session.getStats()).toMatchObject({ videoRequested: 1, videoCompleted: 1 });
  });

  it('empty prompt falls back to the default motion prompt', async () => {
    const mock = await startMockVideoServer();
    cleanups.push(mock.close);
    const { session } = makeSession(mock.url);
    cleanups.push(() => session.close());

    session.requestAnimate(request('r-empty', { prompt: '  ' }));
    await until(() => mock.received.some((m) => m['type'] === 'video_request'));
    const req = must(mock.received.find((m) => m['type'] === 'video_request'), 'video_request');
    expect(req['prompt']).toBe(DEFAULT_ANIMATION_PROMPT);
  });

  it('refuses a second request while one is in flight (busy)', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const { session, clientMessages } = makeSession(mock.url);
    cleanups.push(() => session.close());

    session.requestAnimate(request('r-a'));
    await until(() => mock.pending.length === 1);
    session.requestAnimate(request('r-b'));
    await until(() => clientMessages.some((m) => m['type'] === 'video_cancelled' && m['requestId'] === 'r-b'));
    expect(
      must(clientMessages.find((m) => m['type'] === 'video_cancelled' && m['requestId'] === 'r-b'), 'busy cancel')['error'],
    ).toBe('busy');
    // The first request is unaffected and completes when the server finishes.
    mock.completeRequest(must(mock.pending[0], 'held request'));
    await until(() => clientMessages.some((m) => m['type'] === 'video_complete_data'));
  });

  it('cancel() sends video_cancel upstream and the ack resets the client', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const { session, clientMessages } = makeSession(mock.url);
    cleanups.push(() => session.close());

    session.requestAnimate(request('r-c'));
    await until(() => mock.pending.length === 1);
    session.cancel('r-c');
    await until(() => mock.received.some((m) => m['type'] === 'video_cancel'));
    await until(() => clientMessages.some((m) => m['type'] === 'video_cancelled' && m['requestId'] === 'r-c'));
    expect(session.getStats().videoCancelled).toBe(1);

    // A new request can fire after the cancel cleared the in-flight slot.
    session.requestAnimate(request('r-d'));
    await until(() => mock.received.filter((m) => m['type'] === 'video_request').length === 2);
  });

  it('drops a completion whose cancel raced the finished render', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const { session, clientMessages } = makeSession(mock.url);
    cleanups.push(() => session.close());

    session.requestAnimate(request('r-stale'));
    await until(() => mock.pending.length === 1);
    const held = must(mock.pending[0], 'held request');
    session.cancel('r-stale');
    await until(() => clientMessages.some((m) => m['type'] === 'video_cancelled'));
    // Render finished server-side anyway — completion limps in late.
    mock.completeRequest(held);
    await sleep(150);
    expect(clientMessages.some((m) => m['type'] === 'video_complete_data')).toBe(false);
    expect(clientMessages.some((m) => m['type'] === 'video_frame_data')).toBe(false);
  });

  it('requestAnimate with an unreachable instance resets via video_cancelled', async () => {
    const failed: string[] = [];
    const released: string[] = [];
    const { session, clientMessages } = makeSession('ws://127.0.0.1:1/ws', {
      acquire: () => ({ name: 'kiki-video-dead', url: 'ws://127.0.0.1:1/ws' }),
      release: (n) => released.push(n),
      reportFailure: (n) => failed.push(n),
    });
    cleanups.push(() => session.close());

    session.requestAnimate(request('r-dead'));
    await until(() => clientMessages.some((m) => m['type'] === 'video_cancelled'));
    expect(
      must(clientMessages.find((m) => m['type'] === 'video_cancelled'), 'cancel')['error'],
    ).toBe('video_unavailable');
    expect(failed).toEqual(['kiki-video-dead']);
    expect(released).toEqual(['kiki-video-dead']);
  });

  it('resets the client on upstream loss mid-generation and re-acquires on the next request', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const released: string[] = [];
    const { session, clientMessages } = makeSession(mock.url, {
      acquire: () => ({ name: 'kiki-video-1', url: mock.url }),
      release: (n) => released.push(n),
    });
    cleanups.push(() => session.close());

    session.requestAnimate(request('r-lost'));
    await until(() => mock.pending.length === 1);
    mock.pending[0]?.ws.terminate();
    await until(() => released.length === 1);
    await until(() =>
      clientMessages.some(
        (m) => m['type'] === 'video_cancelled' && m['error'] === 'video_instance_lost',
      ),
    );

    session.requestAnimate(request('r-recover'));
    await until(() => mock.received.filter((m) => m['type'] === 'video_request').length === 2);
  });

  it('stops sending to the client after close() and releases the slot', async () => {
    const mock = await startMockVideoServer({ holdCompletion: true });
    cleanups.push(mock.close);
    const released: string[] = [];
    const { session, clientMessages } = makeSession(mock.url, {
      acquire: () => ({ name: 'kiki-video-live', url: mock.url }),
      release: (n) => released.push(n),
    });

    session.requestAnimate(request('r-close'));
    await until(() => mock.pending.length === 1);
    session.close();
    expect(released).toEqual(['kiki-video-live']);
    const countAtClose = clientMessages.length;
    mock.completeRequest(must(mock.pending[0], 'pending request'));
    await sleep(100);
    expect(clientMessages.length).toBe(countAtClose);
  });
});

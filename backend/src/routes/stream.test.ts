/**
 * Route-level tests of the /v1/stream mid-session fal → H100 UPGRADE.
 *
 * Real Fastify app + real StreamRelay against a mock Lambda IMAGE server
 * (the model-servers/image/server.py wire shape: status → config/binary in,
 * frame_meta + JPEG out). The fal relay is a fake (no network, controllable
 * open-time for metering), and the image pool (devPool) is a fake with a
 * flippable "ready" switch. Identity is a real JWT (`imageProvider=` overrides
 * are only honored for JWT test accounts, so `isTestAccount` is mocked true).
 *
 * Env is set BEFORE the dynamic import of the route (config is a singleton
 * validated at first import; vitest runs each file in a fresh module graph).
 */
import { createServer } from 'node:http';
import type { AddressInfo } from 'node:net';
import { WebSocketServer, WebSocket as WsClient, type WebSocket as WsSocket } from 'ws';
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest';

// ─── Controllable fakes (hoisted so vi.mock factories can close over them) ──
const ctl = vi.hoisted(() => {
  type MsgHandler = (data: Buffer | string, isBinary: boolean) => void;
  class FakeFalRelay {
    static instances: FakeFalRelay[] = [];
    closed = false;
    /** What cumulativeOpenMs() reports — the test sets it to simulate a warm
     * fal socket having been open for N ms. */
    openMs = 0;
    framesSent: Buffer[] = [];
    configs: Array<Record<string, unknown>> = [];
    private messageHandler: MsgHandler | null = null;
    usageHandler: (() => void) | null = null;
    constructor() {
      FakeFalRelay.instances.push(this);
    }
    setLogContext(): void {}
    getLastPhaseTimings(): Record<string, number> {
      return {};
    }
    connect(): Promise<void> {
      return Promise.resolve(); // fal relays "arm" (lazy-connect) — resolves without a socket
    }
    sendConfig(payload: Record<string, unknown>): void {
      this.configs.push(payload);
    }
    sendFrame(jpeg: Buffer): void {
      this.framesSent.push(jpeg);
      // Echo a generated frame the way the real relay does: synthesized
      // frame_meta, then the JPEG.
      this.messageHandler?.(JSON.stringify({ type: 'frame_meta', queueEmpty: true }), false);
      this.messageHandler?.(Buffer.from('fal-jpeg'), true);
    }
    onMessage(cb: MsgHandler): void {
      this.messageHandler = cb;
    }
    onClose(): void {}
    onError(): void {}
    onUsage(cb: () => void): void {
      this.usageHandler = cb;
    }
    cumulativeOpenMs(): number {
      return this.openMs;
    }
    close(): void {
      this.closed = true;
    }
  }
  const pool = {
    ready: false,
    /** URL handed out by acquireStream — points at the mock lambda server,
     * or at a dead port for the wire-failure test. */
    url: '',
    instanceName: 'kiki-serve-test',
    acquireStream: vi.fn((): { name: string; url: string } | null =>
      pool.ready ? { name: pool.instanceName, url: pool.url } : null),
    releaseStream: vi.fn(),
    reportFailure: vi.fn(),
    touch: vi.fn(),
    touchInstance: vi.fn(),
    getState: (): Record<string, unknown> => ({
      status: pool.ready ? 'ready' : 'launching',
      message: pool.ready ? 'ready' : 'searching',
      searchStartedAtMs: 0,
      launchedAtMs: null,
      bootEstimateSeconds: 300,
    }),
  };
  const budget = {
    checkFalBudget: vi.fn(),
    isTestAccount: vi.fn(),
    addMonthlySpendUsd: vi.fn(),
  };
  const analytics = {
    trackSessionClosed: vi.fn(),
    trackProviderSession: vi.fn(),
  };
  return { FakeFalRelay, pool, budget, analytics };
});

vi.mock('../modules/fal/falImageRelay.js', () => ({ FalImageRelay: ctl.FakeFalRelay }));
vi.mock('../modules/fal/falConnectionLog.js', () => ({ recordFalConnection: vi.fn() }));
vi.mock('../modules/falBudget/index.js', () => ({
  RATE_USD_PER_SEC: 0.00194,
  checkFalBudget: ctl.budget.checkFalBudget,
  isTestAccount: ctl.budget.isTestAccount,
  addMonthlySpendUsd: ctl.budget.addMonthlySpendUsd,
}));
vi.mock('../modules/analytics/index.js', () => ({
  trackSessionClosed: ctl.analytics.trackSessionClosed,
  trackProviderSession: ctl.analytics.trackProviderSession,
}));
vi.mock('../modules/lambda/devPool.js', () => ({
  ensure: () => ctl.pool.getState(),
  touch: ctl.pool.touch,
  acquireStream: ctl.pool.acquireStream,
  releaseStream: ctl.pool.releaseStream,
  touchInstance: ctl.pool.touchInstance,
  hasReady: () => ctl.pool.ready,
  getState: () => ctl.pool.getState(),
  reportFailure: ctl.pool.reportFailure,
}));
vi.mock('../modules/lambda/videoPool.js', () => ({
  poolEnabled: () => false,
  getState: () => ({ status: 'none', message: 'off' }),
  touch: vi.fn(),
}));

// ─── Mock Lambda IMAGE server (model-servers/image/server.py wire shape) ─────
interface MockImageServer {
  url: string;
  connections: number;
  received: Array<Record<string, unknown>>;
  framesReceived: number;
  close: () => Promise<void>;
}

function startMockImageServer(): Promise<MockImageServer> {
  return new Promise((resolve) => {
    const server = createServer();
    const wss = new WebSocketServer({ server });
    const state: MockImageServer = {
      url: '',
      connections: 0,
      received: [],
      framesReceived: 0,
      close: () => new Promise<void>((res) => { wss.close(); server.close(() => res()); }),
    };
    wss.on('connection', (ws: WsSocket) => {
      state.connections += 1;
      ws.send(JSON.stringify({ type: 'status', status: 'ready' }));
      ws.on('message', (raw, isBinary) => {
        if (isBinary) {
          state.framesReceived += 1;
          ws.send(JSON.stringify({ type: 'frame_meta', queueEmpty: true, genMs: 7 }));
          ws.send(Buffer.from('lambda-jpeg'));
          return;
        }
        state.received.push(JSON.parse(raw.toString()) as Record<string, unknown>);
      });
    });
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address() as AddressInfo;
      state.url = `ws://127.0.0.1:${port}/ws`;
      resolve(state);
    });
  });
}

/** A port nothing listens on (bind + release) — for ECONNREFUSED. */
function deadPortUrl(): Promise<string> {
  return new Promise((resolve) => {
    const s = createServer();
    s.listen(0, '127.0.0.1', () => {
      const { port } = s.address() as AddressInfo;
      s.close(() => resolve(`ws://127.0.0.1:${port}/ws`));
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

interface Client {
  ws: WsClient;
  messages: Array<Record<string, unknown>>;
  frames: () => string[];
  closed: Promise<void>;
}

async function openClient(url: string, token: string): Promise<Client> {
  const ws = new WsClient(url, { headers: { authorization: `Bearer ${token}` } });
  const messages: Array<Record<string, unknown>> = [];
  ws.on('message', (raw) => messages.push(JSON.parse(raw.toString()) as Record<string, unknown>));
  const closed = new Promise<void>((res) => ws.on('close', () => res()));
  await new Promise<void>((res, rej) => {
    ws.on('open', () => res());
    ws.on('error', rej);
  });
  return {
    ws,
    messages,
    frames: () =>
      messages
        .filter((m) => m['type'] === 'frame')
        .map((m) => Buffer.from(String(m['data']), 'base64').toString()),
    closed,
  };
}

const latestFal = (): InstanceType<typeof ctl.FakeFalRelay> => {
  const inst = ctl.FakeFalRelay.instances.at(-1);
  if (!inst) throw new Error('no fal relay was created');
  return inst;
};

describe('stream route — mid-session fal → H100 upgrade', { timeout: 30_000 }, () => {
  let mockImage: MockImageServer;
  let app: { close: () => Promise<void> };
  let baseUrl: string;
  let token: string;

  beforeAll(async () => {
    mockImage = await startMockImageServer();
    ctl.pool.url = mockImage.url;

    // Must be set before the config singleton loads (dynamic imports below).
    process.env['IMAGE_PROVIDER'] = 'auto';
    process.env['LAMBDA_DEV_POOL_ENABLED'] = 'true';
    process.env['AUTH_REQUIRED'] = 'true';

    const { default: Fastify } = await import('fastify');
    const { default: websocket } = await import('@fastify/websocket');
    const { streamRoute, streamTuning } = await import('./stream.js');
    const { signAccess } = await import('../modules/auth/jwt.js');
    // Shrink the sampler cadence + retry backoff so the tests aren't
    // wall-clock-bound (production: 15 s / 60 s).
    streamTuning.availabilityPollMs = 40;
    streamTuning.upgradeRetryMs = 400;
    token = await signAccess('user-upgrade-test');

    const fastify = Fastify({ logger: false });
    await fastify.register(websocket, { options: { maxPayload: 64 * 1024 * 1024 } });
    await fastify.register(streamRoute);
    await fastify.listen({ port: 0, host: '127.0.0.1' });
    app = fastify;
    const addr = fastify.server.address() as AddressInfo;
    baseUrl = `ws://127.0.0.1:${addr.port}/v1/stream?streamId=s1`;
  });

  afterAll(async () => {
    await app?.close();
    await mockImage?.close();
  });

  beforeEach(() => {
    vi.clearAllMocks();
    ctl.FakeFalRelay.instances.length = 0;
    ctl.pool.ready = false;
    ctl.pool.url = mockImage.url;
    mockImage.connections = 0;
    mockImage.received.length = 0;
    mockImage.framesReceived = 0;
    // Non-exempt JWT test account: metering is ON so the fal→lambda handoff
    // of the ledger is exercised; the override path needs isTestAccount.
    ctl.budget.checkFalBudget.mockResolvedValue({ allowed: true, exempt: false, spendUsd: 0, capUsd: 10 });
    ctl.budget.isTestAccount.mockResolvedValue(true);
    let total = 0;
    ctl.budget.addMonthlySpendUsd.mockImplementation(async (_uid: string, usd: number) => {
      total += usd;
      return total;
    });
  });

  afterEach(async () => {
    // Every test closes its client; give the server's close handler a tick.
    await sleep(20);
  });

  it('(a) auto session parked on fal upgrades to the H100 once the pool is ready', async () => {
    const c = await openClient(baseUrl, token);
    await until(() => c.messages.some((m) => m['type'] === 'state' && m['state'] === 'ready'));
    expect(ctl.pool.acquireStream).not.toHaveBeenCalled(); // resolved to fal: pool had nothing
    const fal = latestFal();

    // Draw on fal: prompt config + a sketch → a fal frame comes back.
    c.ws.send(JSON.stringify({ type: 'config', prompt: 'a red fox' }));
    c.ws.send(Buffer.from('sketch-1'), { binary: true });
    await until(() => c.frames().length === 1);
    expect(c.frames()).toEqual(['fal-jpeg']);
    expect(fal.framesSent).toHaveLength(1);

    // Pool comes ready mid-session. Simulate 5 s of warm fal socket time so
    // the swap's final flush is observable.
    fal.openMs = 5_000;
    ctl.pool.ready = true;
    await until(() => fal.closed);
    expect(mockImage.connections).toBe(1);
    expect(ctl.pool.acquireStream).toHaveBeenCalledTimes(1);
    // lastConfig was resent to the lambda relay before any frame.
    await until(() => mockImage.received.some((m) => m['type'] === 'config'));
    expect(mockImage.received[0]).toMatchObject({ type: 'config', prompt: 'a red fox' });
    // The lambda server's connect-time status line never reached the iPad
    // (it arrived while the relay was not yet adopted).
    expect(c.messages.some((m) => m['type'] === 'status')).toBe(false);
    // Fal open-seconds were flushed at the swap: 5 s × RATE.
    expect(ctl.budget.addMonthlySpendUsd).toHaveBeenCalledWith('user-upgrade-test', 5 * 0.00194);

    // Subsequent sketches go to lambda, not fal.
    c.ws.send(Buffer.from('sketch-2'), { binary: true });
    await until(() => c.frames().length === 2);
    expect(c.frames()).toEqual(['fal-jpeg', 'lambda-jpeg']);
    expect(fal.framesSent).toHaveLength(1);
    expect(mockImage.framesReceived).toBe(1);
    // No error / no 'connecting' regression on the client during the swap.
    expect(c.messages.some((m) => m['type'] === 'error')).toBe(false);
    expect(c.messages.filter((m) => m['type'] === 'state').map((m) => m['state'])).toEqual(['connecting', 'ready']);

    c.ws.close();
    await c.closed;
    await until(() => ctl.analytics.trackProviderSession.mock.calls.length === 1);
    const props = ctl.analytics.trackProviderSession.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(props['provider']).toBe('lambda'); // final provider, not the one it opened on
    expect(props['providerIntent']).toBe('auto');
    expect(props['lambdaUpgraded']).toBe(true);
    expect(typeof props['upgradedAfterMs']).toBe('number');
    expect(props['lambdaWired']).toBe(true);
    expect(props['lambdaFrames']).toBe(1);
    expect(props['lambdaDowngraded']).toBe(false);
    // The single lambda frame was metered on close at $0.001/frame.
    expect(ctl.budget.addMonthlySpendUsd).toHaveBeenCalledWith('user-upgrade-test', 0.001);
    expect(ctl.pool.releaseStream).toHaveBeenCalledWith('kiki-serve-test');
  });

  it('(b) explicit imageProvider=fal never upgrades, even with a ready pool', async () => {
    ctl.pool.ready = true; // ready from the very start
    const c = await openClient(`${baseUrl}&imageProvider=fal`, token);
    await until(() => c.messages.some((m) => m['type'] === 'state' && m['state'] === 'ready'));
    const fal = latestFal();

    c.ws.send(Buffer.from('sketch-1'), { binary: true });
    await until(() => c.frames().length === 1);
    // Sit through several sampler ticks (40 ms each).
    await sleep(250);
    c.ws.send(Buffer.from('sketch-2'), { binary: true });
    await until(() => c.frames().length === 2);

    expect(c.frames()).toEqual(['fal-jpeg', 'fal-jpeg']);
    expect(fal.closed).toBe(false);
    expect(ctl.pool.acquireStream).not.toHaveBeenCalled();
    expect(mockImage.connections).toBe(0);

    c.ws.close();
    await c.closed;
    await until(() => ctl.analytics.trackProviderSession.mock.calls.length === 1);
    const props = ctl.analytics.trackProviderSession.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(props['provider']).toBe('fal');
    expect(props['providerIntent']).toBe('fal');
    expect(props['lambdaUpgraded']).toBe(false);
    expect(props['upgradedAfterMs']).toBeNull();
  });

  it('(c) a failed lambda wire keeps fal, backs off, and retries on a later tick', async () => {
    const c = await openClient(baseUrl, token);
    await until(() => c.messages.some((m) => m['type'] === 'state' && m['state'] === 'ready'));
    const fal = latestFal();

    // Pool advertises ready but the instance refuses connections.
    ctl.pool.url = await deadPortUrl();
    ctl.pool.ready = true;
    await until(() => ctl.pool.reportFailure.mock.calls.length === 1);
    expect(ctl.pool.reportFailure).toHaveBeenCalledWith('kiki-serve-test');
    expect(ctl.pool.releaseStream).toHaveBeenCalledWith('kiki-serve-test');
    expect(ctl.pool.acquireStream).toHaveBeenCalledTimes(1);
    expect(fal.closed).toBe(false);

    // Still drawing on fal, silently — no client-visible error.
    c.ws.send(Buffer.from('sketch-1'), { binary: true });
    await until(() => c.frames().length === 1);
    expect(c.frames()).toEqual(['fal-jpeg']);
    expect(c.messages.some((m) => m['type'] === 'error')).toBe(false);

    // Backoff: ticks keep firing (40 ms) but no second attempt within
    // upgradeRetryMs (400 ms).
    await sleep(200);
    expect(ctl.pool.acquireStream).toHaveBeenCalledTimes(1);

    // Instance recovers; the next tick after the backoff window upgrades.
    ctl.pool.url = mockImage.url;
    await until(() => fal.closed, 5_000);
    expect(ctl.pool.acquireStream).toHaveBeenCalledTimes(2);
    expect(mockImage.connections).toBe(1);
    c.ws.send(Buffer.from('sketch-2'), { binary: true });
    await until(() => c.frames().length === 2);
    expect(c.frames()).toEqual(['fal-jpeg', 'lambda-jpeg']);

    c.ws.close();
    await c.closed;
    await until(() => ctl.analytics.trackProviderSession.mock.calls.length === 1);
    const props = ctl.analytics.trackProviderSession.mock.calls[0]?.[0] as Record<string, unknown>;
    expect(props['provider']).toBe('lambda');
    expect(props['lambdaUpgraded']).toBe(true);
  });
});

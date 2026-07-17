/**
 * Lambda Cloud dev pool — keeps at most ONE `kiki-serve-*` H100 instance
 * running for the IMAGE_PROVIDER=lambda per-session toggle (dev/test-account
 * only). Not the Phase 2 multi-user pool; deliberately single-instance.
 *
 * Lifecycle:
 *  - `ensure()` (called from POST /v1/dev/lambda/ensure at app login, and when
 *    a stream requests lambda) adopts an existing kiki-serve instance or
 *    launches one (capacity-retried), then probes /health until ready.
 *    Non-blocking: returns the current state snapshot immediately.
 *  - Readiness = OUR /health says ok, never Lambda's `status: active` (which
 *    lags real readiness by 27-62s — measured, see
 *    documents/plans/lambda-image-provider.md).
 *  - A reaper terminates the instance after 30 min without activity
 *    (`touch()` is called from the stream relay on every generated frame).
 *
 * The per-instance WS token is HMAC(LAMBDA_API_KEY, instanceId) — deterministic
 * so a backend redeploy can re-adopt a running instance without persisted state.
 * Requires the region's filesystem to be pre-populated via
 * scripts/lambda/setup-lambda.ts (weights + venv + boot.sh).
 */

import { createHmac } from 'node:crypto';
import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { inBackgroundScope } from '../observability/scope.js';
import { LambdaClient, launchWithRetry, lambdaSleep } from './client.js';

const PORT = 8766;
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const NAME_PREFIX = 'kiki-serve-';
const IDLE_TERMINATE_MS = 30 * 60_000;
const REAPER_INTERVAL_MS = 5 * 60_000;
const LAUNCH_RETRY_MINS = 30;
/** Give up on a booting instance that never turns healthy (well past the
 * measured 857s worst-case boot). */
const BOOT_TIMEOUT_MS = 25 * 60_000;

export type DevPoolStatusKind = 'disabled' | 'none' | 'launching' | 'booting' | 'ready' | 'error';

export interface DevPoolState {
  status: DevPoolStatusKind;
  instanceId?: string;
  ip?: string;
  region: string;
  instanceType: string;
  /** Human-readable detail for the iPad settings UI. */
  message: string;
  lastError?: string;
  launchedAtMs?: number;
  readyAtMs?: number;
  /** Rough seconds until ready while booting (measured ~10 min for the
   * 9B-KV + torch.compile boot: VM ~3 min + load ~2 min + compile ~5 min).
   * null when ready, unknown (still hunting capacity), or not applicable.
   * Drives the iPad's "warming up, ready in ~X" UI. */
  etaSeconds: number | null;
}

/** Measured full boot for the current serving config (9B-KV, FLUX_COMPILE=1). */
const BOOT_ESTIMATE_MS = 10 * 60_000;

let status: DevPoolStatusKind = 'none';
let instanceId: string | undefined;
/** Instance NAME (kiki-serve-<ts>) — the WS-token key. The token must be
 * derivable BEFORE launch (it's baked into cloud-init user_data), and the
 * instance id only exists after launch — so the name, chosen pre-launch and
 * recoverable from the API on adoption, is the HMAC input. */
let instanceName: string | undefined;
let ip: string | undefined;
let lastError: string | undefined;
let launchedAtMs: number | undefined;
let readyAtMs: number | undefined;
let lastActivityMs = 0;
let ensureRunning = false;
let reaperTimer: NodeJS.Timeout | null = null;
let log: FastifyBaseLogger | Console = console;

function enabled(): boolean {
  return config.LAMBDA_DEV_POOL_ENABLED && config.LAMBDA_API_KEY.length > 0;
}

function client(): LambdaClient {
  return new LambdaClient(config.LAMBDA_API_KEY);
}

function wsToken(name: string): string {
  return createHmac('sha256', config.LAMBDA_API_KEY).update(name).digest('hex').slice(0, 32);
}

function fsName(): string {
  return `kiki-image-${config.LAMBDA_REGION}`;
}

function userData(name: string): string {
  // Mirrors scripts/lambda/coldstart-bench.ts: per-instance env via
  // write_files, server detached via systemd-run (runcmd would block
  // cloud-init's final stage forever on a non-exiting server).
  return `#cloud-config
write_files:
  - path: /etc/kiki.env
    permissions: '0600'
    content: |
      KIKI_WS_TOKEN=${wsToken(name)}
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /lambda/nfs/${fsName()}/kiki/boot.sh]
`;
}

function statusMessage(): string {
  switch (status) {
    case 'disabled':
      return 'Lambda dev pool disabled (LAMBDA_DEV_POOL_ENABLED / LAMBDA_API_KEY unset)';
    case 'none':
      return 'No instance';
    case 'launching':
      return 'Requesting H100 capacity…';
    case 'booting':
      return `Instance booting (~3 min typical)${ip ? ` at ${ip}` : ''}`;
    case 'ready':
      return `H100 ready at ${ip}`;
    case 'error':
      return `Error: ${lastError ?? 'unknown'}`;
  }
}

export function getState(): DevPoolState {
  let etaSeconds: number | null = null;
  if (status === 'booting' && launchedAtMs !== undefined) {
    etaSeconds = Math.max(15, Math.round((BOOT_ESTIMATE_MS - (Date.now() - launchedAtMs)) / 1000));
  }
  return {
    status: enabled() ? status : 'disabled',
    instanceId,
    ip,
    region: config.LAMBDA_REGION,
    instanceType: config.LAMBDA_INSTANCE_TYPE,
    message: enabled() ? statusMessage() : 'Lambda dev pool disabled',
    lastError,
    launchedAtMs,
    readyAtMs,
    etaSeconds,
  };
}

/** Records activity so the idle reaper doesn't terminate a in-use instance. */
export function touch(): void {
  lastActivityMs = Date.now();
}

/** ws URL for the relay, or null when not ready. */
export function wsUrl(): string | null {
  if (status !== 'ready' || !ip || !instanceName) return null;
  return `ws://${ip}:${PORT}/ws?token=${wsToken(instanceName)}`;
}

/**
 * Kick the pool: adopt-or-launch if nothing is running. Returns the current
 * state immediately; the launch/boot continues in the background.
 */
export function ensure(): DevPoolState {
  if (enabled() && !ensureRunning && (status === 'none' || status === 'error')) {
    ensureRunning = true;
    status = 'launching';
    lastError = undefined;
    touch();
    void inBackgroundScope('lambda_dev_pool', async () => {
      try {
        await ensureLoop();
      } catch (err) {
        status = 'error';
        lastError = (err as Error).message;
        log.error({ err, event: 'lambda_pool_ensure_failed' }, 'lambda dev pool ensure failed');
      } finally {
        ensureRunning = false;
      }
    });
  } else if (enabled()) {
    touch();
  }
  return getState();
}

async function ensureLoop(): Promise<void> {
  const c = client();

  // Adopt a live kiki-serve instance if one exists (e.g. backend redeployed).
  const existing = (await c.listInstances()).find(
    (i) =>
      i.name?.startsWith(NAME_PREFIX) &&
      i.region.name === config.LAMBDA_REGION &&
      ['booting', 'active'].includes(i.status),
  );

  let id: string;
  if (existing) {
    id = existing.id;
    instanceName = existing.name ?? undefined;
    log.info({ instanceId: id, event: 'lambda_pool_adopted' }, 'adopted existing kiki-serve instance');
  } else {
    const name = `${NAME_PREFIX}${Date.now()}`;
    instanceName = name;
    const keys = await c.listSshKeys();
    const firstKey = keys[0];
    if (!firstKey) throw new Error('no SSH key registered on the Lambda account');
    const [launchedId] = await launchWithRetry(
      c,
      {
        region_name: config.LAMBDA_REGION,
        instance_type_name: config.LAMBDA_INSTANCE_TYPE,
        ssh_key_names: [firstKey.name],
        file_system_names: [fsName()],
        name,
        image: { family: OS_IMAGE_FAMILY },
        user_data: userData(name),
      },
      LAUNCH_RETRY_MINS,
      undefined,
      (msg) => log.info({ event: 'lambda_pool_launch_retry' }, msg),
    );
    if (!launchedId) throw new Error('Lambda launch returned no instance id');
    id = launchedId;
    log.info({ instanceId: id, event: 'lambda_pool_launched' }, 'launched kiki-serve instance');
  }

  instanceId = id;
  launchedAtMs = Date.now();
  status = 'booting';
  touch();

  // Wait for IP, then probe OUR /health (never `status: active`).
  const bootDeadline = Date.now() + BOOT_TIMEOUT_MS;
  while (!ip) {
    if (Date.now() > bootDeadline) throw new Error('timed out waiting for instance IP');
    try {
      const inst = await c.getInstance(id);
      if (['terminated', 'terminating', 'unhealthy', 'preempted'].includes(inst.status)) {
        throw new Error(`instance entered ${inst.status} during boot`);
      }
      if (inst.ip) ip = inst.ip;
    } catch (err) {
      if (!/fetch failed|ENOTFOUND|ETIMEDOUT|ECONNRESET/.test((err as Error).message)) throw err;
    }
    if (!ip) await lambdaSleep(3000);
  }

  for (;;) {
    if (Date.now() > bootDeadline) throw new Error('timed out waiting for /health ok');
    try {
      const res = await fetch(`http://${ip}:${PORT}/health`, { signal: AbortSignal.timeout(3000) });
      const health = (await res.json()) as { status?: string };
      if (health.status === 'ok') break;
    } catch {
      // not up yet
    }
    await lambdaSleep(2000);
  }

  status = 'ready';
  readyAtMs = Date.now();
  touch();
  log.info(
    { instanceId: id, ip, bootMs: readyAtMs - (launchedAtMs ?? readyAtMs), event: 'lambda_pool_ready' },
    'lambda dev pool instance ready',
  );
}

async function reaperTick(): Promise<void> {
  if (!enabled() || !instanceId) return;
  const idleMs = Date.now() - lastActivityMs;
  if (idleMs < IDLE_TERMINATE_MS) return;
  const id = instanceId;
  log.info({ instanceId: id, idleMs, event: 'lambda_pool_idle_terminate' }, 'terminating idle kiki-serve instance');
  try {
    await client().terminate([id]);
  } catch (err) {
    log.warn({ err, instanceId: id, event: 'lambda_pool_terminate_failed' }, 'terminate failed (will retry next tick)');
    return;
  }
  instanceId = undefined;
  instanceName = undefined;
  ip = undefined;
  status = 'none';
  readyAtMs = undefined;
}

export function start(logger: FastifyBaseLogger): void {
  log = logger;
  if (!enabled()) {
    logger.info('lambda dev pool disabled (LAMBDA_DEV_POOL_ENABLED/LAMBDA_API_KEY unset)');
    return;
  }
  reaperTimer = setInterval(
    () => void inBackgroundScope('lambda_dev_pool', () => reaperTick()),
    REAPER_INTERVAL_MS,
  );
  // Adopt any instance surviving a redeploy so the reaper tracks it.
  void inBackgroundScope('lambda_dev_pool', async () => {
    try {
      const existing = (await client().listInstances()).find(
        (i) => i.name?.startsWith(NAME_PREFIX) && ['booting', 'active'].includes(i.status),
      );
      if (existing) ensure();
    } catch (err) {
      logger.warn({ err, event: 'lambda_pool_reconcile_failed' }, 'lambda pool startup reconcile failed');
    }
  });
}

export function stop(): void {
  if (reaperTimer) clearInterval(reaperTimer);
  reaperTimer = null;
}
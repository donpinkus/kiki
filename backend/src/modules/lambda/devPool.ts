/**
 * Lambda Cloud H100 pool — serves the production image path.
 *
 * Evolved from the single-instance dev pool into a small fleet manager:
 *  - Registry of `kiki-serve-*` instances (launching → booting → ready),
 *    adopted across backend redeploys by name prefix + deterministic token.
 *  - Streams are ASSIGNED to the least-loaded ready instance
 *    (`acquireStream`/`releaseStream`); sketchify one-shots use `wsUrl()`.
 *  - Sluggish autoscale (60s tick): target streams-per-instance drives the
 *    desired count between LAMBDA_POOL_MIN and LAMBDA_POOL_MAX; one launch
 *    per tick (launch API is rate-limited 1/12s and boots take minutes —
 *    fal absorbs the gap, so aggressive scaling buys nothing).
 *  - Scale-down: an instance with zero streams and 30 min of no activity is
 *    terminated (never below the floor; at most one per tick).
 *  - Health: ready instances are probed every tick; 3 consecutive failures →
 *    terminate + let the scaler replace. In-flight sessions on a dead
 *    instance get re-assigned by stream.ts's recovery path.
 *  - Readiness = OUR /health, never Lambda's `status: active` (lags 27-62s).
 *
 * Capacity model (measured): ~5 fully-served active drawers per instance at
 * 4-step 9B-KV; overload degrades gracefully (fair round-robin), so the
 * TARGET_STREAMS dial is a UX knob, not a stability one.
 */

import { createHmac } from 'node:crypto';
import { request as httpsRequest } from 'node:https';
import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';
import { inBackgroundScope } from '../observability/scope.js';
import { LambdaClient, launchWithRetry, lambdaSleep } from './client.js';

/** Fire-and-forget lifecycle row → lambda_pool_events (H100 waterfall on the
 * Insights Launch tab). Recording must never affect pool operation. */
function recordPoolEvent(
  event: string,
  instanceName?: string,
  region?: string,
  durationMs?: number,
  detail?: string,
): void {
  void query(
    `INSERT INTO lambda_pool_events (event, instance_name, region, duration_ms, detail)
     VALUES ($1, $2, $3, $4, $5)`,
    [event, instanceName ?? null, region ?? null, durationMs ?? null, detail?.slice(0, 500) ?? null],
  ).catch(() => {});
}

const PORT = 8766;
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const NAME_PREFIX = 'kiki-serve-';
const IDLE_TERMINATE_MS = 30 * 60_000;
const TICK_MS = 60_000;
const LAUNCH_RETRY_MINS = 15;
const BOOT_TIMEOUT_MS = 25 * 60_000;
const HEALTH_TIMEOUT_MS = 5_000;
const HEALTH_FAILS_TO_KILL = 3;
/** Boot estimate for the ETA surface. First-ever boot pays full compile
 * (~10 min); with the persisted inductor cache subsequent boots are shorter —
 * refreshed empirically, see plan doc. */
const BOOT_ESTIMATE_MS = 10 * 60_000;

export type DevPoolStatusKind = 'disabled' | 'none' | 'launching' | 'booting' | 'ready' | 'error';

interface PoolInstance {
  id: string;
  name: string;
  region: string;
  ip?: string;
  status: 'launching' | 'booting' | 'ready';
  launchedAtMs: number;
  readyAtMs?: number;
  activeStreams: number;
  lastActivityMs: number;
  healthFails: number;
  /** Re-registered at backend redeploy — launchedAtMs is adoption time, not a
   * real boot start, so waterfall 'ready' timings must exclude it. */
  adopted?: boolean;
}

export interface DevPoolState {
  status: DevPoolStatusKind;
  instanceId?: string;
  ip?: string;
  region: string;
  instanceType: string;
  message: string;
  lastError?: string;
  launchedAtMs?: number;
  readyAtMs?: number;
  etaSeconds: number | null;
  /** Per-instance summary for ops visibility. */
  instances: Array<{
    name: string;
    status: string;
    ip?: string;
    activeStreams: number;
    ageMs: number;
  }>;
}

const instances = new Map<string, PoolInstance>();
let lastError: string | undefined;
let launchesInFlight = 0;
let tickTimer: NodeJS.Timeout | null = null;
let log: FastifyBaseLogger | Console = console;
/** Last time anyone expressed interest (ensure/acquire) — keeps the floor-0
 * pool from launching for nobody. */
let lastInterestMs = 0;

function enabled(): boolean {
  return config.LAMBDA_DEV_POOL_ENABLED && config.LAMBDA_API_KEY.length > 0;
}

function client(): LambdaClient {
  return new LambdaClient(config.LAMBDA_API_KEY);
}

function scheme(): string {
  return config.LAMBDA_TLS_CA ? 'wss' : 'ws';
}

/** GET /health, speaking https with the pinned fleet cert when TLS is
 * configured (hostname check skipped — instances are bare IPs), plain http
 * otherwise. Resolves with the parsed body; rejects on error/timeout. */
function probeHealth(ip: string, timeoutMs: number): Promise<{ status?: string }> {
  if (!config.LAMBDA_TLS_CA) {
    return fetch(`http://${ip}:${PORT}/health`, { signal: AbortSignal.timeout(timeoutMs) }).then(
      (res) => {
        if (!res.ok) throw new Error(`health ${res.status}`);
        return res.json() as Promise<{ status?: string }>;
      },
    );
  }
  return new Promise((resolve, reject) => {
    const req = httpsRequest(
      {
        host: ip,
        port: PORT,
        path: '/health',
        ca: [config.LAMBDA_TLS_CA],
        checkServerIdentity: () => undefined,
        timeout: timeoutMs,
      },
      (res) => {
        if ((res.statusCode ?? 500) >= 400) {
          res.resume();
          reject(new Error(`health ${res.statusCode}`));
          return;
        }
        let body = '';
        res.on('data', (c: Buffer) => (body += c));
        res.on('end', () => {
          try {
            resolve(JSON.parse(body) as { status?: string });
          } catch (err) {
            reject(err as Error);
          }
        });
      },
    );
    req.on('timeout', () => req.destroy(new Error('health timeout')));
    req.on('error', reject);
    req.end();
  });
}

function wsToken(name: string): string {
  return createHmac('sha256', config.LAMBDA_API_KEY).update(name).digest('hex').slice(0, 32);
}

function fsName(region: string): string {
  return `kiki-image-${region}`;
}

function userData(name: string, region: string): string {
  return `#cloud-config
write_files:
  - path: /etc/kiki.env
    permissions: '0600'
    content: |
      KIKI_WS_TOKEN=${wsToken(name)}
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /lambda/nfs/${fsName(region)}/kiki/boot.sh]
`;
}

function readyInstances(): PoolInstance[] {
  return [...instances.values()].filter((i) => i.status === 'ready');
}

function upOrComing(): number {
  return instances.size + launchesInFlight;
}

// ── public API ──────────────────────────────────────────────────────────────

export function touch(): void {
  lastInterestMs = Date.now();
}

/** True when at least one instance is serving (and not marked suspect) —
 * i.e. a new stream asked for right now would actually get a slot. */
export function hasReady(): boolean {
  return assignableInstances().length > 0;
}

/** Instances eligible for NEW stream assignment: ready and not suspect.
 * (healthFails > 0 = a relay just failed to connect, or a tick probe failed —
 * skip it until a probe succeeds and resets the counter. If everything is
 * suspect, callers fall back to fal; nothing is ever assigned blind.) */
function assignableInstances(): PoolInstance[] {
  return readyInstances().filter((i) => i.healthFails === 0);
}

/** A relay failed to reach this instance (connect refused/timeout mid-
 * session). Mark it suspect so assignment skips it NOW instead of waiting
 * out the probe cycle; the tick's probes then either clear it (transient
 * blip — healthFails resets to 0 on the next success) or escalate to the
 * 3-strike terminate. Deliberately only ONE strike per call site: N
 * concurrent sessions failing over must not gang-terminate an instance
 * that's mid-restart. */
export function reportFailure(name: string): void {
  const inst = instances.get(name);
  if (!inst || inst.status !== 'ready') return;
  inst.healthFails = Math.max(inst.healthFails, 1);
  log.warn({ name, event: 'lambda_pool_instance_suspect' }, 'relay connect failed — instance marked suspect');
}

/** Assign a stream to the least-loaded ready instance. Null when none. */
export function acquireStream(): { name: string; url: string } | null {
  lastInterestMs = Date.now();
  const ready = assignableInstances().sort((a, b) => a.activeStreams - b.activeStreams);
  const inst = ready[0];
  if (!inst) return null;
  inst.activeStreams += 1;
  inst.lastActivityMs = Date.now();
  return { name: inst.name, url: `${scheme()}://${inst.ip}:${PORT}/ws?token=${wsToken(inst.name)}` };
}

/** Release a stream slot (on session close or re-assignment). */
export function releaseStream(name: string): void {
  const inst = instances.get(name);
  if (inst) inst.activeStreams = Math.max(0, inst.activeStreams - 1);
}

/** Record instance-level activity (frames flowing) for the idle policy. */
export function touchInstance(name: string): void {
  const inst = instances.get(name);
  if (inst) inst.lastActivityMs = Date.now();
  lastInterestMs = Date.now();
}

/** One-shot URL (sketchify): least-loaded ready instance, no slot held. */
export function wsUrl(): string | null {
  const ready = assignableInstances().sort((a, b) => a.activeStreams - b.activeStreams);
  const inst = ready[0];
  if (!inst?.ip) return null;
  touchInstance(inst.name);
  return `${scheme()}://${inst.ip}:${PORT}/ws?token=${wsToken(inst.name)}`;
}

/** User interest: make sure at least one instance exists/is coming. */
export function ensure(): DevPoolState {
  lastInterestMs = Date.now();
  if (enabled() && instances.size === 0 && launchesInFlight === 0) {
    lastError = undefined;
    void inBackgroundScope('lambda_pool', () => launchOne());
  }
  return getState();
}

export function getState(): DevPoolState {
  const list = [...instances.values()];
  const ready = list.filter((i) => i.status === 'ready');
  const booting = list.filter((i) => i.status === 'booting');
  const launching = launchesInFlight > 0 || list.some((i) => i.status === 'launching');

  let status: DevPoolStatusKind;
  if (!enabled()) status = 'disabled';
  else if (ready.length > 0) status = 'ready';
  else if (booting.length > 0) status = 'booting';
  else if (launching) status = 'launching';
  else if (lastError) status = 'error';
  else status = 'none';

  // ETA from the most-advanced booting instance.
  let etaSeconds: number | null = null;
  let launchedAtMs: number | undefined;
  let readyAtMs: number | undefined;
  const front = booting.sort((a, b) => a.launchedAtMs - b.launchedAtMs)[0];
  if (status === 'booting' && front) {
    launchedAtMs = front.launchedAtMs;
    etaSeconds = Math.max(15, Math.round((BOOT_ESTIMATE_MS - (Date.now() - front.launchedAtMs)) / 1000));
  }
  if (status === 'ready') {
    readyAtMs = ready[0]?.readyAtMs;
  }

  const messages: Record<DevPoolStatusKind, string> = {
    disabled: 'Lambda pool disabled (LAMBDA_DEV_POOL_ENABLED / LAMBDA_API_KEY unset)',
    none: 'No instance',
    launching: 'Requesting H100 capacity…',
    booting: `Instance booting${front?.ip ? ` at ${front.ip}` : ''}`,
    ready: `${ready.length} H100${ready.length === 1 ? '' : 's'} ready · ${ready.reduce((a, i) => a + i.activeStreams, 0)} active streams`,
    error: `Error: ${lastError ?? 'unknown'}`,
  };

  return {
    status,
    instanceId: ready[0]?.id ?? front?.id,
    ip: ready[0]?.ip ?? front?.ip,
    region: config.LAMBDA_REGION,
    instanceType: config.LAMBDA_INSTANCE_TYPE,
    message: messages[status],
    lastError,
    launchedAtMs,
    readyAtMs,
    etaSeconds,
    instances: list.map((i) => ({
      name: i.name,
      status: i.status,
      ip: i.ip,
      activeStreams: i.activeStreams,
      ageMs: Date.now() - i.launchedAtMs,
    })),
  };
}

// ── launch / boot ───────────────────────────────────────────────────────────

async function launchOne(): Promise<void> {
  if (!enabled()) return;
  if (upOrComing() >= config.LAMBDA_POOL_MAX) return;
  launchesInFlight += 1;
  const name = `${NAME_PREFIX}${Date.now()}`;
  const region = config.LAMBDA_REGION;
  const searchStartMs = Date.now();
  recordPoolEvent('launch_requested', name, region);
  try {
    const c = client();
    const keys = await c.listSshKeys();
    const firstKey = keys[0];
    if (!firstKey) throw new Error('no SSH key registered on the Lambda account');
    const [id] = await launchWithRetry(
      c,
      {
        region_name: region,
        instance_type_name: config.LAMBDA_INSTANCE_TYPE,
        ssh_key_names: [firstKey.name],
        file_system_names: [fsName(region)],
        name,
        image: { family: OS_IMAGE_FAMILY },
        user_data: userData(name, region),
      },
      LAUNCH_RETRY_MINS,
      undefined,
      (msg) => log.info({ event: 'lambda_pool_launch_retry' }, msg),
    );
    if (!id) throw new Error('Lambda launch returned no instance id');
    instances.set(name, {
      id,
      name,
      region,
      status: 'booting',
      launchedAtMs: Date.now(),
      activeStreams: 0,
      lastActivityMs: Date.now(),
      healthFails: 0,
    });
    log.info({ instanceId: id, name, event: 'lambda_pool_launched' }, 'launched kiki-serve instance');
    // duration = how long the capacity search took (launch API retries).
    recordPoolEvent('launched', name, region, Date.now() - searchStartMs);
    await watchBoot(name);
  } catch (err) {
    lastError = (err as Error).message;
    log.error({ err, event: 'lambda_pool_launch_failed' }, 'lambda pool launch failed');
    recordPoolEvent('launch_failed', name, region, Date.now() - searchStartMs, (err as Error).message);
  } finally {
    launchesInFlight -= 1;
  }
}

/** True boot-start epoch: the name suffix IS the launch timestamp
 * (`kiki-serve-<epochMs>`), which survives backend redeploys. Adoption sets
 * launchedAtMs to adoption time, so without this a wedged instance gets a
 * FRESH 25-min boot deadline on every redeploy and can stall forever under
 * frequent deploys (observed 2026-07-18). Falls back to launchedAtMs for
 * unparseable names. */
function trueLaunchMs(inst: PoolInstance): number {
  const suffix = Number(inst.name.slice(NAME_PREFIX.length));
  return Number.isFinite(suffix) && suffix > 1_700_000_000_000 ? suffix : inst.launchedAtMs;
}

async function watchBoot(name: string): Promise<void> {
  const c = client();
  const inst = instances.get(name);
  if (!inst) return;
  // Deadline from TRUE launch time, with a 5-min floor from now so a
  // just-redeployed backend still gives a genuinely-booting instance a
  // grace window before declaring it stalled.
  const deadline = Math.max(trueLaunchMs(inst) + BOOT_TIMEOUT_MS, Date.now() + 5 * 60_000);
  // IP first…
  while (!inst.ip) {
    if (Date.now() > deadline) throw new Error(`boot timed out waiting for IP (${name})`);
    if (!instances.has(name)) return; // terminated meanwhile
    try {
      const remote = await c.getInstance(inst.id);
      if (['terminated', 'terminating', 'unhealthy', 'preempted'].includes(remote.status)) {
        instances.delete(name);
        throw new Error(`instance entered ${remote.status} during boot`);
      }
      if (remote.ip) inst.ip = remote.ip;
    } catch (err) {
      if (!/fetch failed|ENOTFOUND|ETIMEDOUT|ECONNRESET/.test((err as Error).message)) throw err;
    }
    if (!inst.ip) await lambdaSleep(5000);
  }
  // …then OUR /health.
  for (;;) {
    if (Date.now() > deadline) {
      instances.delete(name);
      void c.terminate([inst.id]).catch(() => {});
      recordPoolEvent('boot_stalled', name, inst.region, Date.now() - trueLaunchMs(inst));
      throw new Error(`boot timed out waiting for /health (${name})`);
    }
    if (!instances.has(name)) return;
    try {
      const health = await probeHealth(inst.ip, 3000);
      if (health.status === 'ok') break;
    } catch {
      // not up yet
    }
    await lambdaSleep(5000);
  }
  inst.status = 'ready';
  inst.readyAtMs = Date.now();
  inst.lastActivityMs = Date.now();
  log.info(
    { instanceId: inst.id, name, ip: inst.ip, bootMs: inst.readyAtMs - inst.launchedAtMs, event: 'lambda_pool_ready' },
    'lambda pool instance ready',
  );
  // duration = boot/warm time (capacity granted → OUR /health ok). Adopted
  // instances skip this — their launchedAtMs is adoption time, and a ~0s
  // "boot" would corrupt the waterfall's boot p50.
  if (!inst.adopted) recordPoolEvent('ready', name, inst.region, inst.readyAtMs - inst.launchedAtMs);
}

// ── periodic tick: autoscale + idle scale-down + health ─────────────────────

async function tick(): Promise<void> {
  if (!enabled()) return;

  // Health-check ready instances (parallel, bounded by instance count).
  await Promise.all(
    readyInstances().map(async (inst) => {
      if (!inst.ip) return;
      try {
        await probeHealth(inst.ip, HEALTH_TIMEOUT_MS);
        inst.healthFails = 0;
      } catch {
        inst.healthFails += 1;
        if (inst.healthFails >= HEALTH_FAILS_TO_KILL) {
          log.warn(
            { name: inst.name, instanceId: inst.id, event: 'lambda_pool_instance_dead' },
            'instance failed health checks — terminating (scaler will replace if needed)',
          );
          recordPoolEvent(
            'instance_dead',
            inst.name,
            inst.region,
            inst.readyAtMs !== undefined ? Date.now() - inst.readyAtMs : undefined,
          );
          instances.delete(inst.name);
          void client().terminate([inst.id]).catch(() => {});
        }
      }
    }),
  );

  // Desired count from live pressure. Interest within the last 10 min keeps
  // at least one instance warm even before any stream lands (login pre-warm).
  const totalStreams = [...instances.values()].reduce((a, i) => a + i.activeStreams, 0);
  const interested = Date.now() - lastInterestMs < 10 * 60_000;
  const pressureNeed = Math.ceil(totalStreams / Math.max(1, config.LAMBDA_POOL_TARGET_STREAMS));
  const need = Math.min(
    config.LAMBDA_POOL_MAX,
    Math.max(config.LAMBDA_POOL_MIN, pressureNeed, interested && totalStreams === 0 ? 1 : 0),
  );

  if (upOrComing() < need) {
    void inBackgroundScope('lambda_pool', () => launchOne());
  }

  // Idle scale-down: one per tick, never below the floor or below need.
  if (instances.size > Math.max(config.LAMBDA_POOL_MIN, need)) {
    const idle = readyInstances()
      .filter((i) => i.activeStreams === 0 && Date.now() - i.lastActivityMs > IDLE_TERMINATE_MS)
      .sort((a, b) => a.lastActivityMs - b.lastActivityMs)[0];
    if (idle) {
      log.info(
        { name: idle.name, instanceId: idle.id, idleMs: Date.now() - idle.lastActivityMs, event: 'lambda_pool_idle_terminate' },
        'terminating idle pool instance',
      );
      recordPoolEvent('idle_terminate', idle.name, idle.region, Date.now() - idle.lastActivityMs);
      instances.delete(idle.name);
      void client().terminate([idle.id]).catch(() => {});
    }
  }

  // Retention for the waterfall's raw rows (tiny table; cheap on the ts index).
  void query(`DELETE FROM lambda_pool_events WHERE ts < now() - interval '30 days'`).catch(() => {});
}

// ── lifecycle ───────────────────────────────────────────────────────────────

export function start(logger: FastifyBaseLogger): void {
  log = logger;
  if (!enabled()) {
    logger.info('lambda pool disabled (LAMBDA_DEV_POOL_ENABLED/LAMBDA_API_KEY unset)');
    return;
  }
  tickTimer = setInterval(() => void inBackgroundScope('lambda_pool', () => tick()), TICK_MS);
  // Adopt instances surviving a redeploy: register as booting; the boot
  // watcher promotes them to ready via /health (usually instantly).
  void inBackgroundScope('lambda_pool', async () => {
    try {
      const existing = (await client().listInstances()).filter(
        (i) => i.name?.startsWith(NAME_PREFIX) && ['booting', 'active'].includes(i.status),
      );
      for (const remote of existing) {
        const name = remote.name as string;
        if (instances.has(name)) continue;
        instances.set(name, {
          id: remote.id,
          name,
          region: remote.region.name,
          ip: remote.ip ?? undefined,
          status: 'booting',
          launchedAtMs: Date.now(),
          adopted: true,
          activeStreams: 0,
          lastActivityMs: Date.now(),
          healthFails: 0,
        });
        log.info({ instanceId: remote.id, name, event: 'lambda_pool_adopted' }, 'adopted existing kiki-serve instance');
        recordPoolEvent('adopted', name, remote.region.name);
        void inBackgroundScope('lambda_pool', () =>
          watchBoot(name).catch((err: Error) => {
            log.warn({ name, err: err.message, event: 'lambda_pool_adopted_boot_failed' }, 'adopted instance never became healthy');
          }),
        );
      }
    } catch (err) {
      logger.warn({ err, event: 'lambda_pool_reconcile_failed' }, 'lambda pool startup reconcile failed');
    }
  });
}

export function stop(): void {
  if (tickTimer) clearInterval(tickTimer);
  tickTimer = null;
}
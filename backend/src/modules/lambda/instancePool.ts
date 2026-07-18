/**
 * Generic Lambda Cloud H100 pool — the orchestration machinery shared by the
 * IMAGE pool (modules/lambda/devPool.ts, `kiki-serve-*`) and the VIDEO pool
 * (modules/lambda/videoPool.ts, `kiki-video-*`). Factored out 2026-07-18:
 * the two fleets differ only in the node being spun up (name prefix,
 * filesystem, scaling dials) — launch/boot/health/adopt/scale logic is
 * identical.
 *
 * Behavior (unchanged from the pre-factor devPool):
 *  - Registry of `<prefix>*` instances (launching → booting → ready),
 *    adopted across backend redeploys by name prefix + deterministic token.
 *  - Streams are ASSIGNED to the least-loaded ready instance
 *    (`acquireStream`/`releaseStream`); one-shots use `wsUrl()`.
 *  - Sluggish autoscale (60s tick): target streams-per-instance drives the
 *    desired count between poolMin and poolMax; one launch per tick (launch
 *    API is rate-limited 1/12s and boots take minutes — the caller's
 *    fallback path absorbs the gap, so aggressive scaling buys nothing).
 *  - Scale-down: an instance with zero streams and 30 min of no activity is
 *    terminated (never below the floor; at most one per tick).
 *  - Health: ready instances are probed every tick; 3 consecutive failures →
 *    terminate + let the scaler replace. Relays mark instances suspect on
 *    connect failure (`reportFailure`) so assignment skips them immediately.
 *  - Readiness = OUR /health, never Lambda's `status: active` (lags 27-62s).
 *
 * Test seams: `createClient`, `probeHealth`, and the timing dials are
 * injectable via the spec; production instantiations omit them.
 */

import { createHmac } from 'node:crypto';
import { request as httpsRequest } from 'node:https';
import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';
import { inBackgroundScope } from '../observability/scope.js';
import { LambdaClient, launchWithRetry, lambdaSleep } from './client.js';

const PORT = 8766;
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const HEALTH_TIMEOUT_MS = 5_000;
const HEALTH_FAILS_TO_KILL = 3;

export type DevPoolStatusKind = 'disabled' | 'none' | 'launching' | 'booting' | 'ready' | 'error';

export interface PoolInstanceSummary {
  name: string;
  status: string;
  ip?: string;
  activeStreams: number;
  ageMs: number;
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
  instances: PoolInstanceSummary[];
}

export interface InstancePoolSpec {
  /** Pool identity for events/logs: 'image' | 'video'. Stamped into the
   * lambda_pool_events `pool` column so the Insights waterfall can separate
   * fleets, and onto every pool log line. */
  kind: string;
  /** Instance name prefix, e.g. 'kiki-serve-' / 'kiki-video-'. Also the
   * adoption filter — anything else matching it (setup instances!) must use
   * a non-colliding name. */
  namePrefix: string;
  /** Per-region filesystem holding venv+weights+boot.sh, e.g.
   * `kiki-image-${region}`. */
  fsName: (region: string) => string;
  /** Human label used in state messages ("H100" / "video H100"). */
  label: string;
  enabled: () => boolean;
  region: () => string;
  instanceType: () => string;
  poolMin: () => number;
  poolMax: () => number;
  targetStreams: () => number;
  /** Boot estimate for the ETA surface. */
  bootEstimateMs: number;
  // ── test seams (production omits — real implementations used) ──────────
  createClient?: () => LambdaClient;
  probeHealth?: (ip: string, timeoutMs: number) => Promise<{ status?: string }>;
  tickMs?: number;
  idleTerminateMs?: number;
  bootTimeoutMs?: number;
  /** Boot-watch poll cadence (IP + /health). */
  pollMs?: number;
  launchRetryMins?: number;
  /** How recently touch()/acquire must have happened to count as "user
   * interest" (keeps one instance warm on a floor-0 pool). */
  interestWindowMs?: number;
}

export interface InstancePool {
  touch(): void;
  hasReady(): boolean;
  reportFailure(name: string): void;
  acquireStream(): { name: string; url: string } | null;
  releaseStream(name: string): void;
  touchInstance(name: string): void;
  wsUrl(): string | null;
  ensure(): DevPoolState;
  getState(): DevPoolState;
  start(logger: FastifyBaseLogger): void;
  stop(): void;
}

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

/** Default /health probe: https with the pinned fleet cert when TLS is
 * configured (hostname check skipped — instances are bare IPs), plain http
 * otherwise. */
function defaultProbeHealth(ip: string, timeoutMs: number): Promise<{ status?: string }> {
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

export function createInstancePool(spec: InstancePoolSpec): InstancePool {
  const TICK_MS = spec.tickMs ?? 60_000;
  const IDLE_TERMINATE_MS = spec.idleTerminateMs ?? 30 * 60_000;
  const BOOT_TIMEOUT_MS = spec.bootTimeoutMs ?? 25 * 60_000;
  const POLL_MS = spec.pollMs ?? 5_000;
  const LAUNCH_RETRY_MINS = spec.launchRetryMins ?? 15;
  const INTEREST_WINDOW_MS = spec.interestWindowMs ?? 10 * 60_000;
  const probeHealth = spec.probeHealth ?? defaultProbeHealth;
  const scopeName = `lambda_pool_${spec.kind}`;

  /** Fire-and-forget lifecycle row → lambda_pool_events (waterfalls on the
   * Insights Launch tab). Recording must never affect pool operation. */
  function recordPoolEvent(
    event: string,
    instanceName?: string,
    region?: string,
    durationMs?: number,
    detail?: string,
  ): void {
    void query(
      `INSERT INTO lambda_pool_events (event, instance_name, region, duration_ms, detail, pool)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [event, instanceName ?? null, region ?? null, durationMs ?? null, detail?.slice(0, 500) ?? null, spec.kind],
    ).catch(() => {});
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
    return spec.enabled();
  }

  function client(): LambdaClient {
    return spec.createClient ? spec.createClient() : new LambdaClient(config.LAMBDA_API_KEY);
  }

  function scheme(): string {
    return config.LAMBDA_TLS_CA ? 'wss' : 'ws';
  }

  function wsToken(name: string): string {
    return createHmac('sha256', config.LAMBDA_API_KEY).update(name).digest('hex').slice(0, 32);
  }

  function userData(name: string, region: string): string {
    return `#cloud-config
write_files:
  - path: /etc/kiki.env
    permissions: '0600'
    content: |
      KIKI_WS_TOKEN=${wsToken(name)}
runcmd:
  - [systemd-run, --unit=kiki, --property=Restart=on-failure, bash, /lambda/nfs/${spec.fsName(region)}/kiki/boot.sh]
`;
  }

  function readyInstances(): PoolInstance[] {
    return [...instances.values()].filter((i) => i.status === 'ready');
  }

  function upOrComing(): number {
    return instances.size + launchesInFlight;
  }

  /** Instances eligible for NEW stream assignment: ready and not suspect.
   * (healthFails > 0 = a relay just failed to connect, or a tick probe failed —
   * skip it until a probe succeeds and resets the counter. If everything is
   * suspect, callers fall back; nothing is ever assigned blind.) */
  function assignableInstances(): PoolInstance[] {
    return readyInstances().filter((i) => i.healthFails === 0);
  }

  // ── public API ──────────────────────────────────────────────────────────

  function touch(): void {
    lastInterestMs = Date.now();
  }

  function hasReady(): boolean {
    return assignableInstances().length > 0;
  }

  /** A relay failed to reach this instance (connect refused/timeout mid-
   * session). Mark it suspect so assignment skips it NOW instead of waiting
   * out the probe cycle; the tick's probes then either clear it (transient
   * blip — healthFails resets to 0 on the next success) or escalate to the
   * 3-strike terminate. Deliberately only ONE strike per call site: N
   * concurrent sessions failing over must not gang-terminate an instance
   * that's mid-restart. */
  function reportFailure(name: string): void {
    const inst = instances.get(name);
    if (!inst || inst.status !== 'ready') return;
    inst.healthFails = Math.max(inst.healthFails, 1);
    log.warn({ name, pool: spec.kind, event: 'lambda_pool_instance_suspect' }, 'relay connect failed — instance marked suspect');
  }

  /** Assign a stream to the least-loaded ready instance. Null when none. */
  function acquireStream(): { name: string; url: string } | null {
    lastInterestMs = Date.now();
    const ready = assignableInstances().sort((a, b) => a.activeStreams - b.activeStreams);
    const inst = ready[0];
    if (!inst) return null;
    inst.activeStreams += 1;
    inst.lastActivityMs = Date.now();
    return { name: inst.name, url: `${scheme()}://${inst.ip}:${PORT}/ws?token=${wsToken(inst.name)}` };
  }

  /** Release a stream slot (on session close or re-assignment). */
  function releaseStream(name: string): void {
    const inst = instances.get(name);
    if (inst) inst.activeStreams = Math.max(0, inst.activeStreams - 1);
  }

  /** Record instance-level activity (frames flowing) for the idle policy. */
  function touchInstance(name: string): void {
    const inst = instances.get(name);
    if (inst) inst.lastActivityMs = Date.now();
    lastInterestMs = Date.now();
  }

  /** One-shot URL (sketchify): least-loaded ready instance, no slot held. */
  function wsUrl(): string | null {
    const ready = assignableInstances().sort((a, b) => a.activeStreams - b.activeStreams);
    const inst = ready[0];
    if (!inst?.ip) return null;
    touchInstance(inst.name);
    return `${scheme()}://${inst.ip}:${PORT}/ws?token=${wsToken(inst.name)}`;
  }

  /** User interest: make sure at least one instance exists/is coming. */
  function ensure(): DevPoolState {
    lastInterestMs = Date.now();
    if (enabled() && instances.size === 0 && launchesInFlight === 0) {
      lastError = undefined;
      void inBackgroundScope(scopeName, () => launchOne());
    }
    return getState();
  }

  function getState(): DevPoolState {
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
      etaSeconds = Math.max(15, Math.round((spec.bootEstimateMs - (Date.now() - front.launchedAtMs)) / 1000));
    }
    if (status === 'ready') {
      readyAtMs = ready[0]?.readyAtMs;
    }

    const messages: Record<DevPoolStatusKind, string> = {
      disabled: `Lambda ${spec.label} pool disabled`,
      none: 'No instance',
      launching: `Requesting ${spec.label} capacity…`,
      booting: `Instance booting${front?.ip ? ` at ${front.ip}` : ''}`,
      ready: `${ready.length} ${spec.label}${ready.length === 1 ? '' : 's'} ready · ${ready.reduce((a, i) => a + i.activeStreams, 0)} active streams`,
      error: `Error: ${lastError ?? 'unknown'}`,
    };

    return {
      status,
      instanceId: ready[0]?.id ?? front?.id,
      ip: ready[0]?.ip ?? front?.ip,
      region: spec.region(),
      instanceType: spec.instanceType(),
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

  // ── launch / boot ───────────────────────────────────────────────────────

  async function launchOne(): Promise<void> {
    if (!enabled()) return;
    if (upOrComing() >= spec.poolMax()) return;
    launchesInFlight += 1;
    const name = `${spec.namePrefix}${Date.now()}`;
    const region = spec.region();
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
          instance_type_name: spec.instanceType(),
          ssh_key_names: [firstKey.name],
          file_system_names: [spec.fsName(region)],
          name,
          image: { family: OS_IMAGE_FAMILY },
          user_data: userData(name, region),
        },
        LAUNCH_RETRY_MINS,
        undefined,
        (msg) => log.info({ pool: spec.kind, event: 'lambda_pool_launch_retry' }, msg),
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
      log.info({ instanceId: id, name, pool: spec.kind, event: 'lambda_pool_launched' }, `launched ${spec.namePrefix} instance`);
      // duration = how long the capacity search took (launch API retries).
      recordPoolEvent('launched', name, region, Date.now() - searchStartMs);
      await watchBoot(name);
    } catch (err) {
      lastError = (err as Error).message;
      log.error({ err, pool: spec.kind, event: 'lambda_pool_launch_failed' }, 'lambda pool launch failed');
      recordPoolEvent('launch_failed', name, region, Date.now() - searchStartMs, (err as Error).message);
    } finally {
      launchesInFlight -= 1;
    }
  }

  /** True boot-start epoch: the name suffix IS the launch timestamp
   * (`<prefix><epochMs>`), which survives backend redeploys. Adoption sets
   * launchedAtMs to adoption time, so without this a wedged instance gets a
   * FRESH boot deadline on every redeploy and can stall forever under
   * frequent deploys (observed 2026-07-18). Falls back to launchedAtMs for
   * unparseable names. */
  function trueLaunchMs(inst: PoolInstance): number {
    const suffix = Number(inst.name.slice(spec.namePrefix.length));
    return Number.isFinite(suffix) && suffix > 1_700_000_000_000 ? suffix : inst.launchedAtMs;
  }

  async function watchBoot(name: string): Promise<void> {
    const c = client();
    const inst = instances.get(name);
    if (!inst) return;
    // Deadline from TRUE launch time, with a floor from now so a
    // just-redeployed backend still gives a genuinely-booting instance a
    // grace window before declaring it stalled.
    const graceMs = Math.min(5 * 60_000, BOOT_TIMEOUT_MS / 5);
    const deadline = Math.max(trueLaunchMs(inst) + BOOT_TIMEOUT_MS, Date.now() + graceMs);
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
      if (!inst.ip) await lambdaSleep(POLL_MS);
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
      await lambdaSleep(POLL_MS);
    }
    inst.status = 'ready';
    inst.readyAtMs = Date.now();
    inst.lastActivityMs = Date.now();
    log.info(
      { instanceId: inst.id, name, ip: inst.ip, bootMs: inst.readyAtMs - inst.launchedAtMs, pool: spec.kind, event: 'lambda_pool_ready' },
      'lambda pool instance ready',
    );
    // duration = boot/warm time (capacity granted → OUR /health ok). Adopted
    // instances skip this — their launchedAtMs is adoption time, and a ~0s
    // "boot" would corrupt the waterfall's boot p50.
    if (!inst.adopted) recordPoolEvent('ready', name, inst.region, inst.readyAtMs - inst.launchedAtMs);
  }

  // ── periodic tick: autoscale + idle scale-down + health ─────────────────

  async function tick(): Promise<void> {
    if (!enabled()) {
      // DRAIN, don't just idle: a pool disabled at runtime (Insights feature
      // flag, env flip) must not leave instances running — with the tick's
      // normal path off, nothing else would ever reap them and they'd bill
      // until someone noticed. Registry adoption still runs at start() (key
      // permitting), so even instances from before a redeploy get drained.
      if (config.LAMBDA_API_KEY && instances.size > 0) {
        for (const inst of [...instances.values()]) {
          log.info(
            { name: inst.name, instanceId: inst.id, pool: spec.kind, event: 'lambda_pool_disabled_terminate' },
            'pool disabled — terminating instance',
          );
          recordPoolEvent('disabled_terminate', inst.name, inst.region);
          instances.delete(inst.name);
          void client().terminate([inst.id]).catch(() => {});
        }
      }
      return;
    }

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
              { name: inst.name, instanceId: inst.id, pool: spec.kind, event: 'lambda_pool_instance_dead' },
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

    // Desired count from live pressure. Interest within the window keeps
    // at least one instance warm even before any stream lands (login pre-warm).
    const totalStreams = [...instances.values()].reduce((a, i) => a + i.activeStreams, 0);
    const interested = Date.now() - lastInterestMs < INTEREST_WINDOW_MS;
    const pressureNeed = Math.ceil(totalStreams / Math.max(1, spec.targetStreams()));
    const need = Math.min(
      spec.poolMax(),
      Math.max(spec.poolMin(), pressureNeed, interested && totalStreams === 0 ? 1 : 0),
    );

    if (upOrComing() < need) {
      void inBackgroundScope(scopeName, () => launchOne());
    }

    // Idle scale-down: one per tick, never below the floor or below need.
    if (instances.size > Math.max(spec.poolMin(), need)) {
      const idle = readyInstances()
        .filter((i) => i.activeStreams === 0 && Date.now() - i.lastActivityMs > IDLE_TERMINATE_MS)
        .sort((a, b) => a.lastActivityMs - b.lastActivityMs)[0];
      if (idle) {
        log.info(
          { name: idle.name, instanceId: idle.id, idleMs: Date.now() - idle.lastActivityMs, pool: spec.kind, event: 'lambda_pool_idle_terminate' },
          'terminating idle pool instance',
        );
        recordPoolEvent('idle_terminate', idle.name, idle.region, Date.now() - idle.lastActivityMs);
        instances.delete(idle.name);
        void client().terminate([idle.id]).catch(() => {});
      }
    }

    // Retention for the waterfall's raw rows (tiny table; cheap on the ts
    // index; idempotent across pools).
    void query(`DELETE FROM lambda_pool_events WHERE ts < now() - interval '30 days'`).catch(() => {});
  }

  // ── lifecycle ───────────────────────────────────────────────────────────

  function start(logger: FastifyBaseLogger): void {
    log = logger;
    // The tick timer runs even while disabled: enabled() is re-read every
    // tick, so a runtime flag flip (Insights) takes effect within ~60s in
    // BOTH directions — on → adopt/launch, off → drain (see tick()).
    tickTimer = setInterval(() => void inBackgroundScope(scopeName, () => tick()), TICK_MS);
    if (!config.LAMBDA_API_KEY) {
      logger.info(`lambda ${spec.kind} pool: no LAMBDA_API_KEY — inert`);
      return;
    }
    if (!enabled()) {
      logger.info(`lambda ${spec.kind} pool disabled (drain-only)`);
    }
    // Adopt instances surviving a redeploy: register as booting; the boot
    // watcher promotes them to ready via /health (usually instantly). Runs
    // even when disabled so leftover instances are found and drained.
    void inBackgroundScope(scopeName, async () => {
      try {
        const existing = (await client().listInstances()).filter(
          (i) => i.name?.startsWith(spec.namePrefix) && ['booting', 'active'].includes(i.status),
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
          log.info({ instanceId: remote.id, name, pool: spec.kind, event: 'lambda_pool_adopted' }, `adopted existing ${spec.namePrefix} instance`);
          recordPoolEvent('adopted', name, remote.region.name);
          void inBackgroundScope(scopeName, () =>
            watchBoot(name).catch((err: Error) => {
              log.warn({ name, err: err.message, pool: spec.kind, event: 'lambda_pool_adopted_boot_failed' }, 'adopted instance never became healthy');
            }),
          );
        }
      } catch (err) {
        logger.warn({ err, pool: spec.kind, event: 'lambda_pool_reconcile_failed' }, 'lambda pool startup reconcile failed');
      }
    });
  }

  function stop(): void {
    if (tickTimer) clearInterval(tickTimer);
    tickTimer = null;
  }

  return {
    touch,
    hasReady,
    reportFailure,
    acquireStream,
    releaseStream,
    touchInstance,
    wsUrl,
    ensure,
    getState,
    start,
    stop,
  };
}

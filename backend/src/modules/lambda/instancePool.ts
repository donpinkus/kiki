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
 *
 * ── WHY IS AN INSTANCE ALIVE? (decision table — read this before diagnosing)
 * The tick reaps an instance only when EVERY row below says "reapable".
 * Each instance's current verdict is COMPUTED and exposed as
 * `holdReason` in getState() (→ /v1/dev/lambda/status) and logged on
 * change (`event:lambda_pool_instance_hold`) — query it, don't derive it.
 *
 * | Condition (checked in order)              | Verdict            |
 * |-------------------------------------------|--------------------|
 * | status is launching/booting               | held: booting      |
 * | activeStreams > 0                         | held: active streams (a LEAKED slot also pins — check clients) |
 * | pool size ≤ need, where need ≥ 1 because  |                    |
 * |   interest < 10 min ago (see interest log)| held: interest — getState().interest says WHO and WHEN |
 * |   or LAMBDA_*POOL_MIN floor               | held: floor        |
 * |   or stream pressure                      | held: pressure     |
 * | idle < 30 min (lastActivityMs)            | held: idle countdown (reaps in ~N min) |
 * | none of the above                         | reaped this tick   |
 *
 * "Interest" = a user-facing reason to keep one instance warm: stream opens
 * / ensure (image), animation fires (video — NOT stream opens, changed
 * 2026-07-19). Every interest touch records its SOURCE (with the client
 * fingerprint), kept in a ring buffer on getState().interest.recent.
 */

import { createHmac } from 'node:crypto';
import { request as httpsRequest } from 'node:https';
import type { FastifyBaseLogger } from 'fastify';
import { config } from '../../config/index.js';
import { query } from '../../postgres/client.js';
import { inBackgroundScope } from '../observability/scope.js';
import { LambdaClient, isRetryableLaunchError, lambdaSleep, spacedLaunch } from './client.js';
import { latest as latestCapacity, type CapacitySnapshot } from './capacityMonitor.js';

const PORT = 8766;
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const HEALTH_TIMEOUT_MS = 5_000;
const HEALTH_FAILS_TO_KILL = 3;

export type PoolStatusKind = 'disabled' | 'none' | 'launching' | 'booting' | 'ready' | 'error';

/** /health payload. Servers additionally report kernel + process start
 * epochs and per-phase init timings (model-servers image/video get_info),
 * which the ready event folds into its detail column so every boot's time
 * is decomposed (provision vs OS vs our stack) without SSHing anywhere. */
export interface HealthInfo {
  status?: string;
  booted_at_epoch_s?: number;
  started_at_epoch_s?: number;
  phase_timings_ms?: Record<string, number>;
  [key: string]: unknown;
}

export interface PoolInstanceSummary {
  name: string;
  status: string;
  ip?: string;
  region: string;
  activeStreams: number;
  ageMs: number;
  /** WHY the tick kept this instance (computed, human-readable — the
   * anti-misdiagnosis field). */
  holdReason: string;
}

export interface PoolState {
  status: PoolStatusKind;
  instanceId?: string;
  ip?: string;
  region: string;
  instanceType: string;
  message: string;
  lastError?: string;
  launchedAtMs?: number;
  readyAtMs?: number;
  etaSeconds: number | null;
  /** Epoch ms when the CURRENT capacity search started (status 'launching');
   * undefined otherwise. Search duration is capacity-bound and unpredictable
   * (minutes to hours) — clients show elapsed, never an ETA. */
  searchStartedAtMs?: number;
  /** The pool's boot estimate (capacity granted → healthy), for client-side
   * determinate progress bars. Boot durations ARE consistent (image p50
   * ~4 min, video ~5.5 min measured 2026-07-18). */
  bootEstimateSeconds: number;
  /** Per-instance summary for ops visibility. */
  instances: PoolInstanceSummary[];
  /** Interest attribution: who last kept this pool warm (see the decision
   * table in the module header). */
  interest: {
    ageMs: number | null;
    lastSource: string | null;
    recent: Array<{ at: number; source: string }>;
  };
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
  /** Ordered capacity-search space. The sweep is TYPE-MAJOR: for each type
   * (best first), try every region before falling to the next type — a
   * worse GPU anywhere is accepted ONLY after every region has been asked
   * for the better type. Every region listed MUST have a populated
   * `fsName(region)` filesystem (operator-managed; launching into an
   * unpopulated region boots a dead instance). */
  regions: () => string[];
  instanceTypes: () => string[];
  poolMin: () => number;
  poolMax: () => number;
  targetStreams: () => number;
  /** Boot estimate for the ETA surface. */
  bootEstimateMs: number;
  /** Hedged launch: when the pool has NO ready instance and its oldest
   * booting instance exceeds this age, launch ONE extra instance and keep
   * whichever passes /health first (the still-booting loser is terminated).
   * Rationale: VM provisioning (launch accepted → kernel boot) dominates
   * slow boots and is per-VM luck — 2.5 min vs 14 min observed in the same
   * region/hour (2026-08-22) — so a fresh draw usually beats a stuck one.
   * Bounded to one hedge pair at a time; may transiently exceed poolMax by
   * one. 0/undefined disables. */
  hedgeAfterMs?: number;
  // ── test seams (production omits — real implementations used) ──────────
  createClient?: () => LambdaClient;
  probeHealth?: (ip: string, timeoutMs: number) => Promise<HealthInfo>;
  tickMs?: number;
  idleTerminateMs?: number;
  bootTimeoutMs?: number;
  /** Boot-watch poll cadence (IP + /health). */
  pollMs?: number;
  launchRetryMins?: number;
  /** Account-wide launch API spacing override (tests: 0). */
  launchSpacingMs?: number;
  /** How recently touch()/acquire must have happened to count as "user
   * interest" (keeps one instance warm on a floor-0 pool). */
  interestWindowMs?: number;
  /** Latest advertised-capacity snapshot (defaults to capacityMonitor's
   * in-memory poll). The sweep tries advertised cells FIRST — a 12-cell pass
   * at the 13 s launch spacing is ~2.6 min, and the data (2026-09-12) showed
   * hunts spending p90 3.8 min walking dry cells while an open one sat
   * further down the list. Test seam. */
  capacitySnapshot?: () => CapacitySnapshot | null;
  /** Measured launch→ready p50 per 'type@region' cell (ms), from
   * lambda_pool_events over 30 days. Orders advertised cells fastest-boot
   * first within a type tier (us-southeast-1 H100 boots in 2.5 min p50,
   * us-south-2 in 15.8 — same SKU) and scales the hedge trigger. Test seam. */
  cellBootStats?: () => Promise<Map<string, number>>;
  /** How long a cell that produced a dead-on-arrival VM (boot_load_error /
   * boot_stalled) is demoted to the back of the sweep. Default 45 min.
   * Demoted, not removed: if nothing else has capacity it is still tried. */
  cellPenaltyMs?: number;
}

export interface InstancePool {
  /** Register user-facing interest; `source` (e.g. 'stream_open
   * client=simulator:…') lands in getState().interest for attribution. */
  touch(source?: string): void;
  hasReady(): boolean;
  reportFailure(name: string): void;
  acquireStream(source?: string): { name: string; url: string } | null;
  releaseStream(name: string): void;
  touchInstance(name: string): void;
  wsUrl(): string | null;
  ensure(source?: string): PoolState;
  getState(): PoolState;
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
  /** Last computed hold verdict (see holdReasonFor); logged on change. */
  holdReason?: string;
  /** Lambda SKU (e.g. gpu_1x_h100_sxm5) — with `region` identifies the
   * sweep cell this VM came from, for per-cell boot stats + penalties. */
  instanceType?: string;
}

/** 'type@region' — the unit the sweep, capacity samples, boot stats and
 * penalties all key on (matches the `launched` event's detail column). */
function cellKey(type: string, region: string): string {
  return `${type}@${region}`;
}

/** Default /health probe: https with the pinned fleet cert when TLS is
 * configured (hostname check skipped — instances are bare IPs), plain http
 * otherwise. */
function defaultProbeHealth(ip: string, timeoutMs: number): Promise<HealthInfo> {
  if (!config.LAMBDA_TLS_CA) {
    return fetch(`http://${ip}:${PORT}/health`, { signal: AbortSignal.timeout(timeoutMs) }).then(
      (res) => {
        if (!res.ok) throw new Error(`health ${res.status}`);
        return res.json() as Promise<HealthInfo>;
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
            resolve(JSON.parse(body) as HealthInfo);
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
  /** Hedge bookkeeping: maps EACH member of an in-flight hedge pair to its
   * partner (bidirectional; two entries per pair). At most one pair exists
   * at a time (tick guards on hedgePairs.size). Resolved — entries removed —
   * when either member goes ready (loser terminated if still booting) or
   * dies during boot. */
  const hedgePairs = new Map<string, string>();
  /** Instances that already got a hedge launched for them — never hedge the
   * same stuck boot twice. */
  const hedged = new Set<string>();
  /** Names of instances launched AS hedges (the racing partner), so a
   * resolved pair can say which side won. */
  const hedgeInstances = new Set<string>();
  /** Circuit breaker: cell → epoch ms until which it sorts last in sweeps. */
  const cellPenaltyUntil = new Map<string, number>();
  const CELL_PENALTY_MS = spec.cellPenaltyMs ?? 45 * 60_000;
  const CAPACITY_SNAPSHOT_MAX_AGE_MS = 10 * 60_000;
  const CELL_STATS_TTL_MS = 10 * 60_000;
  let cellStatsCache: { atMs: number; map: Map<string, number> } = { atMs: 0, map: new Map() };
  let cellStatsRefresh: Promise<Map<string, number>> | null = null;

  /** Per-cell launch→ready p50 (ms) over 30 days, cached 10 min. A failed
   * or unconfigured DB yields an empty map (static order + flat hedge). */
  function cellBootStats(): Promise<Map<string, number>> {
    if (Date.now() - cellStatsCache.atMs < CELL_STATS_TTL_MS) return Promise.resolve(cellStatsCache.map);
    if (cellStatsRefresh) return cellStatsRefresh;
    const source = spec.cellBootStats ?? defaultCellBootStats;
    cellStatsRefresh = source()
      .catch(() => new Map<string, number>())
      .then((map) => {
        cellStatsCache = { atMs: Date.now(), map };
        cellStatsRefresh = null;
        return map;
      });
    return cellStatsRefresh;
  }
  async function defaultCellBootStats(): Promise<Map<string, number>> {
    const r = await query<{ cell: string; p50: string }>(
      `SELECT l.detail AS cell, percentile_cont(0.5) WITHIN GROUP (ORDER BY r.duration_ms) AS p50
         FROM lambda_pool_events l
         JOIN lambda_pool_events r ON r.instance_name = l.instance_name AND r.event = 'ready'
        WHERE l.event = 'launched' AND l.pool = $1 AND l.ts > now() - interval '30 days'
        GROUP BY 1`,
      [spec.kind],
    );
    return new Map(r.rows.map((row) => [row.cell, Number(row.p50)]));
  }

  function penalizeCell(inst: PoolInstance, reason: string): void {
    if (!inst.instanceType) return;
    const cell = cellKey(inst.instanceType, inst.region);
    cellPenaltyUntil.set(cell, Date.now() + CELL_PENALTY_MS);
    log.warn(
      { pool: spec.kind, cell, name: inst.name, penaltyMs: CELL_PENALTY_MS, reason, event: 'lambda_pool_cell_penalized' },
      `[sweep] ${cell} demoted for ${Math.round(CELL_PENALTY_MS / 60_000)}m after ${reason}`,
    );
    recordPoolEvent('cell_penalized', inst.name, inst.region, CELL_PENALTY_MS, `${cell}: ${reason}`);
  }

  /** Order the (type × region) grid for one sweep pass. Buckets, in order:
   *  0 advertised right now (capacity snapshot < 10 min old) — within the
   *    bucket keep the TYPE preference (an H100 still beats an A100), then
   *    fastest measured boot;
   *  1 not advertised (or no fresh snapshot) — static type-major order;
   *  2 penalized cells (dead-on-arrival VM within the last 45 min);
   *  3 the cell a hedge is racing against — a hedge wants a DIFFERENT draw.
   * Nothing is ever skipped: the launch call stays the authority. */
  async function planSweep(
    types: readonly string[],
    regions: readonly string[],
    avoidCell?: string,
  ): Promise<Array<{ type: string; region: string; cell: string; bucket: number }>> {
    const snap = (spec.capacitySnapshot ?? latestCapacity)();
    const advertised = snap && Date.now() - snap.atMs < CAPACITY_SNAPSHOT_MAX_AGE_MS ? snap.cells : new Set<string>();
    const stats = await cellBootStats();
    const now = Date.now();
    const cells = types.flatMap((type, ti) =>
      regions.map((region, ri) => {
        const cell = cellKey(type, region);
        let bucket = advertised.has(cell) ? 0 : 1;
        if ((cellPenaltyUntil.get(cell) ?? 0) > now) bucket = 2;
        if (cell === avoidCell) bucket = 3;
        return { type, region, cell, bucket, ti, ri, p50: stats.get(cell) ?? spec.bootEstimateMs };
      }),
    );
    cells.sort((a, b) =>
      a.bucket - b.bucket ||
      a.ti - b.ti ||
      (a.bucket === 0 ? a.p50 - b.p50 : 0) ||
      a.ri - b.ri,
    );
    return cells.map(({ type, region, cell, bucket }) => ({ type, region, cell, bucket }));
  }
  let lastError: string | undefined;
  let launchesInFlight = 0;
  /** Launches still in their CAPACITY SWEEP (not yet a registered booting
   * instance). launchesInFlight stays up through the whole boot watch, so
   * the hedge guard needs this narrower counter — a booting instance must
   * not block its own hedge. */
  let sweepsInFlight = 0;
  /** Start of the oldest in-flight capacity search (0 = none). */
  let searchStartedAtMs = 0;
  let tickTimer: NodeJS.Timeout | null = null;
  let log: FastifyBaseLogger | Console = console;
  /** Last time anyone expressed interest (ensure/acquire) — keeps the floor-0
   * pool from launching for nobody. */
  let lastInterestMs = 0;
  /** WHO last expressed interest, ring-buffered (newest first, cap 20) so
   * "why is this pool warm" is a lookup. Throttled: identical consecutive
   * sources within 60s collapse into one entry (frame activity would
   * otherwise flood it). */
  const interestLog: Array<{ at: number; source: string }> = [];
  function recordInterest(source: string): void {
    lastInterestMs = Date.now();
    const head = interestLog[0];
    if (head && head.source === source && Date.now() - head.at < 60_000) {
      head.at = Date.now();
      return;
    }
    interestLog.unshift({ at: Date.now(), source });
    if (interestLog.length > 20) interestLog.pop();
  }

  function enabled(): boolean {
    return spec.enabled();
  }

  /** A Lambda API client is constructible: injected (tests) or env key. */
  function haveClient(): boolean {
    return Boolean(spec.createClient) || config.LAMBDA_API_KEY.length > 0;
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

  function touch(source = 'unattributed'): void {
    recordInterest(source);
  }

  function hasReady(): boolean {
    return assignableInstances().length > 0;
  }

  /** Least-loaded assignable instance, or null. Pure — mutation stays at
   * call sites. */
  function leastLoadedReady(): PoolInstance | null {
    return assignableInstances().sort((a, b) => a.activeStreams - b.activeStreams)[0] ?? null;
  }

  function wsUrlFor(inst: PoolInstance): string {
    return `${scheme()}://${inst.ip}:${PORT}/ws?token=${wsToken(inst.name)}`;
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
  function acquireStream(source = 'acquire'): { name: string; url: string } | null {
    recordInterest(source);
    const inst = leastLoadedReady();
    if (!inst) return null;
    inst.activeStreams += 1;
    inst.lastActivityMs = Date.now();
    return { name: inst.name, url: wsUrlFor(inst) };
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
    recordInterest(`frames:${name}`);
  }

  /** One-shot URL (sketchify): least-loaded ready instance, no slot held. */
  function wsUrl(): string | null {
    const inst = leastLoadedReady();
    if (!inst?.ip) return null;
    touchInstance(inst.name);
    return wsUrlFor(inst);
  }

  /** User interest: make sure at least one instance exists/is coming. */
  function ensure(source = 'ensure'): PoolState {
    recordInterest(source);
    if (enabled() && instances.size === 0 && launchesInFlight === 0) {
      lastError = undefined;
      void inBackgroundScope(scopeName, () => launchOne());
    }
    return getState();
  }

  function getState(): PoolState {
    const list = [...instances.values()];
    const ready = list.filter((i) => i.status === 'ready');
    const booting = list.filter((i) => i.status === 'booting');
    const launching = launchesInFlight > 0 || list.some((i) => i.status === 'launching');

    let status: PoolStatusKind;
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

    const messages: Record<PoolStatusKind, string> = {
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
      region: spec.regions()[0] ?? '',
      instanceType: spec.instanceTypes()[0] ?? '',
      message: messages[status],
      lastError,
      launchedAtMs,
      readyAtMs,
      etaSeconds,
      searchStartedAtMs: status === 'launching' && searchStartedAtMs > 0 ? searchStartedAtMs : undefined,
      bootEstimateSeconds: Math.round(spec.bootEstimateMs / 1000),
      instances: list.map((i) => ({
        name: i.name,
        status: i.status,
        ip: i.ip,
        region: i.region,
        activeStreams: i.activeStreams,
        ageMs: Date.now() - i.launchedAtMs,
        holdReason: i.holdReason ?? 'pending first tick',
      })),
      interest: {
        ageMs: lastInterestMs > 0 ? Date.now() - lastInterestMs : null,
        lastSource: interestLog[0]?.source ?? null,
        recent: interestLog.slice(0, 10),
      },
    };
  }

  // ── launch / boot ───────────────────────────────────────────────────────

  /** The subset of `wanted` whose `spec.fsName(region)` filesystem exists
   * AND is not currently attached to a foreign instance. setup-lambda*.ts /
   * sync-fs.mts create the filesystem EMPTY at the start of a 20-40 min
   * populate and hold their `kiki-*setup-` / `kiki-fssync-` instance on it
   * until done; a pool instance launched into it meanwhile boots a server
   * whose model load fails and sits until the boot timeout (2026-09-12:
   * happened within 60 s of us-southeast-1 joining the video sweep). Any
   * non-pool instance attached = someone is writing; skip the region until
   * they detach. (Lambda's filesystem `bytes_used` is NOT usable for this —
   * it reported 0 GB with 68 GB on disk.) A listing failure sweeps every
   * configured region (the launch call is the authority; this is a
   * pre-filter). */
  async function regionsWithFilesystem(c: LambdaClient, wanted: readonly string[]): Promise<string[]> {
    let present: Set<string>;
    const busyLogged = new Set<string>();
    try {
      const [filesystems, attached] = await Promise.all([c.listFilesystems(), c.listInstances()]);
      present = new Set(filesystems.filter((f) => f.name === spec.fsName(f.region.name)).map((f) => f.region.name));
      for (const inst of attached) {
        const name = inst.name ?? '';
        if (name.startsWith(spec.namePrefix)) continue;
        const region = inst.region.name;
        if (present.has(region) && (inst.file_system_names ?? []).includes(spec.fsName(region))) {
          present.delete(region);
          busyLogged.add(region);
          log.warn(
            { pool: spec.kind, region, writer: name, event: 'lambda_pool_region_fs_busy' },
            `[launch] skipping ${region} — ${name} is attached to ${spec.fsName(region)} (populating?)`,
          );
        }
      }
    } catch (err) {
      log.warn(
        { err, pool: spec.kind, event: 'lambda_pool_fs_list_failed' },
        '[launch] filesystem listing failed — sweeping every configured region',
      );
      return [...wanted];
    }
    const kept = wanted.filter((r) => present.has(r));
    const missing = wanted.filter((r) => !present.has(r) && !busyLogged.has(r));
    if (missing.length > 0) {
      log.warn(
        { pool: spec.kind, regions: missing, event: 'lambda_pool_region_no_fs' },
        `[launch] skipping ${missing.join(', ')} — no usable ${spec.fsName('<region>')} filesystem there`,
      );
    }
    if (kept.length === 0) {
      throw new Error(`no configured region [${wanted.join(', ')}] has a usable ${spec.fsName('<region>')} filesystem`);
    }
    return kept;
  }

  async function launchOne(hedgeFor?: string): Promise<void> {
    if (!enabled()) return;
    // A hedge deliberately exceeds poolMax by one — the pair resolves back to
    // one instance within minutes (loser terminated at first ready).
    if (!hedgeFor && upOrComing() >= spec.poolMax()) return;
    launchesInFlight += 1;
    sweepsInFlight += 1;
    let sweeping = true;
    if (launchesInFlight === 1) searchStartedAtMs = Date.now();
    const name = `${spec.namePrefix}${Date.now()}`;
    if (hedgeFor) {
      hedgePairs.set(name, hedgeFor);
      hedgePairs.set(hedgeFor, name);
      hedgeInstances.add(name);
    }
    const searchStartMs = Date.now();
    const types = spec.instanceTypes();
    let regions = spec.regions();
    recordPoolEvent(
      'launch_requested',
      name,
      regions[0],
      undefined,
      // The hedge marker lets the Insights Boots page tell racing launches
      // from organic ones without reconstructing pairs from loser events.
      `${hedgeFor ? `hedge for ${hedgeFor}; ` : ''}${types.length} types × ${regions.length} regions`,
    );
    // Hoisted out of the try so the launch_failed catch can report how many
    // (type × region) cells were tried before the sweep died.
    let attempts = 0;
    try {
      const c = client();
      const keys = await c.listSshKeys();
      const firstKey = keys[0];
      if (!firstKey) throw new Error('no SSH key registered on the Lambda account');
      // A region without this pool's filesystem can't serve (cloud-init
      // mounts the weights from it) and Lambda refuses the launch with a
      // non-retryable error that would end the whole sweep. Drop those
      // regions up front, loudly — so a region list shared between pools
      // (the video pool defaults to the image pool's) needs only its
      // filesystem populated to join the hunt.
      regions = await regionsWithFilesystem(c, regions);

      // Capacity sweep: circle the (type × region) grid, re-planned every
      // pass (advertised cells first, then static type-major order, penalized
      // cells last — see planSweep), until a cell grants capacity or demand
      // goes away. There is deliberately NO time cliff: the old 15-min
      // window ended 7 video hunts in 30 days while users were still
      // waiting, and the interest window already bounds a hunt nobody
      // wants. Attempt pacing comes from the account-wide launch spacing
      // gate (client.ts), so multiple pools sweeping concurrently still
      // respect Lambda's launch rate limit.
      const longHuntAtMs = Date.now() + LAUNCH_RETRY_MINS * 60_000;
      let longHuntLogged = false;
      const hedgeOrigin = hedgeFor ? instances.get(hedgeFor) : undefined;
      const avoidCell = hedgeOrigin?.instanceType ? cellKey(hedgeOrigin.instanceType, hedgeOrigin.region) : undefined;
      let launched: { id: string; region: string; type: string } | null = null;
      let lastErr: unknown = null;
      let abandonReason = '';
      let pass = 0;
      sweep: for (;;) {
        const plan = await planSweep(types, regions, avoidCell);
        if (pass === 0) {
          log.info(
            {
              pool: spec.kind,
              advertised: plan.filter((p) => p.bucket === 0).map((p) => p.cell),
              penalized: plan.filter((p) => p.bucket === 2).map((p) => p.cell),
              order: plan.map((p) => p.cell),
              event: 'lambda_pool_sweep_plan',
            },
            `[launch] sweep plan: ${plan.filter((p) => p.bucket === 0).length} advertised of ${plan.length} cells`,
          );
        }
        pass += 1;
        for (const { type, region } of plan) {
          if (!enabled() || !instancesWanted()) {
            abandonReason = !enabled() ? 'pool disabled' : 'demand gone';
            break sweep;
          }
          // A hedge whose partner already resolved (original went ready, or
          // died taking the pair down) has nothing left to race for.
          if (hedgeFor && !hedgePairs.has(name)) {
            abandonReason = 'hedge resolved mid-sweep';
            break sweep;
          }
          try {
            attempts += 1;
            const [id] = await spacedLaunch(
              c,
              {
                region_name: region,
                instance_type_name: type,
                ssh_key_names: [firstKey.name],
                file_system_names: [spec.fsName(region)],
                name,
                image: { family: OS_IMAGE_FAMILY },
                user_data: userData(name, region),
              },
              spec.launchSpacingMs,
            );
            if (!id) throw new Error('Lambda launch returned no instance id');
            launched = { id, region, type };
            break sweep;
          } catch (err) {
            lastErr = err;
            if (!isRetryableLaunchError(err)) throw err;
            log.info(
              { pool: spec.kind, type, region, err: (err as Error).message, event: 'lambda_pool_launch_retry' },
              `[launch] no ${type} in ${region} — sweeping on`,
            );
          }
        }
        // Pass boundary: yield to the event loop before re-planning. Launch
        // spacing normally paces attempts; with none (tests, or a future
        // zero-spacing config) a dry grid would otherwise spin on
        // microtasks alone and starve timers — including the interest
        // window that is supposed to end this hunt.
        await lambdaSleep(POLL_MS);
        if (!longHuntLogged && Date.now() > longHuntAtMs) {
          longHuntLogged = true;
          log.warn(
            { pool: spec.kind, attempts, minutes: LAUNCH_RETRY_MINS, event: 'lambda_pool_hunt_long' },
            `[launch] still hunting after ${LAUNCH_RETRY_MINS}m / ${attempts} attempts — continuing while demand persists`,
          );
          recordPoolEvent('hunt_long', name, regions[0], Date.now() - searchStartMs, `${attempts} attempts; last: ${(lastErr as Error | null)?.message ?? '-'}`);
        }
      }
      if (!launched) {
        // Terminal row even when nobody won: without it an abandoned hunt is
        // invisible in lambda_pool_events and the Fleet tab's search stats
        // only ever see successes (the user who waited 20 min for capacity
        // that never came leaves no trace). duration = how long we hunted.
        log.info({ pool: spec.kind, event: 'lambda_pool_sweep_abandoned' }, 'capacity sweep abandoned — demand gone');
        recordPoolEvent(
          'sweep_abandoned',
          name,
          regions[0],
          Date.now() - searchStartMs,
          `${abandonReason} after ${attempts} attempts` +
            (lastErr ? `; last: ${(lastErr as Error).message}` : ''),
        );
        clearHedgePair(name);
        return;
      }
      instances.set(name, {
        id: launched.id,
        name,
        region: launched.region,
        instanceType: launched.type,
        status: 'booting',
        launchedAtMs: Date.now(),
        activeStreams: 0,
        lastActivityMs: Date.now(),
        healthFails: 0,
      });
      log.info(
        { instanceId: launched.id, name, type: launched.type, region: launched.region, pool: spec.kind, event: 'lambda_pool_launched' },
        `launched ${spec.namePrefix} instance`,
      );
      // duration = capacity-search time; detail = which (type, region) won.
      recordPoolEvent('launched', name, launched.region, Date.now() - searchStartMs, `${launched.type}@${launched.region}`);
      sweepsInFlight -= 1;
      sweeping = false;
      await watchBoot(name);
    } catch (err) {
      lastError = (err as Error).message;
      log.error({ err, pool: spec.kind, event: 'lambda_pool_launch_failed' }, 'lambda pool launch failed');
      recordPoolEvent(
        'launch_failed',
        name,
        regions[0],
        Date.now() - searchStartMs,
        `after ${attempts} attempts: ${(err as Error).message}`,
      );
      clearHedgePair(name);
    } finally {
      if (sweeping) sweepsInFlight -= 1;
      launchesInFlight -= 1;
      if (launchesInFlight === 0) searchStartedAtMs = 0;
    }
  }

  /** Drop hedge bookkeeping for an instance (both directions). Called when a
   * pair resolves (winner ready) or a member dies during launch/boot. */
  function clearHedgePair(name: string): void {
    const partner = hedgePairs.get(name);
    hedgePairs.delete(name);
    if (partner) hedgePairs.delete(partner);
    hedged.delete(name);
    if (partner) hedged.delete(partner);
  }

  /** Mid-sweep demand check: keep hunting only while something would still
   * use the instance (active streams, a floor, or fresh interest). Without
   * this, a long sweep started by a since-departed user keeps buying GPUs. */
  function instancesWanted(): boolean {
    const totalStreams = [...instances.values()].reduce((a, i) => a + i.activeStreams, 0);
    return (
      totalStreams > 0 ||
      spec.poolMin() > 0 ||
      Date.now() - lastInterestMs < INTEREST_WINDOW_MS
    );
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
    // The IP-visible moment is the only provisioning progress signal the API
    // gives us; record it so the waterfall can split hunt/provision/boot even
    // for instances whose server never comes up. Baseline is launchedAtMs
    // (capacity granted) to match the ready event — NOT trueLaunchMs, which
    // is sweep start and would fold hunt time into provisioning.
    if (!inst.adopted) recordPoolEvent('ip_assigned', name, inst.region, Date.now() - inst.launchedAtMs);
    // …then OUR /health.
    let readyHealth: HealthInfo | undefined;
    for (;;) {
      if (Date.now() > deadline) {
        instances.delete(name);
        void c.terminate([inst.id]).catch(() => {});
        penalizeCell(inst, 'boot_stalled');
        recordPoolEvent('boot_stalled', name, inst.region, Date.now() - trueLaunchMs(inst));
        throw new Error(`boot timed out waiting for /health (${name})`);
      }
      if (!instances.has(name)) return;
      try {
        const health = await probeHealth(inst.ip, 3000);
        if (health.status === 'ok') {
          readyHealth = health;
          break;
        }
        // The server stayed up but its model load threw (video server.py
        // keeps FastAPI alive and exposes the traceback as
        // status:'error' + load_error). That is terminal for this VM — it
        // never retries the load — so waiting out the boot timeout only
        // delays the replacement. Seen 2026-09-12: a Lambda H100 SXM VM
        // came up with CUDA error 802 (host fabric never initialized the
        // GPU), torch fell back to CPU, and warmup died 12 min in; the pool
        // would have held it 13 more minutes.
        if (health.status === 'error') {
          const reason = String(health['load_error'] ?? 'load failed').trim().split('\n').pop() ?? 'load failed';
          instances.delete(name);
          void c.terminate([inst.id]).catch(() => {});
          penalizeCell(inst, `boot_load_error (${reason})`);
          log.warn(
            { instanceId: inst.id, name, ip: inst.ip, reason, pool: spec.kind, event: 'lambda_pool_boot_load_error' },
            `[boot] ${name} reports a terminal load error — terminating: ${reason}`,
          );
          recordPoolEvent('boot_load_error', name, inst.region, Date.now() - trueLaunchMs(inst), reason);
          throw new Error(`server load failed on ${name}: ${reason}`);
        }
      } catch (err) {
        if ((err as Error).message.startsWith('server load failed')) throw err;
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
    if (!inst.adopted) {
      recordPoolEvent(
        'ready',
        name,
        inst.region,
        inst.readyAtMs - inst.launchedAtMs,
        bootPhaseDetail(inst, readyHealth),
      );
    }
    resolveHedge(name);
  }

  /** Decompose a boot into provision / OS / our-stack from the server's own
   * clocks (kernel + process start epochs on /health), plus the largest init
   * phases. Returned as compact JSON for the ready event's detail column. */
  function bootPhaseDetail(inst: PoolInstance, health: HealthInfo | undefined): string | undefined {
    if (!health) return undefined;
    // Capacity-granted baseline (matches the ready duration) — trueLaunchMs
    // is sweep start and would fold hunt time into provision_s.
    const launchMs = inst.launchedAtMs;
    const out: Record<string, unknown> = {};
    if (typeof health.booted_at_epoch_s === 'number') {
      out['provision_s'] = Math.round(health.booted_at_epoch_s - launchMs / 1000);
    }
    if (typeof health.started_at_epoch_s === 'number') {
      if (typeof health.booted_at_epoch_s === 'number') {
        out['os_s'] = Math.round(health.started_at_epoch_s - health.booted_at_epoch_s);
      }
      out['stack_s'] = Math.round(Date.now() / 1000 - health.started_at_epoch_s);
    }
    const phases = health.phase_timings_ms;
    if (phases && typeof phases === 'object') {
      out['phases_ms'] = Object.fromEntries(
        Object.entries(phases)
          .filter(([, v]) => typeof v === 'number')
          .sort(([, a], [, b]) => b - a)
          .slice(0, 6),
      );
    }
    return Object.keys(out).length > 0 ? JSON.stringify(out) : undefined;
  }

  /** First member of a hedge pair to go ready wins; a partner still booting
   * is terminated immediately (it has served nobody). A partner that also
   * reached ready is left to the idle reaper — harmless. */
  function resolveHedge(winnerName: string): void {
    const partnerName = hedgePairs.get(winnerName);
    if (!partnerName) return;
    clearHedgePair(winnerName);
    const partner = instances.get(partnerName);
    if (!partner || partner.status === 'ready') return;
    const winnerSide = hedgeInstances.has(winnerName) ? 'hedge' : 'original';
    log.info(
      { winner: winnerName, loser: partnerName, winnerSide, pool: spec.kind, event: 'lambda_pool_hedge_resolved' },
      'hedge resolved — terminating still-booting loser',
    );
    // Durable row so Insights can show the hedge WIN RATE (2/15 over the 30
    // days before 2026-09-12 — the flat 8-min trigger fired just before
    // normal 10-min A100 boots finished; see the boot-relative trigger in
    // tick()).
    const winner = instances.get(winnerName);
    recordPoolEvent(
      'hedge_resolved',
      winnerName,
      winner?.region ?? partner.region,
      winner ? Date.now() - trueLaunchMs(winner) : undefined,
      `winner=${winnerSide}; loser=${partnerName}`,
    );
    recordPoolEvent(
      'hedge_loser_terminate',
      partnerName,
      partner.region,
      Date.now() - trueLaunchMs(partner),
      `lost to ${winnerName}`,
    );
    instances.delete(partnerName);
    void client().terminate([partner.id]).catch(() => {});
  }

  /** The decision-table verdict for one instance (module header). `need`
   * and `needReason` come from the tick's own computation so the verdict
   * can never drift from the actual reap logic. */
  function holdReasonFor(inst: PoolInstance, need: number, needReason: string): string {
    if (inst.status !== 'ready') return `booting (${Math.round((Date.now() - inst.launchedAtMs) / 1000)}s)`;
    if (inst.activeStreams > 0) return `active: ${inst.activeStreams} stream(s)`;
    if (instances.size <= Math.max(spec.poolMin(), need)) return `within need (${needReason})`;
    const idleMs = Date.now() - inst.lastActivityMs;
    if (idleMs <= IDLE_TERMINATE_MS) {
      return `idle ${Math.round(idleMs / 60_000)}m of ${Math.round(IDLE_TERMINATE_MS / 60_000)}m — reaps in ~${Math.max(1, Math.round((IDLE_TERMINATE_MS - idleMs) / 60_000))}m`;
    }
    return 'reapable this tick';
  }

  /** Refresh every instance's holdReason; log only transitions. */
  function updateHoldReasons(need: number, needReason: string): void {
    for (const inst of instances.values()) {
      const verdict = holdReasonFor(inst, need, needReason);
      if (verdict !== inst.holdReason) {
        inst.holdReason = verdict;
        log.info(
          { name: inst.name, pool: spec.kind, holdReason: verdict, event: 'lambda_pool_instance_hold' },
          `instance hold: ${verdict}`,
        );
      }
    }
  }

  // ── periodic tick: autoscale + idle scale-down + health ─────────────────

  async function tick(): Promise<void> {
    if (!enabled()) {
      // DRAIN, don't just idle: a pool disabled at runtime (Insights feature
      // flag, env flip) must not leave instances running — with the tick's
      // normal path off, nothing else would ever reap them and they'd bill
      // until someone noticed. Registry adoption still runs at start() (key
      // permitting), so even instances from before a redeploy get drained.
      if (haveClient() && instances.size > 0) {
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
    // Attribution for the hold verdicts: which term of `need` is in charge.
    const needReason =
      pressureNeed >= Math.max(spec.poolMin(), 1) && totalStreams > 0
        ? `pressure: ${totalStreams} streams`
        : interested
          ? `interest ${Math.round((Date.now() - lastInterestMs) / 1000)}s ago (${interestLog[0]?.source ?? 'unattributed'})`
          : spec.poolMin() > 0
            ? `floor: poolMin=${spec.poolMin()}`
            : 'no demand';
    updateHoldReasons(need, needReason);

    if (upOrComing() < need) {
      void inBackgroundScope(scopeName, () => launchOne());
    }

    // Hedged launch: nobody is ready, somebody wants an instance, and the
    // oldest boot has dragged past the threshold (slow VM provisioning is
    // per-VM luck — a fresh draw usually wins; see hedgeAfterMs). One pair
    // at a time; never hedge the same boot twice; never launch over an
    // active capacity sweep (sweepsInFlight — NOT launchesInFlight, which
    // stays up through the whole boot watch and would block every hedge).
    const hedgeAfterMs = spec.hedgeAfterMs ?? 0;
    if (
      hedgeAfterMs > 0 &&
      readyInstances().length === 0 &&
      sweepsInFlight === 0 &&
      hedgePairs.size === 0 &&
      instancesWanted()
    ) {
      // Threshold is per CELL: the flat 8 min fired on every normal ~10-min
      // A100 boot (hedge won 2 of 15 in 30 days) — a boot is only "dragging"
      // once it is well past what its own cell normally takes. Stats refresh
      // in the background; until they exist the flat threshold applies.
      void cellBootStats();
      const stats = cellStatsCache.map;
      const thresholdFor = (i: PoolInstance): number => {
        const p50 = i.instanceType ? stats.get(cellKey(i.instanceType, i.region)) : undefined;
        return Math.max(hedgeAfterMs, p50 ? Math.round(p50 * 1.3) : 0);
      };
      const stuck = [...instances.values()]
        .filter(
          (i) =>
            i.status === 'booting' && !i.adopted && !hedged.has(i.name) &&
            Date.now() - trueLaunchMs(i) > thresholdFor(i),
        )
        .sort((a, b) => trueLaunchMs(a) - trueLaunchMs(b))[0];
      if (stuck) {
        hedged.add(stuck.name);
        const thresholdMs = thresholdFor(stuck);
        log.info(
          { name: stuck.name, ageMs: Date.now() - trueLaunchMs(stuck), thresholdMs, pool: spec.kind, event: 'lambda_pool_hedge_launched' },
          'boot dragging with nothing ready — launching hedge instance',
        );
        recordPoolEvent(
          'hedge_launched',
          stuck.name,
          stuck.region,
          Date.now() - trueLaunchMs(stuck),
          `boot exceeded ${Math.round(thresholdMs / 60_000)}m (cell p50-relative) with no ready instance`,
        );
        void inBackgroundScope(scopeName, () => launchOne(stuck.name));
      }
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
    if (!haveClient()) {
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
            instanceType: remote.instance_type?.name,
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

/**
 * Per-session pod lifecycle orchestration.
 *
 * Responsibilities (all in this one file because they share state and are
 * tightly coupled — separating would just spread the reader's attention across
 * imports):
 *   - Registry: Map<sessionId, Session>
 *   - Provisioner: create pod → SSH setup → health poll
 *   - Reaper: terminate pods idle > 10 min
 *   - Reconcile: on boot, kill orphaned `kiki-session-*` pods from prior runs
 *   - Semaphore: cap concurrent provisions to prevent rate-limit + burst OOM
 */

import { spawn } from 'node:child_process';
import { chmodSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import type { FastifyBaseLogger } from 'fastify';

import { config } from '../../config/index.js';
import { getRedis, ensureRedis, setLogger as setRedisLogger } from '../redis/client.js';
import {
  createOnDemandPod,
  createSpotPod,
  getPod,
  getSpotBid,
  isCapacityError,
  listPodsByPrefix,
  terminatePod,
  type SpotBidInfo,
} from './runpodClient.js';
import { getPolicy } from './policy.js';
import { notifyPodCreated, notifyPodProgress, notifyPodTerminated } from './costMonitor.js';
import { incrementCounter, observeHistogram, setGauge, classifyProvisionError } from './metrics.js';

// ────────────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────────────

export type SessionStatus = 'provisioning' | 'ready' | 'replacing' | 'terminated';

export type PodType = 'spot' | 'onDemand';

// ────────────────────────────────────────────────────────────────────────────
// Module-scoped state
// ────────────────────────────────────────────────────────────────────────────

// Session registry lives in Redis (WS5). Local map only holds in-flight
// provision promises for same-process join (Promises can't be serialized).
const inFlightProvisions = new Map<string, Promise<{ podUrl: string }>>();

const SESSION_PREFIX = 'session:';
const POD_PREFIX = 'kiki-session-';
const IDLE_GRACE_SECONDS = 300; // 5 min grace on top of idle timeout for Redis TTL
const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
// Headroom above the current spot floor. Larger headroom = fewer outbids =
// fewer needless fallbacks to on-demand. 0.05 costs ~$0.03/hr more than the
// 0.02 default on a typical bid, cheaper than one on-demand fallback.
const BID_HEADROOM = 0.05;

const IDLE_TIMEOUT_MS = 10 * 60 * 1000;
const REAPER_INTERVAL_MS = 60 * 1000;
const MAX_CONCURRENT_PROVISIONS = Number(process.env['MAX_CONCURRENT_PROVISIONS'] ?? 5);

// Semaphore state
let activeProvisions = 0;
const semaphoreWaiters: Array<() => void> = [];

// Logger injected by start()
let log: FastifyBaseLogger = console as unknown as FastifyBaseLogger;

// SSH key path — written once on first provision
const SSH_KEY_PATH = '/tmp/kiki-runpod-key';
let sshKeyWritten = false;

// Runtime asset paths — flux-klein-server/ files bundled into backend at build
const __dirname = dirname(fileURLToPath(import.meta.url));
const RUNTIME_ASSETS_DIR = findRuntimeAssets(__dirname);

function findRuntimeAssets(startDir: string): string {
  // Walk up from this file's directory looking for a `runtime-assets/` folder.
  // In dev (tsx): backend/src/modules/orchestrator/ → finds backend/runtime-assets/
  // In prod Docker image: /app/dist/modules/orchestrator/ → finds /app/runtime-assets/
  let dir = startDir;
  for (let i = 0; i < 6; i++) {
    const candidate = join(dir, 'runtime-assets');
    if (existsSync(candidate)) return candidate;
    dir = dirname(dir);
  }
  throw new Error(`Could not locate runtime-assets directory starting from ${startDir}`);
}

// ────────────────────────────────────────────────────────────────────────────
// Redis session helpers
// ────────────────────────────────────────────────────────────────────────────

interface RedisSession {
  sessionId: string;
  podId: string | null;
  podUrl: string | null;
  podType: PodType | null;
  status: SessionStatus;
  createdAt: number;
  lastActivityAt: number;
  replacementCount: number;
}

const IDLE_TTL_SECONDS = Math.ceil(IDLE_TIMEOUT_MS / 1000) + IDLE_GRACE_SECONDS;

function sessionKey(sessionId: string): string {
  return `${SESSION_PREFIX}${sessionId}`;
}

async function readSession(sessionId: string): Promise<RedisSession | null> {
  const data = await getRedis().hgetall(sessionKey(sessionId));
  if (!data || !data['sessionId']) return null;
  return {
    sessionId: data['sessionId']!,
    podId: data['podId'] || null,
    podUrl: data['podUrl'] || null,
    podType: (data['podType'] as PodType) || null,
    status: (data['status'] as SessionStatus) || 'provisioning',
    createdAt: Number(data['createdAt'] ?? 0),
    lastActivityAt: Number(data['lastActivityAt'] ?? 0),
    replacementCount: Number(data['replacementCount'] ?? 0),
  };
}

async function writeSession(session: RedisSession): Promise<void> {
  const key = sessionKey(session.sessionId);
  const fields: Record<string, string> = {
    sessionId: session.sessionId,
    status: session.status,
    createdAt: String(session.createdAt),
    lastActivityAt: String(session.lastActivityAt),
  };
  if (session.podId) fields['podId'] = session.podId;
  if (session.podUrl) fields['podUrl'] = session.podUrl;
  if (session.podType) fields['podType'] = session.podType;
  if (session.replacementCount > 0) fields['replacementCount'] = String(session.replacementCount);
  await getRedis().multi()
    .hset(key, fields)
    .expire(key, IDLE_TTL_SECONDS)
    .exec();
}

/** Delete a session from Redis — exported for stream.ts to clean up stale
 * sessions when relay to a dead pod fails. */
export async function deleteStaleSession(sessionId: string): Promise<void> {
  return deleteSession(sessionId);
}

async function deleteSession(sessionId: string): Promise<void> {
  await getRedis().del(sessionKey(sessionId));
}

// ────────────────────────────────────────────────────────────────────────────
// Public API
// ────────────────────────────────────────────────────────────────────────────

/**
 * Returns a healthy pod URL for the given session, provisioning one if needed.
 * If the same sessionId calls this concurrently while a provision is in flight,
 * both calls await the same promise — we don't create two pods.
 *
 * Session state is stored in Redis (survives deploys). In-flight provision
 * promises are kept in a local map for same-process join only.
 */
export async function getOrProvisionPod(
  sessionId: string,
  onStatus: (msg: string) => void,
): Promise<{ podUrl: string }> {
  // 1. Check Redis for existing session
  const existing = await readSession(sessionId);

  if (existing?.status === 'ready' && existing.podUrl) {
    log.info({ sessionId, podId: existing.podId }, 'Reusing existing session pod');
    onStatus('Ready');
    return { podUrl: existing.podUrl };
  }

  // 2. Check local in-flight map (same-process concurrent callers)
  const inFlight = inFlightProvisions.get(sessionId);
  if (inFlight) {
    log.info({ sessionId }, 'Waiting for in-flight provision');
    onStatus('Joining existing provisioning...');
    return inFlight;
  }

  // 3. If Redis says provisioning but we don't own the promise (post-restart
  // or different replica), the provision is orphaned. Clean up and re-provision.
  if (existing?.status === 'provisioning') {
    log.warn({ sessionId }, 'Stale provisioning session found in Redis — re-provisioning');
    await deleteSession(sessionId);
  }

  // 4. Fresh provision — claim in Redis + start
  const now = Date.now();
  incrementCounter('provision_start_total');
  await writeSession({
    sessionId,
    podId: null,
    podUrl: null,
    podType: null,
    status: 'provisioning',
    createdAt: now,
    lastActivityAt: now,
    replacementCount: 0,
  });

  let provisionedPodId: string | null = null;

  const promise = (async () => {
    try {
      await acquireSemaphore(onStatus);
      try {
        const result = await provision(sessionId, onStatus);
        provisionedPodId = result.podId;
        const elapsedMs = Date.now() - now;
        incrementCounter('provision_success_total');
        observeHistogram('provision_total_ms', elapsedMs);
        await writeSession({
          sessionId,
          podId: result.podId,
          podUrl: result.podUrl,
          podType: result.podType,
          status: 'ready',
          createdAt: now,
          lastActivityAt: Date.now(),
          replacementCount: 0,
        });
        return { podUrl: result.podUrl };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      const elapsedMs = Date.now() - now;
      const category = classifyProvisionError(err as Error);
      incrementCounter('provision_failed_total', { category });
      observeHistogram('provision_failed_ms', elapsedMs);
      log.error({ sessionId, err, category, elapsedMs }, 'Provision failed');
      if (provisionedPodId) {
        notifyPodProgress(provisionedPodId, `❌ **Failed:** ${(err as Error).message}`);
        terminatePod(provisionedPodId).catch((e) =>
          log.warn({ podId: provisionedPodId, err: e }, 'Failed to clean up pod after provision failure'),
        );
      }
      await deleteSession(sessionId).catch(() => {});
      throw err;
    } finally {
      inFlightProvisions.delete(sessionId);
    }
  })();

  inFlightProvisions.set(sessionId, promise);
  return promise;
}

export function touch(sessionId: string): void {
  // Fire-and-forget — don't block frame-relay hot path on Redis round-trip
  const key = sessionKey(sessionId);
  void getRedis().multi()
    .hset(key, 'lastActivityAt', String(Date.now()))
    .expire(key, IDLE_TTL_SECONDS)
    .exec()
    .catch((err) => log.warn({ err: (err as Error).message, sessionId }, 'touch failed'));
}

/** Check if a user already has a ready pod — used to skip rate limiting on reconnect. */
export async function hasReadySession(sessionId: string): Promise<boolean> {
  const session = await readSession(sessionId);
  return session?.status === 'ready' && !!session.podUrl;
}

// ────────────────────────────────────────────────────────────────────────────
// Preemption handling (WS7)
// ────────────────────────────────────────────────────────────────────────────

export type CloseClassification = 'preempted' | 'crashed' | 'voluntary';

/**
 * Classify an upstream WS close. Probes RunPod to determine whether the pod
 * was preempted, crashed, or voluntarily terminated by us.
 */
export async function classifyClose(sessionId: string): Promise<CloseClassification> {
  const session = await readSession(sessionId);
  if (!session || session.status === 'terminated') return 'voluntary';
  if (!session.podId) return 'voluntary';

  try {
    const pod = await getPod(session.podId);
    if (!pod || pod.desiredStatus === 'EXITED' || pod.desiredStatus === 'TERMINATED') {
      return 'preempted';
    }
    if (pod.desiredStatus === 'RUNNING' && pod.runtime) {
      // Pod is alive — check if server is healthy
      try {
        const healthUrl = `https://${session.podId}-8766.proxy.runpod.net/health`;
        const res = await fetch(healthUrl, { signal: AbortSignal.timeout(5000) });
        if (res.ok) return 'voluntary'; // pod healthy, close was intentional
      } catch { /* health failed */ }
      return 'crashed';
    }
    return 'preempted';
  } catch {
    // RunPod API error — assume preemption (safer to replace than ignore)
    return 'preempted';
  }
}

/**
 * Replace a session's pod after preemption or crash. Holds the existing session
 * key in Redis, provisions a new pod, swaps podId/podUrl atomically.
 *
 * Returns the new podUrl. Throws if replacement fails or retry bound exceeded.
 */
export async function replaceSession(
  sessionId: string,
  onStatus: (msg: string) => void,
): Promise<{ podUrl: string }> {
  const session = await readSession(sessionId);
  if (!session) throw new Error('No session to replace');

  if (session.replacementCount >= config.MAX_SESSION_REPLACEMENTS) {
    incrementCounter('session_replacement_exhausted_total');
    await deleteSession(sessionId);
    throw new Error(`Replacement limit reached (${config.MAX_SESSION_REPLACEMENTS} attempts)`);
  }

  const oldPodId = session.podId;
  const attempt = session.replacementCount + 1;

  log.info({ sessionId, oldPodId, attempt }, 'Starting session replacement');
  incrementCounter('session_replacement_started_total');

  // Mark as replacing in Redis
  await writeSession({
    ...session,
    status: 'replacing',
    lastActivityAt: Date.now(),
    replacementCount: attempt,
  });

  // Clean up old pod (fire-and-forget — may already be gone)
  if (oldPodId) {
    terminatePod(oldPodId).catch(() => {});
  }

  const t0 = Date.now();

  try {
    await acquireSemaphore(onStatus);
    try {
      const result = await provision(sessionId, onStatus);
      const replacementMs = Date.now() - t0;

      await writeSession({
        ...session,
        podId: result.podId,
        podUrl: result.podUrl,
        podType: result.podType,
        status: 'ready',
        lastActivityAt: Date.now(),
        replacementCount: attempt,
      });

      log.info({ sessionId, oldPodId, newPodId: result.podId, replacementMs, attempt }, 'Session replaced');
      incrementCounter('session_replacement_succeeded_total');
      observeHistogram('provision_total_ms', replacementMs);

      return { podUrl: result.podUrl };
    } finally {
      releaseSemaphore();
    }
  } catch (err) {
    log.error({ sessionId, attempt, err }, 'Session replacement failed');
    incrementCounter('session_replacement_failed_total');
    await deleteSession(sessionId).catch(() => {});
    throw err;
  }
}

export function sessionClosed(sessionId: string): void {
  // Don't terminate — user may reconnect. Just log. Reaper handles the timeout.
  log.info(
    { sessionId, idleAfterMs: IDLE_TIMEOUT_MS },
    'Client disconnected; pod stays alive pending reconnect',
  );
}

/**
 * Runs once at backend boot: connect to Redis, reconcile orphan pods, then
 * arm the idle reaper.
 */
export async function start(logger: FastifyBaseLogger): Promise<void> {
  log = logger;
  setRedisLogger(logger);
  await ensureRedis();
  await reconcileOrphanPods();
  setInterval(() => void runReaper(), REAPER_INTERVAL_MS);
  log.info({ idleTimeoutMs: IDLE_TIMEOUT_MS, maxConcurrent: MAX_CONCURRENT_PROVISIONS }, 'Orchestrator started');
}

// ────────────────────────────────────────────────────────────────────────────
// Semaphore
// ────────────────────────────────────────────────────────────────────────────

async function acquireSemaphore(onStatus: (msg: string) => void): Promise<void> {
  setGauge('semaphore_active', activeProvisions);
  setGauge('semaphore_queue_depth', semaphoreWaiters.length);
  if (activeProvisions < MAX_CONCURRENT_PROVISIONS) {
    activeProvisions++;
    setGauge('semaphore_active', activeProvisions);
    return;
  }
  const queuedAt = Date.now();
  const queueDepth = semaphoreWaiters.length + 1;
  log.info({ active: activeProvisions, cap: MAX_CONCURRENT_PROVISIONS, queueDepth }, 'Provision queued');
  onStatus(`Waiting for GPU (${queueDepth} in queue)...`);
  await new Promise<void>((resolve) => semaphoreWaiters.push(resolve));
  activeProvisions++;
  const waitedMs = Date.now() - queuedAt;
  incrementCounter('semaphore_wait_total');
  observeHistogram('semaphore_wait_ms', waitedMs);
  setGauge('semaphore_active', activeProvisions);
  setGauge('semaphore_queue_depth', semaphoreWaiters.length);
}

function releaseSemaphore(): void {
  activeProvisions--;
  const next = semaphoreWaiters.shift();
  if (next) next();
}

// ────────────────────────────────────────────────────────────────────────────
// Reaper + reconcile
// ────────────────────────────────────────────────────────────────────────────

async function runReaper(): Promise<void> {
  const now = Date.now();
  const redis = getRedis();
  const stream = redis.scanStream({ match: `${SESSION_PREFIX}*`, count: 100 });
  for await (const keys of stream) {
    for (const key of keys as string[]) {
      try {
        const data = await redis.hgetall(key);
        const status = data['status'];
        if (!data['sessionId'] || !data['podId']) continue;
        if (status !== 'ready') continue; // skip provisioning, replacing, terminated
        const lastActivity = Number(data['lastActivityAt'] ?? 0);
        const idleMs = now - lastActivity;
        if (idleMs <= IDLE_TIMEOUT_MS) continue;

        // Atomic: only reap if status is still 'ready' (prevents two reapers
        // both reaping the same session across replicas).
        const claimed = await redis.multi()
          .hget(key, 'status')
          .hset(key, 'status', 'terminated')
          .exec();
        const prevStatus = claimed?.[0]?.[1];
        if (prevStatus !== 'ready') continue; // another reaper got it

        const podId = data['podId']!;
        const sessionId = data['sessionId']!;
        const createdAt = Number(data['createdAt'] ?? 0);
        const lifetimeMs = createdAt > 0 ? now - createdAt : 0;
        log.info({ sessionId, podId, idleMs, lifetimeMs }, 'Reaping idle pod');
        incrementCounter('session_reaped_total');
        if (lifetimeMs > 0) observeHistogram('session_lifetime_ms', lifetimeMs);
        notifyPodTerminated(podId, `idle ${Math.round(idleMs / 1000)}s`);
        terminatePod(podId)
          .then(() => redis.del(key))
          .catch((err) => log.error({ sessionId, podId, err }, 'Reap failed'));
      } catch (err) {
        log.warn({ key, err: (err as Error).message }, 'Reaper error on key');
      }
    }
  }
}

async function reconcileOrphanPods(): Promise<void> {
  try {
    // 1. Read all session keys from Redis
    const redis = getRedis();
    const sessionPodIds = new Set<string>();
    const staleKeys: string[] = [];
    const stream = redis.scanStream({ match: `${SESSION_PREFIX}*`, count: 100 });
    for await (const keys of stream) {
      for (const key of keys as string[]) {
        const data = await redis.hgetall(key);
        if (data['podId'] && data['status'] === 'ready') {
          sessionPodIds.add(data['podId']);
        } else if (data['status'] === 'provisioning') {
          // Stale provisioning row (no live promise to resume). Clean up.
          staleKeys.push(key);
        }
      }
    }

    // Clean up stale provisioning rows
    for (const key of staleKeys) {
      log.warn({ key }, 'Reconcile: deleting stale provisioning session');
      await redis.del(key);
    }

    // 2. List RunPod pods
    const pods = await listPodsByPrefix(POD_PREFIX);

    // 3. Adopt or terminate
    let adopted = 0;
    let terminated = 0;
    for (const pod of pods) {
      if (sessionPodIds.has(pod.id)) {
        adopted++;
      } else {
        // Genuine orphan — no Redis session references this pod
        log.warn({ podId: pod.id, name: pod.name }, 'Reconcile: terminating orphan pod');
        terminated++;
        await terminatePod(pod.id).catch((err) =>
          log.error({ podId: pod.id, name: pod.name, err }, 'Failed to terminate orphan'),
        );
      }
    }

    // 4. Clean up Redis sessions whose pods no longer exist on RunPod
    const runpodPodIds = new Set(pods.map((p) => p.id));
    const sessionStream = redis.scanStream({ match: `${SESSION_PREFIX}*`, count: 100 });
    for await (const keys of sessionStream) {
      for (const key of keys as string[]) {
        const podId = await redis.hget(key, 'podId');
        if (podId && !runpodPodIds.has(podId)) {
          log.warn({ key, podId }, 'Reconcile: deleting session for pod no longer on RunPod');
          await redis.del(key);
        }
      }
    }

    log.info({ adopted, terminated, staleProvisioning: staleKeys.length }, 'Reconcile complete');
  } catch (err) {
    log.error({ err }, 'Reconcile failed (continuing anyway)');
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Provisioner
// ────────────────────────────────────────────────────────────────────────────

interface ProvisionResult {
  podId: string;
  podUrl: string;
  podType: PodType;
}

async function provision(sessionId: string, onStatus: (msg: string) => void): Promise<ProvisionResult> {
  const t0 = Date.now();

  // 1 + 2. Create a pod — spot first, on-demand fallback if capacity exhausted
  const { podId, podType } = await createPodWithFallback(sessionId, onStatus);
  const podCreateMs = Date.now() - t0;
  incrementCounter('pod_created_total', { type: podType });
  observeHistogram('pod_creation_ms', podCreateMs);

  // 3. Wait for the container to boot. In baked mode the image is slim (~2-3
  // GB) but the very first pull to a host in a DC can still take a few minutes.
  const pullStart = Date.now();
  onStatus('Pulling container image...');
  notifyPodProgress(podId, '⏳ Pulling container image...');
  await waitForRuntime(podId, onStatus);
  const pullMs = Date.now() - pullStart;
  observeHistogram('container_pull_ms', pullMs);
  notifyPodProgress(podId, `📦 Container runtime up (${Math.round(pullMs / 1000)}s)`);

  if (config.FLUX_PROVISION_MODE !== 'baked') {
    const sshInfo = await waitForSsh(podId);
    log.info({ sessionId, podId, ssh: `${sshInfo.ip}:${sshInfo.port}` }, 'Pod SSH ready');

    onStatus('Installing server...');
    notifyPodProgress(podId, '🔧 Installing server...');
    await scpFiles(sshInfo);
    onStatus('Downloading AI model (~2 min)...');
    notifyPodProgress(podId, '⬇️ Downloading AI model...');
    await runSetup(sshInfo, (line) => {
      if (line.includes('Downloading') && line.includes('FLUX.2-klein')) onStatus('Downloading AI model...');
      else if (line.includes('Warming up')) onStatus('Warming up...');
    });
  }

  // 4. Poll /health via RunPod proxy until the FLUX server reports ready
  const healthStart = Date.now();
  onStatus('Loading AI model & warming up...');
  notifyPodProgress(podId, '🧠 Loading AI model & warming up...');
  const healthUrl = `https://${podId}-8766.proxy.runpod.net/health`;
  await waitForHealth(healthUrl);
  observeHistogram('health_ready_ms', Date.now() - healthStart);

  const totalMs = Date.now() - t0;

  // 5. Build WebSocket URL and return
  const podUrl = `wss://${podId}-8766.proxy.runpod.net/ws`;
  log.info({ sessionId, podId, podUrl, podType, totalMs, mode: config.FLUX_PROVISION_MODE }, 'Pod ready');
  onStatus('Ready');
  notifyPodProgress(podId, `✅ **Pod ready** (${Math.round(totalMs / 1000)}s total)`);
  return { podId, podUrl, podType };
}

/**
 * A candidate placement: which DC to pin the pod to, and optionally which
 * pre-populated network volume to attach. `null` for both means "let RunPod
 * pick any DC, no volume" — legacy ssh-mode behavior.
 */
interface PlacementTarget {
  dataCenterId: string | null;
  networkVolumeId: string | null;
  bidInfo: SpotBidInfo | null;
}

/**
 * In baked mode with a configured NETWORK_VOLUMES_BY_DC, iterate through each
 * volume DC and query spot stock. Returns the first DC with Medium/High stock
 * (with its bid info), or the best-stock DC even if Low (so the caller can
 * still try spot before falling back to on-demand). Returns `null` only if
 * every DC returns a hard capacity miss.
 *
 * In non-baked mode or with no volumes configured, returns a single unpinned
 * target (DC = null) and lets RunPod pick.
 */
async function selectPlacement(sessionId: string): Promise<PlacementTarget | null> {
  const volumes = config.NETWORK_VOLUMES_BY_DC;
  const volumeDcs = Object.keys(volumes);
  const useVolumes = config.FLUX_PROVISION_MODE === 'baked' && volumeDcs.length > 0;

  if (!useVolumes) {
    try {
      const bidInfo = await getSpotBid(GPU_TYPE_ID);
      return { dataCenterId: null, networkVolumeId: null, bidInfo };
    } catch (err) {
      if (isCapacityError(err)) return { dataCenterId: null, networkVolumeId: null, bidInfo: null };
      throw err;
    }
  }

  // Volume-aware path: probe each DC, rank by stock, pick the best.
  const rank: Record<string, number> = { High: 3, Medium: 2, Low: 1, None: 0 };
  const probed: Array<{ dc: string; volumeId: string; bid: SpotBidInfo | null }> = [];
  await Promise.all(
    volumeDcs.map(async (dc) => {
      const volumeId = volumes[dc]!;
      try {
        const bid = await getSpotBid(GPU_TYPE_ID, { dataCenterId: dc });
        probed.push({ dc, volumeId, bid });
      } catch (err) {
        if (isCapacityError(err)) {
          probed.push({ dc, volumeId, bid: null });
        } else {
          throw err;
        }
      }
    }),
  );

  // Sort: DCs with stock first (by rank), then null-stock DCs (for on-demand only).
  probed.sort((a, b) => {
    const ar = a.bid ? (rank[a.bid.stockStatus] ?? 0) : -1;
    const br = b.bid ? (rank[b.bid.stockStatus] ?? 0) : -1;
    return br - ar;
  });

  log.info(
    {
      sessionId,
      event: 'provision.placement.ranked',
      dcs: probed.map((p) => ({ dc: p.dc, stock: p.bid?.stockStatus ?? 'none' })),
    },
    'DC placement ranked',
  );

  const top = probed[0];
  if (!top) return null;
  return { dataCenterId: top.dc, networkVolumeId: top.volumeId, bidInfo: top.bid };
}

/**
 * Tries spot first. Falls through to on-demand on capacity exhaustion if
 * `ONDEMAND_FALLBACK_ENABLED` is set and the policy allows it. Emits structured
 * events at each decision point so Workstream 4 can attribute cost by pod type.
 *
 * In baked mode with network volumes, pins both spot and on-demand attempts
 * to the selected volume's DC so the pre-populated weights are reachable.
 */
async function createPodWithFallback(
  sessionId: string,
  onStatus: (msg: string) => void,
): Promise<{ podId: string; podType: PodType }> {
  const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;

  // Image + registry auth depend on provision mode.
  // ssh mode: stock runpod/pytorch base (Docker Hub, RUNPOD_REGISTRY_AUTH_ID).
  // baked mode: GHCR image with deps baked in (RUNPOD_GHCR_AUTH_ID). Weights
  // come from the attached network volume at /workspace/huggingface.
  const imageName = config.FLUX_PROVISION_MODE === 'baked'
    ? (config.FLUX_IMAGE || (() => { throw new Error('FLUX_IMAGE env var required when FLUX_PROVISION_MODE=baked'); })())
    : IMAGE_NAME;
  const authId = config.FLUX_PROVISION_MODE === 'baked'
    ? (config.RUNPOD_GHCR_AUTH_ID || undefined)
    : (config.RUNPOD_REGISTRY_AUTH_ID || undefined);

  // ─── Pick DC (+ volume if baked) ─────────────────────────────────────
  onStatus('Finding available GPU...');
  const target = await selectPlacement(sessionId);
  if (!target) {
    throw new Error('No RunPod DC has 5090 capacity right now (all volume-DCs exhausted)');
  }
  const bidInfo = target.bidInfo;
  const dcField = target.dataCenterId ? { dataCenterId: target.dataCenterId } : {};
  const volField = target.networkVolumeId ? { networkVolumeId: target.networkVolumeId } : {};

  // ─── Try spot ─────────────────────────────────────────────────────────
  let spotCapacityExhausted = false;
  let fallbackReason: string | null = null;

  if (!bidInfo) {
    spotCapacityExhausted = true;
    fallbackReason = 'spot_bid_unavailable';
    log.info(
      { sessionId, event: 'provision.spot.capacityMiss', reason: fallbackReason, dc: target.dataCenterId },
      'No spot pricing — will try on-demand',
    );
  } else if (bidInfo.stockStatus === 'None' || bidInfo.stockStatus === 'Low') {
    spotCapacityExhausted = true;
    fallbackReason = `stock_${bidInfo.stockStatus.toLowerCase()}`;
    log.info(
      { sessionId, event: 'provision.spot.capacityMiss', stockStatus: bidInfo.stockStatus, dc: target.dataCenterId },
      'Spot stock low — will try on-demand',
    );
  }

  if (!spotCapacityExhausted && bidInfo) {
    const bid = Math.round((bidInfo.minimumBidPrice + BID_HEADROOM) * 100) / 100;
    log.info(
      {
        sessionId,
        event: 'provision.spot.attempt',
        minBid: bidInfo.minimumBidPrice,
        stockStatus: bidInfo.stockStatus,
        bid,
        dc: target.dataCenterId,
        volumeId: target.networkVolumeId,
      },
      'Spot bid discovered',
    );
    onStatus('Provisioning GPU...');
    try {
      const { id: podId, costPerHr } = await createSpotPod({
        name: podName,
        imageName,
        gpuTypeId: GPU_TYPE_ID,
        bidPerGpu: bid,
        ...(authId ? { containerRegistryAuthId: authId } : {}),
        ...dcField,
        ...volField,
      });
      log.info(
        { sessionId, event: 'provision.spot.success', podId, costPerHr, podType: 'spot', dc: target.dataCenterId },
        'Pod created (spot)',
      );
      void notifyPodCreated({ podId, podType: 'spot', dc: target.dataCenterId ?? undefined, costPerHr });
      return { podId, podType: 'spot' };
    } catch (err) {
      if (isCapacityError(err)) {
        spotCapacityExhausted = true;
        fallbackReason = 'spot_create_capacity_error';
        log.info(
          { sessionId, event: 'provision.spot.capacityMiss', err: (err as Error).message, dc: target.dataCenterId },
          'Spot createPod hit capacity error — will try on-demand',
        );
      } else {
        throw err;
      }
    }
  }

  // ─── Fall through to on-demand ───────────────────────────────────────
  if (!config.ONDEMAND_FALLBACK_ENABLED) {
    throw new Error(
      `5090 spot capacity exhausted (${fallbackReason ?? 'unknown'}); on-demand fallback disabled`,
    );
  }

  // Policy gate — v1 allows everyone. Post-WS8, free-tier users may stay spot-only.
  const allowed = await getPolicy().allowsOnDemand({ userId: sessionId, source: 'jwt' });
  if (!allowed) {
    throw new Error(
      `5090 spot capacity exhausted (${fallbackReason ?? 'unknown'}); on-demand not allowed by policy`,
    );
  }

  log.info(
    { sessionId, event: 'provision.fallback.triggered', reason: fallbackReason, dc: target.dataCenterId },
    'Switching to on-demand pod',
  );
  // Silent to the user — status says "Creating pod..." same as spot path.
  onStatus('Creating pod...');
  try {
    const { id: podId, costPerHr } = await createOnDemandPod({
      name: podName,
      imageName,
      gpuTypeId: GPU_TYPE_ID,
      cloudType: 'SECURE',
      ...(authId ? { containerRegistryAuthId: authId } : {}),
      ...dcField,
      ...volField,
    });
    log.info(
      { sessionId, event: 'provision.onDemand.success', podId, costPerHr, podType: 'onDemand', dc: target.dataCenterId },
      'Pod created (on-demand)',
    );
    void notifyPodCreated({ podId, podType: 'onDemand', dc: target.dataCenterId ?? undefined, costPerHr });
    return { podId, podType: 'onDemand' };
  } catch (err) {
    log.error(
      { sessionId, event: 'provision.onDemand.failed', err: (err as Error).message, dc: target.dataCenterId },
      'On-demand fallback also failed',
    );
    throw err;
  }
}

interface SshInfo {
  ip: string;
  port: number;
  podId: string;
}

async function waitForSsh(podId: string, timeoutMs = 5 * 60 * 1000): Promise<SshInfo> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (pod?.runtime?.ports) {
      const ssh = pod.runtime.ports.find((p) => p.privatePort === 22);
      if (ssh && ssh.ip) {
        return { ip: ssh.ip, port: ssh.publicPort, podId };
      }
    }
    await sleep(5000);
  }
  throw new Error(`Pod ${podId} never got SSH info within ${timeoutMs}ms`);
}

function ensureSshKey(): void {
  if (sshKeyWritten) return;
  const key = config.RUNPOD_SSH_PRIVATE_KEY;
  writeFileSync(SSH_KEY_PATH, key.endsWith('\n') ? key : key + '\n');
  chmodSync(SSH_KEY_PATH, 0o600);
  sshKeyWritten = true;
}

async function scpFiles(ssh: SshInfo): Promise<void> {
  ensureSshKey();
  const { ip, port } = ssh;
  const scpOpts = ['-i', SSH_KEY_PATH, '-o', 'StrictHostKeyChecking=no', '-P', String(port)];
  const sshOpts = ['-i', SSH_KEY_PATH, '-o', 'StrictHostKeyChecking=no', '-p', String(port)];

  // Wait for sshd to be responsive
  await retryCommand('ssh', [...sshOpts, `root@${ip}`, 'echo ok'], 12, 5000);

  // Prepare target dir
  await runCommand('ssh', [...sshOpts, `root@${ip}`, 'rm -rf /tmp/flux-klein-server && mkdir -p /tmp/flux-klein-server']);

  // SCP the setup script
  await runCommand('scp', [
    ...scpOpts,
    join(RUNTIME_ASSETS_DIR, 'setup-flux-klein.sh'),
    `root@${ip}:/tmp/setup-flux-klein.sh`,
  ]);

  // SCP the server files
  const files = ['server.py', 'pipeline.py', 'config.py', 'requirements.txt'];
  for (const f of files) {
    await runCommand('scp', [
      ...scpOpts,
      join(RUNTIME_ASSETS_DIR, 'flux-klein-server', f),
      `root@${ip}:/tmp/flux-klein-server/${f}`,
    ]);
  }
}

async function runSetup(ssh: SshInfo, onLine: (line: string) => void): Promise<void> {
  ensureSshKey();
  const { ip, port } = ssh;
  const sshOpts = ['-i', SSH_KEY_PATH, '-o', 'StrictHostKeyChecking=no', '-p', String(port)];
  await runCommand(
    'ssh',
    [...sshOpts, `root@${ip}`, 'chmod +x /tmp/setup-flux-klein.sh && /tmp/setup-flux-klein.sh'],
    { onStdoutLine: onLine, timeoutMs: 15 * 60 * 1000 },
  );
}

/**
 * Polls the RunPod API until the pod's `runtime` field is non-null, meaning
 * the container image has been pulled and the container process is running.
 * Emits a status update when the transition happens so the user sees
 * "Pulling container image..." → "Starting server..." in real time.
 */
async function waitForRuntime(
  podId: string,
  onStatus: (msg: string) => void,
  timeoutMs = 10 * 60 * 1000,
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (pod?.runtime) {
      log.info({ podId, uptimeInSeconds: pod.runtime.uptimeInSeconds }, 'Container runtime up');
      onStatus('Starting server...');
      return;
    }
    await sleep(5000);
  }
  throw new Error(`Pod ${podId} container never started within ${Math.round(timeoutMs / 1000)}s`);
}

async function waitForHealth(healthUrl: string, timeoutMs = 10 * 60 * 1000): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(healthUrl, { signal: AbortSignal.timeout(10_000) });
      if (res.ok) {
        const body = (await res.json()) as { status?: string };
        if (body.status === 'ok') return;
      }
    } catch {
      // Ignore — health check hasn't come up yet
    }
    await sleep(10_000);
  }
  throw new Error(`Server at ${healthUrl} never became healthy within ${timeoutMs}ms`);
}

// ────────────────────────────────────────────────────────────────────────────
// Child process helpers
// ────────────────────────────────────────────────────────────────────────────

interface RunCommandOpts {
  onStdoutLine?: (line: string) => void;
  timeoutMs?: number;
}

function runCommand(cmd: string, args: string[], opts: RunCommandOpts = {}): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 2 * 60 * 1000;
  return new Promise((resolve, reject) => {
    const proc = spawn(cmd, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    const timer = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`${cmd} timed out after ${timeoutMs}ms`));
    }, timeoutMs);

    const onStdoutLine = opts.onStdoutLine;
    if (onStdoutLine && proc.stdout) {
      let buf = '';
      proc.stdout.on('data', (chunk: Buffer) => {
        buf += chunk.toString('utf8');
        let idx: number;
        while ((idx = buf.indexOf('\n')) !== -1) {
          onStdoutLine(buf.slice(0, idx));
          buf = buf.slice(idx + 1);
        }
      });
    }

    let stderr = '';
    proc.stderr?.on('data', (chunk: Buffer) => {
      stderr += chunk.toString('utf8');
    });

    proc.on('error', (err) => {
      clearTimeout(timer);
      reject(err);
    });
    proc.on('exit', (code) => {
      clearTimeout(timer);
      if (code === 0) resolve();
      else reject(new Error(`${cmd} exited ${code}: ${stderr.slice(-500)}`));
    });
  });
}

async function retryCommand(cmd: string, args: string[], attempts: number, delayMs: number): Promise<void> {
  let lastErr: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      await runCommand(cmd, args, { timeoutMs: 15_000 });
      return;
    } catch (err) {
      lastErr = err;
      await sleep(delayMs);
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error(String(lastErr));
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

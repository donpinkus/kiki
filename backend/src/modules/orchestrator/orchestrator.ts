/**
 * Per-session pod lifecycle orchestration.
 *
 * Responsibilities (all in this one file because they share state and are
 * tightly coupled — separating would just spread the reader's attention across
 * imports):
 *   - Registry: Map<sessionId, Session>
 *   - Provisioner: create pod → wait for runtime → poll health
 *   - Reaper: terminate pods idle > 10 min
 *   - Reconcile: on boot, kill orphaned `kiki-session-*` pods from prior runs
 *   - Semaphore: cap concurrent provisions to prevent rate-limit + burst OOM
 *
 * ─── Pod Lifecycle Edge Cases ────────────────────────────────────────────
 *
 * Every scenario below MUST be handled. If you change provisioning, replacement,
 * or session logic, verify each case still works. Add new rows as we discover them.
 *
 * ┌─────────────────────────────────────┬──────────────────────────────────────────────────┬──────────────────────────────┐
 * │ Scenario                            │ What happens                                     │ Handling                     │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 1. Spot pod preempted (disappears)  │ Upstream WS closes with code 1006/1012.          │ stream.ts relay.onClose →    │
 * │                                     │ RunPod deletes pod entirely.                     │ classifyClose → replaceSession│
 * │                                     │                                                  │ provisions new pod. iOS      │
 * │                                     │                                                  │ reconnect joins via          │
 * │                                     │                                                  │ status='replacing' check in  │
 * │                                     │                                                  │ getOrProvisionPod.           │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 2. Pod vanishes during provisioning │ Pod created on RunPod but disappears before      │ waitForRuntime / waitForHealth│
 * │    (spot preempted before serving)  │ becoming serve-ready. getPod() returns null.      │ throw PodVanishedError;       │
 * │                                     │                                                  │ provision()'s reroll loop     │
 * │                                     │                                                  │ blacklists the DC and retries.│
 * │                                     │                                                  │ Only after rerolls exhausted  │
 * │                                     │                                                  │ does abortSession fire.       │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 3. Pod errors during provisioning   │ Container pulls but server.py crashes on startup │ waitForHealth polls /health;  │
 * │    (e.g. Python import error)       │ (e.g. missing dep, bad config). Pod is running   │ if pod runtime is up but      │
 * │                                     │ but /health never returns 200.                   │ health never passes, times    │
 * │                                     │                                                  │ out after 10min → abortSession│
 * │                                     │                                                  │ terminates pod + clears Redis.│
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 4. User idle >10min on gallery      │ No WS connection → no touch() calls.             │ Reaper scans every 60s,      │
 * │                                     │ lastActivityAt goes stale.                       │ terminates pod if idle >10min.│
 * │                                     │                                                  │ Redis session deleted. Next   │
 * │                                     │                                                  │ startStream() provisions     │
 * │                                     │                                                  │ fresh.                       │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 5. User idle >10min on canvas       │ WS stays open but no frames sent (canvas         │ Same as #4 — touch() only    │
 * │    (not drawing)                    │ unchanged). No touch() calls from relay.          │ fires on relayed messages.   │
 * │                                     │                                                  │ Pod reaped. Next stroke →    │
 * │                                     │                                                  │ frame send fails → iOS       │
 * │                                     │                                                  │ reconnects → provisions new. │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 6. Railway redeploy during          │ Backend process dies. In-memory                  │ New process boots → reconcile │
 * │    provisioning                     │ inFlightProvisions map lost. Pod may still be    │ adopts or terminates orphans. │
 * │                                     │ provisioning on RunPod.                          │ iOS reconnects → checks Redis │
 * │                                     │                                                  │ status: if 'provisioning',   │
 * │                                     │                                                  │ detected as stale → deleted  │
 * │                                     │                                                  │ → fresh provision.           │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 7. iOS reconnect during replacement │ Spot preempted → replaceSession sets             │ getOrProvisionPod detects    │
 * │    (duplicate pod race)             │ status='replacing'. iOS reconnects and calls     │ status='replacing' → polls   │
 * │                                     │ getOrProvisionPod.                               │ Redis via waitForReplacement │
 * │                                     │                                                  │ until replacement completes. │
 * │                                     │                                                  │ No duplicate pod created.    │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 8. Network glitch during drawing    │ WS momentarily drops. iOS receive loop ends      │ iOS attemptReconnect (3x     │
 * │                                     │ unexpectedly.                                    │ with exponential backoff).   │
 * │                                     │                                                  │ Backend pod stays alive      │
 * │                                     │                                                  │ (sessionClosed keeps it for  │
 * │                                     │                                                  │ reconnect within 10min).     │
 * │                                     │                                                  │ Reconnect reuses ready pod.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 9. App backgrounded then resumed    │ iOS stopStream() on background, restarts on      │ Pod stays alive up to 10min  │
 * │                                     │ foreground if streamWasActiveBeforeBackground.   │ (idle reaper). If resumed    │
 * │                                     │                                                  │ within window, reuses pod.   │
 * │                                     │                                                  │ If >10min, fresh provision.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 10. Docker image pull stalls on     │ Pod created but runtime stays null. GHCR blob    │ waitForRuntime throws        │
 * │     a bad RunPod host (known to     │ serve or host-network stall indistinguishable     │ ImagePullStallError after    │
 * │     happen on GHCR + spot).         │ from the outside — pod.runtime stays null.        │ CONTAINER_PULL_STALL_MS      │
 * │                                     │                                                  │ (default 120s). provision()  │
 * │                                     │                                                  │ terminates pod, blacklists   │
 * │                                     │                                                  │ the DC, and rerolls up to    │
 * │                                     │                                                  │ CONTAINER_PULL_MAX_REROLLS.  │
 * │                                     │                                                  │ Sentry captures each stall.  │
 * │                                     │                                                  │ 10-min hard timeout remains  │
 * │                                     │                                                  │ as a safety net when the     │
 * │                                     │                                                  │ watchdog is disabled.        │
 * └─────────────────────────────────────┴──────────────────────────────────────────────────┴──────────────────────────────┘
 */

import type { FastifyBaseLogger } from 'fastify';
import * as Sentry from '@sentry/node';

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
import { ImagePullStallError, PodVanishedError, classifyProvisionError } from './errorClassification.js';
import {
  trackPodProvisionStarted,
  trackPodProvisionCompleted,
  trackPodProvisionFailed,
  trackPodProvisionStalled,
  trackPodProvisionVanished,
  trackPodReplacementExhausted,
  trackPodTerminated,
} from '../analytics/index.js';

export { ImagePullStallError } from './errorClassification.js';

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
// Headroom above the current spot floor. Larger headroom = fewer outbids =
// fewer needless fallbacks to on-demand. 0.05 costs ~$0.03/hr more than the
// 0.02 default on a typical bid, cheaper than one on-demand fallback.
const BID_HEADROOM = 0.05;

const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const REAPER_INTERVAL_MS = 60 * 1000;
const MAX_CONCURRENT_PROVISIONS = Number(process.env['MAX_CONCURRENT_PROVISIONS'] ?? 5);

// Semaphore state
let activeProvisions = 0;
const semaphoreWaiters: Array<() => void> = [];

// Logger injected by start()
let log: FastifyBaseLogger = console as unknown as FastifyBaseLogger;

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

/**
 * Partial update — only writes the fields in `patch`, refreshes TTL.
 * Safer than `writeSession` for transitions (status changes, pod swaps)
 * because it never risks clobbering a field the caller didn't intend to set.
 */
async function patchSession(
  sessionId: string,
  patch: Partial<Pick<
    RedisSession,
    'status' | 'podId' | 'podUrl' | 'podType' | 'lastActivityAt' | 'replacementCount'
  >>,
): Promise<void> {
  const key = sessionKey(sessionId);
  const fields: Record<string, string> = {};
  if (patch.status !== undefined) fields['status'] = patch.status;
  if (patch.podId !== undefined) fields['podId'] = patch.podId ?? '';
  if (patch.podUrl !== undefined) fields['podUrl'] = patch.podUrl ?? '';
  if (patch.podType !== undefined) fields['podType'] = patch.podType ?? '';
  if (patch.lastActivityAt !== undefined) fields['lastActivityAt'] = String(patch.lastActivityAt);
  if (patch.replacementCount !== undefined) fields['replacementCount'] = String(patch.replacementCount);
  if (Object.keys(fields).length === 0) return;
  await getRedis().multi()
    .hset(key, fields)
    .expire(key, IDLE_TTL_SECONDS)
    .exec();
}

async function deleteSession(sessionId: string): Promise<void> {
  await getRedis().del(sessionKey(sessionId));
}

/**
 * Yields every session key in Redis. Wraps the `scanStream` + nested
 * for-await iteration so the three sweep sites (reaper, reconcile pass 1,
 * reconcile pass 2) don't each re-derive the boilerplate.
 */
async function* eachSessionKey(): AsyncIterable<string> {
  const stream = getRedis().scanStream({ match: `${SESSION_PREFIX}*`, count: 100 });
  for await (const keys of stream) {
    for (const key of keys as string[]) {
      yield key;
    }
  }
}

/**
 * Atomically tear down a session: terminate the pod on RunPod (if any), then
 * delete the Redis row. Used from error paths where we've decided the session
 * is unusable — e.g. relay to the pod's `/ws` failed on upgrade, or provision
 * failed mid-way.
 *
 * Never throws. Logs + swallows individual failures so callers on an error
 * path aren't pushed further off the rails.
 */
export async function abortSession(
  sessionId: string,
  reason: 'manual' | 'error' = 'error',
): Promise<void> {
  try {
    const session = await readSession(sessionId);
    if (session?.podId) {
      const lifetimeMs = session.createdAt > 0 ? Date.now() - session.createdAt : 0;
      trackPodTerminated({ userId: sessionId, reason, lifetimeMs });
      terminatePod(session.podId).catch((err) =>
        log.warn({ sessionId, podId: session.podId, err: (err as Error).message }, 'abortSession: terminatePod failed'),
      );
    }
    await deleteSession(sessionId);
  } catch (err) {
    log.warn({ sessionId, err: (err as Error).message }, 'abortSession failed');
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Public API
// ────────────────────────────────────────────────────────────────────────────

const REPLACEMENT_POLL_MS = 3_000;
const REPLACEMENT_TIMEOUT_MS = 10 * 60 * 1000; // 10 min — same as provision timeout

/**
 * Poll Redis until a 'replacing' session becomes 'ready' or is deleted.
 * Used by getOrProvisionPod when it detects that replaceSession is already
 * handling spot preemption recovery — avoids provisioning a duplicate pod.
 */
async function waitForReplacement(
  sessionId: string,
  onStatus: (msg: string) => void,
): Promise<string> {
  const start = Date.now();
  const deadline = start + REPLACEMENT_TIMEOUT_MS;
  let polls = 0;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, REPLACEMENT_POLL_MS));
    polls++;
    const session = await readSession(sessionId);
    if (!session) {
      log.warn({ sessionId, polls }, 'Session deleted while waiting for replacement');
      throw new Error('Session deleted while waiting for replacement');
    }
    if (session.status === 'ready' && session.podUrl) {
      const elapsed = Math.round((Date.now() - start) / 1000);
      log.info({ sessionId, podId: session.podId, elapsedSec: elapsed }, 'Replacement completed — reusing pod');
      onStatus('Ready');
      return session.podUrl;
    }
    if (session.status !== 'replacing') {
      log.warn({ sessionId, status: session.status, polls }, 'Unexpected status while waiting for replacement');
      throw new Error(`Unexpected session status while waiting for replacement: ${session.status}`);
    }
    if (polls % 10 === 0) {
      const elapsed = Math.round((Date.now() - start) / 1000);
      log.info({ sessionId, elapsedSec: elapsed, status: session.status }, 'Still waiting for replacement');
    }
  }
  throw new Error('Replacement timed out');
}

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

  // 1b. If a replacement is in progress (spot preemption recovery), wait for
  // it instead of provisioning a duplicate pod. The replacement flow in
  // replaceSession() writes status='replacing' and will flip to 'ready' once
  // the new pod is up.
  if (existing?.status === 'replacing') {
    log.info({ sessionId }, 'Replacement in progress — waiting');
    onStatus('Replacing GPU...');
    const podUrl = await waitForReplacement(sessionId, onStatus);
    return { podUrl };
  }

  // 2. Check local in-flight map (same-process concurrent callers)
  const inFlight = inFlightProvisions.get(sessionId);
  if (inFlight) {
    log.info({ sessionId }, 'Waiting for in-flight provision');
    onStatus('Pod is starting up...');
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
        await patchSession(sessionId, {
          podId: result.podId,
          podUrl: result.podUrl,
          podType: result.podType,
          status: 'ready',
          lastActivityAt: Date.now(),
        });
        return { podUrl: result.podUrl };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      const elapsedMs = Date.now() - now;
      const category = classifyProvisionError(err as Error);
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

/**
 * Check if a user already has an active pod — used to skip rate limiting on
 * reconnect. "Active" includes `provisioning` and `replacing`, not just
 * `ready`: a user navigating away and back during cold start is reconnecting
 * to their existing in-flight pod, not creating a new one. Treating this as
 * a fresh provision triggers spurious `too_many_active_pods` rejections.
 */
export async function hasReadySession(sessionId: string): Promise<boolean> {
  const session = await readSession(sessionId);
  if (!session) return false;
  return session.status === 'ready' || session.status === 'provisioning' || session.status === 'replacing';
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
    trackPodReplacementExhausted({
      userId: sessionId,
      maxAttempts: config.MAX_SESSION_REPLACEMENTS,
    });
    await deleteSession(sessionId);
    throw new Error(`Replacement limit reached (${config.MAX_SESSION_REPLACEMENTS} attempts)`);
  }

  const oldPodId = session.podId;
  const attempt = session.replacementCount + 1;

  log.info({ sessionId, oldPodId, attempt }, 'Starting session replacement');

  // Mark as replacing in Redis
  await patchSession(sessionId, {
    status: 'replacing',
    lastActivityAt: Date.now(),
    replacementCount: attempt,
  });

  // Clean up old pod (fire-and-forget — may already be gone)
  if (oldPodId) {
    terminatePod(oldPodId).catch((e) =>
      log.warn(
        { sessionId, oldPodId, err: (e as Error).message },
        'Failed to terminate old pod during replacement — will be reaped',
      ),
    );
  }

  const t0 = Date.now();
  let newPodId: string | null = null;

  try {
    await acquireSemaphore(onStatus);
    try {
      const result = await provision(sessionId, onStatus);
      newPodId = result.podId;
      const replacementMs = Date.now() - t0;

      await patchSession(sessionId, {
        podId: result.podId,
        podUrl: result.podUrl,
        podType: result.podType,
        status: 'ready',
        lastActivityAt: Date.now(),
      });

      log.info({ sessionId, oldPodId, newPodId: result.podId, replacementMs, attempt }, 'Session replaced');

      return { podUrl: result.podUrl };
    } finally {
      releaseSemaphore();
    }
  } catch (err) {
    log.error({ sessionId, attempt, err }, 'Session replacement failed');
    Sentry.captureException(err, {
      tags: { sessionId, attempt: String(attempt), phase: 'session_replacement' },
    });
    // If provision() succeeded but a later step threw (e.g. patchSession),
    // the new pod is running with no Redis pointer. Terminate it so we don't
    // leak. The old pod was already terminated above.
    if (newPodId) {
      terminatePod(newPodId).catch((e) => {
        log.warn({ sessionId, newPodId, err: (e as Error).message }, 'Failed to clean up replacement pod');
        Sentry.captureException(e, {
          tags: { sessionId, phase: 'replacement_pod_cleanup' },
        });
      });
    }
    await deleteSession(sessionId).catch((delErr) => {
      log.error(
        { sessionId, err: (delErr as Error).message },
        'Failed to delete session after replacement failure',
      );
      Sentry.captureException(delErr, {
        tags: { sessionId, phase: 'replacement_session_cleanup' },
      });
    });
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
 * arm the idle reaper + periodic reconcile sweep.
 */
export async function start(logger: FastifyBaseLogger): Promise<void> {
  log = logger;
  setRedisLogger(logger);
  await ensureRedis();
  // Boot-time reconcile is aggressive (no age gate) — we just restarted so
  // anything not in Redis is genuinely orphaned.
  await reconcileOrphanPods(0);
  setInterval(() => void runReaper(), REAPER_INTERVAL_MS);
  // Periodic reconcile with age gate to catch leaks between restarts without
  // killing pods mid-provision.
  setInterval(
    () => void reconcileOrphanPods(config.RECONCILE_MIN_AGE_SEC),
    config.RECONCILE_INTERVAL_MS,
  );
  log.info(
    {
      idleTimeoutMs: IDLE_TIMEOUT_MS,
      maxConcurrent: MAX_CONCURRENT_PROVISIONS,
      reconcileIntervalMs: config.RECONCILE_INTERVAL_MS,
      reconcileMinAgeSec: config.RECONCILE_MIN_AGE_SEC,
    },
    'Orchestrator started',
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Semaphore
// ────────────────────────────────────────────────────────────────────────────

async function acquireSemaphore(onStatus: (msg: string) => void): Promise<void> {
  if (activeProvisions < MAX_CONCURRENT_PROVISIONS) {
    activeProvisions++;
    return;
  }
  const queuedAt = Date.now();
  const queueDepth = semaphoreWaiters.length + 1;
  log.info({ active: activeProvisions, cap: MAX_CONCURRENT_PROVISIONS, queueDepth }, 'Provision queued');
  onStatus(`Waiting for GPU (${queueDepth} in queue)...`);
  await Sentry.startSpan(
    { name: 'pod.semaphore_wait', op: 'pod.semaphore_wait', attributes: { queueDepth } },
    () => new Promise<void>((resolve) => semaphoreWaiters.push(resolve)),
  );
  activeProvisions++;
  const waitedMs = Date.now() - queuedAt;
  log.info({ waitedMs, active: activeProvisions }, 'Provision dequeued');
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
  for await (const key of eachSessionKey()) {
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
      trackPodTerminated({ userId: sessionId, reason: 'idle', lifetimeMs });
      notifyPodTerminated(podId, `idle ${Math.round(idleMs / 1000)}s`);
      terminatePod(podId)
        .then(() => redis.del(key))
        .catch((err) => log.error({ sessionId, podId, err }, 'Reap failed'));
    } catch (err) {
      log.warn({ key, err: (err as Error).message }, 'Reaper error on key');
    }
  }
}

/**
 * Cross-reference Redis sessions with RunPod pods matching our prefix.
 * Pods that no Redis session points at are terminated. Sessions whose pods
 * no longer exist on RunPod are deleted.
 *
 * @param minAgeSec Skip pods younger than this (or whose runtime hasn't
 *   started yet). Pass 0 at boot — every pod is fair game since we just
 *   restarted. At runtime, pass a value comfortably over the provision
 *   deadline so we don't kill pods mid-provision.
 */
async function reconcileOrphanPods(minAgeSec = 0): Promise<void> {
  try {
    // 1. Read all session keys from Redis
    const redis = getRedis();
    const sessionPodIds = new Set<string>();
    const staleKeys: string[] = [];
    for await (const key of eachSessionKey()) {
      const data = await redis.hgetall(key);
      if (data['podId'] && data['status'] === 'ready') {
        sessionPodIds.add(data['podId']);
      } else if (data['status'] === 'provisioning') {
        // Stale provisioning row (no live promise to resume). Clean up.
        staleKeys.push(key);
      }
    }

    // Clean up stale provisioning rows
    for (const key of staleKeys) {
      log.warn({ key }, 'Reconcile: deleting stale provisioning session');
      await redis.del(key);
    }

    // 2. List RunPod pods
    const pods = await listPodsByPrefix(POD_PREFIX);

    // 3. Adopt, skip young, or terminate
    let adopted = 0;
    let skippedYoung = 0;
    let terminated = 0;
    for (const pod of pods) {
      if (sessionPodIds.has(pod.id)) {
        adopted++;
        continue;
      }
      if (minAgeSec > 0) {
        const uptime = pod.runtime?.uptimeInSeconds ?? 0;
        if (pod.runtime === null || uptime < minAgeSec) {
          // Pod might be mid-provision — its Redis row hasn't been written yet.
          skippedYoung++;
          continue;
        }
      }
      // Genuine orphan — no Redis session references this pod and it's old enough
      log.warn({ podId: pod.id, name: pod.name }, 'Reconcile: terminating orphan pod');
      terminated++;
      await terminatePod(pod.id).catch((err) =>
        log.error({ podId: pod.id, name: pod.name, err }, 'Failed to terminate orphan'),
      );
    }

    // 4. Clean up Redis sessions whose pods no longer exist on RunPod
    const runpodPodIds = new Set(pods.map((p) => p.id));
    for await (const key of eachSessionKey()) {
      const podId = await redis.hget(key, 'podId');
      if (podId && !runpodPodIds.has(podId)) {
        log.warn({ key, podId }, 'Reconcile: deleting session for pod no longer on RunPod');
        await redis.del(key);
      }
    }

    log.info({ adopted, terminated, skippedYoung, staleProvisioning: staleKeys.length, minAgeSec }, 'Reconcile complete');
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

type ProvisionPhase =
  | 'placement'
  | 'pod_create'
  | 'runtime_up'
  | 'health_check';

/**
 * Classify a provision-attempt error as "recoverable by DC reroll" or not, and
 * emit the structured observability signals (log + Sentry breadcrumb + PostHog
 * event) for the recoverable class. `ImagePullStallError` and `PodVanishedError`
 * are the two recoverable classes — both point at a flaky DC and are handled
 * identically except for the event names and the `phase` attribute.
 *
 * Returns `'retry'` when the caller should blacklist `errDc` and re-enter the
 * reroll loop, `'abort'` when the caller should fall through to the generic
 * failure path (unrecoverable error, or rerolls exhausted).
 */
function handleRecoverableProvisionError(
  err: Error,
  ctx: {
    sessionId: string;
    dc: string | null;
    podType: PodType | null;
    attempt: number;
    maxRerolls: number;
  },
): { decision: 'retry' | 'abort'; errDc: string | null } {
  if (!(err instanceof ImagePullStallError) && !(err instanceof PodVanishedError)) {
    return { decision: 'abort', errDc: null };
  }
  const errDc = err.dc ?? ctx.dc;
  const willReroll = ctx.attempt < ctx.maxRerolls;
  const isStall = err instanceof ImagePullStallError;
  const errPhase: 'runtime_up' | 'health_check' = isStall ? 'runtime_up' : err.phase;
  const message = isStall ? 'Image pull stalled' : 'Pod vanished during provisioning';

  log.warn(
    {
      sessionId: ctx.sessionId,
      event: isStall ? 'provision.pull.stall_detected' : 'provision.pod.vanished',
      podId: err.podId,
      dc: errDc,
      phase: errPhase,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    },
    message,
  );
  Sentry.captureMessage(message, {
    level: 'warning',
    tags: {
      dc: errDc ?? 'unknown',
      podType: ctx.podType ?? 'unknown',
      phase: errPhase,
      attempt: String(ctx.attempt),
      willReroll: String(willReroll),
    },
    contexts: {
      pod: { id: err.podId, sessionId: ctx.sessionId, elapsedSec: err.elapsedSec },
    },
  });
  if (isStall) {
    trackPodProvisionStalled({
      userId: ctx.sessionId,
      dc: errDc,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    });
  } else {
    trackPodProvisionVanished({
      userId: ctx.sessionId,
      dc: errDc,
      phase: errPhase,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    });
  }
  return { decision: willReroll ? 'retry' : 'abort', errDc };
}

async function provision(sessionId: string, onStatus: (msg: string) => void): Promise<ProvisionResult> {
  return Sentry.startSpan(
    { name: 'pod.provision', op: 'pod.provision', attributes: { sessionId } },
    async (parentSpan) => {
      const t0 = Date.now();
      const blacklistedDcs = new Set<string>();
      const maxRerolls = Math.max(0, config.CONTAINER_PULL_MAX_REROLLS);

      for (let attempt = 0; attempt <= maxRerolls; attempt++) {
        let podId: string | null = null;
        let podType: PodType | null = null;
        let dc: string | null = null;
        let phase: ProvisionPhase = 'placement';
        const attemptStart = Date.now();
        let phaseStart = attemptStart;
        const phaseTimings: Record<string, number> = {};

        trackPodProvisionStarted({
          userId: sessionId,
          attempt,
          excludedDcs: Array.from(blacklistedDcs),
        });

        try {
          phase = 'pod_create';

          // 1 + 2. Create a pod — spot first, on-demand fallback if capacity exhausted
          const created = await Sentry.startSpan(
            { name: 'pod.create', op: 'pod.create', attributes: { sessionId, attempt } },
            () => createPodWithFallback(sessionId, onStatus, blacklistedDcs),
          );
          podId = created.podId;
          podType = created.podType;
          dc = created.dc;

          phaseTimings.pod_create_ms = Date.now() - phaseStart;
          phaseStart = Date.now();

          Sentry.addBreadcrumb({
            category: 'provision',
            level: 'info',
            message: 'Pod created',
            data: { podId, dc, podType, attempt, podCreateMs: phaseTimings.pod_create_ms },
          });

          // If any subsequent step fails, terminate the pod we just created to prevent
          // cost leaks. This matters especially for replaceSession() which calls
          // provision() directly without its own pod cleanup.
          try {
            // 3. Wait for the container to boot. In baked mode the image is slim (~2-3
            // GB) but the very first pull to a host in a DC can still take a few minutes.
            // Wall-clock window: image pull (dominant) + container start +
            // runtime registration. Internally `runtime_up` because that's
            // the gate (`pod.runtime` field becoming non-null); the
            // user-facing string emphasizes the dominant cost.
            phase = 'runtime_up';
            onStatus('Pulling container image...');
            notifyPodProgress(podId, '⏳ Pulling container image...');
            await Sentry.startSpan(
              { name: 'pod.runtime_up', op: 'pod.runtime_up', attributes: { podId, dc: dc ?? 'unknown', attempt } },
              () => waitForRuntime(podId as string, onStatus),
            );
            notifyPodProgress(podId, `📦 Container runtime up`);
            phaseTimings.runtime_up_ms = Date.now() - phaseStart;
            phaseStart = Date.now();

            // 4. Poll /health via RunPod proxy until the FLUX server reports ready
            phase = 'health_check';
            onStatus('Loading AI model & warming up...');
            notifyPodProgress(podId, '🧠 Loading AI model & warming up...');
            const healthUrl = `https://${podId}-8766.proxy.runpod.net/health`;
            await Sentry.startSpan(
              { name: 'pod.health_check', op: 'pod.health_check', attributes: { podId, dc: dc ?? 'unknown' } },
              () => waitForHealth(podId as string, healthUrl),
            );
            phaseTimings.health_check_ms = Date.now() - phaseStart;

            const totalMs = Date.now() - t0;

            // 5. Build WebSocket URL and return
            const podUrl = `wss://${podId}-8766.proxy.runpod.net/ws`;
            log.info(
              { sessionId, podId, podUrl, podType, totalMs, attempt, dc },
              'Pod ready',
            );
            onStatus('Ready');
            notifyPodProgress(podId, `✅ **Pod ready** (${Math.round(totalMs / 1000)}s total)`);

            parentSpan.setAttributes({
              dc: dc ?? 'unknown',
              podType,
              attempt,
              outcome: 'success',
            });
            trackPodProvisionCompleted({
              userId: sessionId,
              durationMs: Date.now() - attemptStart,
              dc,
              podType,
              attempt,
              phaseTimings,
            });
            return { podId, podUrl, podType };
          } catch (err) {
            // Pod was created but a later step failed — clean up to prevent cost leak.
            log.warn(
              { sessionId, podId, err: (err as Error).message, phase, attempt },
              'Provision failed after pod creation — terminating pod',
            );
            terminatePod(podId).catch((e) =>
              log.warn({ podId, err: (e as Error).message }, 'Failed to terminate pod after provision failure'),
            );
            throw err;
          }
        } catch (err) {
          // Recoverable classes (ImagePullStallError, PodVanishedError) come
          // from a flaky DC. The helper emits observability + decides whether
          // we have rerolls left; on retry, blacklist the DC and loop.
          const recovery = handleRecoverableProvisionError(err as Error, {
            sessionId,
            dc,
            podType,
            attempt,
            maxRerolls,
          });
          if (recovery.decision === 'retry') {
            if (recovery.errDc) blacklistedDcs.add(recovery.errDc);
            continue;
          }
          // Fall through: unrecoverable error, or rerolls exhausted.

          parentSpan.setAttributes({
            dc: dc ?? 'unknown',
            podType: podType ?? 'unknown',
            attempt,
            outcome: 'failure',
            phase,
          });

          Sentry.captureException(err, {
            tags: {
              dc: dc ?? 'unknown',
              podType: podType ?? 'unknown',
              phase,
              attempt: String(attempt),
              category: classifyProvisionError(err as Error),
            },
            contexts: {
              pod: {
                id: podId ?? 'none',
                sessionId,
                elapsedSec: Math.round((Date.now() - t0) / 1000),
              },
            },
          });
          trackPodProvisionFailed({
            userId: sessionId,
            durationMs: Date.now() - attemptStart,
            category: classifyProvisionError(err as Error),
            dc,
            phase,
            attempt,
          });
          throw err;
        }
      }

      // Unreachable — loop body either returns or throws. Kept for type-checker.
      throw new Error('provision: reroll loop exited without resolution');
    },
  );
}

/**
 * A candidate placement: which DC to pin the pod to, and optionally which
 * pre-populated network volume to attach. `null` for both means "let RunPod
 * pick any DC, no volume" — only hit when NETWORK_VOLUMES_BY_DC is empty
 * (e.g. local dev without volumes configured).
 */
interface PlacementTarget {
  dataCenterId: string | null;
  networkVolumeId: string | null;
  bidInfo: SpotBidInfo | null;
}

/**
 * With a configured NETWORK_VOLUMES_BY_DC, iterate through each volume DC and
 * query spot stock. Returns the first DC with Medium/High stock (with its
 * bid info), or the best-stock DC even if Low (so the caller can
 * still try spot before falling back to on-demand). Returns `null` only if
 * every DC returns a hard capacity miss.
 *
 * In non-baked mode or with no volumes configured, returns a single unpinned
 * target (DC = null) and lets RunPod pick.
 */
async function selectPlacement(
  sessionId: string,
  excludeDcs: ReadonlySet<string> = new Set(),
): Promise<PlacementTarget | null> {
  const volumes = config.NETWORK_VOLUMES_BY_DC;
  const volumeDcs = Object.keys(volumes).filter((dc) => !excludeDcs.has(dc));
  const useVolumes = volumeDcs.length > 0;

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
      excluded: Array.from(excludeDcs),
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
  excludeDcs: ReadonlySet<string> = new Set(),
): Promise<{ podId: string; podType: PodType; dc: string | null }> {
  const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;

  // GHCR image with deps baked in; weights come from the attached network
  // volume at /workspace/huggingface.
  const imageName = config.FLUX_IMAGE;
  const authId = config.RUNPOD_GHCR_AUTH_ID || undefined;

  // ─── Pick DC + volume ───────────────────────────────────────────────
  onStatus('Finding available GPU...');
  const target = await selectPlacement(sessionId, excludeDcs);
  if (!target) {
    const suffix = excludeDcs.size > 0
      ? ` (excluding ${Array.from(excludeDcs).join(',')} after earlier stall)`
      : '';
    throw new Error(`No RunPod DC has 5090 capacity right now (all volume-DCs exhausted)${suffix}`);
  }
  const bidInfo = target.bidInfo;
  const dcField = target.dataCenterId ? { dataCenterId: target.dataCenterId } : {};
  const volField = target.networkVolumeId ? { networkVolumeId: target.networkVolumeId } : {};

  // ─── Try spot ─────────────────────────────────────────────────────────
  let spotCapacityExhausted = false;
  let fallbackReason: string | null = null;

  if (config.ONDEMAND_ONLY_MODE) {
    // Operator has disabled spot for stability. Skip the spot attempt and
    // fall through to the on-demand path. Probe results from selectPlacement
    // (DC ranking) are still used; only the spot create call is bypassed.
    spotCapacityExhausted = true;
    fallbackReason = 'ondemand_only_mode';
    log.info(
      { sessionId, event: 'provision.spot.skipped', reason: fallbackReason, dc: target.dataCenterId },
      'Spot disabled by ONDEMAND_ONLY_MODE — going straight to on-demand',
    );
  } else if (!bidInfo) {
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
      return { podId, podType: 'spot', dc: target.dataCenterId };
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
  if (!config.ONDEMAND_FALLBACK_ENABLED && !config.ONDEMAND_ONLY_MODE) {
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
    return { podId, podType: 'onDemand', dc: target.dataCenterId };
  } catch (err) {
    log.error(
      { sessionId, event: 'provision.onDemand.failed', err: (err as Error).message, dc: target.dataCenterId },
      'On-demand fallback also failed',
    );
    throw err;
  }
}

/**
 * Polls the RunPod API until the pod's `runtime` field is non-null, meaning
 * the container image has been pulled and the container process is running.
 * Emits a status update when the transition happens so the user sees
 * "Pulling container image..." → "Starting server..." in real time.
 *
 * If `stallMs` is finite and `pod.runtime` stays null longer than that,
 * throws `ImagePullStallError` so the caller can reroll onto a different DC
 * instead of waiting out the full `timeoutMs`. Pass `Infinity` to disable
 * the watchdog and preserve the legacy binary-timeout behavior.
 */
async function waitForRuntime(
  podId: string,
  onStatus: (msg: string) => void,
  opts: { timeoutMs?: number; stallMs?: number } = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 10 * 60 * 1000;
  const stallMs = opts.stallMs
    ?? (config.CONTAINER_PULL_WATCHDOG_ENABLED ? config.CONTAINER_PULL_STALL_MS : Infinity);
  const start = Date.now();
  const deadline = start + timeoutMs;
  let lastUpdateAt = 0;
  let lastDc: string | null = null;
  onStatus('Pulling container image...');
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (!pod) {
      const elapsed = Math.round((Date.now() - start) / 1000);
      log.warn({ podId, elapsedSec: elapsed, dc: lastDc }, 'Pod vanished during runtime_up (spot preempted?)');
      throw new PodVanishedError(podId, lastDc, 'runtime_up', elapsed);
    }
    if (pod.machine?.dataCenterId) lastDc = pod.machine.dataCenterId;
    if (pod.runtime) {
      log.info({ podId, uptimeInSeconds: pod.runtime.uptimeInSeconds }, 'Container runtime up');
      onStatus('Starting server...');
      return;
    }
    const elapsedMs = Date.now() - start;
    if (elapsedMs > stallMs) {
      throw new ImagePullStallError(podId, lastDc, Math.round(elapsedMs / 1000));
    }
    // Send progress updates every 30s so the client knows we're still waiting.
    const now = Date.now();
    if (now - lastUpdateAt > 30_000) {
      const elapsed = Math.round(elapsedMs / 1000);
      log.info({ podId, elapsedSec: elapsed, dc: lastDc }, 'Still waiting for container runtime');
      onStatus(`Pulling container image... (${elapsed}s)`);
      lastUpdateAt = now;
    }
    await sleep(5000);
  }
  throw new Error(`Pod ${podId} runtime never appeared within ${Math.round(timeoutMs / 1000)}s`);
}

async function waitForHealth(
  podId: string,
  healthUrl: string,
  timeoutMs = 10 * 60 * 1000,
): Promise<void> {
  const start = Date.now();
  const deadline = start + timeoutMs;
  let lastLogAt = 0;
  let lastPodProbeAt = 0;
  let lastDc: string | null = null;
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
    const now = Date.now();
    // Probe RunPod every 30s to detect a vanished pod (preempted, host
    // failure). Fail fast instead of waiting out the full timeoutMs polling
    // a dead URL.
    if (now - lastPodProbeAt > 30_000) {
      const pod = await getPod(podId);
      if (!pod) {
        const elapsed = Math.round((now - start) / 1000);
        log.warn({ podId, elapsedSec: elapsed, dc: lastDc }, 'Pod vanished during health_check (spot preempted?)');
        throw new PodVanishedError(podId, lastDc, 'health_check', elapsed);
      }
      if (pod.machine?.dataCenterId) lastDc = pod.machine.dataCenterId;
      lastPodProbeAt = now;
    }
    if (now - lastLogAt > 30_000) {
      const elapsed = Math.round((now - start) / 1000);
      log.info({ healthUrl, elapsedSec: elapsed }, 'Still waiting for health check');
      lastLogAt = now;
    }
    await sleep(10_000);
  }
  throw new Error(`Server at ${healthUrl} never became healthy within ${timeoutMs}ms`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * Per-session pod lifecycle orchestration — public composition layer.
 *
 * This file owns the public entry points (getOrProvisionPod / replaceSession /
 * the video quartet / abortSession / start), the in-flight provision dedupe map,
 * and the concurrency semaphore. The machinery it composes lives in sibling
 * modules, each importing only downward:
 *   - sessionStore.ts : Redis session CRUD + `State` enum + idle-lifetime consts
 *   - podBoot.ts      : pod boot recipe (BASE_IMAGE / BOOT_* / bootEnvFor) + PodKind + prefixes
 *   - broker.ts       : subscribe / emitState — per-process state fan-out to WS clients
 *   - podDeath.ts     : markPodDead — the single pod-death tombstone chokepoint
 *   - provisioner.ts  : the provision state machine (POD_CONFIGS, selectPlacement,
 *                       createPodWithFallback, _runProvisionLoop, waitForRuntime/waitForHealth)
 *   - reaper.ts       : runReaper + reconcileOrphanPods — timer/boot-driven fleet hygiene
 *   - logger.ts       : shared `log` holder, installed once by start()
 *   - orchestrator.ts : THIS FILE — entry points + inFlightProvisions + semaphore + start + barrel
 *
 * ─── Pod Lifecycle Edge Cases ────────────────────────────────────────────
 *
 * Every scenario below MUST be handled. If you change provisioning, replacement,
 * or session logic, verify each case still works. Add new rows as we discover them.
 *
 * ┌─────────────────────────────────────┬──────────────────────────────────────────────────┬──────────────────────────────┐
 * │ Scenario                            │ What happens                                     │ Handling                     │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 1. Spot pod preempted (disappears)  │ Upstream WS closes with code 1006/1012.          │ stream.ts relay.onClose      │
 * │                                     │ RunPod deletes pod entirely.                     │ tries same-pod reconnect     │
 * │                                     │                                                  │ (fails fast — pod is gone),  │
 * │                                     │                                                  │ falls through to             │
 * │                                     │                                                  │ replaceSession which emits   │
 * │                                     │                                                  │ finding_gpu and provisions a │
 * │                                     │                                                  │ fresh pod.                   │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 2. Pod vanishes during provisioning │ Pod created on RunPod but disappears before      │ waitForRuntime / waitForHealth│
 * │    (spot preempted before serving)  │ becoming serve-ready. getPod() returns null.      │ throw PodVanishedError;       │
 * │                                     │                                                  │ provision()'s reroll loop     │
 * │                                     │                                                  │ blacklists the DC and retries.│
 * │                                     │                                                  │ Only after rerolls exhausted  │
 * │                                     │                                                  │ does abortSession fire.       │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 3. Pod errors during provisioning   │ Container pulls but the app crashes on startup   │ waitForHealth polls /health  │
 * │    (e.g. Python import error,       │ — /health never reaches 200, or supervisord       │ AND tracks runtime uptime    │
 * │    crashlooping container)          │ restarts the container repeatedly (uptime resets  │ across probes; uptime         │
 * │                                     │ every probe).                                    │ regression OR 4-min timeout  │
 * │                                     │                                                  │ both throw                    │
 * │                                     │                                                  │ PodBootStallError → reroll.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 4. User idle >30min on gallery      │ No WS connection → no touch() calls.             │ Reaper scans every 60s,      │
 * │                                     │ lastActivityAt goes stale.                       │ terminates pod if idle >30min.│
 * │                                     │                                                  │ Redis session deleted. Next   │
 * │                                     │                                                  │ startStream() provisions     │
 * │                                     │                                                  │ fresh.                       │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 5. User idle >30min on canvas       │ WS stays open but no frames sent (canvas         │ Same as #4 — touch() only    │
 * │    (not drawing)                    │ unchanged). No touch() calls from relay.          │ fires on relayed messages.   │
 * │                                     │                                                  │ Pod reaped. Next stroke →    │
 * │                                     │                                                  │ frame send fails → iOS       │
 * │                                     │                                                  │ reconnects → provisions new. │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 6. Railway redeploy during          │ Backend process dies. In-memory                  │ New process boots → reconcile │
 * │    provisioning                     │ inFlightProvisions map lost. Pod may still be    │ adopts or terminates orphans. │
 * │                                     │ provisioning on RunPod.                          │ iOS reconnects → session in  │
 * │                                     │                                                  │ any non-ready state without  │
 * │                                     │                                                  │ an in-flight promise is      │
 * │                                     │                                                  │ stale → deleted, fresh       │
 * │                                     │                                                  │ provision starts.            │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 7. iOS reconnect during replacement │ replaceSession is live; inFlightProvisions has  │ getOrProvisionPod sees the    │
 * │    (duplicate pod race)             │ the replacement promise.                         │ in-flight promise → joins    │
 * │                                     │                                                  │ it. Broker subscribe seeds   │
 * │                                     │                                                  │ joiner with current state.   │
 * │                                     │                                                  │ No duplicate pod created.    │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 8. Network glitch during drawing    │ WS momentarily drops. iOS receive loop ends      │ iOS attemptReconnect (3x     │
 * │                                     │ unexpectedly.                                    │ with exponential backoff).   │
 * │                                     │                                                  │ Backend pod stays alive      │
 * │                                     │                                                  │ (sessionClosed keeps it for  │
 * │                                     │                                                  │ reconnect within 30min).     │
 * │                                     │                                                  │ Reconnect reuses ready pod.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 9. App backgrounded then resumed    │ iOS stopStream() on background, restarts on      │ Pod stays alive up to 30min  │
 * │                                     │ foreground if streamWasActiveBeforeBackground.   │ (idle reaper). If resumed    │
 * │                                     │                                                  │ within window, reuses pod.   │
 * │                                     │                                                  │ If >30min, fresh provision.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 10. Pod boot stalls on a bad host   │ Pod created but runtime stays null. NFS mount    │ waitForRuntime throws        │
 * │     (stock image pull on fresh      │ delay or stock-image pull on a cold host —       │ PodBootStallError after      │
 * │     host, NFS mount hang).          │ pod.runtime stays null.                          │ POD_BOOT_STALL_MS (default   │
 * │                                     │                                                  │ 45s). provision() terminates │
 * │                                     │                                                  │ pod, blacklists the DC, and  │
 * │                                     │                                                  │ rerolls up to                │
 * │                                     │                                                  │ POD_BOOT_MAX_REROLLS.        │
 * │                                     │                                                  │ Sentry captures each stall.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 11. User signs out mid-provision    │ /v1/auth/signout fires while _runProvisionLoop is │ abortSession aborts the     │
 * │     (Round 6 leak fix)              │ creating a pod. Without cancellation, the loop   │ AbortController on each      │
 * │                                     │ would continue, stamp the row, and leak the pod  │ inFlightProvisions entry and │
 * │                                     │ until reconcile.                                 │ awaits settlement; the loop  │
 * │                                     │                                                  │ checks signal at 3 points    │
 * │                                     │                                                  │ (pre-create / post-create / │
 * │                                     │                                                  │ pre-stamp) and terminates    │
 * │                                     │                                                  │ any pod-in-flight inline.    │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 12. Pod terminated externally       │ Spot preemption, host failure, manual            │ Image kind's                 │
 * │     (Redis row points to dead pod)  │ termination — orchestrator never observes the    │ getReusableFromRow probes    │
 * │                                     │ kill, so the session row keeps claiming          │ RunPod (getPod) before       │
 * │                                     │ state=ready with the dead podId. Reconnect would │ trusting the row. Pod gone → │
 * │                                     │ reuse blindly and 404 on the WS upgrade.         │ returns null → existing      │
 * │                                     │                                                  │ deleteSession + fresh        │
 * │                                     │                                                  │ provision path runs.         │
 * └─────────────────────────────────────┴──────────────────────────────────────────────────┴──────────────────────────────┘
 *
 * The "Handling" column names functions; use the module map above to find the
 * file. Cross-file scenarios span modules — e.g. #11 (signout mid-provision):
 * abortSession (this file) aborts the controller → _runProvisionLoop's abort
 * checkpoints (provisioner.ts) terminate any in-flight pod → markPodDead
 * (podDeath.ts) tombstones it. The AbortSignal is the seam — passed into the
 * loop as a parameter, never shared mutable state.
 */

import { readFileSync } from 'node:fs';
import type { FastifyBaseLogger } from 'fastify';
import * as Sentry from '@sentry/node';

import { config } from '../../config/index.js';
import { getRedis, ensureRedis, setLogger as setRedisLogger } from '../redis/client.js';
import { terminatePod } from './runpodClient.js';
import { notifyPodProgress } from './costMonitor.js';
import { classifyProvisionError } from './errorClassification.js';
import { inBackgroundScope } from '../observability/scope.js';
import { log, setLogger } from './logger.js';
import {
  type PodType,
  isActiveProvisioning,
  IDLE_TIMEOUT_MS,
  IDLE_TTL_SECONDS,
  sessionKey,
  readSession,
  writeSession,
  patchSession,
  deleteSession,
} from './sessionStore.js';
import { emitState } from './broker.js';
import { markPodDead } from './podDeath.js';
import {
  provision,
  _runProvisionLoop,
  getReusableImagePod,
  getReusableVideoPod,
  BACKEND_FLUX_APP_VERSION,
} from './provisioner.js';
import { runReaper, reconcileOrphanPods, REAPER_INTERVAL_MS } from './reaper.js';
import {
  trackPodReplacementExhausted,
  trackPodTerminated,
} from '../analytics/index.js';

// ─── Public surface re-exports (symbols whose real home is a sibling module) ──
// Consumers (stream.ts, ops.ts) import these from orchestrator.js; grouped by
// home file so this block reads as a table-of-contents for the split.
export { subscribe, emitState, type StateEvent } from './broker.js';
export { markPodDead, type PodDeathReason } from './podDeath.js';
export { PodBootStallError } from './errorClassification.js';

// ────────────────────────────────────────────────────────────────────────────
// Module-scoped state
// ────────────────────────────────────────────────────────────────────────────

// Session registry lives in Redis (WS5). Local map only holds in-flight
// provision promises for same-process join (Promises can't be serialized).
// Keyed by `${kind}:${sessionId}` so image and video pods don't collide.
// Each entry pairs the rich-shape promise with an AbortController so
// `abortSession` can cancel the provision mid-flight (otherwise a signout
// during provisioning leaks the just-created pod — see Round 6 plan).
type InFlightEntry = {
  promise: Promise<{ podId: string; podUrl: string; podType: PodType; dc: string | null }>;
  controller: AbortController;
};
const inFlightProvisions = new Map<string, InFlightEntry>();


const MAX_CONCURRENT_PROVISIONS = Number(process.env['MAX_CONCURRENT_PROVISIONS'] ?? 5);


// Backend's commit SHA — kept for forensic context only (logged at startup,
// not used for drift comparison). Same fallback chain as before.
const BACKEND_GIT_SHA = (() => {
  const fromEnv = process.env['RAILWAY_GIT_COMMIT_SHA'];
  if (fromEnv) return fromEnv.trim();
  try {
    return readFileSync('/app/.git-sha', 'utf-8').trim();
  } catch {
    return '';
  }
})();


// Semaphore state
let activeProvisions = 0;
const semaphoreWaiters: Array<() => void> = [];

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
    // Cancel in-flight provisions FIRST (image and video may both be
    // running concurrently). The signal causes _runProvisionLoop to
    // terminate any just-created pod and reject; awaiting settlement
    // ensures no provision can stamp+leak a pod after we return.
    const settled: Promise<unknown>[] = [];
    for (const kind of ['image', 'video'] as const) {
      const entry = inFlightProvisions.get(`${kind}:${sessionId}`);
      if (entry) {
        log.info({ sessionId, kind, reason }, 'Aborting in-flight provision');
        entry.controller.abort('session aborted');
        settled.push(entry.promise.catch(() => {}));
      }
    }
    if (settled.length > 0) await Promise.all(settled);

    const session = await readSession(sessionId);
    if (session?.podId) {
      const lifetimeMs = session.createdAt > 0 ? Date.now() - session.createdAt : 0;
      trackPodTerminated({ userId: sessionId, reason, lifetimeMs });
      void markPodDead({
        podId: session.podId,
        podKind: 'image',
        userId: sessionId,
        lifetimeMs,
        reason: 'manual',
        note: `abortSession reason=${reason}`,
      });
      terminatePod(session.podId).catch((err) =>
        log.warn({ sessionId, podId: session.podId, err: (err as Error).message }, 'abortSession: terminatePod failed'),
      );
    }
    if (session?.videoPodId) {
      void markPodDead({
        podId: session.videoPodId,
        podKind: 'video',
        userId: sessionId,
        reason: 'manual',
        note: `abortSession reason=${reason}`,
      });
      terminatePod(session.videoPodId).catch((err) =>
        log.warn({ sessionId, videoPodId: session.videoPodId, err: (err as Error).message }, 'abortSession: terminate video pod failed'),
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

/**
 * Returns a healthy pod URL for the given session, provisioning one if needed.
 * If the same sessionId calls this concurrently while a provision is in flight,
 * both calls await the same promise — we don't create two pods.
 *
 * Session state is stored in Redis (survives deploys). In-flight provision
 * promises are kept in a local map for same-process join only. State transitions
 * during provision fan out to the broker; stream.ts subscribes to drive the
 * WebSocket status envelope.
 */
export async function getOrProvisionPod(
  sessionId: string,
  streamId?: string | null,
): Promise<{ podId: string; podUrl: string }> {
  // 1. Check Redis for existing session
  const existing = await readSession(sessionId);

  const reusable = existing ? await getReusableImagePod(existing) : null;
  if (reusable) {
    log.info({ sessionId, podId: reusable.podId }, 'Reusing existing session pod');
    return { podId: reusable.podId, podUrl: reusable.podUrl };
  }

  // 2. Check local in-flight map (same-process concurrent callers — fresh
  // provision OR replacement). Joiners subscribe via broker; here we just
  // await the same promise.
  const key = `image:${sessionId}`;
  const inFlight = inFlightProvisions.get(key);
  if (inFlight) {
    log.info({ sessionId }, 'Joining in-flight provision');
    return inFlight.promise.then((r) => ({ podId: r.podId, podUrl: r.podUrl }));
  }

  // 3. If Redis has a non-ready session but we don't own the promise
  // (post-restart, different replica, or orphaned), clean up and re-provision.
  if (existing) {
    log.warn({ sessionId, state: existing.state }, 'Stale session in Redis — re-provisioning');
    await deleteSession(sessionId);
  }

  // 4. Fresh provision — claim in Redis + start. Initial state is 'finding_gpu';
  // if we're about to wait on the semaphore we'll flip to 'queued' first.
  const now = Date.now();
  await writeSession({
    sessionId,
    podId: null,
    podUrl: null,
    podType: null,
    state: 'finding_gpu',
    stateEnteredAt: now,
    failureCategory: null,
    createdAt: now,
    lastActivityAt: now,
    replacementCount: 0,
    videoPodId: null,
  });

  let provisionedPodId: string | null = null;

  const controller = new AbortController();
  const promise = (async () => {
    try {
      if (isSemaphoreFull()) await emitState(sessionId, 'queued');
      await acquireSemaphore();
      try {
        await emitState(sessionId, 'finding_gpu');
        const result = await provision(sessionId, controller.signal, streamId);
        provisionedPodId = result.podId;
        return { podId: result.podId, podUrl: result.podUrl, podType: result.podType, dc: null };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      const elapsedMs = Date.now() - now;
      const category = classifyProvisionError(err as Error);
      log.error({ sessionId, err, category, elapsedMs }, 'Provision failed');
      if (provisionedPodId) {
        notifyPodProgress(provisionedPodId, `❌ **Failed:** ${(err as Error).message}`);
        void markPodDead({
          podId: provisionedPodId,
          podKind: 'image',
          userId: sessionId,
          lifetimeMs: elapsedMs,
          reason: 'provision_error',
          note: (err as Error).message,
        });
        terminatePod(provisionedPodId).catch((e) =>
          log.warn({ podId: provisionedPodId, err: e }, 'Failed to clean up pod after provision failure'),
        );
      }
      // provision() already emitted state='failed' to subscribers; delete the
      // Redis row now that downstream has been notified.
      await deleteSession(sessionId).catch(() => {});
      throw err;
    } finally {
      inFlightProvisions.delete(key);
    }
  })();

  inFlightProvisions.set(key, { promise, controller });
  return promise.then((r) => ({ podId: r.podId, podUrl: r.podUrl }));
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
 * Check if a user already has an in-flight or ready pod — used to skip
 * provision-frequency rate limiting + the fresh-provision codepath on
 * reconnect. "Active" includes all in-progress states (`queued` through
 * `warming_model`) plus `ready`: a user navigating away and back during cold
 * start is reconnecting to their existing in-flight pod, and the slow path
 * would burn an entry against their hourly cap and try to provision a second
 * pod we'd just have to throw away.
 */
export async function hasReadySession(sessionId: string): Promise<boolean> {
  const session = await readSession(sessionId);
  if (!session) return false;
  return session.state === 'ready' || isActiveProvisioning(session.state);
}

// ────────────────────────────────────────────────────────────────────────────
// Preemption handling (WS7)
// ────────────────────────────────────────────────────────────────────────────

/**
 * Replace a session's pod after preemption or crash. Holds the existing session
 * key in Redis, provisions a new pod, swaps podId/podUrl atomically.
 *
 * Returns the new podUrl. Throws if replacement fails or retry bound exceeded.
 */
export async function replaceSession(
  sessionId: string,
  streamId?: string | null,
): Promise<{ podId: string; podUrl: string }> {
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

  // Bump replacement count + clear old pod info. Then emit finding_gpu so any
  // current broker subscribers see the UI reset from 'ready' → 'finding_gpu'
  // (iOS will prefix "Replacing — " because replacementCount > 0).
  await patchSession(sessionId, {
    podId: null,
    podUrl: null,
    podType: null,
    lastActivityAt: Date.now(),
    replacementCount: attempt,
  });
  await emitState(sessionId, 'finding_gpu');

  // Clean up old pod (fire-and-forget — may already be gone)
  if (oldPodId) {
    void markPodDead({
      podId: oldPodId,
      podKind: 'image',
      userId: sessionId,
      reason: 'replaced',
      note: `attempt ${attempt}`,
    });
    terminatePod(oldPodId).catch((e) =>
      log.warn(
        { sessionId, oldPodId, err: (e as Error).message },
        'Failed to terminate old pod during replacement — will be reaped',
      ),
    );
  }

  const t0 = Date.now();
  let newPodId: string | null = null;
  const key = `image:${sessionId}`;
  const controller = new AbortController();
  const replacementPromise = (async () => {
    try {
      if (isSemaphoreFull()) await emitState(sessionId, 'queued');
      await acquireSemaphore();
      try {
        await emitState(sessionId, 'finding_gpu');
        const result = await provision(sessionId, controller.signal, streamId);
        newPodId = result.podId;
        const replacementMs = Date.now() - t0;
        log.info({ sessionId, oldPodId, newPodId: result.podId, replacementMs, attempt }, 'Session replaced');
        return { podId: result.podId, podUrl: result.podUrl, podType: result.podType, dc: null };
      } finally {
        releaseSemaphore();
      }
    } catch (err) {
      log.error({ sessionId, attempt, err }, 'Session replacement failed');
      Sentry.captureException(err, {
        user: { id: sessionId },
        tags: { sessionId, attempt: String(attempt), phase: 'session_replacement' },
      });
      if (newPodId) {
        void markPodDead({
          podId: newPodId,
          podKind: 'image',
          userId: sessionId,
          reason: 'provision_error',
          note: `replacement attempt ${attempt} failed`,
        });
        terminatePod(newPodId).catch((e) => {
          log.warn({ sessionId, newPodId, err: (e as Error).message }, 'Failed to clean up replacement pod');
          Sentry.captureException(e, {
            user: { id: sessionId },
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
          user: { id: sessionId },
          tags: { sessionId, phase: 'replacement_session_cleanup' },
        });
      });
      throw err;
    } finally {
      inFlightProvisions.delete(key);
    }
  })();

  // Register in inFlight so concurrent getOrProvisionPod calls join this
  // replacement instead of starting a duplicate.
  inFlightProvisions.set(key, { promise: replacementPromise, controller });
  return replacementPromise.then((r) => ({ podId: r.podId, podUrl: r.podUrl }));
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
  setLogger(logger);
  setRedisLogger(logger);
  await ensureRedis();
  // Boot-time reconcile is aggressive (no age gate) — we just restarted so
  // anything not in Redis is genuinely orphaned.
  await inBackgroundScope('reconcile_boot', () => reconcileOrphanPods(0));
  // Wrap periodic timers in `inBackgroundScope` so their logs (a) don't
  // inherit ambient `Sentry.setUser` state from any request scope and
  // (b) carry `background_task: <name>` for filtering. See
  // `modules/observability/scope.ts` for context.
  setInterval(
    () => void inBackgroundScope('reaper', () => runReaper()),
    REAPER_INTERVAL_MS,
  );
  setInterval(
    () => void inBackgroundScope('reconcile', () =>
      reconcileOrphanPods(config.RECONCILE_MIN_AGE_SEC),
    ),
    config.RECONCILE_INTERVAL_MS,
  );
  log.info(
    {
      idleTimeoutMs: IDLE_TIMEOUT_MS,
      maxConcurrent: MAX_CONCURRENT_PROVISIONS,
      reconcileIntervalMs: config.RECONCILE_INTERVAL_MS,
      reconcileMinAgeSec: config.RECONCILE_MIN_AGE_SEC,
      backendFluxVersion: BACKEND_FLUX_APP_VERSION ? BACKEND_FLUX_APP_VERSION.slice(0, 8) : '(unset — drift checks disabled)',
      backendGitSha: BACKEND_GIT_SHA ? BACKEND_GIT_SHA.slice(0, 8) : '(unset)',
    },
    'Orchestrator started',
  );
}

// ────────────────────────────────────────────────────────────────────────────
// Semaphore
// ────────────────────────────────────────────────────────────────────────────

function isSemaphoreFull(): boolean {
  return activeProvisions >= MAX_CONCURRENT_PROVISIONS;
}

async function acquireSemaphore(): Promise<void> {
  if (activeProvisions < MAX_CONCURRENT_PROVISIONS) {
    activeProvisions++;
    return;
  }
  const queuedAt = Date.now();
  const queueDepth = semaphoreWaiters.length + 1;
  log.info({ active: activeProvisions, cap: MAX_CONCURRENT_PROVISIONS, queueDepth }, 'Provision queued');
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
// Pod death tombstone — single chokepoint
// ────────────────────────────────────────────────────────────────────────────


// ────────────────────────────────────────────────────────────────────────────
// Video pod public entry points. Both call into the unified machinery
// (`_runProvisionLoop('video', …)` in provisioner.ts). The only video-specific
// concerns here are: (a) best-effort contract — return null on any failure,
// image session continues; (b) co-locate with image's DC; (c) join
// concurrent in-flight provisions (covers a quick iPad reconnect during
// the LTXV warmup window).
// ────────────────────────────────────────────────────────────────────────────

/** Kick off (or reuse) a video provision in the inFlight map. Stores the
 *  rich-shape promise from _runProvisionLoop, returns the narrower
 *  best-effort {podId, podUrl}|null. Used by both fresh provision
 *  (getOrProvisionVideoPod) and replacement (replaceVideoSession).
 *
 *  Note: pre-LTX-2.3 we passed `preferredDc=imagePodDc` here to co-locate
 *  the video pod with the image pod's DC. Post-migration, image and video
 *  use disjoint GPU SKUs (5090 vs H100 SXM) which RunPod allocates to
 *  disjoint DCs — co-location can never succeed. The forwarded video_request
 *  payload is one JPEG (~200 KB) over RunPod's backbone (~50 ms cross-DC),
 *  acceptable. */
async function _runVideoProvision(
  sessionId: string,
  streamId?: string | null,
): Promise<{ podId: string; podUrl: string } | null> {
  const key = `video:${sessionId}`;
  const controller = new AbortController();
  const promise = (async () => {
    try {
      return await _runProvisionLoop('video', sessionId, { signal: controller.signal, streamId });
    } finally {
      inFlightProvisions.delete(key);
    }
  })();
  inFlightProvisions.set(key, { promise, controller });
  try {
    const r = await promise;
    return { podId: r.podId, podUrl: r.podUrl };
  } catch (err) {
    log.warn(
      { sessionId, err: (err as Error).message, pod_kind: 'video' },
      'video provision failed; session is image-only',
    );
    return null;
  }
}

/**
 * Get-or-provision the video pod for a session.
 *
 * Returns null on failure (best-effort — image session keeps going). On
 * success returns { podId, podUrl } for stream.ts to wire its relay.
 *
 * Reuse path: probes RunPod via getReusableVideoPod (provisioner.ts).
 * If pod is RUNNING+runtime, reuse. If RUNNING-but-still-booting AND we
 * own the in-flight promise, join it. Otherwise (gone, mid-boot on a
 * different replica, or no prior pod) fall through to a fresh provision.
 */
export async function getOrProvisionVideoPod(
  sessionId: string,
  streamId?: string | null,
): Promise<{ podId: string; podUrl: string } | null> {
  const existing = await readSession(sessionId);

  // ── Reuse path: ready pod (RUNNING+runtime). ───────────────────────
  if (existing) {
    const reusable = await getReusableVideoPod(existing);
    if (reusable) {
      log.info(
        { sessionId, videoPodId: reusable.podId, pod_kind: 'video', event: '[provision/video] reused' },
        '[provision/video] reusing existing pod (no cold start)',
      );
      return reusable;
    }
  }

  // ── In-flight join: another concurrent caller is already provisioning. ──
  // (Catches both "row has videoPodId, mid-boot on this instance" and
  // "no row stamp yet, but provision started microseconds ago".)
  const inFlight = inFlightProvisions.get(`video:${sessionId}`);
  if (inFlight) {
    log.info(
      { sessionId, pod_kind: 'video', event: '[provision/video] joined in-flight' },
      '[provision/video] joining in-flight provision',
    );
    try {
      const r = await inFlight.promise;
      return { podId: r.podId, podUrl: r.podUrl };
    } catch {
      return null;
    }
  }

  // ── Stale row stamp: pod gone or owned by a different replica. ────
  if (existing?.videoPodId) {
    log.info(
      { sessionId, videoPodId: existing.videoPodId, pod_kind: 'video', event: '[provision/video] stale id' },
      '[provision/video] stashed videoPodId is stale; reprovisioning',
    );
    await clearVideoPod(sessionId).catch(() => {});
  }

  // ── Fresh provision. ──────────────────────────────────────────────
  return _runVideoProvision(sessionId, streamId);
}

/**
 * Replace a session's video pod after it dies mid-session. Mirror of
 * `replaceSession` for the video kind: terminate the old video pod,
 * reprovision via the shared loop, return the new pod info or null on
 * failure. Called by stream.ts's `handleVideoUpstreamClose` after a
 * same-pod reconnect attempt fails (i.e., the pod is truly gone, not
 * just a transient WS drop).
 *
 * Best-effort contract: returns null on any failure. No `replacementCount`
 * bump — that budget is for image (where exhaustion bounces the iPad);
 * video replacement just falls back to image-only on giveup.
 */
export async function replaceVideoSession(
  sessionId: string,
  streamId?: string | null,
): Promise<{ podId: string; podUrl: string } | null> {
  const session = await readSession(sessionId);
  if (!session) {
    log.warn({ sessionId }, 'replaceVideoSession: no session to replace');
    return null;
  }
  log.info(
    { sessionId, oldPodId: session.videoPodId, pod_kind: 'video' },
    'Starting video session replacement',
  );

  // Clear old pod ref + terminate (fire-and-forget).
  await clearVideoPod(sessionId).catch(() => {});
  if (session.videoPodId) {
    void markPodDead({
      podId: session.videoPodId,
      podKind: 'video',
      userId: sessionId,
      reason: 'replaced',
    });
    terminatePod(session.videoPodId).catch((e) =>
      log.warn(
        { sessionId, oldPodId: session.videoPodId, err: (e as Error).message },
        'replaceVideoSession: terminate old pod failed (reaper will clean)',
      ),
    );
  }

  return _runVideoProvision(sessionId, streamId);
}

/** Terminate a video pod by ID. Never throws. Used by stream.ts on relay
 *  wire failure. */
export async function terminateVideoPod(podId: string): Promise<void> {
  try {
    await terminatePod(podId);
    log.info({ podId, pod_kind: 'video', event: '[provision/video] terminated' }, '[provision/video] terminated');
  } catch (err) {
    log.warn(
      { podId, err: (err as Error).message, pod_kind: 'video' },
      '[provision/video] terminate failed (will be cleaned by reconcile)',
    );
  }
}

/** Clear videoPodId on session row. Never throws. Used by stream.ts on
 *  relay wire failure to ensure the next reconnect provisions fresh. */
export async function clearVideoPod(sessionId: string): Promise<void> {
  try {
    await patchSession(sessionId, { videoPodId: null });
  } catch (err) {
    log.warn(
      { sessionId, err: (err as Error).message },
      'clearVideoPod patchSession failed',
    );
  }
}

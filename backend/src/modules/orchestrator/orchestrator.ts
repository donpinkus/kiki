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
 * │                                     │                                                  │ reconnect within 10min).     │
 * │                                     │                                                  │ Reconnect reuses ready pod.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 9. App backgrounded then resumed    │ iOS stopStream() on background, restarts on      │ Pod stays alive up to 10min  │
 * │                                     │ foreground if streamWasActiveBeforeBackground.   │ (idle reaper). If resumed    │
 * │                                     │                                                  │ within window, reuses pod.   │
 * │                                     │                                                  │ If >10min, fresh provision.  │
 * ├─────────────────────────────────────┼──────────────────────────────────────────────────┼──────────────────────────────┤
 * │ 10. Pod boot stalls on a bad host   │ Pod created but runtime stays null. NFS mount    │ waitForRuntime throws        │
 * │     (stock image pull on fresh      │ delay or stock-image pull on a cold host —       │ PodBootStallError after      │
 * │     host, NFS mount hang).          │ pod.runtime stays null.                          │ POD_BOOT_STALL_MS (default   │
 * │                                     │                                                  │ 45s). provision() terminates │
 * │                                     │                                                  │ pod, blacklists the DC, and  │
 * │                                     │                                                  │ rerolls up to                │
 * │                                     │                                                  │ POD_BOOT_MAX_REROLLS.        │
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
import { PodBootStallError, PodVanishedError, classifyProvisionError, type FailureCategory } from './errorClassification.js';
import {
  trackPodProvisionStarted,
  trackPodProvisionCompleted,
  trackPodProvisionFailed,
  trackPodProvisionStalled,
  trackPodProvisionVanished,
  trackPodReplacementExhausted,
  trackPodStateEntered,
  trackPodTerminated,
} from '../analytics/index.js';

export { PodBootStallError } from './errorClassification.js';

// ────────────────────────────────────────────────────────────────────────────
// Types
// ────────────────────────────────────────────────────────────────────────────

/**
 * Single flat state enum for a session's provisioning lifecycle. Replaces the
 * old `SessionStatus` + internal `ProvisionPhase` duo. iOS maps state codes to
 * display text; backend only tracks structured state.
 *
 * Active (in-progress) states: 'queued' through 'warming_model'.
 * Terminal states: 'ready' (pod serving), 'failed', 'terminated'.
 */
export type State =
  | 'queued'          // semaphore-held (too many concurrent provisions in process)
  | 'finding_gpu'     // selectPlacement: probing DCs for spot stock
  | 'creating_pod'    // createSpotPod / createOnDemandPod RPC
  | 'fetching_image'  // pod exists; waiting for pod.runtime (GHCR image pull)
  | 'warming_model'   // container running; polling /health while model loads
  | 'connecting'      // pod /health ok; backend wiring the iOS↔pod frame relay
  | 'ready'           // relay live; iOS can stream
  | 'failed'          // unrecoverable error; WS closes after
  | 'terminated';     // session ended (reaped / aborted / replaced out)

const ACTIVE_PROVISION_STATES: readonly State[] = [
  'queued', 'finding_gpu', 'creating_pod', 'fetching_image', 'warming_model', 'connecting',
] as const;

export function isActiveProvisioning(state: State): boolean {
  return (ACTIVE_PROVISION_STATES as readonly string[]).includes(state);
}

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

// ─── Pod boot configuration ─────────────────────────────────────────────
// We launch pods from stock `runpod/pytorch` and bootstrap the FLUX server
// from files on the attached network volume. See scripts/sync-flux-app.ts
// for how the volume gets populated, and documents/decisions.md entry
// 2026-04-23 for the full context + rollback procedure.
const BASE_IMAGE = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
// `bash -lc` sources /etc/profile.d/* for CUDA paths; activate the volume
// venv (inherits base-image torch via --system-site-packages); exec Python
// so SIGTERM reaches uvicorn directly.
const BOOT_DOCKER_ARGS =
  "bash -lc 'source /workspace/venv/bin/activate && cd /workspace/app && exec python3 -u server.py'";
const BOOT_ENV: Array<{ key: string; value: string }> = [
  { key: 'HF_HOME', value: '/workspace/huggingface' },
  { key: 'HF_HUB_OFFLINE', value: '1' },
  { key: 'FLUX_HOST', value: '0.0.0.0' },
  { key: 'FLUX_PORT', value: '8766' },
  { key: 'FLUX_USE_NVFP4', value: '1' },
];

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
  state: State;
  stateEnteredAt: number;       // ms epoch — updated on every state transition
  failureCategory: FailureCategory | null;  // only non-null when state === 'failed'
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
  const rawState = data['state'];
  // Guard against legacy rows written by the pre-refactor backend (`status` field).
  // Reconcile / reaper will clean these up; meanwhile treat them as non-existent.
  if (!rawState) return null;
  return {
    sessionId: data['sessionId']!,
    podId: data['podId'] || null,
    podUrl: data['podUrl'] || null,
    podType: (data['podType'] as PodType) || null,
    state: rawState as State,
    stateEnteredAt: Number(data['stateEnteredAt'] ?? 0),
    failureCategory: (data['failureCategory'] as FailureCategory) || null,
    createdAt: Number(data['createdAt'] ?? 0),
    lastActivityAt: Number(data['lastActivityAt'] ?? 0),
    replacementCount: Number(data['replacementCount'] ?? 0),
  };
}

async function writeSession(session: RedisSession): Promise<void> {
  const key = sessionKey(session.sessionId);
  const fields: Record<string, string> = {
    sessionId: session.sessionId,
    state: session.state,
    stateEnteredAt: String(session.stateEnteredAt),
    createdAt: String(session.createdAt),
    lastActivityAt: String(session.lastActivityAt),
  };
  if (session.podId) fields['podId'] = session.podId;
  if (session.podUrl) fields['podUrl'] = session.podUrl;
  if (session.podType) fields['podType'] = session.podType;
  if (session.failureCategory) fields['failureCategory'] = session.failureCategory;
  if (session.replacementCount > 0) fields['replacementCount'] = String(session.replacementCount);
  await getRedis().multi()
    .hset(key, fields)
    .expire(key, IDLE_TTL_SECONDS)
    .exec();
}

/**
 * Partial update — only writes the fields in `patch`, refreshes TTL.
 * Safer than `writeSession` for transitions because it never risks clobbering
 * a field the caller didn't intend to set.
 */
async function patchSession(
  sessionId: string,
  patch: Partial<Pick<
    RedisSession,
    'state' | 'stateEnteredAt' | 'failureCategory' | 'podId' | 'podUrl' | 'podType' | 'lastActivityAt' | 'replacementCount'
  >>,
): Promise<void> {
  const key = sessionKey(sessionId);
  const fields: Record<string, string> = {};
  if (patch.state !== undefined) fields['state'] = patch.state;
  if (patch.stateEnteredAt !== undefined) fields['stateEnteredAt'] = String(patch.stateEnteredAt);
  if (patch.failureCategory !== undefined) fields['failureCategory'] = patch.failureCategory ?? '';
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

// ────────────────────────────────────────────────────────────────────────────
// Broker — per-process fan-out of state transitions to WS subscribers
// ────────────────────────────────────────────────────────────────────────────
//
// Redis is the source of truth for session state (durable, survives deploys).
// The broker is just the efficient-push layer: when a provision transitions
// from one state to the next, every iOS WS currently subscribed to that
// sessionId gets the event in real time. No in-memory state cache — on
// subscribe, the handler is seeded with the current Redis state so joiners
// see whatever phase is active right now, then receives every future emit.

export interface StateEvent {
  state: State;
  stateEnteredAt: number;
  replacementCount: number;
  failureCategory: FailureCategory | null;
}

type StateHandler = (event: StateEvent) => void;

const subscribers = new Map<string, Set<StateHandler>>();

/**
 * Subscribe a handler to a session's state events. Immediately invokes the
 * handler with the current Redis state (if any) so joiners see their current
 * phase synchronously. Returns an unsubscribe function — call it when the
 * client disconnects or the provision settles.
 */
export async function subscribe(
  sessionId: string,
  handler: StateHandler,
): Promise<() => void> {
  const existing = subscribers.get(sessionId);
  const set = existing ?? new Set<StateHandler>();
  set.add(handler);
  if (!existing) subscribers.set(sessionId, set);

  // Seed with current state (if session exists) so joiner sees where we are.
  const session = await readSession(sessionId);
  if (session) {
    handler({
      state: session.state,
      stateEnteredAt: session.stateEnteredAt,
      replacementCount: session.replacementCount,
      failureCategory: session.failureCategory,
    });
  }

  return () => {
    const s = subscribers.get(sessionId);
    if (!s) return;
    s.delete(handler);
    if (s.size === 0) subscribers.delete(sessionId);
  };
}

/**
 * Write a state transition to Redis and fan out to every subscriber.
 * Exported so stream.ts can emit `connecting` / `ready` after the frame
 * relay is wired up (those emits can't happen inside provision() because
 * provision doesn't own the relay).
 */
export async function emitState(
  sessionId: string,
  state: State,
  failureCategory: FailureCategory | null = null,
): Promise<void> {
  const now = Date.now();

  // Read the *current* (soon-to-be-previous) state so we can attach its
  // duration to the outgoing PostHog event. This turns per-state duration
  // analytics into a one-line query: AVG(previous_state_duration_ms) WHERE
  // previous_state = 'X'. The alternative (post-hoc LEAD() in HogQL) works
  // but costs a self-join on every dashboard.
  const prevSession = await readSession(sessionId);
  const previousState = prevSession?.state ?? null;
  const previousStateDurationMs = prevSession?.stateEnteredAt
    ? now - prevSession.stateEnteredAt
    : null;
  const replacementCount = prevSession?.replacementCount ?? 0;

  await patchSession(sessionId, { state, stateEnteredAt: now, failureCategory });

  const event: StateEvent = {
    state,
    stateEnteredAt: now,
    replacementCount,
    failureCategory,
  };

  // Fan out to in-process subscribers (iOS WebSocket handlers in stream.ts).
  subscribers.get(sessionId)?.forEach((h) => {
    try { h(event); } catch (err) {
      log.warn({ sessionId, err: (err as Error).message }, 'State subscriber threw');
    }
  });

  // Sentry breadcrumb for error-trace context + PostHog event for funnel analytics.
  Sentry.addBreadcrumb({
    category: 'provision',
    level: 'info',
    message: `state → ${state}`,
    data: { sessionId, state, previousState, previousStateDurationMs, replacementCount, failureCategory },
  });
  trackPodStateEntered({
    userId: sessionId,
    state,
    stateEnteredAt: now,
    previousState,
    previousStateDurationMs,
    replacementCount,
    failureCategory,
  });
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
export async function getOrProvisionPod(sessionId: string): Promise<{ podUrl: string }> {
  // 1. Check Redis for existing session
  const existing = await readSession(sessionId);

  if (existing?.state === 'ready' && existing.podUrl) {
    log.info({ sessionId, podId: existing.podId }, 'Reusing existing session pod');
    return { podUrl: existing.podUrl };
  }

  // 2. Check local in-flight map (same-process concurrent callers — fresh
  // provision OR replacement). Joiners subscribe via broker; here we just
  // await the same promise.
  const inFlight = inFlightProvisions.get(sessionId);
  if (inFlight) {
    log.info({ sessionId }, 'Joining in-flight provision');
    return inFlight;
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
  });

  let provisionedPodId: string | null = null;

  const promise = (async () => {
    try {
      if (isSemaphoreFull()) await emitState(sessionId, 'queued');
      await acquireSemaphore();
      try {
        await emitState(sessionId, 'finding_gpu');
        const result = await provision(sessionId);
        provisionedPodId = result.podId;
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
      // provision() already emitted state='failed' to subscribers; delete the
      // Redis row now that downstream has been notified.
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
 * reconnect. "Active" includes all in-progress states (`queued` through
 * `warming_model`) plus `ready`: a user navigating away and back during cold
 * start is reconnecting to their existing in-flight pod, not creating a new
 * one. Treating this as a fresh provision triggers spurious
 * `too_many_active_pods` rejections.
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
export async function replaceSession(sessionId: string): Promise<{ podUrl: string }> {
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
    terminatePod(oldPodId).catch((e) =>
      log.warn(
        { sessionId, oldPodId, err: (e as Error).message },
        'Failed to terminate old pod during replacement — will be reaped',
      ),
    );
  }

  const t0 = Date.now();
  let newPodId: string | null = null;
  const replacementPromise = (async () => {
    try {
      if (isSemaphoreFull()) await emitState(sessionId, 'queued');
      await acquireSemaphore();
      try {
        await emitState(sessionId, 'finding_gpu');
        const result = await provision(sessionId);
        newPodId = result.podId;
        const replacementMs = Date.now() - t0;
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
    } finally {
      inFlightProvisions.delete(sessionId);
    }
  })();

  // Register in inFlight so concurrent getOrProvisionPod calls join this
  // replacement instead of starting a duplicate.
  inFlightProvisions.set(sessionId, replacementPromise);
  return replacementPromise;
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
// Reaper + reconcile
// ────────────────────────────────────────────────────────────────────────────

async function runReaper(): Promise<void> {
  const now = Date.now();
  const redis = getRedis();
  for await (const key of eachSessionKey()) {
    try {
      const data = await redis.hgetall(key);
      const state = data['state'];
      if (!data['sessionId'] || !data['podId']) continue;
      if (state !== 'ready') continue; // skip in-progress and terminal states
      const lastActivity = Number(data['lastActivityAt'] ?? 0);
      const idleMs = now - lastActivity;
      if (idleMs <= IDLE_TIMEOUT_MS) continue;

      // Atomic: only reap if state is still 'ready' (prevents two reapers
      // both reaping the same session across replicas).
      const claimed = await redis.multi()
        .hget(key, 'state')
        .hset(key, 'state', 'terminated')
        .exec();
      const prevState = claimed?.[0]?.[1];
      if (prevState !== 'ready') continue; // another reaper got it

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
      const state = data['state'];
      if (data['podId'] && state === 'ready') {
        sessionPodIds.add(data['podId']);
      } else if (state && isActiveProvisioning(state as State)) {
        // Stale in-progress row (no live promise to resume). Clean up.
        staleKeys.push(key);
      } else if (!state) {
        // Legacy row from pre-refactor backend (had `status` field instead);
        // treat as stale and clean up.
        staleKeys.push(key);
      }
    }

    // Clean up stale in-progress rows
    for (const key of staleKeys) {
      log.warn({ key }, 'Reconcile: deleting stale in-progress session');
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

/**
 * Classify a provision-attempt error as "recoverable by DC reroll" or not, and
 * emit the structured observability signals (log + Sentry breadcrumb + PostHog
 * event) for the recoverable class. `PodBootStallError` and `PodVanishedError`
 * are the two recoverable classes — both point at a flaky DC and are handled
 * identically except for the event names and the state attribute.
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
  if (!(err instanceof PodBootStallError) && !(err instanceof PodVanishedError)) {
    return { decision: 'abort', errDc: null };
  }
  const errDc = err.dc ?? ctx.dc;
  const willReroll = ctx.attempt < ctx.maxRerolls;
  const isStall = err instanceof PodBootStallError;
  const errState: State = isStall ? 'fetching_image' : err.state;
  const message = isStall ? 'Image pull stalled' : 'Pod vanished during provisioning';

  log.warn(
    {
      sessionId: ctx.sessionId,
      event: isStall ? 'provision.pull.stall_detected' : 'provision.pod.vanished',
      podId: err.podId,
      dc: errDc,
      state: errState,
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
      state: errState,
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
      state: errState,
      elapsedSec: err.elapsedSec,
      attempt: ctx.attempt,
      willReroll,
    });
  }
  return { decision: willReroll ? 'retry' : 'abort', errDc };
}

async function provision(sessionId: string): Promise<ProvisionResult> {
  return Sentry.startSpan(
    { name: 'pod.provision', op: 'pod.provision', attributes: { sessionId } },
    async (parentSpan) => {
      const t0 = Date.now();
      const blacklistedDcs = new Set<string>();
      const maxRerolls = Math.max(0, config.POD_BOOT_MAX_REROLLS);

      for (let attempt = 0; attempt <= maxRerolls; attempt++) {
        let podId: string | null = null;
        let podType: PodType | null = null;
        let dc: string | null = null;
        // `currentState` tracks the last state we emitted, used for error-path
        // analytics tagging. Starts at 'finding_gpu' because caller set that.
        let currentState: State = 'finding_gpu';
        const attemptStart = Date.now();
        let phaseStart = attemptStart;
        const phaseTimings: Record<string, number> = {};

        // On reroll (attempt > 0), we need to return the UI to 'finding_gpu'
        // before the next pod create attempt. Idempotent on first iteration.
        if (attempt > 0) {
          await emitState(sessionId, 'finding_gpu');
          currentState = 'finding_gpu';
        }

        trackPodProvisionStarted({
          userId: sessionId,
          attempt,
          excludedDcs: Array.from(blacklistedDcs),
        });

        try {
          // 1 + 2. Create a pod — spot first, on-demand fallback if capacity exhausted.
          // `createPodWithFallback` emits 'creating_pod' right before the create RPC.
          const created = await Sentry.startSpan(
            { name: 'pod.create', op: 'pod.create', attributes: { sessionId, attempt } },
            () => createPodWithFallback(sessionId, blacklistedDcs),
          );
          podId = created.podId;
          podType = created.podType;
          dc = created.dc;
          currentState = 'creating_pod';

          phaseTimings.creating_pod_ms = Date.now() - phaseStart;
          phaseStart = Date.now();

          Sentry.addBreadcrumb({
            category: 'provision',
            level: 'info',
            message: 'Pod created',
            data: { podId, dc, podType, attempt, creatingPodMs: phaseTimings.creating_pod_ms },
          });

          // If any subsequent step fails, terminate the pod we just created to prevent
          // cost leaks. This matters especially for replaceSession() which calls
          // provision() directly without its own pod cleanup.
          try {
            // 3. Wait for container to boot. Dominated by GHCR image pull (~60-90s).
            await emitState(sessionId, 'fetching_image');
            currentState = 'fetching_image';
            notifyPodProgress(podId, '⏳ Fetching container image...');
            await Sentry.startSpan(
              { name: 'pod.fetching_image', op: 'pod.fetching_image', attributes: { podId, dc: dc ?? 'unknown', attempt } },
              () => waitForRuntime(podId as string),
            );
            notifyPodProgress(podId, `📦 Container runtime up`);
            phaseTimings.fetching_image_ms = Date.now() - phaseStart;
            phaseStart = Date.now();

            // 4. Poll /health via RunPod proxy until the FLUX server reports ready
            await emitState(sessionId, 'warming_model');
            currentState = 'warming_model';
            notifyPodProgress(podId, '🧠 Warming up AI model...');
            const healthUrl = `https://${podId}-8766.proxy.runpod.net/health`;
            await Sentry.startSpan(
              { name: 'pod.warming_model', op: 'pod.warming_model', attributes: { podId, dc: dc ?? 'unknown' } },
              () => waitForHealth(podId as string, healthUrl),
            );
            phaseTimings.warming_model_ms = Date.now() - phaseStart;

            const totalMs = Date.now() - t0;

            // 5. Pod is serving. Persist pod info and return — stream.ts will
            // emit 'connecting' / 'ready' once it wires up the iOS↔pod relay.
            // Keeping the 'ready' emit out of provision() prevents a window
            // where iOS sees 'ready' but the backend's relay isn't yet set up
            // to forward its frames to the pod.
            const podUrl = `wss://${podId}-8766.proxy.runpod.net/ws`;
            await patchSession(sessionId, { podId, podUrl, podType });
            log.info(
              { sessionId, podId, podUrl, podType, totalMs, attempt, dc },
              'Pod serving — awaiting relay',
            );
            notifyPodProgress(podId, `✅ **Pod serving** (${Math.round(totalMs / 1000)}s total)`);

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
              { sessionId, podId, err: (err as Error).message, state: currentState, attempt },
              'Provision failed after pod creation — terminating pod',
            );
            terminatePod(podId).catch((e) =>
              log.warn({ podId, err: (e as Error).message }, 'Failed to terminate pod after provision failure'),
            );
            throw err;
          }
        } catch (err) {
          // Recoverable classes (PodBootStallError, PodVanishedError) come
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
            state: currentState,
          });

          const category = classifyProvisionError(err as Error);
          Sentry.captureException(err, {
            tags: {
              dc: dc ?? 'unknown',
              podType: podType ?? 'unknown',
              state: currentState,
              attempt: String(attempt),
              category,
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
            category,
            dc,
            state: currentState,
            attempt,
          });
          // Transition to terminal failed state so subscribers see the final event.
          await emitState(sessionId, 'failed', category);
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
  excludeDcs: ReadonlySet<string> = new Set(),
): Promise<{ podId: string; podType: PodType; dc: string | null }> {
  const podName = `${POD_PREFIX}${sessionId.slice(0, 16)}`;

  // Volume-entrypoint mode: stock RunPod pytorch image + our code/deps from
  // the attached network volume. See BASE_IMAGE / BOOT_DOCKER_ARGS / BOOT_ENV
  // constants near top of file. Replaces the previous GHCR custom-image flow —
  // eliminates registry auth, build pipeline, and the image-pull stall mode
  // that affected ~38% of provisions. See documents/decisions.md entry
  // 2026-04-23 for context + rollback procedure.
  const imageName = BASE_IMAGE;

  // ─── Pick DC + volume (state stays 'finding_gpu' during selectPlacement) ──
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
    await emitState(sessionId, 'creating_pod');
    try {
      const { id: podId, costPerHr } = await createSpotPod({
        name: podName,
        imageName,
        gpuTypeId: GPU_TYPE_ID,
        bidPerGpu: bid,
        dockerArgs: BOOT_DOCKER_ARGS,
        env: BOOT_ENV,
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
  await emitState(sessionId, 'creating_pod');
  try {
    const { id: podId, costPerHr } = await createOnDemandPod({
      name: podName,
      imageName,
      gpuTypeId: GPU_TYPE_ID,
      cloudType: 'SECURE',
      dockerArgs: BOOT_DOCKER_ARGS,
      env: BOOT_ENV,
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
 * Caller emits state transitions (fetching_image → warming_model); this just
 * blocks until pod.runtime appears or the watchdog fires.
 *
 * If `stallMs` is finite and `pod.runtime` stays null longer than that,
 * throws `PodBootStallError` so the caller can reroll onto a different DC
 * instead of waiting out the full `timeoutMs`. Pass `Infinity` to disable
 * the watchdog and preserve the legacy binary-timeout behavior.
 */
async function waitForRuntime(
  podId: string,
  opts: { timeoutMs?: number; stallMs?: number } = {},
): Promise<void> {
  const timeoutMs = opts.timeoutMs ?? 10 * 60 * 1000;
  const stallMs = opts.stallMs
    ?? (config.POD_BOOT_WATCHDOG_ENABLED ? config.POD_BOOT_STALL_MS : Infinity);
  const start = Date.now();
  const deadline = start + timeoutMs;
  let lastLogAt = 0;
  let lastDc: string | null = null;
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    if (!pod) {
      const elapsed = Math.round((Date.now() - start) / 1000);
      log.warn({ podId, elapsedSec: elapsed, dc: lastDc }, 'Pod vanished during fetching_image (spot preempted?)');
      throw new PodVanishedError(podId, lastDc, 'fetching_image', elapsed);
    }
    if (pod.machine?.dataCenterId) lastDc = pod.machine.dataCenterId;
    if (pod.runtime) {
      log.info({ podId, uptimeInSeconds: pod.runtime.uptimeInSeconds }, 'Container runtime up');
      return;
    }
    const elapsedMs = Date.now() - start;
    if (elapsedMs > stallMs) {
      throw new PodBootStallError(podId, lastDc, Math.round(elapsedMs / 1000));
    }
    // Log periodically so backend observers can see long pulls; iOS gets
    // per-state elapsed via stateEnteredAt and doesn't need push updates here.
    const now = Date.now();
    if (now - lastLogAt > 30_000) {
      const elapsed = Math.round(elapsedMs / 1000);
      log.info({ podId, elapsedSec: elapsed, dc: lastDc }, 'Still waiting for container runtime');
      lastLogAt = now;
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
        log.warn({ podId, elapsedSec: elapsed, dc: lastDc }, 'Pod vanished during warming_model (spot preempted?)');
        throw new PodVanishedError(podId, lastDc, 'warming_model', elapsed);
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

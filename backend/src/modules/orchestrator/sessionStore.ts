// ────────────────────────────────────────────────────────────────────────────
// Session store — Redis-backed session registry (durable, survives deploys).
// ────────────────────────────────────────────────────────────────────────────
//
// The single data-access layer for the `session:<id>` hash. Everything above it
// (broker, provisioner, reaper, the orchestrator entry points) reads/writes
// session state only through these helpers. Pure CRUD: the only dependency is
// the Redis client. The session lifecycle enum (`State`) and the idle-lifetime
// constants live here too, because they describe the record's own shape and TTL.

import { getRedis } from '../redis/client.js';
import type { FailureCategory } from './errorClassification.js';

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

const SESSION_PREFIX = 'session:';
const IDLE_GRACE_SECONDS = 300; // 5 min grace on top of idle timeout for Redis TTL
// Idle lifetime lives here (not in reaper.ts): `IDLE_TTL_SECONDS` derives from it
// for the Redis write-TTL, so the reaper imports it down from this layer rather
// than the store importing up.
export const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
// Exported for `touch()` in orchestrator.ts, which refreshes the TTL on a direct
// fire-and-forget Redis write outside the helpers below.
export const IDLE_TTL_SECONDS = Math.ceil(IDLE_TIMEOUT_MS / 1000) + IDLE_GRACE_SECONDS;

export interface RedisSession {
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
  // Best-effort video pod tracking. Stamped by POD_CONFIGS.video.stampRow
  // on successful provision; cleared by clearVideoPod() on relay-wire
  // failure or replacement. The image pod can serve without this — it
  // exists only to (a) drive reconcile so we don't orphan video pods
  // after crashes, and (b) let the reaper terminate both pods together.
  videoPodId: string | null;
}

export function sessionKey(sessionId: string): string {
  return `${SESSION_PREFIX}${sessionId}`;
}

export async function readSession(sessionId: string): Promise<RedisSession | null> {
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
    videoPodId: data['videoPodId'] || null,
  };
}

export async function writeSession(session: RedisSession): Promise<void> {
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
export async function patchSession(
  sessionId: string,
  patch: Partial<Pick<
    RedisSession,
    'state' | 'stateEnteredAt' | 'failureCategory' | 'podId' | 'podUrl' | 'podType' | 'lastActivityAt' | 'replacementCount' | 'videoPodId'
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
  if (patch.videoPodId !== undefined) fields['videoPodId'] = patch.videoPodId ?? '';
  if (Object.keys(fields).length === 0) return;
  await getRedis().multi()
    .hset(key, fields)
    .expire(key, IDLE_TTL_SECONDS)
    .exec();
}

export async function deleteSession(sessionId: string): Promise<void> {
  await getRedis().del(sessionKey(sessionId));
}

/**
 * Yields every session key in Redis. Wraps the `scanStream` + nested
 * for-await iteration so the three sweep sites (reaper, reconcile pass 1,
 * reconcile pass 2) don't each re-derive the boilerplate.
 */
export async function* eachSessionKey(): AsyncIterable<string> {
  const stream = getRedis().scanStream({ match: `${SESSION_PREFIX}*`, count: 100 });
  for await (const keys of stream) {
    for (const key of keys as string[]) {
      yield key;
    }
  }
}

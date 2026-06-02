// ────────────────────────────────────────────────────────────────────────────
// Reaper + reconcile — background fleet hygiene.
// ────────────────────────────────────────────────────────────────────────────
//
// The only timer/boot-driven code in the module. `runReaper` terminates pods
// idle past IDLE_TIMEOUT_MS; `reconcileOrphanPods` cross-references RunPod pods
// against Redis sessions and reaps the ones nothing claims. Both funnel kills
// through `markPodDead` (podDeath.ts) and never touch POD_CONFIGS or the
// in-flight provision map — they operate purely on Redis rows + the pod-name
// prefixes. `start()` in orchestrator.ts arms them on REAPER_INTERVAL_MS.

import { getRedis } from '../redis/client.js';
import { listPodsByPrefix, terminatePod } from './runpodClient.js';
import { notifyPodTerminated } from './costMonitor.js';
import { log } from './logger.js';
import {
  type State,
  isActiveProvisioning,
  IDLE_TIMEOUT_MS,
  eachSessionKey,
} from './sessionStore.js';
import { POD_PREFIX, VIDEO_POD_PREFIX } from './podBoot.js';
import { emitState } from './broker.js';
import { markPodDead } from './podDeath.js';
import { trackPodTerminated } from '../analytics/index.js';

export const REAPER_INTERVAL_MS = 60 * 1000;
// ────────────────────────────────────────────────────────────────────────────
// Reaper + reconcile
// ────────────────────────────────────────────────────────────────────────────

export async function runReaper(): Promise<void> {
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
      const videoPodId = data['videoPodId'] || null;
      const createdAt = Number(data['createdAt'] ?? 0);
      const lifetimeMs = createdAt > 0 ? now - createdAt : 0;
      log.info({ sessionId, podId, videoPodId, idleMs, lifetimeMs, kind: 'image' }, '[reaper] terminating idle session');
      trackPodTerminated({ userId: sessionId, reason: 'idle', lifetimeMs });
      notifyPodTerminated(podId, `idle ${Math.round(idleMs / 1000)}s`);
      void markPodDead({ podId, podKind: 'image', userId: sessionId, lifetimeMs, reason: 'idle_reaped' });
      // Emit through the broker so the iPad sees state='terminated' with
      // failure_category='idle_timeout' BEFORE we close the upstream pod WS.
      // stream.ts's broker subscriber will close the iPad WS cleanly with
      // code 1000, so when relay.onClose fires from the pod kill below,
      // the recovery path's clientDisconnected check exits early — no
      // confusing "Recovery failed" bounce.
      await emitState(sessionId, 'terminated', 'idle_timeout');
      terminatePod(podId)
        .then(() => redis.del(key))
        .catch((err) => log.error({ sessionId, podId, err }, 'Reap failed'));
      if (videoPodId) {
        log.info({ sessionId, videoPodId, kind: 'video' }, '[reaper] terminating video pod alongside image');
        void markPodDead({ podId: videoPodId, podKind: 'video', userId: sessionId, lifetimeMs, reason: 'idle_reaped' });
        terminatePod(videoPodId).catch((err) =>
          log.error({ sessionId, videoPodId, err }, 'Reap video pod failed'),
        );
      }
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
export async function reconcileOrphanPods(minAgeSec = 0): Promise<void> {
  try {
    // 1. Read all session keys from Redis
    const redis = getRedis();
    const sessionPodIds = new Set<string>();
    const sessionVideoPodIds = new Set<string>();
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
      // Video pods: in use whenever a session row references them, regardless
      // of the image pod's state — the video provision happens after image
      // 'ready', so the row's state is always 'ready' by the time videoPodId
      // is set. But guard with the same `state === 'ready'` filter to avoid
      // adopting a videoPodId from a row that's mid-cleanup.
      if (data['videoPodId'] && state === 'ready') {
        sessionVideoPodIds.add(data['videoPodId']);
      }
    }

    // Clean up stale in-progress rows
    for (const key of staleKeys) {
      log.warn({ key }, 'Reconcile: deleting stale in-progress session');
      await redis.del(key);
    }

    // 2. List RunPod pods (image + video, separately so we count distinctly).
    const pods = await listPodsByPrefix(POD_PREFIX);
    const videoPods = await listPodsByPrefix(VIDEO_POD_PREFIX);

    // 3. Adopt, skip young, or terminate (image pods)
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
      void markPodDead({
        podId: pod.id,
        podKind: 'image',
        lifetimeMs: pod.runtime?.uptimeInSeconds != null ? pod.runtime.uptimeInSeconds * 1000 : undefined,
        reason: 'orphan_reconciled',
        note: pod.name,
      });
      await terminatePod(pod.id).catch((err) =>
        log.error({ podId: pod.id, name: pod.name, err }, 'Failed to terminate orphan'),
      );
    }

    // 3b. Same logic for video pods. Source of truth: videoPodId fields on
    // Redis session rows. Anything else under the kiki-vsession-* prefix is
    // an orphan (backend crash mid-stream, or stream.ts close handler missed
    // the terminate). Boot reconcile (minAgeSec=0) is aggressive — there
    // are no live sessions yet — and periodic respects skip-young.
    let videoAdopted = 0;
    let videoSkippedYoung = 0;
    let videoTerminated = 0;
    for (const pod of videoPods) {
      if (sessionVideoPodIds.has(pod.id)) {
        videoAdopted++;
        continue;
      }
      if (minAgeSec > 0) {
        const uptime = pod.runtime?.uptimeInSeconds ?? 0;
        if (pod.runtime === null || uptime < minAgeSec) {
          videoSkippedYoung++;
          continue;
        }
      }
      log.warn({ podId: pod.id, name: pod.name, kind: 'video' }, '[reconcile] orphans found terminating video pod');
      videoTerminated++;
      void markPodDead({
        podId: pod.id,
        podKind: 'video',
        lifetimeMs: pod.runtime?.uptimeInSeconds != null ? pod.runtime.uptimeInSeconds * 1000 : undefined,
        reason: 'orphan_reconciled',
        note: pod.name,
      });
      await terminatePod(pod.id).catch((err) =>
        log.error({ podId: pod.id, name: pod.name, err }, 'Failed to terminate orphan video pod'),
      );
    }

    // 4. Clean up Redis sessions whose pods no longer exist on RunPod
    const runpodPodIds = new Set(pods.map((p) => p.id));
    const runpodVideoPodIds = new Set(videoPods.map((p) => p.id));
    for await (const key of eachSessionKey()) {
      const podId = await redis.hget(key, 'podId');
      if (podId && !runpodPodIds.has(podId)) {
        log.warn({ key, podId }, 'Reconcile: deleting session for pod no longer on RunPod');
        await redis.del(key);
        continue;
      }
      // Image pod still exists; clear stale videoPodId if the video pod is gone.
      const stashedVideoPodId = await redis.hget(key, 'videoPodId');
      if (stashedVideoPodId && !runpodVideoPodIds.has(stashedVideoPodId)) {
        log.warn(
          { key, videoPodId: stashedVideoPodId },
          'Reconcile: clearing stale videoPodId on session (video pod gone)',
        );
        await redis.hdel(key, 'videoPodId');
      }
    }

    log.info(
      {
        adopted, terminated, skippedYoung, staleProvisioning: staleKeys.length,
        videoAdopted, videoTerminated, videoSkippedYoung,
        minAgeSec,
        event: '[reconcile] orphans found',
        image: pods.length,
        video: videoPods.length,
      },
      'Reconcile complete',
    );
  } catch (err) {
    log.error({ err }, 'Reconcile failed (continuing anyway)');
  }
}

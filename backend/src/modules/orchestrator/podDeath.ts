// ────────────────────────────────────────────────────────────────────────────
// Pod death — the single tombstone chokepoint.
// ────────────────────────────────────────────────────────────────────────────
//
// Every pod termination/observed-death funnels through `markPodDead`, which
// emits one structured `event: 'pod.death'` log. A leaf module (depends only on
// the RunPod client + logger) so its three classes of caller — provisioner
// (provision-error / abort paths), reaper (idle / orphan), and the orchestrator
// entry points (abortSession) — can all import it downward without any of them
// importing each other.

import { log } from './logger.js';
import type { PodKind } from './podBoot.js';
import { getPod } from './runpodClient.js';

/**
 * Reasons a pod stops serving its session. The orchestrator either causes
 * the death (idle_reaped, replaced, manual, …) or merely observes it
 * (runpod_exited, boot_stalled, unhealthy_timeout). Either way, every pod
 * death emits one structured `event: 'pod.death'` log so a Sentry query
 * can answer "what happened to pod X" without grep-by-substring.
 */
export type PodDeathReason =
  | 'idle_reaped'           // Reaper terminated the pod after IDLE_TIMEOUT_MS of no traffic.
  | 'orphan_reconciled'     // No Redis row claimed the pod; reconcile reaped it.
  | 'replaced'              // Old pod superseded by a fresh one (preemption recovery / replaceSession).
  | 'provision_error'       // Provision pipeline failed after pod creation; old pod cleaned up.
  | 'boot_stalled'          // POD_BOOT_STALL_MS expired without runtime ready (handled via PodBootStallError).
  | 'manual'                // abortSession called by the WS handler (user disconnected mid-provision, error path).
  | 'unhealthy_timeout'     // Health check loop exhausted budget on a previously-healthy pod.
  | 'runpod_exited';        // RunPod state poll observed pod EXITED without the orchestrator initiating termination.

export interface MarkPodDeadArgs {
  podId: string;
  podKind: PodKind;
  userId?: string | null;
  dc?: string | null;
  lifetimeMs?: number;
  reason: PodDeathReason;
  /** ms since epoch of the last successful /health probe, if known. Helps
   *  triage how far into its lifetime the pod was when it died. */
  lastHealthAt?: number | null;
  /** Free-form human note (e.g. boot-stall elapsed seconds, provision error
   *  message). Log-only; not promoted to a Sentry attribute. */
  note?: string;
}

/**
 * Emit a single structured `event: 'pod.death'` Pino log line. Routed
 * through `pinoIntegration` + `beforeSendLog` (in `src/index.ts`) into
 * Sentry's Logs product with `pod_id`, `pod_kind`, `user_id`, `dc`, and
 * `reason` as queryable attributes. NOT a Sentry exception/issue — those
 * still fire from their own throw sites (e.g. PodBootStallError). The
 * tombstone log gives us the searchable surface; the exceptions give us
 * the alerting + grouping surface.
 *
 * For `runpod_exited` and `boot_stalled` we additionally poll RunPod for
 * the pod's current `desiredStatus`. RunPod doesn't surface the kernel
 * exit reason (OOMKilled etc.) on the standard pod query, but `desiredStatus`
 * + `runtime !== null` distinguishes "RunPod thinks it's running but health
 * timed out" from "RunPod itself moved the pod to EXITED."
 *
 * Never throws — death logging is best-effort observability.
 */
export async function markPodDead(args: MarkPodDeadArgs): Promise<void> {
  const { podId, podKind, userId, dc, lifetimeMs, reason, lastHealthAt, note } = args;
  let runpodDesiredStatus: string | undefined;
  let runpodRuntimePresent: boolean | undefined;
  if (reason === 'runpod_exited' || reason === 'boot_stalled' || reason === 'unhealthy_timeout') {
    try {
      const pod = await getPod(podId);
      if (pod) {
        runpodDesiredStatus = pod.desiredStatus;
        runpodRuntimePresent = pod.runtime !== null;
      }
    } catch {
      // Best-effort; absence is logged via the undefined fields below.
    }
  }
  log.info(
    {
      event: 'pod.death',
      podId,
      kind: podKind,
      userId: userId ?? undefined,
      dc: dc ?? undefined,
      reason,
      lifetimeMs: lifetimeMs ?? undefined,
      lastHealthAt: lastHealthAt ?? undefined,
      runpodDesiredStatus,
      runpodRuntimePresent,
      note,
    },
    'pod.death',
  );
}

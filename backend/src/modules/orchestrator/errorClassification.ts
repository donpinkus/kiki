/**
 * Orchestrator-local error types and classification.
 *
 * `PodBootStallError` is thrown by `waitForRuntime` when `pod.runtime` stays
 * null longer than the watchdog threshold. `provision` catches it specifically
 * to terminate the stalled pod and reroll onto a different DC. Pre-2026-04-23
 * this was named `ImagePullStallError` and was GHCR-specific; after the switch
 * to stock image + volume-entrypoint, the same mechanism covers NFS mount
 * delays and cold-host stock-image pulls.
 *
 * `classifyProvisionError` maps thrown errors into a stable category string
 * used as a Sentry tag so we can group/filter failures without relying on
 * the free-form error message. New failure modes should add a new category
 * here rather than reusing `unknown`.
 *
 * Capacity detection delegates to `isCapacityError` in `runpodClient.ts` so
 * there's one source of truth for the set of RunPod capacity error phrasings.
 */

export class PodBootStallError extends Error {
  readonly podId: string;
  readonly dc: string | null;
  readonly elapsedSec: number;

  constructor(podId: string, dc: string | null, elapsedSec: number) {
    super(`Pod ${podId} boot stalled after ${elapsedSec}s (dc=${dc ?? 'unknown'})`);
    this.name = 'PodBootStallError';
    this.podId = podId;
    this.dc = dc;
    this.elapsedSec = elapsedSec;
  }
}

/**
 * Pod was created but disappeared from RunPod before becoming serve-ready.
 * Most often spot preemption (RunPod reclaiming the GPU under a higher bid),
 * occasionally a RunPod-side host failure. Either way: same DC may be flaky,
 * so `provision()` blacklists the DC and rerolls — symmetric with
 * `PodBootStallError`.
 */
export class PodVanishedError extends Error {
  readonly podId: string;
  readonly dc: string | null;
  readonly state: 'fetching_image' | 'warming_model';
  readonly elapsedSec: number;

  constructor(
    podId: string,
    dc: string | null,
    state: 'fetching_image' | 'warming_model',
    elapsedSec: number,
  ) {
    super(`Pod ${podId} vanished during ${state} after ${elapsedSec}s (dc=${dc ?? 'unknown'})`);
    this.name = 'PodVanishedError';
    this.podId = podId;
    this.dc = dc;
    this.state = state;
    this.elapsedSec = elapsedSec;
  }
}

/**
 * Provision was cancelled mid-flight by `abortSession` (e.g. user signed out).
 * `_runProvisionLoop` checks its `signal` between phases and throws this with
 * the just-created pod (if any) already terminated. Non-recoverable: callers
 * should not retry, since the cancellation reflects a deliberate caller
 * decision, not a flaky DC.
 */
export class ProvisionAbortedError extends Error {
  readonly podId: string | null;

  constructor(podId: string | null, phase: string) {
    super(`Provision aborted at ${phase}${podId ? ` (pod ${podId} terminated)` : ''}`);
    this.name = 'ProvisionAbortedError';
    this.podId = podId;
  }
}

export type FailureCategory =
  | 'spot_capacity'
  | 'pod_create_failed'
  | 'pod_boot_stall'
  | 'pod_vanished'
  | 'provision_aborted'
  | 'warm_model_timeout'
  | 'monthly_cap'
  | 'idle_timeout'
  | 'transient_runpod'
  | 'unknown';

import { isCapacityError } from './runpodClient.js';

export function classifyProvisionError(err: Error): FailureCategory {
  if (err instanceof PodBootStallError) return 'pod_boot_stall';
  if (err instanceof PodVanishedError) return 'pod_vanished';
  if (err instanceof ProvisionAbortedError) return 'provision_aborted';
  // Delegate capacity detection to the single source of truth in runpodClient.
  // Also retain the legacy internal phrasings ("spot capacity", "capacity exhausted",
  // "no runpod dc") since those are thrown by our own code, not RunPod.
  if (isCapacityError(err)) return 'spot_capacity';
  const msg = err.message.toLowerCase();
  if (
    msg.includes('spot capacity') ||
    msg.includes('capacity exhausted') ||
    msg.includes('no runpod dc')
  ) return 'spot_capacity';
  if (msg.includes('runtime never appeared')) return 'pod_boot_stall';
  if (msg.includes('never became healthy')) return 'warm_model_timeout';
  if (msg.includes('monthly_cap') || msg.includes('cost gate')) return 'monthly_cap';
  if (msg.includes('failed to create') || msg.includes('returned no pod')) return 'pod_create_failed';
  // RunPod's generic backend error. Observed on 2026-04-22 during a DC-pull
  // probe: 3/15 pod.create attempts came back with this exact phrasing, all
  // sub-second, on DCs where capacity was also intermittently available. It's
  // transient, not a capacity signal — classifying separately so PostHog can
  // distinguish it from spot_capacity and unknown.
  if (msg.includes('something went wrong. please try again later')) return 'transient_runpod';
  return 'unknown';
}

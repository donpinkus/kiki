/**
 * PostHog product-analytics wrapper.
 *
 * Single module owns every backend event we send to PostHog. Call sites use
 * the typed `track*()` functions below so event names + property shapes stay
 * in one place instead of being scattered as magic strings.
 *
 * If `POSTHOG_API_KEY` is unset (local dev, CI), everything no-ops — no
 * errors, no guards needed at call sites.
 *
 * Division of concerns:
 *   - Sentry — errors, crashes, APM traces (see orchestrator.ts spans)
 *   - PostHog — product events, funnels, cohorts (this file)
 *
 * See `documents/plans/scale-to-100-users.md` WS6 for the full picture.
 */

import { PostHog } from 'posthog-node';
import { config } from '../../config/index.js';

let client: PostHog | null = null;

function getClient(): PostHog | null {
  if (!config.POSTHOG_API_KEY) return null;
  if (!client) {
    client = new PostHog(config.POSTHOG_API_KEY, { host: config.POSTHOG_HOST });
  }
  return client;
}

/**
 * Flush queued events. Call on SIGTERM / SIGINT so in-flight events don't
 * get dropped when Railway restarts the container.
 */
export async function shutdownAnalytics(): Promise<void> {
  if (client) {
    await client.shutdown();
    client = null;
  }
}

// ────────────────────────────────────────────────────────────────────────────
// Typed event functions
// ────────────────────────────────────────────────────────────────────────────

function capture(distinctId: string, event: string, properties: Record<string, unknown>): void {
  const c = getClient();
  if (!c) return;
  c.capture({ distinctId, event, properties });
}

export function trackPodProvisionStarted(props: {
  userId: string;
  attempt: number;
  excludedDcs: string[];
}): void {
  capture(props.userId, 'pod.provision.started', {
    attempt: props.attempt,
    excluded_dcs: props.excludedDcs,
  });
}

export function trackPodProvisionCompleted(props: {
  userId: string;
  durationMs: number;
  dc: string | null;
  podType: string;
  attempt: number;
  mode: string;
  /** Per-phase durations for funnel analysis. Keys: pod_create_ms, runtime_up_ms, setup_ms (optional), health_check_ms. */
  phaseTimings?: Record<string, number>;
}): void {
  capture(props.userId, 'pod.provision.completed', {
    duration_ms: props.durationMs,
    dc: props.dc ?? 'unknown',
    pod_type: props.podType,
    attempt: props.attempt,
    mode: props.mode,
    ...(props.phaseTimings ?? {}),
  });
}

/**
 * Pod was returned from `getOrProvisionPod` but the relay failed to connect
 * to it (typically a 404 from the RunPod proxy because the pod silently
 * died). Distinct from `pod.provision.failed` which covers fresh-provision
 * failures inside the orchestrator.
 */
export function trackPodRelayFailed(props: {
  userId: string;
  wasReused: boolean;
  errorMessage: string;
  getOrProvisionMs: number;
}): void {
  capture(props.userId, 'pod.relay_failed', {
    was_reused: props.wasReused,
    error_message: props.errorMessage,
    get_or_provision_ms: props.getOrProvisionMs,
  });
}

export function trackPodProvisionFailed(props: {
  userId: string;
  durationMs: number;
  category: string;
  dc: string | null;
  phase: string;
  attempt: number;
}): void {
  capture(props.userId, 'pod.provision.failed', {
    duration_ms: props.durationMs,
    category: props.category,
    dc: props.dc ?? 'unknown',
    phase: props.phase,
    attempt: props.attempt,
  });
}

export function trackPodProvisionStalled(props: {
  userId: string;
  dc: string | null;
  elapsedSec: number;
  attempt: number;
  willReroll: boolean;
}): void {
  capture(props.userId, 'pod.provision.stalled', {
    dc: props.dc ?? 'unknown',
    elapsed_sec: props.elapsedSec,
    attempt: props.attempt,
    will_reroll: props.willReroll,
  });
}

/**
 * Pod was created but vanished mid-provisioning (typically spot preemption,
 * occasionally a host failure). Distinct from `pod.preempted` — that one
 * fires for the WS7 mid-stream replacement path (pod was already serving
 * frames). This one fires before the pod ever became serve-ready.
 */
export function trackPodProvisionVanished(props: {
  userId: string;
  dc: string | null;
  phase: string;
  elapsedSec: number;
  attempt: number;
  willReroll: boolean;
}): void {
  capture(props.userId, 'pod.provision.vanished', {
    dc: props.dc ?? 'unknown',
    phase: props.phase,
    elapsed_sec: props.elapsedSec,
    attempt: props.attempt,
    will_reroll: props.willReroll,
  });
}

export function trackPodPreempted(props: {
  userId: string;
  replacementAttempt: number;
}): void {
  capture(props.userId, 'pod.preempted', {
    replacement_attempt: props.replacementAttempt,
  });
}

export function trackPodReplacementExhausted(props: {
  userId: string;
  maxAttempts: number;
}): void {
  capture(props.userId, 'pod.replacement.exhausted', {
    max_attempts: props.maxAttempts,
  });
}

export function trackPodTerminated(props: {
  userId: string;
  reason: 'idle' | 'error' | 'preempted' | 'manual';
  lifetimeMs: number;
}): void {
  capture(props.userId, 'pod.terminated', {
    reason: props.reason,
    lifetime_ms: props.lifetimeMs,
  });
}

export function trackSessionClosed(props: {
  userId: string;
  durationMs: number;
}): void {
  capture(props.userId, 'session.closed', {
    duration_ms: props.durationMs,
  });
}

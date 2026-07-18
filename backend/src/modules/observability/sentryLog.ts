/**
 * `beforeSendLog` hook for Sentry's Logs product — the backend half of the
 * cross-stack log-attribute convention (mirrors `before_send_log` in
 * `model-servers/shared/sentry_init.py`, which does the same for the pod).
 *
 * Lives here (not index.ts) because its inputs are this module's
 * AsyncLocalStorage stores: the active `phase` (phase.ts) and the active
 * `background_task` (scope.ts). Type-only Sentry import keeps this safe to
 * import before `Sentry.init` runs.
 */
import type * as Sentry from '@sentry/node';

import { getActivePhase } from './phase.js';
import { getActiveBackgroundTask } from './scope.js';

type BeforeSendLog = NonNullable<Sentry.NodeOptions['beforeSendLog']>;

// Pino fields → Sentry log attribute names. Keep snake_case across the stack
// (pod side already does — pod_kind, pod_id, phase, user_id, stream_id) so
// `user_id:X` returns identical results from kiki-pod, node-fastify, and
// kiki-ios. Without this normalization, Pino's camelCase would land as
// `attributes.userId` in Sentry while pods write `attributes.user_id`, and
// cross-stack queries would silently fragment.
const PINO_TO_SENTRY: Record<string, string> = {
  userId: 'user_id',
  sessionId: 'session_id',
  connId: 'conn_id',
  streamId: 'stream_id',
  elapsedMs: 'elapsed_ms',
};

// Promote Pino's camelCase structured fields to snake_case Sentry log
// attributes per the cross-stack convention. Also injects the active
// `phase` from AsyncLocalStorage if any `withPhase(...)` block is on the
// stack at log-emit time.
export const beforeSendLog: BeforeSendLog = (log) => {
  log.attributes ??= {};
  // Rebuild attributes once with snake_case keys mapped over. Building a
  // new dict (rather than `delete log.attributes[dynamicKey]` per pair)
  // sidesteps `@typescript-eslint/no-dynamic-delete` and avoids any
  // ordering subtleties if Sentry preserves insertion order.
  const remapped: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(log.attributes)) {
    const sentryKey = PINO_TO_SENTRY[k] ?? k;
    remapped[sentryKey] = v;
  }
  log.attributes = remapped;
  const activePhase = getActivePhase();
  if (activePhase !== undefined) {
    log.attributes['phase'] = activePhase;
  }
  // Background-task tagging: scope tags don't propagate to the Logs
  // product (verified empirically — same gotcha pod-side `before_send_log`
  // works around). Read the active task name from `inBackgroundScope`'s
  // AsyncLocalStorage and inject as `background_task` attribute.
  const activeBackgroundTask = getActiveBackgroundTask();
  if (activeBackgroundTask !== undefined) {
    log.attributes['background_task'] = activeBackgroundTask;
  }
  return log;
};

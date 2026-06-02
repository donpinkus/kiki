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

import * as Sentry from '@sentry/node';

import { log } from './logger.js';
import { type State, readSession, patchSession } from './sessionStore.js';
import type { FailureCategory } from './errorClassification.js';
import { trackPodStateEntered } from '../analytics/index.js';

export interface StateEvent {
  state: State;
  stateEnteredAt: number;
  /// Ms epoch when this warm-up cycle began (= session.createdAt). Stable
  /// across all state transitions so a reconnecting client can resume the
  /// progress bar instead of restarting from zero.
  warmingStartedAt: number;
  replacementCount: number;
  failureCategory: FailureCategory | null;
  /** Real error message from the failure source. Populated only on
   * `state === 'failed'`. Client renders it directly — no client-side
   * category-to-string mapping that fabricates a cause. */
  message?: string;
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
  log.info(
    {
      sessionId,
      seeded: !!session,
      seededState: session?.state ?? null,
      stateAgeMs: session?.stateEnteredAt ? Date.now() - session.stateEnteredAt : null,
      subscriberCount: set.size,
      event: 'subscribe_seed',
    },
    'subscribe_seed',
  );
  if (session) {
    handler({
      state: session.state,
      stateEnteredAt: session.stateEnteredAt,
      warmingStartedAt: session.createdAt,
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
  message?: string,
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
  const warmingStartedAt = prevSession?.createdAt ?? now;

  await patchSession(sessionId, { state, stateEnteredAt: now, failureCategory });

  const event: StateEvent = {
    state,
    stateEnteredAt: now,
    warmingStartedAt,
    replacementCount,
    failureCategory,
    ...(message !== undefined ? { message } : {}),
  };

  // Fan out to in-process subscribers (iOS WebSocket handlers in stream.ts).
  const subSet = subscribers.get(sessionId);
  const subCount = subSet?.size ?? 0;
  log.info(
    {
      sessionId,
      state,
      previousState,
      subscriberCount: subCount,
      // 0 subscribers ⇒ no iPad will ever see this transition. Critical
      // signal for stuck-on-Connecting diagnoses where the state machine
      // moved but the client never saw it.
      orphaned: subCount === 0,
      event: 'emit_state',
    },
    'emit_state',
  );
  subSet?.forEach((h) => {
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

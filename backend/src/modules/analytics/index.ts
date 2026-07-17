/**
 * Product-analytics wrapper — events go to Kiki Insights.
 *
 * Single module owns every backend event we track. Call sites use the typed
 * `track*()` functions below so event names + property shapes stay in one
 * place instead of being scattered as magic strings.
 *
 * If `INSIGHTS_URL` / `INSIGHTS_INGEST_KEY` are unset (local dev, CI),
 * everything no-ops — no errors, no guards needed at call sites.
 *
 * Division of concerns:
 *   - Sentry — errors, crashes, structured logs
 *   - Kiki Insights — product events, per-user timelines, session replay (this file)
 */

import { captureInsights, flushInsights } from '../insights/client.js';

/**
 * Flush queued events. Call on SIGTERM / SIGINT so in-flight events don't
 * get dropped when Railway restarts the container.
 */
export async function shutdownAnalytics(): Promise<void> {
  await flushInsights();
}

// ────────────────────────────────────────────────────────────────────────────
// Typed event functions
// ────────────────────────────────────────────────────────────────────────────

function capture(distinctId: string, event: string, properties: Record<string, unknown>): void {
  // Best-effort, no-op unless Insights is configured.
  captureInsights(distinctId, event, properties);
}

export function trackSessionClosed(props: {
  userId: string;
  durationMs: number;
}): void {
  capture(props.userId, 'session.closed', {
    duration_ms: props.durationMs,
  });
}

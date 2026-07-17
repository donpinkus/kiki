/**
 * Kiki Insights dual-write sink.
 *
 * Sends backend analytics events to the Insights microsite's /ingest
 * endpoint (the same contract iOS uses). This is the server-side half of
 * event collection — session lifecycle events the iPad never sees, tagged
 * source='backend' on the Insights side.
 *
 * Best-effort and fully decoupled:
 *   - No-op unless both INSIGHTS_URL and INSIGHTS_INGEST_KEY are set.
 *   - Fire-and-forget: events are queued and flushed on a short timer / batch
 *     threshold; failures are swallowed (never throw into a call site).
 *   - Bounded queue so a down Insights service can't leak memory.
 *
 * Auth: presents `x-insights-key`; Insights trusts the per-event `user_id` for
 * service-key callers (the backend is the authority for who the event is about).
 */

import { config } from '../../config/index.js';

interface QueuedEvent {
  user_id: string;
  name: string;
  properties: Record<string, unknown>;
  occurred_at: string;
}

const FLUSH_INTERVAL_MS = 2_000;
const FLUSH_BATCH_SIZE = 50;
const MAX_QUEUE = 1_000;

const queue: QueuedEvent[] = [];
let flushTimer: NodeJS.Timeout | null = null;

function enabled(): boolean {
  return !!config.INSIGHTS_URL && !!config.INSIGHTS_INGEST_KEY;
}

export function captureInsights(
  userId: string,
  name: string,
  properties: Record<string, unknown>,
): void {
  if (!enabled() || !userId) return;
  queue.push({ user_id: userId, name, properties, occurred_at: new Date().toISOString() });
  // Drop oldest if the sink has been unreachable for a while — observability
  // must never become a memory leak.
  if (queue.length > MAX_QUEUE) queue.splice(0, queue.length - MAX_QUEUE);

  if (queue.length >= FLUSH_BATCH_SIZE) {
    void flushInsights();
  } else if (!flushTimer) {
    flushTimer = setTimeout(() => {
      flushTimer = null;
      void flushInsights();
    }, FLUSH_INTERVAL_MS);
  }
}

export async function flushInsights(): Promise<void> {
  if (!enabled() || queue.length === 0) return;
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  const batch = queue.splice(0, queue.length);
  try {
    const res = await fetch(`${config.INSIGHTS_URL.replace(/\/$/, '')}/ingest`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-insights-key': config.INSIGHTS_INGEST_KEY,
      },
      body: JSON.stringify({ events: batch }),
      // Don't let a slow Insights service hold a backend request path.
      signal: AbortSignal.timeout(5_000),
    });
    if (!res.ok) {
      // Re-queue on server error so a transient blip doesn't lose events.
      if (res.status >= 500) requeue(batch);
    }
  } catch {
    requeue(batch);
  }
}

function requeue(batch: QueuedEvent[]): void {
  // Prepend, then enforce the cap (favoring newer events).
  queue.unshift(...batch);
  if (queue.length > MAX_QUEUE) queue.splice(0, queue.length - MAX_QUEUE);
}

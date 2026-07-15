/**
 * Persists per-connection fal relay records (see `FalConnectionRecord` in
 * falImageRelay.ts) into `fal_connections` — real user connections
 * (source='user') and keep-warm pings (source='warmer') land in the SAME
 * table so "do real users see the same cold starts as our pings?" is a
 * GROUP BY, not a data-stitching exercise. Queried by Kiki Insights → Ops.
 *
 * Fire-and-forget: recording must never block or break the relay hot path.
 * Rows are pruned to ~30 days by the warmer tick (falWarmer.ts).
 */
import { query } from '../../postgres/client.js';
import type { FalConnectionRecord } from './falImageRelay.js';

/** First-result wait below this ⇒ the pool was warm. Warm connections answer
 * in ~0.5-1s; cold spin-ups take minutes (p50 ~101s measured 2026-07-14) —
 * generous gap on both sides. Shared with the warmer's classification. */
export const WARM_THRESHOLD_MS = 6_000;

interface ConnectionCtx {
  userId?: string | null;
  streamId?: string | null;
}

interface MinimalLogger {
  warn(obj: Record<string, unknown>, msg?: string): void;
}

export function recordFalConnection(
  source: 'user' | 'warmer',
  ctx: ConnectionCtx,
  rec: FalConnectionRecord,
  logger?: MinimalLogger,
): void {
  void query(
    `INSERT INTO fal_connections
       (opened_at, source, user_id, stream_id, connect_ms, first_frame_ms,
        wait_ms, found_warm, frames_sent, frames_received, open_ms,
        close_reason, close_code)
     VALUES (to_timestamp($1 / 1000.0), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)`,
    [
      rec.openedAt,
      source,
      ctx.userId ?? null,
      ctx.streamId ?? null,
      rec.connectMs,
      rec.firstFrameMs,
      rec.waitMs,
      rec.waitMs === null ? null : rec.waitMs < WARM_THRESHOLD_MS,
      rec.framesSent,
      rec.framesReceived,
      rec.openMs,
      rec.closeReason,
      rec.closeCode,
    ],
  ).catch((err: Error) => {
    logger?.warn({ event: 'fal.connection_record_failed', err: err.message }, 'fal connection record insert failed');
  });
}

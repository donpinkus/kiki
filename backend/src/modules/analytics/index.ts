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

/**
 * Per-stream provider summary, emitted once at socket close. Powers the
 * Insights Launch tab's H100 visibility (success rate, time-to-H100,
 * disconnects, fal-vs-lambda frame share) and the per-user breakdown.
 * `timeToProviderMs` is WS-open → relay wired: for lambda sessions that IS
 * "how long until the H100 was serving me". `lambdaBounced` marks sessions
 * that requested lambda but were turned away (lambda_not_ready).
 */
export function trackProviderSession(props: {
  userId: string;
  streamId: string | null;
  provider: string;
  durationMs: number;
  framesDelivered: number;
  timeToProviderMs: number | null;
  upstreamDisconnects: number;
  upstreamReconnects: number;
  lambdaBounced: boolean;
  /** Pool status at the bounce moment ('launching' = still searching for
   * H100 capacity, 'booting' = instance warming, 'none'/'error' = pool cold
   * or failed). Null when the session wasn't bounced. Powers the H100
   * waterfall's failed-at-which-stage attribution. */
  poolStatusAtBounce: string | null;
  /** Pre-resolution provider ask: 'auto' (launch mode), or an explicit
   * 'lambda'/'fal' override. 'auto'+'lambda' = "requested an H100". */
  providerIntent: string;
  /** Pool status when 'auto' resolved ('booting' = an H100 existed but wasn't
   * warm — the found-vs-warmed waterfall distinction). Null for non-auto. */
  poolStatusAtResolve: string | null;
  /** The lambda relay reached open — the session was CONNECTED to an H100. */
  lambdaWired: boolean;
  /** Frames served by the H100 specifically (a downgraded session's later
   * frames are fal's and excluded). */
  lambdaFrames: number;
  /** Wired → first H100 frame (ms); null when no H100 frame was served. */
  lambdaFirstFrameMs: number | null;
  /** Session had the H100 and lost it (finished on fal). */
  lambdaDowngraded: boolean;
  everReachedReady: boolean;
  /** Video-session counters (null when the session had no video path —
   * feature off or never configured). Powers the Launch tab's video
   * acquisition/success metrics. */
  videoStats: {
    videoTriggered: number;
    videoCompleted: number;
    videoCancelled: number;
    videoFailed: number;
  } | null;
}): void {
  capture(props.userId, 'stream.provider_session', {
    stream_id: props.streamId,
    provider: props.provider,
    duration_ms: props.durationMs,
    frames_delivered: props.framesDelivered,
    time_to_provider_ms: props.timeToProviderMs,
    upstream_disconnects: props.upstreamDisconnects,
    upstream_reconnects: props.upstreamReconnects,
    lambda_bounced: props.lambdaBounced,
    pool_status_at_bounce: props.poolStatusAtBounce,
    requested_provider: props.providerIntent,
    pool_status_at_resolve: props.poolStatusAtResolve,
    lambda_wired: props.lambdaWired,
    lambda_frames: props.lambdaFrames,
    lambda_first_frame_ms: props.lambdaFirstFrameMs,
    lambda_downgraded: props.lambdaDowngraded,
    ever_reached_ready: props.everReachedReady,
    video_triggered: props.videoStats?.videoTriggered ?? null,
    video_completed: props.videoStats?.videoCompleted ?? null,
    video_cancelled: props.videoStats?.videoCancelled ?? null,
    video_failed: props.videoStats?.videoFailed ?? null,
  });
}

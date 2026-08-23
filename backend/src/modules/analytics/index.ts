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
/** One DELIVERED animation (post-stale-guard). wait_ms is the full
 * user-perceived fire→delivery latency (queueing + generation + transfer);
 * gen_ms is the instance's pure generation time from video_complete meta.
 * Powers the GPU Fleet tab's video latency distributions. */
export function trackVideoGeneration(props: {
  userId: string;
  streamId: string | null;
  source: string;
  waitMs: number;
  genMs: number | null;
  bytes: number;
}): void {
  capture(props.userId, 'stream.video_generation', {
    stream_id: props.streamId,
    source: props.source,
    wait_ms: props.waitMs,
    gen_ms: props.genMs,
    bytes: props.bytes,
  });
}

/** One AI Edit (inpaint) generation via POST /v1/edit. `scope` is 'region'
 * (lasso/wand selection, masked client-side) or 'full' (whole drawing). */
export function trackImageEdit(props: {
  userId: string;
  scope: string;
  steps: number;
  elapsedMs: number;
  bytes: number;
}): void {
  capture(props.userId, 'canvas.ai_edit', {
    scope: props.scope,
    steps: props.steps,
    elapsed_ms: props.elapsedMs,
    bytes: props.bytes,
  });
}

/** One Insights row per 3D lift attempt (Hunyuan via /v1/lift3d) — makes
 * lift counts, durations, and failure reasons visible on the user timeline. */
export function trackLift3d(props: {
  userId: string;
  ok: boolean;
  elapsedMs: number;
  glbBytes?: number;
  error?: string;
}): void {
  capture(props.userId, 'objects.lift3d', {
    ok: props.ok,
    elapsed_ms: props.elapsedMs,
    ...(props.glbBytes !== undefined ? { glb_bytes: props.glbBytes } : {}),
    ...(props.error ? { error: props.error.slice(0, 200) } : {}),
  });
}

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
  /** Image-pool status when the socket closed. For never-wired sessions this
   * is the "why they never got it": 'launching' = still hunting capacity when
   * they left, 'booting' = instance found but still warming, 'none'/'error' =
   * pool wasn't even trying, 'ready' = it WAS ready but the session started
   * on fal and auto never upgrades mid-session. */
  poolStatusAtClose: string;
  /** WS-open → first moment the pool reported a ready instance during this
   * session (15s sampling). Null = the pool never became ready while the
   * user was here — the true "waited N minutes, GPU never came" duration is
   * then the session duration itself. */
  h100ReadyAfterMs: number | null;
  /** Video-session counters (null when the session had no video path —
   * feature off or never configured). Powers the Launch tab's video
   * acquisition/success metrics. */
  videoStats: {
    videoTriggered: number;
    videoCompleted: number;
    videoCancelled: number;
    videoFailed: number;
  } | null;
  /** X-Kiki-Client fingerprint (simulator:… / device:… / ua:…) — device-vs-
   * simulator attribution for session forensics. */
  clientTag: string;
  /** Binary sketch frames the client sent — frames_delivered/sketches_sent
   * is the render ratio (the image server drops stale queued sketches under
   * load by design). */
  sketchesSent: number;
  /** Per-session image generation-time percentiles (lambda frame_meta.genMs
   * samples; null on fal-only sessions or pre-genMs instances). */
  imageGenMsP50: number | null;
  imageGenMsP90: number | null;
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
    pool_status_at_close: props.poolStatusAtClose,
    h100_ready_after_ms: props.h100ReadyAfterMs,
    client: props.clientTag,
    sketches_sent: props.sketchesSent,
    image_gen_ms_p50: props.imageGenMsP50,
    image_gen_ms_p90: props.imageGenMsP90,
    video_triggered: props.videoStats?.videoTriggered ?? null,
    video_completed: props.videoStats?.videoCompleted ?? null,
    video_cancelled: props.videoStats?.videoCancelled ?? null,
    video_failed: props.videoStats?.videoFailed ?? null,
  });
}

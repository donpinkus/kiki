/**
 * Session frame capture → Kiki Insights (admin replay).
 *
 * Mirrors a throttled sample of each drawing session's frames to Insights'
 * /ingest/capture endpoint: `sketch` = the canvas JPEG the iPad sent to the
 * image provider, `generated` = the JPEG that came back. Insights stores them
 * on its blob volume + `capture_frames` rows; the Gallery page replays them
 * side-by-side as a scrubable video.
 *
 * PRIVACY: this persists user drawings server-side, superseding the old
 * "sketch data is ephemeral" rule (owner decision 2026-07-15 — see CLAUDE.md
 * Critical Constraints). Retention is enforced Insights-side
 * (CAPTURE_RETENTION_DAYS); disclosure must land in the privacy policy before
 * external users.
 *
 * Design constraints (same spirit as insights/client.ts):
 *   - Hot-path safe: capture() is synchronous fire-and-forget; a slow or down
 *     Insights can never stall the drawing relay.
 *   - Bounded: per-kind throttle (≥ SESSION_CAPTURE_MIN_INTERVAL_MS between
 *     stored frames), per-kind per-stream cap (SESSION_CAPTURE_MAX_FRAMES),
 *     and a small in-flight-request ceiling with drop-on-saturation.
 *   - No-op unless SESSION_CAPTURE_ENABLED + INSIGHTS_URL + INSIGHTS_INGEST_KEY.
 */

import { config } from '../../config/index.js';

const MAX_INFLIGHT = 4;

interface CaptureLogger {
  warn(obj: Record<string, unknown>, msg?: string): void;
}

export function captureEnabled(): boolean {
  return (
    config.SESSION_CAPTURE_ENABLED && !!config.INSIGHTS_URL && !!config.INSIGHTS_INGEST_KEY
  );
}

const MAX_PROMPTS_PER_STREAM = 200;
const MAX_PROMPT_CHARS = 2000;
/** Completed animations per stream kept in Insights (rare events — one per
 * idle pause / Animate tap that survives the stale guard). */
const MAX_VIDEOS_PER_STREAM = 40;
const MAX_VIDEO_BYTES = 25 * 1024 * 1024;

export class FrameCapture {
  private readonly seq = { sketch: 0, generated: 0 };
  private readonly lastAt = { sketch: 0, generated: 0 };
  private videoSeq = 0;
  private inflight = 0;
  private warnedOnce = false;
  private promptSeq = 0;
  private lastPrompt: string | null = null;

  constructor(
    private readonly streamId: string,
    private readonly userId: string,
    private readonly logger?: CaptureLogger,
  ) {}

  capture(kind: 'sketch' | 'generated', jpeg: Buffer): void {
    if (!captureEnabled()) return;
    const now = Date.now();
    if (now - this.lastAt[kind] < config.SESSION_CAPTURE_MIN_INTERVAL_MS) return;
    if (this.seq[kind] >= config.SESSION_CAPTURE_MAX_FRAMES) return;
    if (this.inflight >= MAX_INFLIGHT) return; // saturated → drop, never queue
    this.lastAt[kind] = now;
    const seq = ++this.seq[kind];

    const params = new URLSearchParams({
      stream_id: this.streamId,
      user_id: this.userId,
      kind,
      seq: String(seq),
      ts: String(now),
    });
    this.inflight += 1;
    void fetch(`${config.INSIGHTS_URL.replace(/\/$/, '')}/ingest/capture?${params}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'image/jpeg',
        'x-insights-key': config.INSIGHTS_INGEST_KEY,
      },
      body: new Uint8Array(jpeg),
      signal: AbortSignal.timeout(10_000),
    })
      .then((res) => {
        if (!res.ok && !this.warnedOnce) {
          this.warnedOnce = true;
          this.logger?.warn(
            { event: 'capture.ingest_rejected', status: res.status, streamId: this.streamId },
            'frame capture rejected by Insights (logging once per stream)',
          );
        }
      })
      .catch(() => {
        /* unreachable Insights must never surface into the relay */
      })
      .finally(() => {
        this.inflight -= 1;
      });
  }

  /** Store a DELIVERED animation MP4 (post-stale-guard — never cancelled or
   * out-of-date renders). Same pipeline as frames: blob + capture_frames row,
   * kind='video'; the Gallery associates it with the stream's drawing. */
  captureVideo(mp4: Buffer): void {
    if (!captureEnabled()) return;
    if (mp4.length === 0 || mp4.length > MAX_VIDEO_BYTES) return;
    if (this.videoSeq >= MAX_VIDEOS_PER_STREAM) return;
    if (this.inflight >= MAX_INFLIGHT) return;
    const seq = ++this.videoSeq;
    const params = new URLSearchParams({
      stream_id: this.streamId,
      user_id: this.userId,
      kind: 'video',
      seq: String(seq),
      ts: String(Date.now()),
    });
    this.inflight += 1;
    void fetch(`${config.INSIGHTS_URL.replace(/\/$/, '')}/ingest/capture?${params}`, {
      method: 'POST',
      headers: {
        'Content-Type': 'video/mp4',
        'x-insights-key': config.INSIGHTS_INGEST_KEY,
      },
      body: new Uint8Array(mp4),
      signal: AbortSignal.timeout(30_000),
    })
      .then((res) => {
        if (!res.ok && !this.warnedOnce) {
          this.warnedOnce = true;
          this.logger?.warn(
            { event: 'capture.ingest_rejected', status: res.status, streamId: this.streamId },
            'video capture rejected by Insights (logging once per stream)',
          );
        }
      })
      .catch(() => {
        /* unreachable Insights must never surface into the relay */
      })
      .finally(() => {
        this.inflight -= 1;
      });
  }

  /** Record the prompt whenever the iPad's config changes it (deduped against
   * the last captured value — config messages repeat the prompt on every
   * settings tweak). Timestamped on the same clock as frame captures, so the
   * replay can show which prompt was live for each generated frame. */
  capturePrompt(prompt: string): void {
    if (!captureEnabled()) return;
    const p = prompt.slice(0, MAX_PROMPT_CHARS);
    if (p === this.lastPrompt) return;
    if (this.promptSeq >= MAX_PROMPTS_PER_STREAM) return;
    if (this.inflight >= MAX_INFLIGHT) return;
    this.lastPrompt = p;
    const seq = ++this.promptSeq;

    this.inflight += 1;
    void fetch(`${config.INSIGHTS_URL.replace(/\/$/, '')}/ingest/capture-prompt`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-insights-key': config.INSIGHTS_INGEST_KEY,
      },
      body: JSON.stringify({
        stream_id: this.streamId,
        user_id: this.userId,
        seq,
        ts: Date.now(),
        prompt: p,
      }),
      signal: AbortSignal.timeout(10_000),
    })
      .catch(() => {
        /* unreachable Insights must never surface into the relay */
      })
      .finally(() => {
        this.inflight -= 1;
      });
  }
}

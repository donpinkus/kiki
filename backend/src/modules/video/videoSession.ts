/**
 * Per-stream video session: idle-trigger + relay to the dedicated Lambda
 * LTX-2.3 video instance (model-servers/video/server.py).
 *
 * Trigger semantics (product decision 2026-07-18, replaces the RunPod-era
 * queueEmpty trigger): fire ONE video_request per idle period, 3 s
 * (VIDEO_IDLE_TRIGGER_MS) after the user's LAST sketch frame — animating the
 * latest GENERATED image (the AI output the user is looking at), not the raw
 * sketch. If the final image generation is still in flight when the idle
 * window elapses, the trigger waits for it and fires the moment a generated
 * frame newer than the last sketch arrives, so the video always animates the
 * image that reflects the finished drawing.
 *
 * Priority: image generation is structurally unaffected — the video model
 * runs on its OWN H100 (LTX 22B FP8 + Gemma ≈ 46 GiB resident can't share an
 * 80 GB card with the 9B-KV image server anyway), and this module never
 * touches the image relay. Everything here is best-effort: any failure
 * disables video for the session and logs; the drawing loop never notices.
 *
 * iPad contract (unchanged from the RunPod era — the iOS handlers are intact
 * and purely message-driven):
 *   { type: 'video_frame_data',    data: <b64 JPEG>, meta: {...} }
 *   { type: 'video_complete_data', data: <b64 MP4>,  meta: {...} }
 *   { type: 'video_cancelled',     requestId, ... }   (forwarded verbatim)
 */

import type { FastifyBaseLogger } from 'fastify';
import { StreamRelay } from '../relay/streamRelay.js';

export interface VideoSessionOptions {
  /** wss/ws URL of the video instance, including ?token=. */
  url: string;
  /** Pinned fleet cert (config.LAMBDA_TLS_CA) for wss URLs; null = default trust. */
  tlsCa: string | null;
  /** Idle window before triggering (config.VIDEO_IDLE_TRIGGER_MS). */
  idleMs: number;
  /** Send a text message to the iPad. Caller guards socket.readyState. */
  sendToClient: (text: string) => void;
  /** True while the iPad WS is open. */
  isClientOpen: () => boolean;
  log: FastifyBaseLogger;
  ctx: { userId: string | null; connId: string; streamId: string | null };
}

export interface VideoSessionStats {
  videoTriggered: number;
  videoCompleted: number;
  videoCancelled: number;
  videoFailed: number;
}

export class VideoSession {
  private readonly opts: VideoSessionOptions;
  private relay: StreamRelay | null = null;
  /** Set on unrecoverable relay failure — session continues image-only. */
  private disabled = false;
  private closed = false;
  private reconnecting = false;

  // ── idle-trigger state ────────────────────────────────────────────────
  private idleTimer: NodeJS.Timeout | null = null;
  /** Epoch ms of the last sketch frame from the iPad; 0 = none yet. */
  private lastSketchAtMs = 0;
  /** Latest generated JPEG from the image relay + its arrival time. */
  private lastGeneratedJpeg: Buffer | null = null;
  private lastGeneratedAtMs = 0;
  /** Monotonic event ordering: Date.now() ties (same-ms sketch + generation)
   * would make wall-clock freshness comparison ambiguous, so ordering uses a
   * sequence counter and wall-clock is only used for the idle window. */
  private eventSeq = 0;
  private lastSketchSeq = 0;
  private lastGeneratedSeq = 0;
  /** Latest config from the iPad (prompt + optional video* overrides). */
  private lastConfig: Record<string, unknown> | null = null;
  /** One video per idle period: set on fire, cleared by the next sketch. */
  private firedThisIdle = false;
  /** requestId of the in-flight generation on the video instance. */
  private inFlightRequestId: string | null = null;
  private requestCounter = 0;

  // ── protocol state (preamble → binary pairing, mirrors old wireVideoRelay)
  private pendingBinaryWrapper: { type: string; meta: Record<string, unknown> } | null = null;

  private stats: VideoSessionStats = {
    videoTriggered: 0,
    videoCompleted: 0,
    videoCancelled: 0,
    videoFailed: 0,
  };

  constructor(opts: VideoSessionOptions) {
    this.opts = opts;
  }

  /** Best-effort connect. Never throws — failure logs once and disables
   * video for this session (image path unaffected). */
  async start(): Promise<void> {
    try {
      await this.wireRelay();
      this.opts.log.info(
        { ...this.opts.ctx, event: 'video_relay_wired' },
        'video relay wired',
      );
    } catch (err) {
      this.disabled = true;
      this.opts.log.warn(
        { ...this.opts.ctx, err: (err as Error).message, event: 'video_relay_wire_failed' },
        'video relay wire failed — session continues image-only',
      );
    }
  }

  /** A sketch frame arrived from the iPad: the user is drawing. Cancel any
   * in-flight video and re-arm the idle window. */
  noteSketchFrame(): void {
    if (this.closed) return;
    this.lastSketchAtMs = Date.now();
    this.lastSketchSeq = ++this.eventSeq;
    this.firedThisIdle = false;
    // A new sketch supersedes any in-flight video. Send video_cancel on
    // EVERY iPad frame while a request is outstanding (defensive repetition,
    // carried over from the RunPod-era relay) — once the instance responds
    // video_cancelled, inFlightRequestId clears.
    if (this.inFlightRequestId && this.relay) {
      const req = this.inFlightRequestId;
      this.relay.sendConfig({ type: 'video_cancel', requestId: req });
      this.opts.log.info(
        { ...this.opts.ctx, req, reason: 'user_resumed_drawing', event: 'video_cancel_sent' },
        'video_cancel_sent',
      );
    }
    this.armIdleTimer();
  }

  /** A generated image arrived from the image relay. */
  noteGeneratedFrame(jpeg: Buffer): void {
    if (this.closed) return;
    this.lastGeneratedJpeg = jpeg;
    this.lastGeneratedAtMs = Date.now();
    this.lastGeneratedSeq = ++this.eventSeq;
    // If the idle window already elapsed but we were waiting on this fresher
    // generation, fire now.
    this.maybeFire('generated_frame');
  }

  /** Config (prompt etc.) from the iPad. */
  noteConfig(cfg: Record<string, unknown>): void {
    if (this.closed) return;
    this.lastConfig = cfg;
  }

  getStats(): VideoSessionStats {
    return { ...this.stats };
  }

  close(): void {
    this.closed = true;
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
    this.relay?.close();
    this.relay = null;
  }

  // ── internals ─────────────────────────────────────────────────────────

  private armIdleTimer(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      this.maybeFire('idle_timer');
    }, this.opts.idleMs);
  }

  /** Central trigger gate. Called from the idle timer, from generated-frame
   * arrival, and from in-flight-cleared (complete/cancelled) events; the
   * conditions make multiple calls per idle period safe. */
  private maybeFire(source: string): void {
    if (this.closed || this.disabled || !this.relay) return;
    if (!this.opts.isClientOpen()) return;
    if (this.firedThisIdle || this.inFlightRequestId) return;
    if (this.lastSketchAtMs === 0) return; // never drew — nothing to animate
    if (Date.now() - this.lastSketchAtMs < this.opts.idleMs) return; // not idle yet
    const prompt = this.lastConfig?.['prompt'];
    if (typeof prompt !== 'string') {
      this.opts.log.warn(
        { ...this.opts.ctx, reason: 'prompt_not_cached', event: 'video_skipped' },
        'video_skipped',
      );
      // Don't retry this idle period — the next sketch resets the flag.
      this.firedThisIdle = true;
      return;
    }
    if (!this.lastGeneratedJpeg || this.lastGeneratedSeq < this.lastSketchSeq) {
      // The final image generation for the finished drawing hasn't landed
      // yet — noteGeneratedFrame() calls back into maybeFire when it does.
      return;
    }
    this.fire(prompt, source);
  }

  private fire(prompt: string, source: string): void {
    const relay = this.relay;
    const jpeg = this.lastGeneratedJpeg;
    if (!relay || !jpeg) return;
    this.requestCounter += 1;
    const reqId = `vid-${Date.now()}-${this.requestCounter}`;
    const payload: Record<string, unknown> = {
      type: 'video_request',
      requestId: reqId,
      image_b64: jpeg.toString('base64'),
      prompt,
    };
    // Optional per-request overrides forwarded from the iPad config
    // (Settings → Diagnostics), same passthrough as the RunPod-era relay.
    for (const k of ['videoWidth', 'videoHeight', 'videoFrames'] as const) {
      const v = this.lastConfig?.[k];
      if (typeof v === 'number' && Number.isFinite(v)) payload[k] = Math.trunc(v);
    }
    if (this.lastConfig?.['enableProfiling'] === true) payload['enableProfiling'] = true;
    if (typeof this.lastConfig?.['videoPromptSuffix'] === 'string') {
      payload['videoPromptSuffix'] = this.lastConfig['videoPromptSuffix'];
    }
    relay.sendConfig(payload);
    this.inFlightRequestId = reqId;
    this.firedThisIdle = true;
    this.stats.videoTriggered += 1;
    this.opts.log.info(
      {
        ...this.opts.ctx,
        req: reqId,
        source,
        idleMs: Date.now() - this.lastSketchAtMs,
        imageAgeMs: Date.now() - this.lastGeneratedAtMs,
        videoWidth: payload['videoWidth'],
        videoHeight: payload['videoHeight'],
        videoFrames: payload['videoFrames'],
        event: 'video_trigger',
      },
      'video_trigger',
    );
  }

  private async wireRelay(): Promise<void> {
    const relay = new StreamRelay(this.opts.url, {
      tlsCa: this.opts.url.startsWith('wss') ? this.opts.tlsCa : null,
    });
    relay.setLogContext({ ...this.opts.ctx, role: 'video' });
    relay.onMessage((data, isBinary) => this.handleUpstreamMessage(data, isBinary));
    relay.onClose((code, reason) => this.handleUpstreamClose(code, reason));
    relay.onError((err) => {
      this.opts.log.warn(
        { ...this.opts.ctx, err: err.message, event: 'video_relay_error' },
        'video relay error',
      );
    });
    await relay.connect();
    this.relay = relay;
  }

  /** Wrap/forward messages from the video instance to the iPad. Mirrors the
   * RunPod-era wireVideoRelay: the instance sends a JSON preamble
   * (video_frame / video_complete) before each binary; we wrap the binary as
   * *_data for the iPad and drop the bare preamble (iOS has no handler for
   * it). video_cancelled and unknown text pass through verbatim. */
  private handleUpstreamMessage(data: Buffer | string, isBinary: boolean): void {
    if (this.closed || !this.opts.isClientOpen()) return;
    if (isBinary) {
      const buf = data as Buffer;
      const wrap = this.pendingBinaryWrapper;
      this.pendingBinaryWrapper = null;
      const wrapperType =
        wrap?.type === 'video_complete'
          ? 'video_complete_data'
          : wrap?.type === 'video_frame'
            ? 'video_frame_data'
            : 'video_unknown_data';
      this.opts.sendToClient(
        JSON.stringify({ type: wrapperType, data: buf.toString('base64'), meta: wrap?.meta ?? {} }),
      );
      return;
    }
    if (typeof data !== 'string') return;
    let parsed: Record<string, unknown> | null = null;
    try {
      parsed = JSON.parse(data) as Record<string, unknown>;
    } catch {
      // Not JSON — pass through opaquely.
    }
    if (parsed === null) {
      this.opts.sendToClient(data);
      return;
    }
    const t = parsed['type'];
    if (t === 'video_frame' || t === 'video_complete') {
      this.pendingBinaryWrapper = { type: t as string, meta: parsed };
      if (t === 'video_complete') {
        this.stats.videoCompleted += 1;
        this.inFlightRequestId = null;
        // If the user has been idle all along, firedThisIdle stays true —
        // exactly one video per idle period (iOS loops the MP4).
      }
      return; // bare preamble — wrapped *_data goes out on the binary path
    }
    if (t === 'video_cancelled') {
      if (parsed['error']) {
        this.stats.videoFailed += 1;
      } else {
        this.stats.videoCancelled += 1;
      }
      this.inFlightRequestId = null;
      this.pendingBinaryWrapper = null;
      this.opts.sendToClient(data);
      // The cancel usually came from the user resuming drawing (flag already
      // reset by that sketch), but a server-side failure mid-idle should not
      // permanently eat the idle period's video — let the gate re-check.
      this.maybeFire('cancelled_cleared');
      return;
    }
    // status / unknown → forward verbatim (iOS ignores unknown types).
    this.opts.sendToClient(data);
  }

  /** One same-URL reconnect attempt (transient transport drop); on failure
   * the session drops to image-only. Best-effort by design — no iPad-visible
   * error, no image-path impact. */
  private handleUpstreamClose(code: number, reason: string): void {
    this.opts.log.warn(
      { ...this.opts.ctx, code, reason, event: 'video_relay_closed' },
      'video_relay_closed',
    );
    this.inFlightRequestId = null;
    this.pendingBinaryWrapper = null;
    this.relay?.close();
    this.relay = null;
    if (this.closed || !this.opts.isClientOpen() || this.reconnecting) {
      return;
    }
    this.reconnecting = true;
    void (async () => {
      try {
        await this.wireRelay();
        this.opts.log.info(
          { ...this.opts.ctx, event: 'video_relay_reconnected' },
          'video same-URL reconnect succeeded',
        );
      } catch (err) {
        this.disabled = true;
        this.opts.log.warn(
          { ...this.opts.ctx, err: (err as Error).message, event: 'video_relay_reconnect_failed' },
          'video reconnect failed — session continues image-only',
        );
      } finally {
        this.reconnecting = false;
      }
    })();
  }
}

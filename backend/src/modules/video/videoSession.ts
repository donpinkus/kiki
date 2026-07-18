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
 * iPad contract (the *_data shapes are unchanged from the RunPod era — the
 * iOS handlers are intact and purely message-driven):
 *   { type: 'video_started',       requestId }        (NEW 2026-07-18: emitted
 *       the moment a video_request fires — auto or manual — so the toolbar's
 *       Animate button can show its disabled "Animating" state)
 *   { type: 'video_frame_data',    data: <b64 JPEG>, meta: {...} }
 *   { type: 'video_complete_data', data: <b64 MP4>,  meta: {...} }
 *   { type: 'video_cancelled',     requestId, ... }   (forwarded verbatim;
 *       also synthesized locally when a manual animate request can't run,
 *       so the button always resets)
 */

import type { FastifyBaseLogger } from 'fastify';
import { StreamRelay } from '../relay/streamRelay.js';

export interface VideoSessionOptions {
  /** Get a video-instance slot to relay to. Static mode (LAMBDA_VIDEO_URL)
   * returns the fixed URL every time; pool mode proxies
   * videoPool.acquireStream() (least-loaded ready instance, slot held).
   * Null = nothing assignable right now — the session stays image-only and
   * RETRIES on the next fire attempt, so a session that started before the
   * pool warmed picks up video mid-session. */
  acquire: () => { name?: string; url: string } | null;
  /** Release a held slot (close / upstream loss). No-op in static mode. */
  release?: (name: string) => void;
  /** Mark an instance suspect after a failed connect (pool skips it for
   * assignment until a health probe clears it). No-op in static mode. */
  reportFailure?: (name: string) => void;
  /** Record instance activity (frames flowing) for the pool's idle reaper. */
  touchInstance?: (name: string) => void;
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
  /** Pool instance name our slot is held on (undefined slot name = static). */
  private slotName: string | null = null;
  private closed = false;
  /** Guards concurrent ensureRelay() runs (timer + generated-frame events
   * can race). */
  private wiring = false;

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

  /** Best-effort connect at session start. Never throws; when no instance
   * is assignable yet (pool still booting) the session stays image-only and
   * every later fire attempt lazily retries via ensureRelay(). */
  async start(): Promise<void> {
    await this.ensureRelay();
  }

  /** Acquire a slot + wire the relay if not already wired. Returns true when
   * a relay is available. All failure modes leave the session retryable:
   * no slot → try again next fire; connect failure → reportFailure (pool
   * skips the instance) + release, try again next fire. */
  private async ensureRelay(): Promise<boolean> {
    if (this.relay) return true;
    if (this.closed || this.wiring) return false;
    const slot = this.opts.acquire();
    if (!slot) {
      this.opts.log.info(
        { ...this.opts.ctx, event: 'video_pool_no_instance' },
        'no video instance assignable — session image-only for now',
      );
      return false;
    }
    this.wiring = true;
    try {
      await this.wireRelay(slot.url);
      this.slotName = slot.name ?? null;
      this.opts.log.info(
        { ...this.opts.ctx, instance: slot.name, event: 'video_relay_wired' },
        'video relay wired',
      );
      return true;
    } catch (err) {
      if (slot.name) {
        this.opts.reportFailure?.(slot.name);
        this.opts.release?.(slot.name);
      }
      this.opts.log.warn(
        { ...this.opts.ctx, instance: slot.name, err: (err as Error).message, event: 'video_relay_wire_failed' },
        'video relay wire failed — will retry on next trigger',
      );
      return false;
    } finally {
      this.wiring = false;
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

  /** Manual "Animate" button ({type:'animate'} from the iPad): fire NOW,
   * bypassing the idle window and the once-per-idle flag, animating the
   * newest generated image. When it can't run (no relay, no prompt, no
   * image), synthesize a video_cancelled with an error so the iPad's
   * optimistically-disabled button always resets. Ignored while a video is
   * already in flight (the button is disabled client-side; this is the
   * backstop). */
  requestAnimate(): void {
    if (this.closed) return;
    if (this.inFlightRequestId) return;
    const fail = (error: string): void => {
      this.opts.log.info(
        { ...this.opts.ctx, reason: error, event: 'video_animate_failed' },
        'video_animate_failed',
      );
      this.opts.sendToClient(JSON.stringify({ type: 'video_cancelled', requestId: null, error }));
    };
    const prompt = this.lastConfig?.['prompt'];
    if (typeof prompt !== 'string') return fail('no_prompt');
    if (!this.lastGeneratedJpeg) return fail('no_image');
    if (this.relay) {
      this.fire(prompt, 'manual');
      return;
    }
    // No relay yet (pool booting / previous instance lost): acquire + wire,
    // then fire — or reset the iPad button if nothing is assignable.
    void this.ensureRelay().then((ok) => {
      if (this.closed || this.inFlightRequestId) return;
      if (!ok) return fail('video_unavailable');
      const p = this.lastConfig?.['prompt'];
      if (typeof p === 'string' && this.lastGeneratedJpeg) this.fire(p, 'manual');
    });
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
    if (this.slotName) {
      this.opts.release?.(this.slotName);
      this.slotName = null;
    }
  }

  // ── internals ─────────────────────────────────────────────────────────

  /** (Re-)arm the idle timer to the fixed deadline lastSketchAtMs + idleMs.
   * Computed as a remainder (not a flat idleMs) so re-arms from maybeFire's
   * not-idle-yet branch converge on the SAME deadline; +5ms slack because
   * setTimeout can fire marginally early vs Date.now() (ms rounding) — the
   * source of a nasty bug where an early fire hit the not-idle-yet guard
   * and, with nothing re-arming the timer, the idle period never triggered. */
  private armIdleTimer(): void {
    if (this.idleTimer) clearTimeout(this.idleTimer);
    const remaining = Math.max(0, this.opts.idleMs - (Date.now() - this.lastSketchAtMs));
    this.idleTimer = setTimeout(() => {
      this.idleTimer = null;
      this.maybeFire('idle_timer');
    }, remaining + 5);
  }

  /** Central trigger gate. Called from the idle timer, from generated-frame
   * arrival, and from in-flight-cleared (complete/cancelled) events; the
   * conditions make multiple calls per idle period safe. */
  private maybeFire(source: string): void {
    if (this.closed) return;
    if (!this.opts.isClientOpen()) return;
    if (this.firedThisIdle || this.inFlightRequestId) return;
    if (this.lastSketchAtMs === 0) return; // never drew — nothing to animate
    if (Date.now() - this.lastSketchAtMs < this.opts.idleMs) {
      // Not idle yet (early timer fire, or a non-timer caller). Re-arm to
      // the true deadline — a bare return here would strand the idle period
      // with no armed timer when the timer itself fired early.
      this.armIdleTimer();
      return;
    }
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
    if (!this.relay) {
      // Lazy (re-)acquire: pool may have warmed since session start, or the
      // previous instance died. On success, re-run the gate (conditions may
      // have changed while wiring — e.g. the user resumed drawing).
      void this.ensureRelay().then((ok) => {
        if (ok) this.maybeFire(`${source}:relay_wired`);
      });
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
    // Tell the iPad a video is generating (auto AND manual triggers) so the
    // toolbar's Animate button flips to its disabled "Animating" state even
    // when the user didn't tap it.
    this.opts.sendToClient(JSON.stringify({ type: 'video_started', requestId: reqId }));
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

  private async wireRelay(url: string): Promise<void> {
    const relay = new StreamRelay(url, {
      tlsCa: url.startsWith('wss') ? this.opts.tlsCa : null,
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
    // Keep the pool's idle reaper honest while video traffic flows.
    if (this.slotName) this.opts.touchInstance?.(this.slotName);
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

  /** Upstream relay lost (instance died / restarted / network drop). Release
   * the slot and clear state — the next fire attempt lazily re-acquires
   * (possibly a DIFFERENT pool instance), so recovery needs no dedicated
   * reconnect loop. If a generation was in flight, tell the iPad so the
   * Animate button and video UI reset instead of hanging. Best-effort by
   * design — no iPad-visible error, no image-path impact. */
  private handleUpstreamClose(code: number, reason: string): void {
    this.opts.log.warn(
      { ...this.opts.ctx, instance: this.slotName, code, reason, event: 'video_relay_closed' },
      'video_relay_closed',
    );
    const lostRequest = this.inFlightRequestId;
    this.inFlightRequestId = null;
    this.pendingBinaryWrapper = null;
    this.relay?.close();
    this.relay = null;
    if (this.slotName) {
      this.opts.release?.(this.slotName);
      this.slotName = null;
    }
    if (this.closed || !this.opts.isClientOpen()) return;
    if (lostRequest) {
      this.opts.sendToClient(
        JSON.stringify({ type: 'video_cancelled', requestId: lostRequest, error: 'video_instance_lost' }),
      );
    }
  }
}

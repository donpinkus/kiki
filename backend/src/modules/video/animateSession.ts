/**
 * Per-connection Animate-screen session: on-demand relay to a dedicated
 * Lambda LTX-2.3 video instance (model-servers/video/server.py).
 *
 * This replaces the drawing-stream VideoSession (removed 2026-07-19): there
 * is no idle trigger and no sketch coupling any more — the iPad's Animate
 * screen sends explicit `animate_request` messages over its own
 * `/v1/animate` WebSocket, each carrying 1–4 keyframes (base64 images
 * pinned at fractional positions of the video duration) plus a motion
 * prompt and optional shape overrides.
 *
 * Everything is best-effort: any failure synthesizes a `video_cancelled`
 * with an error string so the iPad's Animate button always resets; nothing
 * here can take down the connection.
 *
 * iPad contract (unchanged *_data shapes from the drawing-stream era — the
 * iOS parsing was already message-driven):
 *   { type: 'video_started',       requestId }
 *   { type: 'video_frame_data',    data: <b64 JPEG>, meta: {...} }
 *   { type: 'video_complete_data', data: <b64 MP4>,  meta: {...} }
 *   { type: 'video_cancelled',     requestId, error? }
 */

import type { FastifyBaseLogger } from 'fastify';
import { StreamRelay } from '../relay/streamRelay.js';

/** Motion prompt used when the user leaves the prompt empty. Describes
 * MOTION, not content — LTX gets the content from the keyframes; the prompt
 * steers how it moves. Tuned in the 2026-07-18 quality sweep. */
export const DEFAULT_ANIMATION_PROMPT =
  'gentle cinematic motion: the scene subtly comes alive with natural movement, ' +
  'soft ambient animation, camera slowly drifting closer';

export interface AnimateKeyframe {
  /** base64 JPEG/PNG. */
  imageB64: string;
  /** 0.0 (first frame) … 1.0 (last frame). */
  position: number;
  /** Conditioning strength 0.0–1.0 (default 1.0). */
  strength?: number;
}

export interface AnimateRequestInput {
  requestId: string;
  prompt: string;
  keyframes: AnimateKeyframe[];
  seed?: number;
  numFrames?: number;
  width?: number;
  height?: number;
}

export interface AnimateSessionOptions {
  /** Get a video-instance slot to relay to (see videoPool.acquireStream).
   * Null = nothing assignable right now. */
  acquire: () => { name?: string; url: string } | null;
  release?: (name: string) => void;
  reportFailure?: (name: string) => void;
  touchInstance?: (name: string) => void;
  /** Pinned fleet cert for wss URLs; null = default trust. */
  tlsCa: string | null;
  /** Send a text message to the iPad. Caller guards socket.readyState. */
  sendToClient: (text: string) => void;
  isClientOpen: () => boolean;
  /** A completed MP4 was delivered to the iPad. Metering + analytics hook.
   * `info.waitMs` = request → delivery. */
  onVideoDelivered?: (
    mp4: Buffer,
    meta: Record<string, unknown>,
    info: { waitMs: number },
  ) => void;
  log: FastifyBaseLogger;
  ctx: { userId: string | null; connId: string };
}

export interface AnimateSessionStats {
  videoRequested: number;
  videoCompleted: number;
  videoCancelled: number;
  videoFailed: number;
}

export class AnimateSession {
  private readonly opts: AnimateSessionOptions;
  private relay: StreamRelay | null = null;
  private slotName: string | null = null;
  private closed = false;
  private wiring = false;

  /** requestId of the in-flight generation; one at a time per connection. */
  private inFlightRequestId: string | null = null;
  private inFlightFiredAtMs = 0;

  /** Preamble → binary pairing (video_frame / video_complete then bytes). */
  private pendingBinaryWrapper: { type: string; meta: Record<string, unknown> } | null = null;

  private stats: AnimateSessionStats = {
    videoRequested: 0,
    videoCompleted: 0,
    videoCancelled: 0,
    videoFailed: 0,
  };

  constructor(opts: AnimateSessionOptions) {
    this.opts = opts;
  }

  /** Fire a generation. One in flight per connection: a request while one is
   * running is refused with error 'busy' (the iPad disables the button
   * client-side; this is the backstop). All failure paths synthesize a
   * video_cancelled so the button resets. */
  requestAnimate(input: AnimateRequestInput): void {
    if (this.closed) return;
    const fail = (error: string): void => {
      this.opts.log.info(
        { ...this.opts.ctx, req: input.requestId, reason: error, event: 'animate_request_failed' },
        'animate_request_failed',
      );
      this.opts.sendToClient(
        JSON.stringify({ type: 'video_cancelled', requestId: input.requestId, error }),
      );
    };
    if (this.inFlightRequestId) return fail('busy');
    if (input.keyframes.length === 0) return fail('no_image');
    if (this.relay) {
      this.fire(input);
      return;
    }
    void this.ensureRelay().then((ok) => {
      if (this.closed) return;
      if (this.inFlightRequestId) return fail('busy');
      if (!ok) return fail('video_unavailable');
      this.fire(input);
    });
  }

  /** Cancel the in-flight generation (user tapped stop / left the screen). */
  cancel(requestId: string | null): void {
    if (this.closed) return;
    const req = requestId ?? this.inFlightRequestId;
    if (!req || !this.relay) return;
    this.relay.sendConfig({ type: 'video_cancel', requestId: req });
    this.opts.log.info(
      { ...this.opts.ctx, req, event: 'animate_cancel_sent' },
      'animate_cancel_sent',
    );
  }

  getStats(): AnimateSessionStats {
    return { ...this.stats };
  }

  close(): void {
    this.closed = true;
    this.relay?.close();
    this.relay = null;
    if (this.slotName) {
      this.opts.release?.(this.slotName);
      this.slotName = null;
    }
  }

  // ── internals ─────────────────────────────────────────────────────────

  private async ensureRelay(): Promise<boolean> {
    if (this.relay) return true;
    if (this.closed || this.wiring) return false;
    const slot = this.opts.acquire();
    if (!slot) {
      this.opts.log.info(
        { ...this.opts.ctx, event: 'video_pool_no_instance' },
        'no video instance assignable',
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
        'video relay wire failed',
      );
      return false;
    } finally {
      this.wiring = false;
    }
  }

  private fire(input: AnimateRequestInput): void {
    const relay = this.relay;
    if (!relay) return;
    const prompt = input.prompt.trim().length > 0 ? input.prompt : DEFAULT_ANIMATION_PROMPT;
    const payload: Record<string, unknown> = {
      type: 'video_request',
      requestId: input.requestId,
      prompt,
      keyframes: input.keyframes.map((kf) => ({
        image_b64: kf.imageB64,
        position: kf.position,
        strength: kf.strength ?? 1.0,
      })),
    };
    if (typeof input.seed === 'number' && Number.isFinite(input.seed)) {
      payload['seed'] = Math.trunc(input.seed);
    }
    if (typeof input.numFrames === 'number' && Number.isFinite(input.numFrames)) {
      payload['videoFrames'] = Math.trunc(input.numFrames);
    }
    if (typeof input.width === 'number' && Number.isFinite(input.width)) {
      payload['videoWidth'] = Math.trunc(input.width);
    }
    if (typeof input.height === 'number' && Number.isFinite(input.height)) {
      payload['videoHeight'] = Math.trunc(input.height);
    }
    relay.sendConfig(payload);
    this.inFlightRequestId = input.requestId;
    this.inFlightFiredAtMs = Date.now();
    this.stats.videoRequested += 1;
    this.opts.sendToClient(JSON.stringify({ type: 'video_started', requestId: input.requestId }));
    this.opts.log.info(
      {
        ...this.opts.ctx,
        req: input.requestId,
        keyframes: input.keyframes.length,
        numFrames: input.numFrames,
        event: 'animate_request_fired',
      },
      'animate_request_fired',
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

  /** Wrap/forward instance messages to the iPad: JSON preamble
   * (video_frame / video_complete) + binary → base64 *_data; video_cancelled
   * passes through. A completion for a requestId that isn't the in-flight
   * one (cancel raced the finished render) is dropped with its binary. */
  private handleUpstreamMessage(data: Buffer | string, isBinary: boolean): void {
    if (this.closed || !this.opts.isClientOpen()) return;
    if (this.slotName) this.opts.touchInstance?.(this.slotName);
    if (isBinary) {
      const buf = data as Buffer;
      const wrap = this.pendingBinaryWrapper;
      this.pendingBinaryWrapper = null;
      if (wrap?.type === '__stale__') return;
      const wrapperType =
        wrap?.type === 'video_complete'
          ? 'video_complete_data'
          : wrap?.type === 'video_frame'
            ? 'video_frame_data'
            : 'video_unknown_data';
      this.opts.sendToClient(
        JSON.stringify({ type: wrapperType, data: buf.toString('base64'), meta: wrap?.meta ?? {} }),
      );
      if (wrapperType === 'video_complete_data') {
        this.opts.onVideoDelivered?.(buf, wrap?.meta ?? {}, {
          waitMs: this.inFlightFiredAtMs > 0 ? Date.now() - this.inFlightFiredAtMs : 0,
        });
      }
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
      const reqId = typeof parsed['requestId'] === 'string' ? parsed['requestId'] : null;
      if (reqId !== null && reqId !== this.inFlightRequestId) {
        this.pendingBinaryWrapper = { type: '__stale__', meta: parsed };
        if (t === 'video_complete') {
          this.stats.videoCancelled += 1;
          this.opts.log.info(
            { ...this.opts.ctx, req: reqId, inFlight: this.inFlightRequestId, event: 'video_stale_dropped' },
            'stale video dropped',
          );
        }
        return;
      }
      this.pendingBinaryWrapper = { type: t as string, meta: parsed };
      if (t === 'video_complete') {
        this.stats.videoCompleted += 1;
        this.inFlightRequestId = null;
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
      return;
    }
    // status / unknown → forward verbatim (iOS ignores unknown types).
    this.opts.sendToClient(data);
  }

  /** Upstream lost. Release the slot; the next request lazily re-acquires
   * (possibly a different pool instance). If a generation was in flight,
   * tell the iPad so the Animate button resets. */
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

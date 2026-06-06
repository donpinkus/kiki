/**
 * fal.ai HOSTED realtime image relay — drop-in replacement for `StreamRelay`
 * on the IMAGE path only (video stays on RunPod).
 *
 * When `IMAGE_PROVIDER=fal`, `routes/stream.ts` wires one of these instead of a
 * RunPod `StreamRelay`. It speaks fal's realtime protocol upstream
 * (`wss://fal.run/fal-ai/flux-2/klein/realtime`, msgpack frames, server-side
 * `Authorization: Key $FAL_KEY` — no token minting, no secret on the client)
 * and presents the SAME surface `StreamRelay` does downstream, so the existing
 * `wireRelay` closure and video-trigger code in `stream.ts` work unchanged.
 *
 * The one piece of glue: fal emits no `frame_meta`/`queueEmpty`. So for each
 * returned frame this relay synthesizes a `frame_meta` text message immediately
 * before the binary JPEG, with `queueEmpty` derived exactly as the RunPod pod
 * derives it (`model-servers/image/server.py:281` — "no newer sketch arrived
 * during this frame's generation"). That keeps the user-paused → video
 * idle-state animation working without touching `stream.ts` or the video pod.
 *
 * Protocol verified live 2026-06-06 (see `fal-spike/README.md` verdict):
 *   - input msg : {image_url:"data:image/jpeg;base64,…", prompt,
 *                  num_inference_steps, schedule_mu, output_feedback_strength,
 *                  image_size, seed, sync_mode:true}  (msgpack, useRecords:false)
 *   - output msg: {images:[{content:<jpeg bytes>, content_type, height, width}],
 *                  seed}  (msgpack binary frame)
 *   - control   : text JSON, e.g. {type:"x-fal-error", error:"TIMEOUT", …}
 *   - idle      : after ~30s with no input fal sends a TIMEOUT control + closes
 *                 ("reconnect when needed"). We reconnect lazily on next frame.
 *
 * ISOLATION: the entire fal coupling is this one module. Reverting to RunPod =
 * set `IMAGE_PROVIDER=runpod` (the RunPod image path is dormant, not removed).
 * Removing fal entirely = delete this file + the `IMAGE_PROVIDER==='fal'` branch
 * in stream.ts + the two config fields. No coupling into the orchestrator/relay.
 */
import WebSocket from 'ws';
import { Packr } from 'msgpackr';
import * as Sentry from '@sentry/node';

import type { WireRelayPhaseTimings } from '../relay/streamRelay.js';

/** The subset of `StreamRelay` that `routes/stream.ts` actually calls. Both
 * `StreamRelay` (RunPod) and `FalImageRelay` (fal) satisfy this structurally,
 * so the image-path wiring is provider-agnostic. */
export interface ImageRelay {
  setLogContext(ctx: Record<string, unknown>): void;
  getLastPhaseTimings(): WireRelayPhaseTimings;
  connect(): Promise<unknown>;
  sendConfig(payload: Record<string, unknown>): void;
  sendFrame(jpeg: Buffer): void;
  onMessage(cb: (data: Buffer | string, isBinary: boolean) => void): void;
  onClose(cb: (code: number, reason: string) => void): void;
  onError(cb: (err: Error) => void): void;
  close(): void;
}

const FAL_REALTIME_URL =
  process.env['FAL_REALTIME_URL'] ?? 'wss://fal.run/fal-ai/flux-2/klein/realtime';
const CONNECT_TIMEOUT_MS = 15_000;

/** Minimal logger shape — accepts a Fastify/pino logger or any structured
 * logger. Optional; falls back to Sentry breadcrumbs only. */
interface RelayLogger {
  info(obj: Record<string, unknown>, msg?: string): void;
  warn(obj: Record<string, unknown>, msg?: string): void;
}

interface FalImageRelayOpts {
  logger?: RelayLogger;
  ctx?: Record<string, unknown>;
  /** Proactively close the fal WS after this many ms with no new frame (then
   * lazily reconnect on the next stroke). 0 = disabled (let fal's ~30s idle
   * timeout close it). Cost lever; see FAL_IDLE_CLOSE_MS. */
  idleCloseMs?: number;
}

export class FalImageRelay implements ImageRelay {
  private ws: WebSocket | null = null;
  private opened = false;
  private closedByUs = false;
  private reconnecting = false;
  /** True once any socket has opened — distinguishes the first (lazy) open from
   * later reconnects for log labeling. */
  private everOpened = false;
  /** Set right before WE close an idle socket so handleUpstreamClose logs it as
   * an idle-close, NOT a transient drop, and does NOT block reconnect (unlike
   * closedByUs). */
  private idleClosed = false;
  /** Proactive idle-close timer (Lever B). */
  private idleTimer: NodeJS.Timeout | null = null;
  private readonly idleCloseMs: number;

  private readonly falKey: string;
  private readonly logger?: RelayLogger;
  private logContext: Record<string, unknown>;
  private readonly packr = new Packr({ useRecords: false });

  private messageHandler: ((data: Buffer | string, isBinary: boolean) => void) | null = null;
  private errorHandler: ((err: Error) => void) | null = null;

  /** Generation params (prompt + knobs) merged from each iPad `config`
   * message; ride along with every frame fal request. */
  private params: Record<string, unknown> = {
    num_inference_steps: 3,
    schedule_mu: 2.3,
    output_feedback_strength: 1.0,
    image_size: 'square',
    enable_interpolation: false,
  };

  /** Single-slot latest-wins frame buffer — only the newest sketch matters for
   * img2img, and it survives a reconnect so a stroke right after fal's idle
   * close isn't lost. */
  private pendingFrame: Buffer | null = null;

  /** Monotonic id stamped on each frame sent to fal. */
  private sentSeq = 0;
  /** FIFO of seqs sent to fal awaiting a result. Length 0 after a result is
   * matched ⇒ no newer sketch pending ⇒ queueEmpty (user paused). Mirrors the
   * pod's `latest_frame is None` check. Cleared on (re)connect. */
  private inFlightSeqs: number[] = [];

  private connectMs = 0;

  constructor(falKey: string, opts?: FalImageRelayOpts) {
    this.falKey = falKey;
    this.logger = opts?.logger;
    this.logContext = opts?.ctx ?? {};
    this.idleCloseMs = opts?.idleCloseMs ?? 0;
  }

  setLogContext(ctx: Record<string, unknown>): void {
    this.logContext = { ...this.logContext, ...ctx };
  }

  getLastPhaseTimings(): WireRelayPhaseTimings {
    return { upgradeMs: this.connectMs };
  }

  private log(level: 'info' | 'warn', event: string, extra?: Record<string, unknown>): void {
    const obj = { ...this.logContext, provider: 'fal', event, ...extra };
    this.logger?.[level](obj, event);
    Sentry.addBreadcrumb({ category: 'fal_relay', level: 'info', message: event, data: obj });
  }

  /** Lever A — LAZY CONNECT. Don't open the fal WS at wire time (drawing-open).
   * Opening a connection is what fal bills (~$0.06/~30s), so a user who opens a
   * drawing but never draws would pay for nothing. Instead we "arm": resolve
   * immediately without a socket; the first `sendFrame` opens it via the
   * existing lazy path in `flush()`. Result: open-but-don't-draw costs $0. */
  connect(): Promise<void> {
    this.log('info', 'fal.armed', {});
    return Promise.resolve();
  }

  private openSocket(args: { isReconnect: boolean }): Promise<void> {
    const start = Date.now();
    return new Promise<void>((resolve, reject) => {
      let settled = false;
      const ws = new WebSocket(FAL_REALTIME_URL, {
        perMessageDeflate: false,
        headers: { Authorization: `Key ${this.falKey}` },
      });

      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        try { ws.close(); } catch { /* swallow */ }
        reject(new Error('fal realtime connect timeout'));
      }, CONNECT_TIMEOUT_MS);

      ws.on('open', () => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        this.ws = ws;
        this.opened = true;
        this.connectMs = Date.now() - start;
        // A fresh connection has no carried-over in-flight work; old seqs from
        // a dropped socket will never return, so don't let them skew queueEmpty.
        this.inFlightSeqs = [];
        // First-ever open is the lazy first-frame open (Lever A); later ones are
        // reconnects after idle-close / drop. Label by everOpened, not the arg.
        const event = !this.everOpened
          ? 'fal.lazy_first_open'
          : args.isReconnect
            ? 'fal.reconnected'
            : 'fal.connected';
        this.everOpened = true;
        this.log('info', event, { connectMs: this.connectMs });
        resolve();
      });

      ws.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
        this.handleUpstreamMessage(data as Buffer, isBinary);
      });

      ws.on('close', (code: number, reason: Buffer) => {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          reject(new Error(`fal realtime closed before open (code=${code})`));
          return;
        }
        this.handleUpstreamClose(code, reason?.toString('utf-8') ?? '');
      });

      ws.on('error', (err: Error) => {
        if (!settled) {
          settled = true;
          clearTimeout(timeout);
          reject(err);
          return;
        }
        // Post-open error: log; the 'close' that follows drives reconnect.
        this.log('warn', 'fal.error', { err: err.message });
        this.errorHandler?.(err);
      });
    });
  }

  private handleUpstreamMessage(data: Buffer, isBinary: boolean): void {
    if (!this.opened) return;
    if (isBinary) {
      let decoded: { images?: Array<{ content?: unknown }> } | undefined;
      try {
        decoded = this.packr.unpack(data) as typeof decoded;
      } catch (err) {
        this.log('warn', 'fal.decode_failed', { err: (err as Error).message });
        return;
      }
      const content = decoded?.images?.[0]?.content;
      if (!(content instanceof Uint8Array)) {
        this.log('warn', 'fal.no_image_in_message', {
          keys: decoded ? Object.keys(decoded).join(',') : null,
        });
        return;
      }
      const jpeg = Buffer.isBuffer(content) ? content : Buffer.from(content);

      // Match this result to the oldest outstanding send (FIFO; fal returns
      // one result per input at our ~2 FPS cadence). queueEmpty ⇔ nothing
      // newer is still pending after removing it — same semantics as the pod.
      this.inFlightSeqs.shift();
      const queueEmpty = this.inFlightSeqs.length === 0;

      // Synthesize the frame_meta the downstream code expects, THEN the binary.
      // stream.ts sniffs frame_meta → sets nextImageBinaryQueueEmpty → the
      // following binary forwards as {type:'frame'} and fires the video trigger.
      this.messageHandler?.(
        JSON.stringify({ type: 'frame_meta', requestId: null, queueEmpty }),
        false,
      );
      this.messageHandler?.(jpeg, true);
      return;
    }

    // Text control frame (JSON). fal sends idle/timeout + error notices here.
    const text = data.toString('utf-8');
    let parsed: Record<string, unknown> | null = null;
    try {
      parsed = JSON.parse(text) as Record<string, unknown>;
    } catch {
      return; // opaque non-JSON control; ignore
    }
    const type = parsed['type'];
    const errStr = `${parsed['error'] ?? ''} ${parsed['reason'] ?? ''}`;
    if (type === 'x-fal-error' || /TIMEOUT|no inputs/i.test(errStr)) {
      // Idle timeout / "reconnect when needed" — expected when the user pauses
      // drawing. Swallow (do NOT surface to the iPad as an error); the close
      // that follows triggers a lazy reconnect on the next stroke.
      this.log('info', 'fal.idle_notice', { error: parsed['error'] ?? null });
      return;
    }
    // Other control messages (x-fal-message etc.) — ignore silently.
  }

  private handleUpstreamClose(code: number, reason: string): void {
    this.opened = false;
    this.ws = null;
    this.clearIdleTimer();
    if (this.closedByUs) return;
    // Never call closeHandler: there's no pod to replace, and stream.ts's
    // handleUpstreamClose would kick a RunPod replaceSession. fal closes are
    // expected (our idle-close, fal's ~30s timeout, or a transient drop) —
    // recover by reconnecting on the next frame.
    const wasIdleClose = this.idleClosed;
    this.idleClosed = false;
    this.log('info', wasIdleClose ? 'fal.idle_closed' : 'fal.upstream_closed', { code, reason });
    if (this.pendingFrame) {
      // A stroke is already waiting (user kept drawing through the drop) —
      // reconnect now rather than waiting for the next sendFrame. (Won't happen
      // on an idle-close: we only idle-close when pendingFrame is null.)
      void this.reconnectAndFlush();
    }
  }

  // ─── Lever B: proactive idle-close ──────────────────────────────────────
  // Arm a timer after each frame is sent; if no new frame arrives within
  // idleCloseMs, close the fal WS ourselves (instead of paying for the runner
  // until fal's ~30s idle timeout). The next stroke reopens via the lazy path.
  private armIdleTimer(): void {
    this.clearIdleTimer();
    if (this.idleCloseMs <= 0) return;
    this.idleTimer = setTimeout(() => this.idleClose(), this.idleCloseMs);
    this.idleTimer.unref?.();
  }

  private clearIdleTimer(): void {
    if (this.idleTimer) {
      clearTimeout(this.idleTimer);
      this.idleTimer = null;
    }
  }

  private idleClose(): void {
    this.idleTimer = null;
    if (!this.opened || !this.ws) return;
    // Never close mid-generation: a result is still expected (and it carries the
    // queueEmpty:true frame_meta that fires the video idle-state animation).
    // Re-arm and wait for the queue to drain.
    if (this.inFlightSeqs.length > 0 || this.pendingFrame) {
      this.armIdleTimer();
      return;
    }
    // Mark as our idle-close (NOT closedByUs — that would block reconnect).
    // handleUpstreamClose logs it and leaves the relay reconnectable.
    this.idleClosed = true;
    try { this.ws.close(); } catch { /* swallow */ }
  }

  private async reconnectAndFlush(): Promise<void> {
    if (this.reconnecting || this.opened || this.closedByUs) return;
    this.reconnecting = true;
    try {
      await this.openSocket({ isReconnect: true });
      this.reconnecting = false;
      this.flush();
    } catch (err) {
      this.reconnecting = false;
      this.log('warn', 'fal.reconnect_failed', { err: (err as Error).message });
      // Leave pendingFrame set; the next sendFrame retries.
    }
  }

  sendConfig(payload: Record<string, unknown>): void {
    // Map the iPad's config message (prompt/steps/seed + optional fal knobs)
    // onto fal's input params. Unknown keys are ignored. `steps` is the
    // existing iPad field; `num_inference_steps` lets the fal params be set
    // directly from SettingsPanel later.
    const next = { ...this.params };
    if (typeof payload['prompt'] === 'string') next['prompt'] = payload['prompt'];
    const steps = payload['num_inference_steps'] ?? payload['steps'];
    if (typeof steps === 'number' && Number.isFinite(steps)) {
      next['num_inference_steps'] = Math.max(1, Math.min(8, Math.trunc(steps)));
    }
    if (typeof payload['schedule_mu'] === 'number') next['schedule_mu'] = payload['schedule_mu'];
    if (typeof payload['output_feedback_strength'] === 'number') {
      next['output_feedback_strength'] = payload['output_feedback_strength'];
    }
    if (typeof payload['image_size'] === 'string') next['image_size'] = payload['image_size'];
    if (typeof payload['enable_interpolation'] === 'boolean') {
      next['enable_interpolation'] = payload['enable_interpolation'];
    }
    if (typeof payload['seed'] === 'number' && Number.isFinite(payload['seed'])) {
      next['seed'] = Math.trunc(payload['seed']);
    }
    this.params = next;
  }

  sendFrame(jpeg: Buffer): void {
    this.pendingFrame = jpeg; // latest-wins
    this.flush();
  }

  private flush(): void {
    if (!this.pendingFrame) return;
    if (!this.opened || this.ws?.readyState !== WebSocket.OPEN) {
      if (!this.reconnecting && !this.closedByUs) void this.reconnectAndFlush();
      return;
    }
    const jpeg = this.pendingFrame;
    this.pendingFrame = null;
    const dataUri = `data:image/jpeg;base64,${jpeg.toString('base64')}`;
    const seq = ++this.sentSeq;
    this.inFlightSeqs.push(seq);
    const msg = { ...this.params, image_url: dataUri, sync_mode: true };
    try {
      this.ws.send(this.packr.pack(msg));
      this.armIdleTimer(); // Lever B: (re)start the no-new-frame countdown
    } catch (err) {
      this.log('warn', 'fal.send_failed', { err: (err as Error).message });
      this.inFlightSeqs.pop();
      this.pendingFrame = jpeg; // put it back; retry on next tick/reconnect
    }
  }

  onMessage(cb: (data: Buffer | string, isBinary: boolean) => void): void {
    this.messageHandler = cb;
  }

  onClose(_cb: (code: number, reason: string) => void): void {
    // Intentionally a no-op. fal upstream closes (idle TIMEOUT or transient
    // drop) are recovered internally via lazy reconnect — there's no pod to
    // replace. Propagating to stream.ts's handleUpstreamClose would wrongly
    // kick a RunPod replaceSession. Accepted only for ImageRelay compatibility.
  }

  onError(cb: (err: Error) => void): void {
    this.errorHandler = cb;
  }

  close(): void {
    this.closedByUs = true;
    this.opened = false;
    this.clearIdleTimer();
    if (this.ws) {
      try { this.ws.close(); } catch { /* swallow */ }
      this.ws = null;
    }
  }
}

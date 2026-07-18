import type { IncomingMessage } from 'http';
import type { Socket } from 'net';

import WebSocket from 'ws';
import * as Sentry from '@sentry/node';

/**
 * WebSocket relay to a single upstream URL.
 *
 * Lifecycle:
 *   1. caller registers handlers via `onMessage` / `onClose` / `onError`
 *   2. caller awaits `connect()`
 *   3. on success, the relay proxies frames until either side closes
 *   4. on failure, `connect()` rejects with `WireRelayError` (structured —
 *      includes kind, phase timings, HTTP response info if any) and the
 *      user-supplied handlers are NEVER invoked. Pre-open events only flow
 *      through the connect promise.
 *
 * The pre-open gate matters because `onClose` typically runs
 * preemption/replacement logic that is meaningless for a socket that never
 * opened. Invoking it on a pre-open close has caused user-visible races where
 * the close handler outraced the connect() catch block and closed the client
 * with a misleading status (see incident 2026-04-18).
 */

/** Phase timings captured from the underlying TCP/TLS socket events.
 *  Filled progressively; fields may be undefined if the connection didn't
 *  reach that stage (e.g. a DNS failure leaves tcpMs/tlsMs unset).
 *  Captured on both success and failure paths so failure timings are
 *  interpretable against a baseline distribution. */
export interface WireRelayPhaseTimings {
  dnsMs?: number;
  tcpMs?: number;
  tlsMs?: number;
  upgradeMs?: number;
}

/** Subset of HTTP response headers we capture on `'unexpected-response'`.
 *  Cherry-picked for diagnostic value: `cf-ray` identifies a Cloudflare-style
 *  proxy hop; `server` distinguishes Uvicorn from a proxy. */
export interface RelevantHttpHeaders {
  'cf-ray'?: string;
  server?: string;
  'content-type'?: string;
}

/** Structured failure information surfaced by `connect()`'s rejection.
 *
 * Replaces the previous opaque `Error.message` string. The caller in
 * `routes/stream.ts`'s `wire_relay_failed` log emits these fields directly
 * — no regex parsing, no inference from the human-readable message. */
export class WireRelayError extends Error {
  /** Discriminator. Each kind populates a different subset of fields. */
  readonly kind:
    | 'timeout' // 10s elapsed without 'open' or any other terminal event
    | 'preopen_close' // server closed the WS before sending the 101 upgrade
    | 'unexpected_response' // server returned a non-101 HTTP response (5xx etc.)
    | 'socket_error'; // lower-level socket error (ECONNREFUSED, ECONNRESET, ENOTFOUND, ...)
  readonly elapsedMs: number;
  readonly phaseTimings: WireRelayPhaseTimings;
  readonly wsCode?: number;
  readonly httpStatus?: number;
  readonly httpHeaders?: RelevantHttpHeaders;
  /** Truncated body of the unexpected-response (max 512 bytes). Often
   *  carries a FastAPI traceback or a proxy error page — the actual content
   *  that distinguishes "the proxy returned an error" from "the pod returned
   *  an error." */
  readonly httpBodySample?: string;
  readonly errno?: string; // e.g. ECONNREFUSED, ECONNRESET, ENOTFOUND, EAI_AGAIN
  readonly syscall?: string;

  constructor(args: {
    kind: WireRelayError['kind'];
    message: string;
    elapsedMs: number;
    phaseTimings: WireRelayPhaseTimings;
    wsCode?: number;
    httpStatus?: number;
    httpHeaders?: RelevantHttpHeaders;
    httpBodySample?: string;
    errno?: string;
    syscall?: string;
  }) {
    super(args.message);
    this.name = 'WireRelayError';
    this.kind = args.kind;
    this.elapsedMs = args.elapsedMs;
    this.phaseTimings = args.phaseTimings;
    this.wsCode = args.wsCode;
    this.httpStatus = args.httpStatus;
    this.httpHeaders = args.httpHeaders;
    this.httpBodySample = args.httpBodySample;
    this.errno = args.errno;
    this.syscall = args.syscall;
  }
}

const RELEVANT_HEADER_KEYS: ReadonlyArray<keyof RelevantHttpHeaders> = [
  'cf-ray',
  'server',
  'content-type',
];

function pickHeaders(rawHeaders: Record<string, string | string[] | undefined> | undefined): RelevantHttpHeaders | undefined {
  if (!rawHeaders) return undefined;
  const out: RelevantHttpHeaders = {};
  let any = false;
  for (const key of RELEVANT_HEADER_KEYS) {
    const v = rawHeaders[key];
    if (v !== undefined) {
      out[key] = Array.isArray(v) ? v.join(', ') : v;
      any = true;
    }
  }
  return any ? out : undefined;
}

interface NodeError extends Error {
  code?: string;
  errno?: string | number;
  syscall?: string;
}

export class StreamRelay {
  private upstream: WebSocket | null = null;
  private opened = false;
  private readonly url: string;
  /** Phase timings captured during the most recent connect(). Caller can
   *  read after `connect()` resolves (success path) or from a thrown
   *  WireRelayError (failure path). Updated in-place by socket event
   *  listeners. */
  private lastPhaseTimings: WireRelayPhaseTimings = {};

  private messageHandler: ((data: Buffer | string, isBinary: boolean) => void) | null = null;
  private closeHandler: ((code: number, reason: string) => void) | null = null;
  private errorHandler: ((err: Error) => void) | null = null;

  /** Optional diagnostic context; set by the caller via `setLogContext()` so
   * relay-internal logs can be cross-referenced with stream.ts session logs. */
  private logContext: Record<string, unknown> = {};

  /** PEM of the fleet's self-signed cert to PIN (chain verified against
   * exactly this cert; hostname check skipped — instances are bare IPs). */
  private tlsCa: string | null = null;

  constructor(url: string, opts?: { tlsCa?: string | null }) {
    this.url = url;
    this.tlsCa = opts?.tlsCa ?? null;
  }

  /** Attach context (e.g. { connId, userId, role: 'image' }) included in
   * every Sentry breadcrumb emitted from this relay. Diagnostics-only. */
  setLogContext(ctx: Record<string, unknown>): void {
    this.logContext = ctx;
  }

  /** Phase timings from the most recent connect() — read by the caller
   *  to emit on the wire_relay_open success log. Failure path receives
   *  these via the thrown WireRelayError. */
  getLastPhaseTimings(): WireRelayPhaseTimings {
    return { ...this.lastPhaseTimings };
  }

  private breadcrumb(message: string, data: Record<string, unknown>): void {
    Sentry.addBreadcrumb({
      category: 'relay',
      level: 'info',
      message,
      data: { ...this.logContext, url: this.url, ...data },
    });
  }

  connect(): Promise<WebSocket> {
    const connectStart = Date.now();
    this.lastPhaseTimings = {};
    this.breadcrumb('connect: start', {});

    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url, {
        perMessageDeflate: false,
        ...(this.tlsCa
          ? {
              ca: [this.tlsCa],
              // Pinning, not PKI: trust exactly our cert, ignore that the
              // peer presents an IP instead of the cert's CN. (false = no
              // error, per ws's checkServerIdentity typing.)
              checkServerIdentity: () => false,
            }
          : {}),
      });
      let settled = false;

      const settle = (
        outcome: 'open' | { error: WireRelayError },
      ): void => {
        if (settled) return;
        settled = true;
        clearTimeout(timeout);
        if (outcome === 'open') {
          this.opened = true;
          this.upstream = ws;
          resolve(ws);
        } else {
          // Force-close the underlying socket to free fds even if the
          // upstream is still partially-connected (e.g. on timeout).
          try { ws.close(); } catch { /* swallow */ }
          reject(outcome.error);
        }
      };

      // Hook the underlying TCP/TLS socket as soon as ws creates it. The
      // events fire in order: 'lookup' (DNS) → 'connect' (TCP handshake) →
      // 'secureConnect' (TLS handshake, only for wss://) → 'upgrade' (101).
      // Each captures elapsedMs from connectStart so we can later compute
      // per-stage durations.
      //
      // Note: `ws._socket` is internal API but the `ws` library exposes it
      // and it's the only way to observe these events. The lookup/connect/
      // secureConnect events fire on the raw socket *before* ws emits
      // 'open'. If anything throws while wiring these up, we just lose
      // the timing data — the connect itself isn't affected.
      const wsAny = ws as unknown as { _socket?: Socket };
      const wireSocketTiming = (): void => {
        const socket = wsAny._socket;
        if (!socket) return;
        socket.once('lookup', () => {
          this.lastPhaseTimings.dnsMs = Date.now() - connectStart;
        });
        socket.once('connect', () => {
          this.lastPhaseTimings.tcpMs = Date.now() - connectStart;
        });
        socket.once('secureConnect', () => {
          this.lastPhaseTimings.tlsMs = Date.now() - connectStart;
        });
      };
      // _socket may not exist immediately; nextTick is enough for ws to
      // create it. Defensive: also re-try at 0ms in case the library lazy-
      // initializes on a later tick.
      process.nextTick(wireSocketTiming);
      setTimeout(wireSocketTiming, 0);

      const timeout = setTimeout(() => {
        const elapsedMs = Date.now() - connectStart;
        this.breadcrumb('connect: timeout', { elapsedMs });
        settle({
          error: new WireRelayError({
            kind: 'timeout',
            message: 'Upstream connection timeout',
            elapsedMs,
            phaseTimings: { ...this.lastPhaseTimings },
          }),
        });
      }, 10_000);

      ws.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
        if (!this.opened) return;
        if (this.messageHandler) {
          const payload = isBinary ? (data as Buffer) : (data as Buffer).toString('utf-8');
          this.messageHandler(payload, isBinary);
        }
      });

      ws.on('close', (code: number, reason: Buffer) => {
        const elapsedMs = Date.now() - connectStart;
        if (!this.opened) {
          this.breadcrumb('connect: pre-open close', {
            code,
            reason: reason.toString('utf-8'),
            elapsedMs,
          });
          settle({
            error: new WireRelayError({
              kind: 'preopen_close',
              message: `Upstream closed before open (code=${code})`,
              elapsedMs,
              phaseTimings: { ...this.lastPhaseTimings },
              wsCode: code,
            }),
          });
          return;
        }
        this.breadcrumb('post-open close', {
          code,
          reason: reason.toString('utf-8'),
        });
        this.closeHandler?.(code, reason.toString('utf-8'));
      });

      // 'unexpected-response' fires when the server returns a non-101 HTTP
      // response to our upgrade request (e.g. 502 from a proxy that couldn't
      // reach the pod, 500 from a FastAPI handler crash). Without this
      // listener the ws library would emit a generic error and we'd lose
      // the entire HTTP response — status code, headers, body all gone.
      // This is the single highest-signal addition: a 5xx with a `cf-ray`
      // header points at the proxy; a 5xx with a `server: uvicorn` header
      // points at the pod itself; the body sample often contains the
      // FastAPI traceback that names the failing route.
      ws.on(
        'unexpected-response',
        (
          _request: unknown,
          response: IncomingMessage,
        ) => {
          const elapsedMs = Date.now() - connectStart;
          const httpStatus = response.statusCode ?? 0;
          const headers = pickHeaders(response.headers);

          // Drain a small body sample (max 512 bytes) for diagnostic
          // detail. We cap explicitly to avoid retaining a large response
          // and because the response is being discarded — we don't need
          // the full body, just enough to read a server identifier or a
          // FastAPI traceback's first line.
          const chunks: Buffer[] = [];
          let total = 0;
          const MAX_SAMPLE = 512;
          response.on('data', (chunk: Buffer) => {
            const remaining = MAX_SAMPLE - total;
            if (remaining <= 0) return;
            const slice = chunk.length > remaining ? chunk.subarray(0, remaining) : chunk;
            chunks.push(slice);
            total += slice.length;
          });
          const finalize = (): void => {
            const sample = chunks.length > 0 ? Buffer.concat(chunks).toString('utf-8') : undefined;
            this.breadcrumb('connect: unexpected-response', {
              elapsedMs,
              httpStatus,
              headers,
            });
            settle({
              error: new WireRelayError({
                kind: 'unexpected_response',
                message: `Upstream returned HTTP ${httpStatus} (not 101)`,
                elapsedMs,
                phaseTimings: { ...this.lastPhaseTimings },
                httpStatus,
                httpHeaders: headers,
                httpBodySample: sample,
              }),
            });
          };
          response.once('end', finalize);
          response.once('error', finalize);
          // Some proxies close the connection without sending 'end' on a
          // 5xx. Defensive: if 200ms elapses with no body activity, finalize
          // anyway so we don't hold the promise forever.
          setTimeout(finalize, 200);
        },
      );

      ws.on('error', (err: Error) => {
        if (this.opened) {
          this.errorHandler?.(err);
          return;
        }
        const elapsedMs = Date.now() - connectStart;
        const nodeErr = err as NodeError;
        const errno = typeof nodeErr.code === 'string' ? nodeErr.code : undefined;
        const syscall = typeof nodeErr.syscall === 'string' ? nodeErr.syscall : undefined;
        this.breadcrumb('connect: pre-open error', {
          err: err.message,
          errno,
          syscall,
          elapsedMs,
        });
        settle({
          error: new WireRelayError({
            kind: 'socket_error',
            message: err.message,
            elapsedMs,
            phaseTimings: { ...this.lastPhaseTimings },
            errno,
            syscall,
          }),
        });
      });

      ws.on('upgrade', () => {
        // 101 Switching Protocols received — the WS handshake succeeded at
        // the HTTP layer. 'open' fires immediately after this once ws
        // finishes its internal state transition.
        this.lastPhaseTimings.upgradeMs = Date.now() - connectStart;
      });

      ws.on('open', () => {
        const elapsedMs = Date.now() - connectStart;
        this.breadcrumb('connect: open', { elapsedMs });
        settle('open');
      });
    });
  }

  sendConfig(configPayload: Record<string, unknown>): void {
    if (this.upstream?.readyState === WebSocket.OPEN) {
      this.upstream.send(JSON.stringify(configPayload));
    }
  }

  sendFrame(jpegData: Buffer): void {
    if (this.upstream?.readyState === WebSocket.OPEN) {
      this.upstream.send(jpegData);
    }
  }

  onMessage(callback: (data: Buffer | string, isBinary: boolean) => void): void {
    this.messageHandler = callback;
  }

  onClose(callback: (code: number, reason: string) => void): void {
    this.closeHandler = callback;
  }

  onError(callback: (err: Error) => void): void {
    this.errorHandler = callback;
  }

  close(): void {
    if (this.upstream) {
      this.upstream.close();
      this.upstream = null;
    }
  }
}

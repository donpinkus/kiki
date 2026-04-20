import WebSocket from 'ws';

/**
 * WebSocket relay to a single upstream URL.
 *
 * Lifecycle:
 *   1. caller registers handlers via `onMessage` / `onClose` / `onError`
 *   2. caller awaits `connect()`
 *   3. on success, the relay proxies frames until either side closes
 *   4. on failure, `connect()` rejects and the user-supplied handlers are
 *      NEVER invoked — pre-open events only flow through the connect promise
 *
 * The pre-open gate matters because `onClose` typically runs
 * preemption/replacement logic that is meaningless for a socket that never
 * opened. Invoking it on a pre-open close has caused user-visible races where
 * the close handler outraced the connect() catch block and closed the client
 * with a misleading status (see incident 2026-04-18).
 */
export class StreamRelay {
  private upstream: WebSocket | null = null;
  private opened = false;
  private readonly url: string;

  private messageHandler: ((data: Buffer | string, isBinary: boolean) => void) | null = null;
  private closeHandler: ((code: number, reason: string) => void) | null = null;
  private errorHandler: ((err: Error) => void) | null = null;

  // Single-slot frame buffer: drops stale frames when the upstream socket
  // has backpressure, so the pod always processes the latest sketch.
  private pendingFrame: Buffer | null = null;
  private drainScheduled = false;

  constructor(url: string) {
    this.url = url;
  }

  connect(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url, { perMessageDeflate: false });
      let settled = false;
      const timeout = setTimeout(() => {
        if (settled) return;
        settled = true;
        ws.close();
        reject(new Error('Upstream connection timeout'));
      }, 10_000);

      ws.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
        if (!this.opened) return;
        if (this.messageHandler) {
          const payload = isBinary ? (data as Buffer) : (data as Buffer).toString('utf-8');
          this.messageHandler(payload, isBinary);
        }
      });

      ws.on('close', (code: number, reason: Buffer) => {
        if (!this.opened) {
          // Pre-open close — reject connect() if it hasn't already settled.
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          reject(new Error(`Upstream closed before open (code=${code})`));
          return;
        }
        this.closeHandler?.(code, reason.toString('utf-8'));
      });

      ws.on('error', (err: Error) => {
        if (!this.opened) {
          if (settled) return;
          settled = true;
          clearTimeout(timeout);
          reject(err);
          return;
        }
        this.errorHandler?.(err);
      });

      ws.on('open', () => {
        this.opened = true;
        settled = true;
        clearTimeout(timeout);
        this.upstream = ws;
        resolve(ws);
      });
    });
  }

  sendConfig(configPayload: Record<string, unknown>): void {
    if (this.upstream?.readyState === WebSocket.OPEN) {
      this.upstream.send(JSON.stringify(configPayload));
    }
  }

  /**
   * Send a sketch frame to the upstream pod. Uses a single-slot buffer:
   * if the previous send hasn't completed (socket backpressure), the new
   * frame replaces it so the pod always gets the latest sketch. Without
   * this, WebSocket buffering causes a queue of stale frames that the pod
   * processes sequentially, creating visible lag.
   */
  sendFrame(jpegData: Buffer): void {
    if (this.upstream?.readyState !== WebSocket.OPEN) return;
    // bufferedAmount > 0 means the previous send is still in the kernel
    // buffer — the pod hasn't read it yet. Drop it by replacing with the
    // latest frame. We can't un-send what's already in the buffer, but
    // we can skip sending more data until it drains.
    if (this.upstream.bufferedAmount > 0) {
      this.pendingFrame = jpegData;
      if (!this.drainScheduled) {
        this.drainScheduled = true;
        this.upstream.once('drain', () => {
          this.drainScheduled = false;
          if (this.pendingFrame) {
            const frame = this.pendingFrame;
            this.pendingFrame = null;
            this.sendFrame(frame);
          }
        });
      }
      return;
    }
    this.pendingFrame = null;
    this.upstream.send(jpegData);
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

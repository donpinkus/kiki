import WebSocket from 'ws';

export interface StreamConfig {
  type: 'config';
  prompt?: string;
  strength?: number;
  width?: number;
  height?: number;
}

/**
 * Manages a WebSocket connection to the upstream StreamDiffusion server.
 * Acts as a relay: forwards binary frames (JPEG) and text frames (config) bidirectionally.
 */
export class StreamDiffusionRelay {
  private upstream: WebSocket | null = null;
  private readonly url: string;

  // Callbacks registered before connect — attached to the socket immediately on open
  private messageHandler: ((data: Buffer | string) => void) | null = null;
  private closeHandler: ((code: number, reason: string) => void) | null = null;
  private errorHandler: ((err: Error) => void) | null = null;

  constructor(url: string) {
    this.url = url;
  }

  /**
   * Open a connection to the upstream StreamDiffusion server.
   * Event handlers registered via onMessage/onClose/onError before calling connect()
   * are attached immediately, avoiding race conditions.
   */
  connect(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error('Upstream connection timeout'));
      }, 10_000);

      // Register handlers immediately on the socket (before 'open' fires)
      // so no events are missed between open and handler registration.
      ws.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
        if (this.messageHandler) {
          if (isBinary) {
            this.messageHandler(data as Buffer);
          } else {
            this.messageHandler((data as Buffer).toString('utf-8'));
          }
        }
      });

      ws.on('close', (code: number, reason: Buffer) => {
        if (this.closeHandler) {
          this.closeHandler(code, reason.toString('utf-8'));
        }
      });

      ws.on('error', (err: Error) => {
        if (this.errorHandler) {
          this.errorHandler(err);
        }
      });

      ws.on('open', () => {
        clearTimeout(timeout);
        this.upstream = ws;
        resolve(ws);
      });

      // Also handle pre-open errors (connection refused, DNS failure, etc.)
      ws.once('error', (err: Error) => {
        clearTimeout(timeout);
        reject(err);
      });
    });
  }

  sendConfig(config: StreamConfig): void {
    if (this.upstream?.readyState === WebSocket.OPEN) {
      this.upstream.send(JSON.stringify(config));
    }
  }

  sendFrame(jpegData: Buffer): void {
    if (this.upstream?.readyState === WebSocket.OPEN) {
      this.upstream.send(jpegData);
    }
  }

  onMessage(callback: (data: Buffer | string) => void): void {
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

  get isConnected(): boolean {
    return this.upstream?.readyState === WebSocket.OPEN;
  }
}

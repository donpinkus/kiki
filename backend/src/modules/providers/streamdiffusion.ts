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

  constructor(url: string) {
    this.url = url;
  }

  /**
   * Open a connection to the upstream StreamDiffusion server.
   * Resolves when the connection is established or rejects on error/timeout.
   */
  connect(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url);
      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error('Upstream connection timeout'));
      }, 10_000);

      ws.on('open', () => {
        clearTimeout(timeout);
        this.upstream = ws;
        resolve(ws);
      });

      ws.on('error', (err: Error) => {
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
    this.upstream?.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
      if (isBinary) {
        callback(data as Buffer);
      } else {
        callback((data as Buffer).toString('utf-8'));
      }
    });
  }

  onClose(callback: (code: number, reason: string) => void): void {
    this.upstream?.on('close', (code: number, reason: Buffer) => {
      callback(code, reason.toString('utf-8'));
    });
  }

  onError(callback: (err: Error) => void): void {
    this.upstream?.on('error', callback);
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

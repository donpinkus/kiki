import type { FastifyPluginAsync } from 'fastify';
import WebSocket from 'ws';
import { config } from '../config/index.js';

/**
 * WebSocket relay to upstream FLUX.2-klein server.
 * Forwards binary frames (JPEG) and text frames (config) bidirectionally.
 */
class StreamRelay {
  private upstream: WebSocket | null = null;
  private readonly url: string;

  private messageHandler: ((data: Buffer | string, isBinary: boolean) => void) | null = null;
  private closeHandler: ((code: number, reason: string) => void) | null = null;
  private errorHandler: ((err: Error) => void) | null = null;

  constructor(url: string) {
    this.url = url;
  }

  connect(): Promise<WebSocket> {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(this.url, { perMessageDeflate: false });
      const timeout = setTimeout(() => {
        ws.close();
        reject(new Error('Upstream connection timeout'));
      }, 10_000);

      ws.on('message', (data: WebSocket.RawData, isBinary: boolean) => {
        if (this.messageHandler) {
          const payload = isBinary ? (data as Buffer) : (data as Buffer).toString('utf-8');
          this.messageHandler(payload, isBinary);
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

      ws.once('error', (err: Error) => {
        clearTimeout(timeout);
        reject(err);
      });
    });
  }

  sendConfig(config: Record<string, unknown>): void {
    if (this.upstream?.readyState === WebSocket.OPEN) {
      this.upstream.send(JSON.stringify(config));
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

export const streamRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/stream', { websocket: true }, (socket, request) => {
    if (!config.FLUX_KLEIN_URL) {
      request.log.error('FLUX_KLEIN_URL not configured');
      socket.send(JSON.stringify({
        type: 'error',
        message: 'Stream server not configured',
      }));
      socket.close(1011, 'Server not configured');
      return;
    }

    const clientId = Math.random().toString(36).slice(2, 8);
    request.log.info({ clientId }, 'Stream client connected');

    const relay = new StreamRelay(config.FLUX_KLEIN_URL);

    relay.onMessage((data, isBinary) => {
      if (socket.readyState === socket.OPEN) {
        if (isBinary) {
          const base64 = (data as Buffer).toString('base64');
          socket.send(JSON.stringify({ type: 'frame', data: base64 }));
        } else {
          socket.send(data);
        }
      }
    });

    relay.onClose((code, reason) => {
      request.log.info({ clientId, code, reason }, 'Upstream closed');
      if (socket.readyState === socket.OPEN) {
        socket.send(JSON.stringify({ type: 'error', message: 'Upstream connection lost' }));
        socket.close(1001, 'Upstream closed');
      }
    });

    relay.onError((err) => {
      request.log.error({ clientId, err }, 'Upstream error');
    });

    relay.connect()
      .then(() => {
        request.log.info({ clientId }, 'Upstream connected');

        socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
          const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
          if (isBinary) {
            relay.sendFrame(buf);
          } else {
            const text = buf.toString('utf-8');
            try {
              const parsed = JSON.parse(text);
              if (parsed.type === 'config') {
                relay.sendConfig(parsed);
              }
            } catch {
              request.log.warn({ clientId }, 'Invalid JSON from client');
            }
          }
        });
      })
      .catch((err: unknown) => {
        request.log.error({ clientId, err }, 'Failed to connect to upstream');
        socket.send(JSON.stringify({
          type: 'error',
          message: `Cannot connect to stream server: ${err instanceof Error ? err.message : String(err)}`,
        }));
        socket.close(1011, 'Upstream unavailable');
      });

    socket.on('close', () => {
      request.log.info({ clientId }, 'Stream client disconnected');
      relay.close();
    });

    socket.on('error', (err: Error) => {
      request.log.error({ clientId, err }, 'Client socket error');
      relay.close();
    });
  });
};

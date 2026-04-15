import type { FastifyPluginAsync } from 'fastify';
import WebSocket from 'ws';
import { getOrProvisionPod, touch, sessionClosed } from '../modules/orchestrator/orchestrator.js';

/**
 * WebSocket relay to a per-session FLUX.2-klein pod.
 *
 * Client connects with `?session=<uuid>`. If the session doesn't have a
 * running pod, we provision one (blocking the client WebSocket with status
 * messages for ~3–5 min). Once ready, we relay frames bidirectionally and
 * touch the session on every frame so the idle reaper can distinguish active
 * from abandoned sessions.
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

function extractSessionId(rawUrl: string | undefined): string | null {
  if (!rawUrl) return null;
  try {
    const url = new URL(rawUrl, 'http://placeholder');
    return url.searchParams.get('session');
  } catch {
    return null;
  }
}

export const streamRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/stream', { websocket: true }, (socket, request) => {
    const sessionId = extractSessionId(request.url);
    if (!sessionId) {
      socket.send(JSON.stringify({ type: 'error', message: 'missing session query param' }));
      socket.close(1008, 'missing session');
      return;
    }

    request.log.info({ sessionId }, 'Stream client connected');

    // Fire-and-forget async flow: provision, then proxy.
    void (async () => {
      let relay: StreamRelay | null = null;
      try {
        const { podUrl } = await getOrProvisionPod(sessionId, (msg) => {
          if (socket.readyState === socket.OPEN) {
            socket.send(
              JSON.stringify({ type: 'status', status: 'provisioning', message: msg }),
            );
          }
        });

        if (socket.readyState !== socket.OPEN) {
          request.log.info({ sessionId }, 'Client disconnected during provisioning');
          return;
        }

        relay = new StreamRelay(podUrl);

        relay.onMessage((data, isBinary) => {
          if (socket.readyState !== socket.OPEN) return;
          // Any upstream frame counts as activity (the pod is doing work for this user).
          touch(sessionId);
          if (isBinary) {
            const base64 = (data as Buffer).toString('base64');
            socket.send(JSON.stringify({ type: 'frame', data: base64 }));
          } else {
            socket.send(data);
          }
        });

        relay.onClose((code, reason) => {
          request.log.info({ sessionId, code, reason }, 'Upstream closed');
          if (socket.readyState === socket.OPEN) {
            socket.send(
              JSON.stringify({ type: 'error', message: 'Pod terminated (possible spot preemption)' }),
            );
            socket.close(1001, 'Upstream closed');
          }
        });

        relay.onError((err) => {
          request.log.error({ sessionId, err }, 'Upstream error');
        });

        await relay.connect();
        request.log.info({ sessionId }, 'Upstream connected, relaying');

        // Send a final "ready" status so the client can transition UI out of provisioning.
        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify({ type: 'status', status: 'ready' }));
        }

        // Capture a non-null local so the message handler closure doesn't
        // need non-null assertions on the outer-scoped `relay`.
        const activeRelay = relay;
        socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
          const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
          touch(sessionId);
          if (isBinary) {
            activeRelay.sendFrame(buf);
          } else {
            const text = buf.toString('utf-8');
            try {
              const parsed = JSON.parse(text);
              if (parsed.type === 'config') {
                activeRelay.sendConfig(parsed);
              }
            } catch {
              request.log.warn({ sessionId }, 'Invalid JSON from client');
            }
          }
        });
      } catch (err) {
        request.log.error({ sessionId, err }, 'Provisioning or relay failed');
        if (socket.readyState === socket.OPEN) {
          socket.send(
            JSON.stringify({
              type: 'error',
              message: `Provisioning failed: ${err instanceof Error ? err.message : String(err)}`,
            }),
          );
          socket.close(1011, 'Provisioning failed');
        }
      }

      socket.on('close', () => {
        request.log.info({ sessionId }, 'Stream client disconnected');
        sessionClosed(sessionId);
        relay?.close();
      });

      socket.on('error', (err: Error) => {
        request.log.error({ sessionId, err }, 'Client socket error');
        relay?.close();
      });
    })();
  });
};

import type { FastifyPluginAsync } from 'fastify';
import WebSocket from 'ws';

import { config } from '../config/index.js';
import { extractBearer } from '../modules/auth/index.js';
import { verifyAccess } from '../modules/auth/jwt.js';
import {
  getOrProvisionPod,
  touch,
  sessionClosed,
} from '../modules/orchestrator/orchestrator.js';
import {
  checkProvisionQuota,
  registerProvision,
  releaseActivePod,
} from '../modules/auth/rateLimiter.js';
import { checkEntitlement } from '../modules/entitlement/index.js';

/**
 * WebSocket relay to a per-user FLUX.2-klein pod.
 *
 * Identity resolution (in order):
 *   1. `Authorization: Bearer <jwt>` — preferred. Extracts userId from access
 *      token, subject to entitlement + rate-limit gates.
 *   2. `?session=<uuid>` legacy query param — accepted only when
 *      `AUTH_REQUIRED=false`. Skips auth/entitlement/rate-limit checks.
 *      Will be removed once the iOS client ships JWT auth.
 *
 * After identity is resolved, we provision (or reuse) a pod and relay frames
 * bidirectionally. `touch()` on every relayed frame keeps the idle reaper
 * honest.
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

function extractQueryParam(rawUrl: string | undefined, name: string): string | null {
  if (!rawUrl) return null;
  try {
    const url = new URL(rawUrl, 'http://placeholder');
    return url.searchParams.get(name);
  } catch {
    return null;
  }
}

interface Identity {
  userId: string;
  source: 'jwt' | 'legacy_session';
}

async function resolveIdentity(
  request: { url?: string; headers: { authorization?: string } },
): Promise<Identity | { error: string; code: number }> {
  // Try Bearer first.
  const token = extractBearer(request.headers.authorization);
  if (token) {
    try {
      const claims = await verifyAccess(token);
      return { userId: claims.sub, source: 'jwt' };
    } catch {
      return { error: 'invalid_token', code: 1008 };
    }
  }

  // Fallback to legacy ?session= if auth is not required yet.
  if (!config.AUTH_REQUIRED) {
    const sessionId = extractQueryParam(request.url, 'session');
    if (sessionId) {
      return { userId: sessionId, source: 'legacy_session' };
    }
  }

  return {
    error: config.AUTH_REQUIRED ? 'authentication_required' : 'missing_identity',
    code: 1008,
  };
}

export const streamRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/stream', { websocket: true }, (socket, request) => {
    void (async () => {
      const identity = await resolveIdentity({
        url: request.url,
        headers: { authorization: request.headers.authorization },
      });

      if ('error' in identity) {
        socket.send(JSON.stringify({ type: 'error', message: identity.error }));
        socket.close(identity.code, identity.error);
        return;
      }

      const { userId, source } = identity;
      request.log.info({ userId, source }, 'Stream client connected');

      // Entitlement check — only applies when authenticated via JWT. Legacy
      // sessions bypass entitlement to keep the old iPad binaries working
      // during the rollout window.
      if (source === 'jwt') {
        const entitlement = checkEntitlement(userId);
        if (!entitlement.allowed) {
          socket.send(
            JSON.stringify({
              type: 'error',
              code: entitlement.reason,
              message: 'Subscription required to continue',
            }),
          );
          socket.close(1008, entitlement.reason);
          return;
        }

        const quota = checkProvisionQuota(userId);
        if (!quota.allowed) {
          socket.send(
            JSON.stringify({
              type: 'error',
              code: quota.reason,
              message: 'Too many sessions — try again shortly',
              retryAfterSec: quota.retryAfterSec,
            }),
          );
          socket.close(1008, quota.reason ?? 'rate_limited');
          return;
        }
      }

      let relay: StreamRelay | null = null;
      let provisionRegistered = false;

      try {
        // Only count against the per-user quota for JWT-authed sessions.
        if (source === 'jwt') {
          registerProvision(userId);
          provisionRegistered = true;
        }

        const { podUrl } = await getOrProvisionPod(userId, (msg) => {
          if (socket.readyState === socket.OPEN) {
            socket.send(
              JSON.stringify({ type: 'status', status: 'provisioning', message: msg }),
            );
          }
        });

        if (socket.readyState !== socket.OPEN) {
          request.log.info({ userId }, 'Client disconnected during provisioning');
          return;
        }

        relay = new StreamRelay(podUrl);

        relay.onMessage((data, isBinary) => {
          if (socket.readyState !== socket.OPEN) return;
          touch(userId);
          if (isBinary) {
            const base64 = (data as Buffer).toString('base64');
            socket.send(JSON.stringify({ type: 'frame', data: base64 }));
          } else {
            socket.send(data);
          }
        });

        relay.onClose((code, reason) => {
          request.log.info({ userId, code, reason }, 'Upstream closed');
          if (socket.readyState === socket.OPEN) {
            socket.send(
              JSON.stringify({ type: 'error', message: 'Pod terminated (possible spot preemption)' }),
            );
            socket.close(1001, 'Upstream closed');
          }
        });

        relay.onError((err) => {
          request.log.error({ userId, err }, 'Upstream error');
        });

        await relay.connect();
        request.log.info({ userId }, 'Upstream connected, relaying');

        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify({ type: 'status', status: 'ready' }));
        }

        const activeRelay = relay;
        socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
          const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
          touch(userId);
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
              request.log.warn({ userId }, 'Invalid JSON from client');
            }
          }
        });
      } catch (err) {
        request.log.error({ userId, err }, 'Provisioning or relay failed');
        if (provisionRegistered) {
          releaseActivePod(userId);
          provisionRegistered = false;
        }
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
        request.log.info({ userId }, 'Stream client disconnected');
        sessionClosed(userId);
        if (provisionRegistered) {
          releaseActivePod(userId);
          provisionRegistered = false;
        }
        relay?.close();
      });

      socket.on('error', (err: Error) => {
        request.log.error({ userId, err }, 'Client socket error');
        relay?.close();
      });
    })();
  });
};

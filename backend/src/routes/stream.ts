import type { FastifyPluginAsync } from 'fastify';

import { config } from '../config/index.js';
import { extractBearer } from '../modules/auth/index.js';
import { verifyAccess } from '../modules/auth/jwt.js';
import {
  getOrProvisionPod,
  hasReadySession,
  replaceSession,
  abortSession,
  touch,
  sessionClosed,
  subscribe,
  emitState,
} from '../modules/orchestrator/orchestrator.js';
import { StreamRelay } from '../modules/relay/streamRelay.js';
import {
  checkProvisionQuota,
  recordProvision,
} from '../modules/auth/rateLimiter.js';
import { checkEntitlement } from '../modules/entitlement/index.js';
import { trackPodPreempted, trackPodRelayFailed, trackSessionClosed } from '../modules/analytics/index.js';

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
      // Skip rate limiting if the user is reconnecting to an existing pod
      // (ready, provisioning, or replacing). Only apply rate limits + register
      // provision for genuinely new provisions.
      const isReconnect = await hasReadySession(userId);

      if (source === 'jwt' && !isReconnect) {
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

        const quota = await checkProvisionQuota(userId);
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
      let currentPodUrl: string | null = null;
      let lastConfig: Record<string, unknown> | null = null;
      let clientDisconnected = false;
      const sessionStartMs = Date.now();

      // Subscribe to provision state events so the iOS client sees every
      // transition — fresh caller AND joiner both go through this single path.
      // The broker seeds the handler with the current Redis state (if any),
      // then forwards every subsequent transition.
      //
      // On state='terminated' (e.g. idle reaper), we also close the iPad WS
      // cleanly with code 1000. This sets clientDisconnected via the existing
      // socket.on('close') handler — so when the upstream pod is killed next
      // and relay.onClose fires, the recovery path's clientDisconnected check
      // returns early. iPad sees a clean close + the terminated state event
      // (with failureCategory) instead of a "Recovery failed" error bounce.
      const unsubscribeState = await subscribe(userId, (event) => {
        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify({ type: 'state', ...event }));
          if (event.state === 'terminated') {
            socket.close(1000, event.failureCategory ?? 'session_ended');
          }
        }
      });

      // Wire a fresh StreamRelay to `podUrl`: install message/close/error
      // handlers, connect, resend lastConfig. On success, `relay` and
      // `currentPodUrl` are updated. Used for the initial connect, same-pod
      // reconnects after a transient upstream drop, and replacement pods.
      const wireRelay = async (podUrl: string): Promise<void> => {
        relay?.close();
        relay = null;
        const newRelay = new StreamRelay(podUrl);
        newRelay.onMessage((data, isBinary) => {
          if (socket.readyState !== socket.OPEN) return;
          touch(userId);
          if (isBinary) {
            const base64 = (data as Buffer).toString('base64');
            socket.send(JSON.stringify({ type: 'frame', data: base64 }));
          } else {
            socket.send(data);
          }
        });
        newRelay.onClose(handleUpstreamClose);
        newRelay.onError((err) => {
          request.log.error({ userId, err }, 'Upstream error');
        });
        await newRelay.connect();
        relay = newRelay;
        currentPodUrl = podUrl;
        if (lastConfig) newRelay.sendConfig(lastConfig);
      };

      // Recover from an upstream close. If the iPad WS is still open, always
      // attempt recovery: first a same-pod reconnect (transient transport
      // drop — RunPod proxy idle timeout, network blip), then a full
      // replaceSession if that fails (pod actually gone). There is no
      // "voluntary upstream close while client is connected" case — the
      // user-left-the-app path closes the iPad WS first and is filtered by
      // the clientDisconnected check.
      function handleUpstreamClose(code: number, reason: string): void {
        request.log.info({ userId, code, reason }, 'Upstream closed');

        if (!config.PREEMPTION_REPLACEMENT_ENABLED) {
          // Legacy escape hatch: tear down immediately, no recovery.
          if (socket.readyState === socket.OPEN) {
            socket.send(
              JSON.stringify({ type: 'error', message: 'Pod terminated (possible spot preemption)' }),
            );
            socket.close(1001, 'Upstream closed');
          }
          return;
        }

        // Stop any residual events from the dead relay.
        relay?.close();
        relay = null;

        void (async () => {
          try {
            if (clientDisconnected || socket.readyState !== socket.OPEN) return;

            await emitState(userId, 'connecting');

            // Fast path: reconnect to the same pod. If the close was a
            // transient transport drop the pod is still serving and this
            // succeeds in ~1–2 s — no full re-provision cost, no UI
            // "Replacing — …" flash.
            if (currentPodUrl) {
              try {
                await wireRelay(currentPodUrl);
                if (clientDisconnected || socket.readyState !== socket.OPEN) return;
                await emitState(userId, 'ready');
                return;
              } catch (reconnectErr) {
                request.log.info(
                  { userId, err: (reconnectErr as Error).message },
                  'Same-pod reconnect failed; falling through to replaceSession',
                );
              }
            }

            // Slow path: pod is truly gone. Full replacement (~90 s).
            // `replaceSession` emits state transitions through the broker with
            // replacementCount > 0 so the iOS UI prefixes "Replacing — ".
            // MAX_SESSION_REPLACEMENTS protects against flapping pods — if
            // exhausted, replaceSession throws and the outer catch bounces iPad.
            trackPodPreempted({ userId, replacementAttempt: 1 });
            const { podUrl: newPodUrl } = await replaceSession(userId);
            if (clientDisconnected || socket.readyState !== socket.OPEN) {
              request.log.info({ userId }, 'Client disconnected during replacement — pod will idle-reap');
              return;
            }
            await wireRelay(newPodUrl);
            if (clientDisconnected || socket.readyState !== socket.OPEN) return;
            await emitState(userId, 'ready');
          } catch (err) {
            request.log.error({ userId, err }, 'Upstream recovery failed');
            if (socket.readyState === socket.OPEN) {
              socket.send(
                JSON.stringify({ type: 'error', message: `Recovery failed: ${(err as Error).message}` }),
              );
              socket.close(1011, 'Recovery failed');
            }
          }
        })();
      }

      let getOrProvisionMs = 0;
      try {
        // Record this provision in the sliding-window history for hourly/daily
        // rate limiting. Active-pod enforcement is derived from the session
        // row in Redis, so there's no counter to roll back on failure.
        if (source === 'jwt' && !isReconnect) {
          await recordProvision(userId);
        }

        const getOrProvisionStart = Date.now();
        const { podUrl } = await getOrProvisionPod(userId);
        getOrProvisionMs = Date.now() - getOrProvisionStart;

        if (socket.readyState !== socket.OPEN) {
          request.log.info({ userId }, 'Client disconnected during provisioning');
          return;
        }

        // Pod is serving; transition to 'connecting' while we wire up the relay.
        await emitState(userId, 'connecting');
        await wireRelay(podUrl);
        request.log.info({ userId }, 'Upstream connected, relaying');

        socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
          if (!relay) return;
          const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
          touch(userId);
          if (isBinary) {
            relay.sendFrame(buf);
          } else {
            const text = buf.toString('utf-8');
            try {
              const parsed = JSON.parse(text) as Record<string, unknown>;
              if (parsed.type === 'config') {
                lastConfig = parsed;
                relay.sendConfig(parsed);
              }
            } catch {
              request.log.warn({ userId }, 'Invalid JSON from client');
            }
          }
        });

        // Relay connected AND message handler registered — iOS frames will
        // now flow to the pod. Safe to tell iOS we're truly ready.
        await emitState(userId, 'ready');
      } catch (err) {
        request.log.error({ userId, err }, 'Provisioning or relay failed');
        // If the failure happened essentially-instantly, getOrProvisionPod
        // returned a cached podUrl and the relay then 404'd — i.e. the pod
        // we thought was ready turned out dead. Tracking this distinctly
        // from generic provision failures so we can spot stale-session bugs.
        const errMsg = err instanceof Error ? err.message : String(err);
        const looksLikeStalePodReuse = isReconnect && getOrProvisionMs < 1000;
        if (looksLikeStalePodReuse) {
          trackPodRelayFailed({
            userId,
            wasReused: true,
            errorMessage: errMsg,
            getOrProvisionMs,
          });
        }
        // Terminate the pod AND clear Redis. If the failure was a bad /ws
        // upgrade on an otherwise-healthy pod, we'd rather burn a fresh
        // provision (~130s) than leak a pod at $0.99/hr. abortSession deletes
        // the Redis session row, which is what the rate limiter reads to
        // decide whether the user still has an "active pod" — so the
        // accounting is released transitively.
        await abortSession(userId, 'error');
        if (socket.readyState === socket.OPEN) {
          const errorMsg = `Provisioning failed: ${errMsg}`;
          request.log.info({ userId }, 'Sending provisioning error to client and closing socket');
          socket.send(JSON.stringify({ type: 'error', message: errorMsg }));
          socket.close(1011, 'Provisioning failed');
        } else {
          request.log.warn({ userId, readyState: socket.readyState }, 'Cannot send provisioning error — socket not open');
        }
      }

      socket.on('close', () => {
        clientDisconnected = true;
        request.log.info({ userId }, 'Stream client disconnected');
        trackSessionClosed({ userId, durationMs: Date.now() - sessionStartMs });
        sessionClosed(userId);
        unsubscribeState();
        relay?.close();
      });

      socket.on('error', (err: Error) => {
        request.log.error({ userId, err }, 'Client socket error');
        unsubscribeState();
        relay?.close();
      });
    })();
  });
};

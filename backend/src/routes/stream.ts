import { randomBytes } from 'crypto';
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
  getOrProvisionVideoPod,
  replaceVideoSession,
  terminateVideoPod,
  clearVideoPod,
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
      // ─── Hoisted state ────────────────────────────────────────────────
      // All state referenced by close/error/message handlers must be
      // declared before those handlers are registered, which has to happen
      // before any `await` so we don't miss a close event during the slow
      // identity/quota/subscribe/provision/wire path (Node EventEmitter
      // drops events with no listener; cold start can take ~96 s).
      let userId: string | null = null;
      let source: 'jwt' | 'legacy_session' | null = null;
      let streamId: string | null = null;
      let relay: StreamRelay | null = null;
      let currentPodUrl: string | null = null;
      let lastConfig: Record<string, unknown> | null = null;
      let unsubscribeState: (() => void) | null = null;
      let clientDisconnected = false;
      const sessionStartMs = Date.now();
      // Per-WS short id so back-to-back reconnects from the same userId can
      // be told apart in logs. Diagnostics-only — never sent on the wire.
      const connId = randomBytes(4).toString('hex');

      // Diagnostics: track the journey to ready so socket.on('close') can
      // report "did the iPad ever see ready?" and how long ago.
      let everReachedReady = false;
      let lastEmittedState: string | null = null;
      let lastEmittedStateAt: number | null = null;
      let subscribeSeededState: string | null = null;
      let sawSubscribeSeed = false;

      // ─── Video pod state (best-effort, see getOrProvisionVideoPod) ────
      let videoRelay: StreamRelay | null = null;
      let videoPodId: string | null = null;
      // Once the upstream video relay closes uninitiated we don't try
      // again for this session — image gen continues normally.
      let videoSessionEnabled = true;
      // Captured from the last frame_meta JSON; consumed when the
      // following binary lands. The pair tells us "this image is video-
      // eligible" — pod-side authoritative, more robust than a backend
      // counter.
      let nextImageBinaryQueueEmpty = false;
      let nextImageBinaryRequestId: string | null = null;
      // Set when we forward a binary from the video pod. The next text
      // preamble gets matched with the binary that immediately follows.
      let pendingVideoBinaryWrapper: { type: string; meta: Record<string, unknown> } | null = null;
      let inFlightVideoRequestId: string | null = null;
      // Counters reported in the session_close summary (paste-friendly
      // for the triage cookbook in documents/plans/drawing-animation.md).
      let videoTriggered = 0;
      let videoCompleted = 0;
      let videoCancelled = 0;
      let videoFailed = 0;

      // Single-slot buffer for the latest config + frame received before the
      // relay is wired. iOS sends initial config immediately after WS open,
      // well before the backend reaches `.ready` — pre-fix that config was
      // dropped and the pod ran on whatever default it had until the iPad's
      // next config tick, breaking the user's prompt for early frames.
      let pendingConfig: Record<string, unknown> | null = null;
      let pendingFrame: Buffer | null = null;

      // ─── Idempotent cleanup ──────────────────────────────────────────
      // close + error can both fire for one underlying socket teardown,
      // and the provisioning catch may also reach this path. didCleanup
      // gates everything: sessionClosed, unsubscribeState, relay.close,
      // videoRelay.close, plus the per-close logline + trackSessionClosed.
      let didCleanup = false;
      const cleanupOnDisconnect = (): void => {
        if (didCleanup) return;
        didCleanup = true;
        clientDisconnected = true;
        unsubscribeState?.();
        unsubscribeState = null;
        relay?.close();
        relay = null;
        videoRelay?.close();
        videoRelay = null;
        // sessionClosed is keyed by userId; no-op if identity hadn't resolved.
        if (userId) sessionClosed(userId);
      };

      // ─── Register close/error/message handlers BEFORE any await ───────
      // These must run synchronously after the WS upgrade callback fires,
      // before any `await` work, so a client that disconnects during cold
      // start is observed and cleaned up. Pre-fix the late registration
      // dropped close events emitted on Node's EventEmitter.
      socket.on('close', (code: number, reason: Buffer) => {
        // didCleanup gates the per-close logline + analytics so it fires
        // exactly once even if `error` arrives first.
        if (didCleanup) return;
        const durationMs = Date.now() - sessionStartMs;
        const lastStateAgeMs = lastEmittedStateAt
          ? Date.now() - lastEmittedStateAt
          : null;
        request.log.info(
          {
            userId,
            connId,
            streamId,
            code,
            reason: reason?.toString('utf-8') ?? '',
            durationMs,
            everReachedReady,
            lastEmittedState,
            lastStateAgeMs,
            subscribeSeededState,
            videoTriggered,
            videoCompleted,
            videoCancelled,
            videoFailed,
            event: 'session_close',
          },
          'session_close',
        );
        if (userId) trackSessionClosed({ userId, durationMs });
        cleanupOnDisconnect();
      });

      socket.on('error', (err: Error) => {
        request.log.error({ userId, connId, streamId, err }, 'Client socket error');
        cleanupOnDisconnect();
      });

      socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
        const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
        if (userId) touch(userId);
        if (isBinary) {
          if (relay) {
            relay.sendFrame(buf);
            // A new sketch from the iPad supersedes any in-flight video.
            // Send video_cancel on EVERY iPad frame while a video request
            // is in flight; the pod treats it idempotently. Once the
            // video pod responds with video_cancelled, we clear the id.
            if (inFlightVideoRequestId && videoRelay) {
              const t0 = Date.now();
              videoRelay.sendConfig({
                type: 'video_cancel',
                requestId: inFlightVideoRequestId,
              });
              request.log.info(
                {
                  userId,
                  connId,
                  streamId,
                  req: inFlightVideoRequestId,
                  elapsedSinceRequestMs: t0 - sessionStartMs,
                  event: 'video_cancel_sent',
                },
                'video_cancel_sent',
              );
              inFlightVideoRequestId = null;
            }
          } else {
            // Coalesce: only the latest pre-wire frame matters for img2img.
            pendingFrame = buf;
          }
        } else {
          const text = buf.toString('utf-8');
          try {
            const parsed = JSON.parse(text) as Record<string, unknown>;
            if (parsed.type === 'config') {
              lastConfig = parsed;
              if (relay) {
                relay.sendConfig(parsed);
              } else {
                // Buffered for flush after wireRelay completes.
                pendingConfig = parsed;
              }
            }
          } catch {
            request.log.warn({ userId, connId, streamId }, 'Invalid JSON from client');
          }
        }
      });

      // ─── Now the slow path: identity → entitlement/quota → subscribe → provision ──
      const identity = await resolveIdentity({
        url: request.url,
        headers: { authorization: request.headers.authorization },
      });

      if ('error' in identity) {
        socket.send(JSON.stringify({ type: 'error', message: identity.error }));
        socket.close(identity.code, identity.error);
        return;
      }

      userId = identity.userId;
      source = identity.source;
      // Non-nullable shadow for the slow path. The hoisted `let userId`
      // is captured by close/error/message handlers (which null-check it);
      // closures defined later in this scope (wireVideoRelay,
      // handleUpstreamClose) need a `string` and TypeScript can't narrow
      // a let through async closures.
      const uid: string = identity.userId;
      // Per-startStream id issued by iOS. One streamId may correspond to N
      // connIds if the client internally reconnects within one StreamSession.
      // Search by streamId for the whole user attempt; by connId for one
      // specific WS upgrade. null when an older client without streamId connects.
      streamId = extractQueryParam(request.url, 'streamId');
      request.log.info({ userId, source, connId, streamId, event: 'ws_open' }, 'Stream client connected');

      // Entitlement check — only applies when authenticated via JWT. Legacy
      // sessions bypass entitlement to keep the old iPad binaries working
      // during the rollout window.
      // Skip rate limiting if the user is reconnecting to an existing pod
      // (ready, provisioning, or replacing). Only apply rate limits + register
      // provision for genuinely new provisions.
      const hasReadySessionStart = Date.now();
      const isReconnect = await hasReadySession(userId);
      request.log.info(
        {
          userId,
          connId,
          streamId,
          isReconnect,
          elapsedMs: Date.now() - hasReadySessionStart,
          event: 'has_ready_session',
        },
        'has_ready_session',
      );

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
      // Note: the broker's first invocation of this handler (synchronous on
      // subscribe) is the seed with current Redis state. We capture it
      // separately so we can distinguish "iPad got the seed" from "iPad got
      // a fresh transition fired AFTER subscribe returned" in stuck-on-
      // Connecting diagnoses.
      unsubscribeState = await subscribe(userId, (event) => {
        const isSeed = !sawSubscribeSeed;
        sawSubscribeSeed = true;
        if (isSeed) {
          subscribeSeededState = event.state;
        }
        lastEmittedState = event.state;
        lastEmittedStateAt = Date.now();
        if (event.state === 'ready') everReachedReady = true;
        request.log.info(
          {
            userId,
            connId,
            streamId,
            isSeed,
            state: event.state,
            replacementCount: event.replacementCount,
            failureCategory: event.failureCategory,
            socketReady: socket.readyState === socket.OPEN,
            event: 'state_handler',
          },
          'state_handler',
        );
        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify({ type: 'state', ...event }));
          if (event.state === 'terminated') {
            socket.close(1000, event.failureCategory ?? 'session_ended');
          }
        }
      });
      request.log.info(
        {
          userId,
          connId,
          streamId,
          subscribeSeededState,
          event: 'subscribe_complete',
        },
        'subscribe_complete',
      );

      // Wire a fresh StreamRelay to `podUrl`: install message/close/error
      // handlers, connect, resend lastConfig. On success, `relay` and
      // `currentPodUrl` are updated. Used for the initial connect, same-pod
      // reconnects after a transient upstream drop, and replacement pods.
      const wireRelay = async (podUrl: string): Promise<void> => {
        const wireStart = Date.now();
        request.log.info(
          { userId, connId, streamId, podUrl, event: 'wire_relay_start' },
          'wire_relay_start',
        );
        relay?.close();
        relay = null;
        const newRelay = new StreamRelay(podUrl);
        newRelay.setLogContext({ userId, connId, streamId, role: 'image' });
        newRelay.onMessage((data, isBinary) => {
          if (socket.readyState !== socket.OPEN) return;
          touch(userId);
          if (isBinary) {
            const buf = data as Buffer;
            const base64 = buf.toString('base64');
            socket.send(JSON.stringify({ type: 'frame', data: base64 }));

            // Video trigger: the immediately preceding frame_meta said
            // queueEmpty:true, so this JPEG is the just-completed
            // generation that the user is now idle on. Forward it to
            // the video pod for animation. Pod-side queueEmpty is the
            // authoritative idle signal — see flux-klein-server/server.py.
            if (nextImageBinaryQueueEmpty) {
              if (!videoSessionEnabled) {
                request.log.info(
                  { userId, connId, streamId, reason: 'session_disabled', event: 'video_skipped' },
                  'video_skipped',
                );
              } else if (!videoRelay) {
                request.log.info(
                  { userId, connId, streamId, reason: 'relay_disconnected', event: 'video_skipped' },
                  'video_skipped',
                );
              } else if (!lastConfig || typeof lastConfig['prompt'] !== 'string') {
                request.log.warn(
                  { userId, connId, streamId, reason: 'prompt_not_cached', event: 'video_skipped' },
                  'video_skipped',
                );
              } else if (inFlightVideoRequestId) {
                // A video is mid-generation. Don't fire another trigger —
                // the pod would cancel the in-flight one to start a new
                // request, starving us of any completion. Wait for the
                // current video to finish (or be cancelled by the user
                // resuming drawing) before triggering again.
                request.log.info(
                  { userId, connId, streamId, reason: 'already_in_flight', inFlightReq: inFlightVideoRequestId, event: 'video_skipped' },
                  'video_skipped',
                );
              } else {
                const reqId = nextImageBinaryRequestId ?? `vid-${Date.now()}`;
                const videoRequestPayload: Record<string, unknown> = {
                  type: 'video_request',
                  requestId: reqId,
                  image_b64: base64,
                  prompt: lastConfig['prompt'],
                };
                // Step 3.5 — per-request resolution/frames overrides. Forward
                // only when the iPad sent them (and they parse to integers);
                // otherwise pod falls back to its config defaults.
                for (const k of ['videoWidth', 'videoHeight', 'videoFrames'] as const) {
                  const v = lastConfig[k];
                  if (typeof v === 'number' && Number.isFinite(v)) {
                    videoRequestPayload[k] = Math.trunc(v);
                  }
                }
                // Per-request torch.profiler toggle (iPad SettingsPanel >
                // Diagnostics). Forward only when truthy; absence ⇒ no
                // profiling (zero overhead on the pod).
                if (lastConfig['enableProfiling'] === true) {
                  videoRequestPayload['enableProfiling'] = true;
                }
                if (typeof lastConfig['videoPromptSuffix'] === 'string') {
                  videoRequestPayload['videoPromptSuffix'] = lastConfig['videoPromptSuffix'];
                }
                videoRelay.sendConfig(videoRequestPayload);
                inFlightVideoRequestId = reqId;
                videoTriggered++;
                request.log.info(
                  {
                    userId,
                    connId,
                    streamId,
                    req: reqId,
                    promptCached: true,
                    videoRelayConnected: true,
                    videoWidth: videoRequestPayload['videoWidth'],
                    videoHeight: videoRequestPayload['videoHeight'],
                    videoFrames: videoRequestPayload['videoFrames'],
                    enableProfiling: videoRequestPayload['enableProfiling'] === true,
                    event: 'video_trigger',
                  },
                  'video_trigger',
                );
              }
            }
            nextImageBinaryQueueEmpty = false;
            nextImageBinaryRequestId = null;
          } else {
            // Forward text frames (frame_meta, status, error) to the iPad
            // unchanged. Sniff frame_meta to capture queueEmpty for the
            // following binary.
            socket.send(data);
            if (typeof data === 'string') {
              try {
                const parsed = JSON.parse(data) as Record<string, unknown>;
                if (parsed['type'] === 'frame_meta') {
                  nextImageBinaryQueueEmpty = parsed['queueEmpty'] === true;
                  nextImageBinaryRequestId = (parsed['requestId'] as string | null) ?? null;
                }
              } catch {
                // Not JSON; ignore — relay forwards opaquely.
              }
            }
          }
        });
        newRelay.onClose(handleUpstreamClose);
        newRelay.onError((err) => {
          request.log.error({ userId, connId, streamId, err }, 'Upstream error');
        });
        try {
          await newRelay.connect();
        } catch (err) {
          request.log.warn(
            {
              userId,
              connId,
              streamId,
              podUrl,
              elapsedMs: Date.now() - wireStart,
              err: (err as Error).message,
              event: 'wire_relay_failed',
            },
            'wire_relay_failed',
          );
          throw err;
        }
        request.log.info(
          {
            userId,
            connId,
            streamId,
            podUrl,
            elapsedMs: Date.now() - wireStart,
            event: 'wire_relay_open',
          },
          'wire_relay_open',
        );
        relay = newRelay;
        currentPodUrl = podUrl;
        if (lastConfig) newRelay.sendConfig(lastConfig);
      };

      // ─── Video relay wiring ────────────────────────────────────────────
      // Best-effort: getOrProvisionVideoPod returns null on any failure, in which
      // case videoRelay stays null and queueEmpty triggers log a single
      // 'video_skipped: relay_disconnected' line. No iPad-visible error.
      const wireVideoRelay = async (podUrl: string): Promise<void> => {
        const newRelay = new StreamRelay(podUrl);
        newRelay.setLogContext({ userId, connId, streamId, role: 'video' });
        newRelay.onMessage((data, isBinary) => {
          if (socket.readyState !== socket.OPEN) return;
          touch(userId);
          if (isBinary) {
            const buf = data as Buffer;
            const base64 = buf.toString('base64');
            // The text preamble that arrived just before this binary tells
            // us how to wrap it for the iPad. Falls back to a generic
            // wrapper if (somehow) no preamble was seen — iPad will log
            // and drop the frame.
            const wrap = pendingVideoBinaryWrapper;
            pendingVideoBinaryWrapper = null;
            const wrapperType = wrap?.type === 'video_complete' ? 'video_complete_data'
              : wrap?.type === 'video_frame' ? 'video_frame_data'
              : 'video_unknown_data';
            socket.send(JSON.stringify({ type: wrapperType, data: base64, meta: wrap?.meta ?? {} }));
          } else if (typeof data === 'string') {
            // The pod sends the preamble type before the binary, so we cache
            // the type and forward the *_data wrapped binary on arrival.
            // Bare preambles (video_frame, video_complete) are NOT forwarded
            // — the iPad has no handler for them, so forwarding is wasted
            // bandwidth (~one extra WS message per decoded frame).
            let parsed: Record<string, unknown> | null = null;
            try {
              parsed = JSON.parse(data) as Record<string, unknown>;
            } catch {
              // Not JSON — pass through opaquely below.
            }
            if (parsed === null) {
              socket.send(data);
              return;
            }
            const t = parsed['type'];
            if (t === 'video_frame' || t === 'video_complete') {
              pendingVideoBinaryWrapper = { type: t as string, meta: parsed };
              if (t === 'video_complete') {
                videoCompleted++;
                inFlightVideoRequestId = null;
              }
              return; // bare preamble — wrapped *_data goes out on the binary path
            }
            if (t === 'video_cancelled') {
              if (parsed['error']) {
                videoFailed++;
              } else {
                videoCancelled++;
              }
              inFlightVideoRequestId = null;
              pendingVideoBinaryWrapper = null;
            }
            socket.send(data);
          }
        });
        newRelay.onClose((code, reason) => handleVideoUpstreamClose(code, reason));
        newRelay.onError((err) => {
          request.log.warn({ userId, connId, streamId, err: err.message }, 'video relay error');
        });
        await newRelay.connect();
        videoRelay = newRelay;
      };

      // Mirror of handleUpstreamClose for the video pod's relay. Same
      // policy: same-pod reconnect first (transient transport drop), then
      // replaceVideoSession if that fails (pod truly gone). On final
      // failure, drop to image-only — video is best-effort, no iPad-visible
      // error.
      function handleVideoUpstreamClose(code: number, reason: string): void {
        request.log.warn(
          { userId, connId, streamId, code, reason, event: 'video_relay_closed' },
          'video_relay_closed',
        );

        if (clientDisconnected || socket.readyState !== socket.OPEN) {
          // Client already left; don't try to recover.
          videoSessionEnabled = false;
          videoRelay = null;
          return;
        }

        // Stop any residual events from the dead relay.
        videoRelay?.close();
        videoRelay = null;

        void (async () => {
          // Fast path: same-pod reconnect. RunPod proxy idle timeout or
          // network blip; pod is still serving — succeeds in ~1–2 s.
          if (videoPodId) {
            const samePodUrl = `wss://${videoPodId}-8766.proxy.runpod.net/ws`;
            try {
              await wireVideoRelay(samePodUrl);
              request.log.info(
                { userId, connId, streamId, videoPodId, event: 'video_relay_reconnected' },
                'video same-pod reconnect succeeded',
              );
              return;
            } catch (reconnectErr) {
              request.log.info(
                { userId, connId, streamId, videoPodId, err: (reconnectErr as Error).message },
                'video same-pod reconnect failed; trying replaceVideoSession',
              );
            }
          }

          // Slow path: replace the pod. Best-effort; null on failure.
          if (clientDisconnected || socket.readyState !== socket.OPEN) return;
          const result = await replaceVideoSession(uid);
          if (!result || clientDisconnected || socket.readyState !== socket.OPEN) {
            videoSessionEnabled = false;
            videoPodId = null;
            return;
          }
          videoPodId = result.podId;
          try {
            await wireVideoRelay(result.podUrl);
            request.log.info(
              { userId, connId, streamId, videoPodId, event: 'video_relay_replaced' },
              'video pod replaced; relay re-wired',
            );
          } catch (err) {
            request.log.warn(
              { userId, connId, streamId, videoPodId, err: (err as Error).message },
              'video replacement relay-wire failed; image-only',
            );
            // The replacement pod is alive but unreachable. Eagerly clean
            // up so it doesn't sit idle until reconcile. Mirrors the
            // initial-provision wire-failure handling above.
            terminateVideoPod(result.podId).catch(() => {});
            await clearVideoPod(uid).catch(() => {});
            videoPodId = null;
            videoSessionEnabled = false;
          }
        })();
      }

      // Recover from an upstream close. If the iPad WS is still open, always
      // attempt recovery: first a same-pod reconnect (transient transport
      // drop — RunPod proxy idle timeout, network blip), then a full
      // replaceSession if that fails (pod actually gone). There is no
      // "voluntary upstream close while client is connected" case — the
      // user-left-the-app path closes the iPad WS first and is filtered by
      // the clientDisconnected check.
      function handleUpstreamClose(code: number, reason: string): void {
        request.log.info(
          { userId, connId, streamId, code, reason, currentPodUrl, event: 'upstream_closed' },
          'Upstream closed',
        );

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

            await emitState(uid, 'connecting');

            // Fast path: reconnect to the same pod. If the close was a
            // transient transport drop the pod is still serving and this
            // succeeds in ~1–2 s — no full re-provision cost, no UI
            // "Replacing — …" flash.
            if (currentPodUrl) {
              const samePodStart = Date.now();
              try {
                await wireRelay(currentPodUrl);
                if (clientDisconnected || socket.readyState !== socket.OPEN) return;
                request.log.info(
                  {
                    userId,
                    connId,
                    streamId,
                    elapsedMs: Date.now() - samePodStart,
                    event: 'same_pod_reconnect_ok',
                  },
                  'same_pod_reconnect_ok',
                );
                await emitState(uid, 'ready');
                return;
              } catch (reconnectErr) {
                request.log.info(
                  {
                    userId,
                    connId,
                    streamId,
                    elapsedMs: Date.now() - samePodStart,
                    err: (reconnectErr as Error).message,
                    event: 'same_pod_reconnect_failed',
                  },
                  'Same-pod reconnect failed; falling through to replaceSession',
                );
              }
            }

            // Slow path: pod is truly gone. Full replacement (~90 s).
            // `replaceSession` emits state transitions through the broker with
            // replacementCount > 0 so the iOS UI prefixes "Replacing — ".
            // MAX_SESSION_REPLACEMENTS protects against flapping pods — if
            // exhausted, replaceSession throws and the outer catch bounces iPad.
            trackPodPreempted({ userId: uid, replacementAttempt: 1 });
            const { podUrl: newPodUrl } = await replaceSession(uid);
            if (clientDisconnected || socket.readyState !== socket.OPEN) {
              request.log.info({ userId, connId, streamId }, 'Client disconnected during replacement — pod will idle-reap');
              return;
            }
            await wireRelay(newPodUrl);
            if (clientDisconnected || socket.readyState !== socket.OPEN) return;
            await emitState(uid, 'ready');
          } catch (err) {
            request.log.error({ userId, connId, streamId, err }, 'Upstream recovery failed');
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

        // Kick off video pod provisioning IN PARALLEL with image. The image
        // pod gating user input takes ~96s cold; running video alongside
        // (~157s LTXV warmup) saves ~96s of time-to-first-video vs starting
        // it after image is wired. Video is best-effort: any failure here
        // logs and falls back to image-only without affecting the image
        // path. Race note: getOrProvisionVideoPod reads the session row
        // for an existing videoPodId; for fresh sessions the row gets
        // written by getOrProvisionPod kicked off below, but for new
        // sessions there's no prior pod to reuse anyway, so the race is
        // benign.
        if (config.VIDEO_POD_ENABLED) {
          void (async () => {
          try {
            const result = await getOrProvisionVideoPod(userId);
            if (!result || clientDisconnected || socket.readyState !== socket.OPEN) {
              // Client left during provision/reuse. We don't terminate
              // here — the pod (whether fresh or reused) is on the
              // session row and will be picked up by the next reconnect
              // or terminated by the reaper alongside the image pod.
              return;
            }
            videoPodId = result.podId;
            // Helper stamps the row's videoPodId field internally during
            // provision; no need to do it again here.
            try {
              await wireVideoRelay(result.podUrl);
              request.log.info(
                { userId, connId, streamId, videoPodId, event: '[provision/video] relay wired' },
                'video relay wired',
              );
            } catch (err) {
              // Relay connect failed for an otherwise-live pod. Terminate
              // + clear so the next reconnect provisions fresh (avoids
              // looping on a broken pod). The reaper would catch this
              // anyway, but eagerly clearing keeps the next session
              // healthy without a 30-min wait.
              request.log.warn(
                { userId, connId, streamId, videoPodId, err: (err as Error).message, event: '[provision/video] relay connect failed' },
                'video relay connect failed; terminating pod',
              );
              terminateVideoPod(result.podId).catch(() => {});
              videoPodId = null;
              await clearVideoPod(userId);
              videoSessionEnabled = false;
            }
          } catch (err) {
            request.log.warn(
              { userId, connId, streamId, err: (err as Error).message, event: '[provision/video] unexpected throw' },
              'getOrProvisionVideoPod unexpectedly threw (returns null on failure normally)',
            );
            videoSessionEnabled = false;
          }
          })();
        } else {
          request.log.info(
            { userId, connId, streamId, event: '[provision/video] disabled by config' },
            'video pod disabled (VIDEO_POD_ENABLED=false); session is image-only',
          );
          videoSessionEnabled = false;
        }

        const getOrProvisionStart = Date.now();
        const { podUrl } = await getOrProvisionPod(userId);
        getOrProvisionMs = Date.now() - getOrProvisionStart;
        request.log.info(
          {
            userId,
            connId,
            streamId,
            podUrl,
            isReconnect,
            elapsedMs: getOrProvisionMs,
            // Fast (<1s) on a reused-from-Redis pod; >>1s implies the
            // RunPod probe in getReusableFromRow ran or fresh provision.
            looksLikeReuse: getOrProvisionMs < 1000,
            event: 'get_or_provision_done',
          },
          'get_or_provision_done',
        );

        if (socket.readyState !== socket.OPEN) {
          request.log.info({ userId, connId, streamId }, 'Client disconnected during provisioning');
          return;
        }

        // Pod is serving; transition to 'connecting' while we wire up the relay.
        await emitState(userId, 'connecting');
        // Retry initial relay connect once. Occasionally RunPod's proxy
        // fails to upgrade the first WS to a freshly-ready pod: /health
        // returns ok but the /ws upgrade on the same pod 10 s later hangs
        // (observed 2026-04-25 02:30 UTC — pod was healthy, connect
        // timed out). A brief second attempt usually succeeds; if it
        // doesn't, the outer catch aborts the session cleanly.
        try {
          await wireRelay(podUrl);
        } catch (firstErr) {
          if (clientDisconnected || socket.readyState !== socket.OPEN) throw firstErr;
          request.log.warn(
            { userId, connId, streamId, podUrl, err: (firstErr as Error).message, event: 'initial_wire_retry' },
            'Initial relay connect failed, retrying in 2s',
          );
          await new Promise((r) => setTimeout(r, 2000));
          await wireRelay(podUrl);
        }
        request.log.info({ userId, connId, streamId, event: 'relay_connected' }, 'Upstream connected, relaying');

        // Flush any messages buffered by the early-registered message
        // handler during cold start. Order matters: config first (so the
        // pod sees the right prompt before the first frame), then the
        // latest pending frame.
        if (pendingConfig && relay) {
          (relay as StreamRelay).sendConfig(pendingConfig);
          pendingConfig = null;
        }
        if (pendingFrame && relay) {
          (relay as StreamRelay).sendFrame(pendingFrame);
          pendingFrame = null;
        }

        // Relay connected AND any buffered messages flushed — iOS frames
        // are now flowing to the pod. Safe to tell iOS we're truly ready.
        await emitState(userId, 'ready');
      } catch (err) {
        // Distinguish "user closed the app mid-cold-start" from "real
        // provisioning failure". The early-registered close handler sets
        // clientDisconnected = true and runs cleanupOnDisconnect; here we
        // just log and return. Calling abortSession in this case would
        // tear down a perfectly good pod the user might reconnect to.
        if (clientDisconnected || socket.readyState !== socket.OPEN) {
          request.log.info(
            {
              userId,
              connId,
              streamId,
              err: err instanceof Error ? err.message : String(err),
              event: 'provisioning_aborted_after_client_disconnect',
            },
            'provisioning aborted after client disconnect',
          );
          return;
        }
        request.log.error({ userId, connId, streamId, err }, 'Provisioning or relay failed');
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
          // Send the raw error verbatim — no fabricated "Provisioning failed:"
          // prefix. provision()'s catch already emitted state=failed with the
          // same message; this type=error envelope is the fallback for cases
          // where no state was emitted (e.g., a relay-wire failure after
          // getOrProvisionPod succeeded).
          request.log.info({ userId, connId, streamId }, 'Sending provisioning error to client and closing socket');
          socket.send(JSON.stringify({ type: 'error', message: errMsg }));
          socket.close(1011, 'Provisioning failed');
          // socket.close triggers the early-registered close handler,
          // which runs cleanupOnDisconnect (idempotent).
        } else {
          request.log.warn({ userId, connId, streamId, readyState: socket.readyState }, 'Cannot send provisioning error — socket not open');
        }
      }
      // close + error handlers are registered at the top of the IIFE,
      // before any await — see "Register close/error/message handlers
      // BEFORE any await" above. Late registration here would miss close
      // events fired during the slow path.
    })();
  });
};

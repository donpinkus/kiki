import { randomBytes } from 'crypto';
import type { FastifyPluginAsync } from 'fastify';

import { config } from '../config/index.js';
import { extractBearer } from '../modules/auth/index.js';
import { verifyAccess } from '../modules/auth/jwt.js';
import { withPhase } from '../modules/observability/phase.js';
import { StreamRelay, WireRelayError, type WireRelayPhaseTimings, type RelevantHttpHeaders } from '../modules/relay/streamRelay.js';
import { FalImageRelay, type ImageRelay } from '../modules/fal/falImageRelay.js';
import { recordFalConnection } from '../modules/fal/falConnectionLog.js';
import { FrameCapture } from '../modules/insights/frameCapture.js';
import { checkFalBudget, isTestAccount, addMonthlySpendUsd, RATE_USD_PER_SEC } from '../modules/falBudget/index.js';
import {
  ensure as ensureDevPool,
  touch as touchDevPool,
  acquireStream as poolAcquireStream,
  releaseStream as poolReleaseStream,
  touchInstance as poolTouchInstance,
  hasReady as poolHasReady,
  getState as poolGetState,
  reportFailure as poolReportFailure,
} from '../modules/lambda/devPool.js';
import { trackSessionClosed, trackProviderSession } from '../modules/analytics/index.js';

/**
 * WebSocket relay from the iPad to the image provider (fal hosted realtime,
 * or a Lambda Cloud instance running our own image server).
 *
 * Identity resolution (in order):
 *   1. `Authorization: Bearer <jwt>` — preferred. Extracts userId from access
 *      token, subject to entitlement gates.
 *   2. `?session=<uuid>` legacy query param — accepted only when
 *      `AUTH_REQUIRED=false`. Skips auth/entitlement checks.
 *      Will be removed once the iOS client ships JWT auth.
 *
 * State messages: the client receives `{type:'state', state:'connecting'|
 * 'ready'}` transitions emitted inline by this handler (there is no
 * cross-connection session registry — every state transition happens within
 * the lifetime of the WS connection that observes it).
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
  // `config.public` opts out of the global JWT gate (the WS handshake does its
  // own auth so it can send an error frame before closing). Also guarded by the
  // url-prefix check in authHook.
  fastify.get('/v1/stream', { websocket: true, config: { public: true } }, (socket, request) => {
    void (async () => {
      // ─── Hoisted state ────────────────────────────────────────────────
      // All state referenced by close/error/message handlers must be
      // declared before those handlers are registered, which has to happen
      // before any `await` so we don't miss a close event during the slow
      // identity/budget/wire path (Node EventEmitter drops events with no
      // listener).
      let userId: string | null = null;
      let source: 'jwt' | 'legacy_session' | null = null;
      let streamId: string | null = null;
      // Image relay: a Lambda StreamRelay or a fal FalImageRelay depending on
      // the provider. Both satisfy ImageRelay, so the wiring below is
      // provider-agnostic.
      let relay: ImageRelay | null = null;
      let currentUpstreamUrl: string | null = null;
      let lastConfig: Record<string, unknown> | null = null;
      // fal-spend cap: metering runs for non-exempt users on the fal image
      // path. `lastBilledMs` tracks how much of relay.cumulativeOpenMs() has
      // already been persisted to the monthly_usage ledger (advanced only on
      // a successful DB write, so a failed write is retried, not lost).
      let falMeteringEnabled = false;
      // Lambda metering: per-frame billing into the SAME monthly_usage ledger
      // (one unified $10 free tier across providers). ~$0.0007 raw GPU cost
      // per 4-step frame (590ms @ $4.29/hr H100), charged at $0.001 to absorb
      // pool idle overhead. Batched writes every 25 frames; fail-open like fal.
      let lambdaMeteringEnabled = false;
      let lambdaUnbilledFrames = 0;
      let lambdaBillInFlight = false;
      const LAMBDA_USD_PER_FRAME = 0.001;
      // Shared cap-reached cut (session-start denial, lambda mid-session,
      // fal mid-session): one place owns the user-facing message + close.
      const sendLimitReachedAndClose = (): void => {
        socket.send(
          JSON.stringify({
            type: 'error',
            code: 'free_limit_reached',
            message: "You're out of free drawing time this month — subscribe to keep drawing.",
          }),
        );
        socket.close(1008, 'free_limit_reached');
      };
      const billLambdaFrames = (): void => {
        if (!lambdaMeteringEnabled || lambdaBillInFlight || lambdaUnbilledFrames === 0) return;
        const uidNow = userId;
        if (!uidNow) return;
        const count = lambdaUnbilledFrames;
        lambdaUnbilledFrames = 0;
        lambdaBillInFlight = true;
        void addMonthlySpendUsd(uidNow, count * LAMBDA_USD_PER_FRAME)
          .then((total) => {
            if (clientDisconnected || socket.readyState !== socket.OPEN) return;
            // Live meter push (same shape as the fal path's usage events).
            socket.send(JSON.stringify({ type: 'usage', spendUsd: total, capUsd: config.FREE_TIER_FAL_USD }));
            if (total >= config.FREE_TIER_FAL_USD) {
              request.log.info(
                { userId: uidNow, connId, streamId, spendUsd: total, event: 'free_limit_reached' },
                'AI spend cap reached mid-session (lambda) — cutting stream',
              );
              sendLimitReachedAndClose();
            }
          })
          .catch(() => { lambdaUnbilledFrames += count; })  // retry on next flush
          .finally(() => { lambdaBillInFlight = false; });
      };
      let lastBilledMs = 0;
      // Admin session replay: throttled sketch/generated frame mirror to
      // Insights (see modules/insights/frameCapture.ts). Created lazily once
      // identity + streamId exist; null when capture is disabled/unconfigured.
      let frameCapture: FrameCapture | null = null;
      const captureFrame = (kind: 'sketch' | 'generated', jpeg: Buffer): void => {
        if (!frameCapture && userId && streamId) {
          frameCapture = new FrameCapture(streamId, userId, request.log);
        }
        frameCapture?.capture(kind, jpeg);
      };
      let clientDisconnected = false;
      const sessionStartMs = Date.now();
      // Which provider serves this session. Hoisted (with the default) so the
      // close handler can read it even if the client disconnects before the
      // per-session override below resolves — a mid-handler `let` would be in
      // its temporal dead zone at early-close time. Assigned (not redeclared)
      // by the override block.
      let imageProvider: typeof config.IMAGE_PROVIDER = config.IMAGE_PROVIDER;
      // Provider-session accounting → trackProviderSession at close (Insights
      // Launch tab H100 visibility + per-user provider breakdown).
      let framesDelivered = 0;
      let upstreamDisconnects = 0;
      let upstreamReconnects = 0;
      let wiredAtMs: number | null = null;
      let lambdaBounced = false;
      // What the pool was doing when we bounced ('launching' = still searching
      // for H100 capacity, 'booting' = warming, 'none'/'error' = not even
      // trying) — the waterfall's "how far did this session get" resolution.
      let poolStatusAtBounce: string | null = null;
      // ─── H100 waterfall stage tracking (Insights Launch tab) ──────────
      // Each flag marks the furthest stage this session reached on the H100
      // path; trackProviderSession ships them at close. providerIntent is the
      // PRE-resolution ask ('auto'/'lambda'/'fal'); poolStatusAtResolve is the
      // pool's state at the auto-resolution moment ('booting' = an instance
      // existed but wasn't warm — "found but not warmed").
      let providerIntent: string = config.IMAGE_PROVIDER;
      let poolStatusAtResolve: string | null = null;
      let lambdaWired = false;
      let lambdaFrames = 0;
      let lambdaDowngraded = false;
      // Wired → first H100 frame (ms) — the connected→first-frame transition
      // in the waterfall timing widget. Null until the first lambda frame.
      let lambdaFirstFrameMs: number | null = null;
      // True when `imageProvider` was resolved from 'auto' (the launch mode).
      // Auto sessions degrade to fal MID-SESSION when the lambda upstream dies
      // with no replacement instance — the drawing keeps flowing. Explicit
      // `?imageProvider=lambda` overrides keep the hard bounce instead (a
      // silent fal handoff would corrupt the A/B adherence comparison).
      let providerResolvedFromAuto = false;
      // Pool instance this session's stream slot is held on (lambda only);
      // released on close / re-assignment.
      let poolInstanceName: string | null = null;
      // Per-WS short id so back-to-back reconnects from the same userId can
      // be told apart in logs. Diagnostics-only — never sent on the wire.
      const connId = randomBytes(4).toString('hex');

      // Diagnostics: track the journey to ready so socket.on('close') can
      // report "did the iPad ever see ready?" and how long ago.
      let everReachedReady = false;
      let lastEmittedState: string | null = null;
      let lastEmittedStateAt: number | null = null;

      // Send a `{type:'state', ...}` transition to the iPad. All transitions
      // happen inline in this handler (no cross-connection broker), so this
      // is a plain socket.send with diagnostics bookkeeping.
      const sendState = (state: 'connecting' | 'ready'): void => {
        lastEmittedState = state;
        lastEmittedStateAt = Date.now();
        if (state === 'ready') everReachedReady = true;
        request.log.info(
          { userId, connId, streamId, state, socketReady: socket.readyState === socket.OPEN, event: 'state_emit' },
          'state_emit',
        );
        if (socket.readyState === socket.OPEN) {
          socket.send(JSON.stringify({ type: 'state', state }));
        }
      };

      // Per-attempt diagnostic accumulator for wire_relay attempts within this
      // WS handler's lifetime (initial attempt + retries). Each entry captures
      // the structured failure shape from `WireRelayError` plus an attempt
      // index. Drained into the rich `wire_relay_session_failed` log if all
      // attempts fail — answers "what exactly happened in this user's
      // incident" without manual log-stitching. Empty when wire_relay
      // succeeded on the first attempt.
      type WireRelayAttempt = {
        attempt: number;
        kind: WireRelayError['kind'];
        elapsedMs: number;
        phaseTimings: WireRelayPhaseTimings;
        wsCode?: number;
        httpStatus?: number;
        httpHeaders?: RelevantHttpHeaders;
        httpBodySample?: string;
        errno?: string;
        syscall?: string;
        message: string;
      };
      const wireRelayAttempts: WireRelayAttempt[] = [];

      // Single-slot buffer for the latest config + frame received before the
      // relay is wired. iOS sends initial config immediately after WS open,
      // possibly before the relay is connected — pre-fix that config was
      // dropped and the provider ran on whatever default it had until the
      // iPad's next config tick, breaking the user's prompt for early frames.
      let pendingConfig: Record<string, unknown> | null = null;
      let pendingFrame: Buffer | null = null;

      // ─── Idempotent cleanup ──────────────────────────────────────────
      // close + error can both fire for one underlying socket teardown,
      // and the wiring catch may also reach this path. didCleanup gates
      // relay teardown + the final spend flush; didFinalize separately
      // gates the per-close logline, lambda billing, pool release, and
      // analytics. They must be separate flags: ws emits `error` BEFORE
      // `close`, and when the error handler ran cleanup first, the close
      // handler still has to finalize (pre-fix it bailed on didCleanup —
      // leaking the pool stream slot and dropping the final lambda bill +
      // session analytics on every error-first teardown).
      let didCleanup = false;
      let didFinalize = false;
      const cleanupOnDisconnect = (): void => {
        if (didCleanup) return;
        didCleanup = true;
        clientDisconnected = true;
        // Final fal spend flush: persist the last partial open span BEFORE
        // closing the relay (close() would finalize it out of reach). Read the
        // delta synchronously; fire-and-forget the DB write (low-stakes ~cents).
        if (falMeteringEnabled && userId && relay?.cumulativeOpenMs) {
          const deltaMs = relay.cumulativeOpenMs() - lastBilledMs;
          if (deltaMs > 0) {
            void addMonthlySpendUsd(userId, (deltaMs / 1000) * RATE_USD_PER_SEC).catch(() => {});
          }
        }
        relay?.close();
        relay = null;
      };

      // ─── Register close/error/message handlers BEFORE any await ───────
      // These must run synchronously after the WS upgrade callback fires,
      // before any `await` work, so a client that disconnects during the
      // slow path is observed and cleaned up. Pre-fix the late registration
      // dropped close events emitted on Node's EventEmitter.
      socket.on('close', (code: number, reason: Buffer) => {
        // didFinalize gates the per-close logline + analytics so they fire
        // exactly once — but still fire when `error` arrived first.
        if (didFinalize) return;
        didFinalize = true;
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
            event: 'session_close',
          },
          'session_close',
        );
        billLambdaFrames();
        if (poolInstanceName) {
          poolReleaseStream(poolInstanceName);
          poolInstanceName = null;
        }
        if (userId) {
          trackSessionClosed({ userId, durationMs });
          trackProviderSession({
            userId,
            streamId,
            provider: imageProvider,
            durationMs,
            framesDelivered,
            timeToProviderMs: wiredAtMs !== null ? wiredAtMs - sessionStartMs : null,
            upstreamDisconnects,
            upstreamReconnects,
            lambdaBounced,
            poolStatusAtBounce,
            providerIntent,
            poolStatusAtResolve,
            lambdaWired,
            lambdaFrames,
            lambdaFirstFrameMs,
            lambdaDowngraded,
            everReachedReady,
          });
        }
        cleanupOnDisconnect();
      });

      socket.on('error', (err: Error) => {
        request.log.error({ userId, connId, streamId, err }, 'Client socket error');
        cleanupOnDisconnect();
      });

      socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
        const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
        if (isBinary) {
          if (relay) {
            relay.sendFrame(buf);
            captureFrame('sketch', buf);
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
              // Replay: record prompt changes (deduped in FrameCapture) so
              // the Gallery player can show which prompt drove each frame.
              if (typeof parsed['prompt'] === 'string') {
                if (!frameCapture && userId && streamId) {
                  frameCapture = new FrameCapture(streamId, userId, request.log);
                }
                frameCapture?.capturePrompt(parsed['prompt']);
              }
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

      // ─── Now the slow path: identity → entitlement → wire ─────────────
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
      // closures defined later in this scope (handleUpstreamClose) need a
      // `string` and TypeScript can't narrow a let through async closures.
      const uid: string = identity.userId;
      // Per-startStream id issued by iOS. One streamId may correspond to N
      // connIds if the client internally reconnects within one StreamSession.
      // Search by streamId for the whole user attempt; by connId for one
      // specific WS upgrade. null when an older client without streamId connects.
      streamId = extractQueryParam(request.url, 'streamId');
      // Per-session image-provider override (`?imageProvider=fal|lambda`) —
      // the iPad Settings dev toggle for sketch-adherence A/B. Honored for
      // JWT-authed TEST ACCOUNTS only; everyone else stays on the global
      // config.IMAGE_PROVIDER. `imageProvider` (hoisted above) shadows the
      // config value for the rest of this handler.
      const requestedProvider = extractQueryParam(request.url, 'imageProvider');
      if (requestedProvider && requestedProvider !== imageProvider) {
        if ((requestedProvider === 'fal' || requestedProvider === 'lambda') && source === 'jwt') {
          if (await isTestAccount(uid)) {
            imageProvider = requestedProvider;
            providerIntent = requestedProvider;
            request.log.info(
              { userId, connId, streamId, imageProvider, event: 'image_provider_override' },
              'per-session image provider override (test account)',
            );
          } else {
            request.log.warn(
              { userId, connId, streamId, requestedProvider, event: 'image_provider_override_denied' },
              'imageProvider param ignored — not a test account',
            );
          }
        }
      }
      // `auto` (the launch mode): serve from the H100 pool when it has a
      // ready instance, else fal — nobody waits on a boot. Interest is
      // recorded either way so the pool warms while fal serves.
      if (imageProvider === 'auto') {
        touchDevPool();
        providerResolvedFromAuto = true;
        // Waterfall stage attribution: the pool's state RIGHT NOW is what this
        // session experienced ('booting' = H100 found but not yet warm).
        poolStatusAtResolve = poolGetState().status;
        imageProvider = poolHasReady() || config.LAMBDA_IMAGE_URL ? 'lambda' : 'fal';
        request.log.info(
          { userId, connId, streamId, imageProvider, event: 'image_provider_auto' },
          'auto provider resolved',
        );
      }

      // User attribution comes from the `userId` Pino field on every log line
      // in this handler — promoted to `user_id` Sentry log attribute by
      // `beforeSendLog` in `index.ts`. Don't `Sentry.setUser` here: the
      // WS connection's lifetime outlives `fastifyIntegration`'s per-request
      // isolation, and setUser leaks onto the global scope for the rest of
      // the connection — distorting `user_id:X` queries by attaching this
      // user to background-process logs. Errors below pass `user: { id }` to
      // `captureException` explicitly so error-event attribution stays correct.
      request.log.info({ userId, source, connId, streamId, event: 'ws_open' }, 'Stream client connected');

      // fal spend cap — gate on EVERY connection (incl. reconnects / a 2nd
      // device) so the monthly free budget can't be bypassed by reconnecting.
      // Exempt users (test accounts, active subscribers) pass and skip
      // mid-session metering. Only applies when the image path is fal.
      if ((imageProvider === 'fal' || imageProvider === 'lambda') && source === 'jwt') {
        try {
          const budget = await checkFalBudget(userId);
          if (!budget.allowed) {
            request.log.info(
              { userId, connId, streamId, spendUsd: budget.spendUsd, capUsd: budget.capUsd, event: 'free_limit_reached' },
              'AI spend cap reached at session start — denying',
            );
            sendLimitReachedAndClose();
            return;
          }
          falMeteringEnabled = imageProvider === 'fal' && !budget.exempt;
          lambdaMeteringEnabled = imageProvider === 'lambda' && !budget.exempt;
        } catch (err) {
          // Fail-open: if the budget DB is unreachable, let the user draw rather
          // than hang or hard-deny. Enable metering so spend resumes capping
          // once the DB recovers (mid-session metering is itself fail-open).
          request.log.warn(
            { userId, connId, streamId, err: (err as Error).message, event: 'fal_budget_check_failed' },
            'fal_budget_check_failed — failing open (allowing session)',
          );
          falMeteringEnabled = imageProvider === 'fal';
          lambdaMeteringEnabled = imageProvider === 'lambda';
        }
      }

      // Wire a fresh relay to the upstream: install message/close/error
      // handlers, connect, resend lastConfig. On success, `relay` and
      // `currentUpstreamUrl` are updated. Used for the initial connect and
      // same-URL reconnects after a transient upstream drop.
      const wireRelay = async (upstreamUrl: string): Promise<void> => {
        const wireStart = Date.now();
        // Attempt index threaded into per-attempt logs; matches the
        // accumulator entry's `attempt` field so log lines and array
        // entries cross-reference cleanly when triaging.
        const attemptIndex = wireRelayAttempts.length + 1;
        request.log.info(
          { userId, connId, streamId, upstreamUrl, attempt: attemptIndex, event: 'wire_relay_start' },
          'wire_relay_start',
        );
        relay?.close();
        relay = null;
        const newRelay: ImageRelay =
          imageProvider === 'fal'
            ? new FalImageRelay(config.FAL_KEY, {
                logger: request.log,
                ctx: { userId, connId, streamId, role: 'image' },
                idleCloseMs: config.FAL_IDLE_CLOSE_MS,
                // Per-connection cold-start/latency record → fal_connections
                // (source='user'), comparable 1:1 against warmer pings.
                onConnection: (rec) =>
                  recordFalConnection('user', { userId, streamId }, rec, request.log),
              })
            : new StreamRelay(upstreamUrl, {
                tlsCa: upstreamUrl.startsWith('wss') ? config.LAMBDA_TLS_CA : null,
              });
        newRelay.setLogContext({ userId, connId, streamId, role: 'image' });
        newRelay.onMessage((data, isBinary) => {
          if (socket.readyState !== socket.OPEN) return;
          // Keep the Lambda dev-pool idle reaper honest while frames flow.
          if (imageProvider === 'lambda') {
            if (poolInstanceName) poolTouchInstance(poolInstanceName);
            else touchDevPool();
          }
          if (isBinary) {
            const buf = data as Buffer;
            const base64 = buf.toString('base64');
            socket.send(JSON.stringify({ type: 'frame', data: base64 }));
            framesDelivered += 1;
            if (imageProvider === 'lambda') {
              lambdaFrames += 1;
              if (lambdaFrames === 1) {
                lambdaFirstFrameMs = Date.now() - (wiredAtMs ?? sessionStartMs);
              }
              lambdaUnbilledFrames += 1;
              if (lambdaUnbilledFrames >= 25) billLambdaFrames();
            }
            captureFrame('generated', buf);
          } else {
            // Forward text frames (frame_meta, status, error) to the iPad
            // unchanged.
            socket.send(data);
          }
        });
        newRelay.onClose(handleUpstreamClose);
        newRelay.onError((err) => {
          request.log.error({ userId, connId, streamId, err }, 'Upstream error');
        });
        try {
          await newRelay.connect();
        } catch (err) {
          // Structured rejection from `streamRelay.connect()`. WireRelayError
          // carries kind, phase timings, HTTP response info (when the
          // server returned non-101), socket errno (ECONNREFUSED etc.).
          // Defensive fallback for any non-WireRelayError that escapes —
          // shouldn't happen, but logging shape stays uniform.
          const wre = err instanceof WireRelayError ? err : null;
          const elapsedMs = wre ? wre.elapsedMs : Date.now() - wireStart;
          wireRelayAttempts.push({
            attempt: attemptIndex,
            kind: wre?.kind ?? 'socket_error',
            elapsedMs,
            phaseTimings: wre?.phaseTimings ?? {},
            wsCode: wre?.wsCode,
            httpStatus: wre?.httpStatus,
            httpHeaders: wre?.httpHeaders,
            httpBodySample: wre?.httpBodySample,
            errno: wre?.errno,
            syscall: wre?.syscall,
            message: (err as Error).message,
          });
          request.log.warn(
            {
              userId,
              connId,
              streamId,
              upstreamUrl,
              attempt: attemptIndex,
              elapsedMs,
              kind: wre?.kind ?? 'socket_error',
              phaseTimings: wre?.phaseTimings ?? {},
              wsCode: wre?.wsCode,
              httpStatus: wre?.httpStatus,
              httpHeaders: wre?.httpHeaders,
              httpBodySample: wre?.httpBodySample,
              errno: wre?.errno,
              syscall: wre?.syscall,
              err: (err as Error).message,
              event: 'wire_relay_failed',
            },
            'wire_relay_failed',
          );
          throw err;
        }
        // Phase timings populated on the success path too — every successful
        // session contributes to the `dnsMs`/`tcpMs`/`tlsMs`/`upgradeMs`
        // baseline distribution. Failure timings are interpretable only
        // against this baseline (e.g. "tcpMs was 9s when normally <100ms").
        const phaseTimings = newRelay.getLastPhaseTimings();
        request.log.info(
          {
            userId,
            connId,
            streamId,
            upstreamUrl,
            attempt: attemptIndex,
            elapsedMs: Date.now() - wireStart,
            phaseTimings,
            event: 'wire_relay_open',
          },
          'wire_relay_open',
        );
        relay = newRelay;
        wiredAtMs ??= Date.now();
        if (imageProvider === 'lambda') lambdaWired = true;
        currentUpstreamUrl = upstreamUrl;
        if (lastConfig) newRelay.sendConfig(lastConfig);
      };

      // Mid-session fal spend metering (non-exempt users only). The relay
      // fires onUsage when open-time may have advanced (on each connection
      // close + a ~10s throttle); we persist the delta and hard-stop if over
      // cap. Called after every fal wireRelay — initial connect AND the
      // mid-session lambda→fal downgrade — because onUsage registration
      // lives on the relay instance. No-op unless fal metering is on.
      const setupFalMetering = (): void => {
        if (!falMeteringEnabled) return;
        const enforceCut = (spendUsd: number): void => {
          if (clientDisconnected || socket.readyState !== socket.OPEN) return;
          request.log.info(
            { userId, connId, streamId, spendUsd, capUsd: config.FREE_TIER_FAL_USD, event: 'free_limit_reached' },
            'fal spend cap reached mid-session — cutting stream',
          );
          // Any reconnect re-hits the start-of-session budget gate and is
          // denied cleanly (no cut→reconnect loop).
          sendLimitReachedAndClose();
        };
        const meterFalUsage = async (): Promise<void> => {
          if (!relay?.cumulativeOpenMs) return;
          const ms = relay.cumulativeOpenMs();
          const deltaMs = ms - lastBilledMs;
          if (deltaMs <= 0) return;
          try {
            const total = await addMonthlySpendUsd(uid, (deltaMs / 1000) * RATE_USD_PER_SEC);
            lastBilledMs = ms; // advance only on success → a failed write retries next fire
            // Live usage push so the client's free-tier meter ticks up in
            // near-real-time (every onUsage fire, ~10s). Best-effort.
            if (!clientDisconnected && socket.readyState === socket.OPEN) {
              socket.send(
                JSON.stringify({ type: 'usage', spendUsd: total, capUsd: config.FREE_TIER_FAL_USD }),
              );
            }
            if (total >= config.FREE_TIER_FAL_USD) enforceCut(total);
          } catch (err) {
            // Fail-open: don't advance lastBilledMs; the delta is retried on
            // the next onUsage fire. Never throw out of the relay callback.
            request.log.warn(
              { userId, connId, streamId, err: (err as Error).message, event: 'fal_spend_record_failed' },
              'fal_spend_record_failed',
            );
          }
        };
        relay?.onUsage?.(() => void meterFalUsage());
      };

      // Recover from an upstream close. If the iPad WS is still open, attempt
      // a same-URL reconnect (transient transport drop — network blip, fal
      // pool churn). There is no "voluntary upstream close while client is
      // connected" case — the user-left-the-app path closes the iPad WS first
      // and is filtered by the clientDisconnected check. (The fal relay
      // handles its own idle-close/lazy-reconnect internally and only
      // surfaces terminal closes here.)
      function handleUpstreamClose(code: number, reason: string): void {
        upstreamDisconnects += 1;
        request.log.info(
          { userId, connId, streamId, code, reason, currentUpstreamUrl, event: 'upstream_closed' },
          'Upstream closed',
        );

        // Stop any residual events from the dead relay.
        relay?.close();
        relay = null;

        // Tag every log emitted during the recovery attempt with
        // `phase: reconnecting` (read by `beforeSendLog` from
        // AsyncLocalStorage). Distinct from `preparing` so triage can spot
        // mid-session failures (where bug reports start) separately from
        // fresh-launch issues.
        void withPhase('reconnecting', async () => {
          try {
            if (clientDisconnected || socket.readyState !== socket.OPEN) return;

            sendState('connecting');

            if (currentUpstreamUrl) {
              const reconnectStart = Date.now();
              try {
                await wireRelay(currentUpstreamUrl);
                upstreamReconnects += 1;
                if (clientDisconnected || socket.readyState !== socket.OPEN) return;
                request.log.info(
                  {
                    userId,
                    connId,
                    streamId,
                    elapsedMs: Date.now() - reconnectStart,
                    event: 'upstream_reconnect_ok',
                  },
                  'upstream_reconnect_ok',
                );
                sendState('ready');
                return;
              } catch (reconnectErr) {
                request.log.warn(
                  {
                    userId,
                    connId,
                    streamId,
                    elapsedMs: Date.now() - reconnectStart,
                    err: (reconnectErr as Error).message,
                    event: 'upstream_reconnect_failed',
                  },
                  'Upstream reconnect failed',
                );
              }
            }

            // Lambda failover: the instance is gone — mark it suspect (so the
            // pool stops assigning it immediately; tick probes decide whether
            // it recovers or gets the 3-strike terminate) and hand the session
            // to a DIFFERENT pool instance if one is assignable.
            if (imageProvider === 'lambda' && poolInstanceName) {
              const failedInstance = poolInstanceName;
              poolReportFailure(failedInstance);
              poolReleaseStream(failedInstance);
              poolInstanceName = null;
              const slot = poolAcquireStream();
              if (slot && slot.name !== failedInstance && !clientDisconnected && socket.readyState === socket.OPEN) {
                poolInstanceName = slot.name;
                request.log.info(
                  { userId, connId, streamId, newInstance: slot.name, event: 'lambda_pool_failover' },
                  'reassigning session to another pool instance',
                );
                try {
                  await wireRelay(slot.url);
                  if (clientDisconnected || socket.readyState !== socket.OPEN) return;
                  sendState('ready');
                  return;
                } catch (failoverErr) {
                  // The replacement is bad too — mark and fall through to the
                  // fal downgrade / bounce below.
                  poolReportFailure(slot.name);
                  poolReleaseStream(slot.name);
                  poolInstanceName = null;
                  request.log.warn(
                    { userId, connId, streamId, instance: slot.name, err: (failoverErr as Error).message, event: 'lambda_pool_failover_failed' },
                    'failover instance also unreachable',
                  );
                }
              } else if (slot) {
                // Only the just-failed instance came back — don't reuse it.
                poolReleaseStream(slot.name);
              }
            }

            // No pool instance to fail over to. Auto-resolved sessions degrade
            // to fal in place — the drawing keeps flowing, the pool heals in
            // the background, and the next fresh session lands back on the
            // H100 path. (Explicit ?imageProvider=lambda keeps the hard bounce
            // below so A/B comparisons never silently mix providers.)
            if (
              imageProvider === 'lambda' &&
              providerResolvedFromAuto &&
              !clientDisconnected &&
              socket.readyState === socket.OPEN
            ) {
              request.log.warn(
                { userId, connId, streamId, event: 'lambda_auto_downgrade_fal' },
                'auto-resolved lambda session downgraded to fal mid-session',
              );
              billLambdaFrames(); // flush frames already served on lambda
              if (lambdaWired) lambdaDowngraded = true; // waterfall: had the H100, lost it
              imageProvider = 'fal';
              falMeteringEnabled = lambdaMeteringEnabled;
              lambdaMeteringEnabled = false;
              await wireRelay('fal://flux-2-klein-realtime');
              setupFalMetering();
              if (clientDisconnected || socket.readyState !== socket.OPEN) return;
              sendState('ready');
              return;
            }

            // Nothing to fail over to: fal reconnects hit the same hosted
            // endpoint (already tried above); the pool has no second ready
            // instance. Bounce the client with an explicit error; iOS
            // auto-retries with a fresh connection.
            if (socket.readyState === socket.OPEN) {
              socket.send(
                JSON.stringify({ type: 'error', message: 'Image provider unreachable' }),
              );
              socket.close(1001, 'Upstream closed');
            }
          } catch (err) {
            request.log.error({ userId, connId, streamId, err }, 'Upstream recovery failed');
            if (socket.readyState === socket.OPEN) {
              socket.send(
                JSON.stringify({ type: 'error', message: `Recovery failed: ${(err as Error).message}` }),
              );
              socket.close(1011, 'Recovery failed');
            }
          }
        });
      }

      // Tag every log emitted during the slow path (wire-relay → ready) with
      // `phase: preparing` via Node AsyncLocalStorage. Read at log-emit time
      // by the `beforeSendLog` hook in `index.ts`. Cross-stack query
      // `user_id:X phase:preparing` returns iOS preparing logs + backend
      // wiring lifecycle, in one filter.
      await withPhase('preparing', async () => {
      try {
        // Downgrade an auto-resolved lambda session to fal — used at initial
        // connect (pool advertised ready but the connect failed / no slot) and
        // NEVER for explicit `?imageProvider=lambda` overrides (those bounce so
        // the A/B comparison stays honest). Metering exemption carries over.
        const downgradeAutoToFal = (why: string): void => {
          request.log.warn(
            { userId, connId, streamId, why, event: 'lambda_auto_downgrade_fal' },
            'auto-resolved lambda session downgraded to fal',
          );
          billLambdaFrames(); // flush any frames already served on lambda
          if (lambdaWired) lambdaDowngraded = true; // waterfall: had the H100, lost it
          imageProvider = 'fal';
          falMeteringEnabled = lambdaMeteringEnabled;
          lambdaMeteringEnabled = false;
        };

        if (imageProvider === 'lambda') {
          // Lambda Cloud path: relay to our own image server on a Lambda
          // H100 — either the static LAMBDA_IMAGE_URL instance or a pool
          // kiki-serve instance (modules/lambda/devPool.ts).
          let lambdaUrl = config.LAMBDA_IMAGE_URL || null;
          if (!lambdaUrl) {
            const slot = poolAcquireStream();
            if (slot) {
              poolInstanceName = slot.name;
              lambdaUrl = slot.url;
            }
          }
          if (!lambdaUrl) {
            if (providerResolvedFromAuto) {
              // hasReady() flipped between resolution and acquire (suspect
              // mark, health kill) — serve fal instead of dying.
              downgradeAutoToFal('no_assignable_instance');
            } else {
              // Explicit lambda override — kick the pool and tell the iPad
              // explicitly. Serving fal silently here would corrupt the A/B
              // comparison; an explicit bounce lets Donald retry once the
              // pool reports ready.
              const poolState = ensureDevPool();
              request.log.info(
                { userId, connId, streamId, poolStatus: poolState.status, event: 'lambda_not_ready' },
                'imageProvider=lambda but no instance ready — bouncing client',
              );
              socket.send(
                JSON.stringify({
                  type: 'error',
                  code: 'lambda_not_ready',
                  message: `Lambda H100 not ready: ${poolState.message}. Toggle back to fal or retry in ~3 min.`,
                }),
              );
              lambdaBounced = true;
              poolStatusAtBounce = poolState.status;
              socket.close(1013, 'lambda_not_ready');
              return;
            }
          }
          if (lambdaUrl) {
            request.log.info(
              { userId, connId, streamId, event: 'image_provider_lambda' },
              'imageProvider=lambda — relaying to Lambda Cloud image instance',
            );
            sendState('connecting');
            try {
              await wireRelay(lambdaUrl);
            } catch (err) {
              // Mark the instance suspect so the pool stops assigning it
              // before the next probe cycle; free the slot either way.
              if (poolInstanceName) {
                poolReportFailure(poolInstanceName);
                poolReleaseStream(poolInstanceName);
                poolInstanceName = null;
              }
              if (!providerResolvedFromAuto) throw err;
              downgradeAutoToFal(`initial_connect_failed: ${(err as Error).message}`);
            }
          }
        }
        if (imageProvider === 'fal') {
          // fal hosted image path. The relay connects in ~0.5s when the pool
          // is warm (see modules/fal/falWarmer.ts).
          request.log.info(
            { userId, connId, streamId, event: 'image_provider_fal' },
            'imageProvider=fal — relaying to fal hosted klein',
          );
          sendState('connecting');
          await wireRelay('fal://flux-2-klein-realtime');

          setupFalMetering();
        }
        request.log.info({ userId, connId, streamId, event: 'relay_connected' }, 'Upstream connected, relaying');

        // Flush any messages buffered by the early-registered message
        // handler before the relay was wired. Order matters: config first
        // (so the provider sees the right prompt before the first frame),
        // then the latest pending frame.
        if (pendingConfig && relay) {
          relay.sendConfig(pendingConfig);
          pendingConfig = null;
        }
        if (pendingFrame && relay) {
          relay.sendFrame(pendingFrame);
          pendingFrame = null;
        }

        // Relay connected AND any buffered messages flushed — iOS frames
        // are now flowing to the provider. Safe to tell iOS we're truly ready.
        sendState('ready');
      } catch (err) {
        // Distinguish "user closed the app mid-connect" from "real wiring
        // failure". The early-registered close handler sets
        // clientDisconnected = true and runs cleanupOnDisconnect; here we
        // just log and return.
        if (clientDisconnected || socket.readyState !== socket.OPEN) {
          request.log.info(
            {
              userId,
              connId,
              streamId,
              err: err instanceof Error ? err.message : String(err),
              event: 'wiring_aborted_after_client_disconnect',
            },
            'wiring aborted after client disconnect',
          );
          return;
        }
        request.log.error({ userId, connId, streamId, err }, 'Relay wiring failed');

        // Rich forensic log — one row per failed session containing the
        // per-attempt array (phase timings, errors, HTTP responses). Used for
        // triaging individual user complaints —
        // `event:wire_relay_session_failed user_id:<X>` returns one row with
        // the full picture.
        if (wireRelayAttempts.length > 0) {
          request.log.warn(
            {
              userId,
              connId,
              streamId,
              event: 'wire_relay_session_failed',
              attempts: wireRelayAttempts,
              total_elapsed_ms: wireRelayAttempts.reduce((a, x) => a + x.elapsedMs, 0),
            },
            'wire_relay_session_failed',
          );
        }

        const errMsg = err instanceof Error ? err.message : String(err);
        if (socket.readyState === socket.OPEN) {
          request.log.info({ userId, connId, streamId }, 'Sending wiring error to client and closing socket');
          socket.send(JSON.stringify({ type: 'error', message: errMsg }));
          socket.close(1011, 'Relay wiring failed');
          // socket.close triggers the early-registered close handler,
          // which runs cleanupOnDisconnect (idempotent).
        } else {
          request.log.warn({ userId, connId, streamId, readyState: socket.readyState }, 'Cannot send wiring error — socket not open');
        }
      }
      }); // end withPhase('preparing')
      // close + error handlers are registered at the top of the IIFE,
      // before any await — see "Register close/error/message handlers
      // BEFORE any await" above. Late registration here would miss close
      // events fired during the slow path.
    })();
  });
};

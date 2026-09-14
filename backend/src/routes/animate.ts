import { randomBytes } from 'crypto';
import type { FastifyPluginAsync } from 'fastify';

import { config } from '../config/index.js';
import { resolveWsIdentity, extractQueryParam } from '../modules/auth/wsIdentity.js';
import { checkFalBudget, addMonthlySpendUsd } from '../modules/falBudget/index.js';
import { FrameCapture } from '../modules/insights/frameCapture.js';
import { trackVideoGeneration } from '../modules/analytics/index.js';
import { AnimateSession, type AnimateKeyframe, DEFAULT_ANIMATION_PROMPT } from '../modules/video/animateSession.js';
import { falAnimate, hostedEngineSpec, isHostedEngine, parseEngineId } from '../modules/video/falAnimate.js';
import { getState as poolGetState } from '../modules/lambda/devPool.js';
import {
  poolEnabled as videoPoolEnabled,
  getState as videoPoolGetState,
  touch as touchVideoPool,
  acquireStream as videoPoolAcquire,
  releaseStream as videoPoolRelease,
  touchInstance as videoPoolTouchInstance,
  reportFailure as videoPoolReportFailure,
} from '../modules/lambda/videoPool.js';

/**
 * WebSocket for the iPad's Animate screen (2026-07-19; replaces the
 * drawing-stream idle auto-animate). The client opens this socket when the
 * user enters the Animate screen and sends explicit generation requests:
 *
 *   client → { type: 'animate_request', requestId, prompt, audioPrompt?,
 *              enableAudio?, seed?, numFrames?, width?, height?, engine?,
 *              keyframes: [{ data: <b64 image>, position: 0..1, strength? }] }
 *
 * `engine` (2026-09-10) picks the generator: `ltx` (default — our Lambda
 * H100 LTX-2.5 pool via AnimateSession, streamed preview frames + MP4) or a
 * hosted fal engine (`wan3` / `h3max`, modules/video/falAnimate.ts — queue
 * job, MP4 only, pass-through cost metered per second). Same reply shapes
 * either way, so the iPad's parsing is engine-agnostic.
 *   client → { type: 'animate_cancel', requestId }
 *
 *   server → { type: 'system_availability', image, video }   (on open + change)
 *   server → { type: 'video_started', requestId }
 *   server → { type: 'video_frame_data',    data, meta }
 *   server → { type: 'video_complete_data', data, meta }
 *   server → { type: 'video_cancelled', requestId, error? }
 *   server → { type: 'usage', spendUsd, capUsd }
 *
 * Opening the socket registers interest with the video pool (floor-0 pool
 * wakes on interest), so the pool starts warming the moment the user lands
 * on the screen, and the availability push tells the client how far along
 * the boot is.
 */

const MAX_KEYFRAMES = 4;
/** Per-keyframe base64 cap (~6 MB decoded). The iPad downscales keyframes
 * to ≤1024px JPEG before sending; this is the abuse backstop. */
const MAX_KEYFRAME_B64_CHARS = 8_000_000;

export const animateRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/animate', { websocket: true, config: { public: true } }, (socket, request) => {
    void (async () => {
      // ── Hoisted state: handlers register before any await ─────────────
      let userId: string | null = null;
      let session: AnimateSession | null = null;
      let clientDisconnected = false;
      let availTimer: NodeJS.Timeout | null = null;
      let videoMeteringEnabled = false;
      let frameCapture: FrameCapture | null = null;
      /** In-flight hosted (fal) generation — one at a time per connection,
       * same rule as the LTX relay. Aborting cancels the fal queue job. */
      let hosted: { requestId: string; abort: AbortController } | null = null;
      const connId = randomBytes(4).toString('hex');
      const sessionStartMs = Date.now();
      // The Animate screen sends its own per-visit id so Insights can group
      // a visit's outputs; falls back to the connId.
      const captureId = extractQueryParam(request.url, 'animateId') ?? `animate-${connId}`;

      const sendToClient = (text: string): void => {
        if (!clientDisconnected && socket.readyState === socket.OPEN) socket.send(text);
      };

      const cleanup = (): void => {
        if (clientDisconnected) return;
        clientDisconnected = true;
        session?.close();
        session = null;
        hosted?.abort.abort();
        hosted = null;
        if (availTimer) clearInterval(availTimer);
        availTimer = null;
      };

      socket.on('close', (code: number, reason: Buffer) => {
        request.log.info(
          {
            userId,
            connId,
            code,
            reason: reason?.toString('utf-8') ?? '',
            durationMs: Date.now() - sessionStartMs,
            video: session?.getStats(),
            event: 'animate_session_close',
          },
          'animate_session_close',
        );
        cleanup();
      });
      socket.on('error', (err: Error) => {
        request.log.error({ userId, connId, err }, 'Animate socket error');
        cleanup();
      });

      // Buffer pre-identity messages? No — the iPad waits for the
      // availability push before sending requests; a request racing identity
      // resolution gets a video_unavailable cancel below (session === null).
      socket.on('message', (data: Buffer | ArrayBuffer | Buffer[], isBinary: boolean) => {
        if (isBinary) return; // no binary uplink on this socket
        const buf = Array.isArray(data) ? Buffer.concat(data) : Buffer.from(data as ArrayBuffer);
        const text = buf.toString('utf-8');
        let parsed: Record<string, unknown>;
        try {
          parsed = JSON.parse(text) as Record<string, unknown>;
        } catch {
          request.log.warn({ userId, connId }, 'Invalid JSON from animate client');
          return;
        }
        if (parsed.type === 'animate_request') {
          const requestId = typeof parsed['requestId'] === 'string' && parsed['requestId'].length > 0
            ? parsed['requestId']
            : `anim-${Date.now()}`;
          const reject = (error: string): void =>
            sendToClient(JSON.stringify({ type: 'video_cancelled', requestId, error }));
          const engine = parseEngineId(parsed['engine']);
          if (engine === 'ltx' && !session) return reject('video_unavailable');
          if (engine !== 'ltx' && !userId) return reject('video_unavailable');
          const rawKeyframes = parsed['keyframes'];
          if (!Array.isArray(rawKeyframes) || rawKeyframes.length === 0) return reject('no_image');
          if (rawKeyframes.length > MAX_KEYFRAMES) return reject('too_many_keyframes');
          const keyframes: AnimateKeyframe[] = [];
          for (const entry of rawKeyframes) {
            if (typeof entry !== 'object' || entry === null) return reject('invalid_keyframe');
            const e = entry as Record<string, unknown>;
            const b64 = e['data'];
            if (typeof b64 !== 'string' || b64.length === 0) return reject('invalid_keyframe');
            if (b64.length > MAX_KEYFRAME_B64_CHARS) return reject('keyframe_too_large');
            const position = typeof e['position'] === 'number' ? e['position'] : 0;
            const strength = typeof e['strength'] === 'number' ? e['strength'] : undefined;
            const kf: AnimateKeyframe = { imageB64: b64, position };
            if (strength !== undefined) kf.strength = strength;
            keyframes.push(kf);
          }
          const num = (v: unknown): number | undefined =>
            typeof v === 'number' && Number.isFinite(v) ? v : undefined;
          const input: Parameters<AnimateSession['requestAnimate']>[0] = {
            requestId,
            prompt: typeof parsed['prompt'] === 'string' ? parsed['prompt'] : '',
            keyframes,
          };
          if (typeof parsed['audioPrompt'] === 'string') input.audioPrompt = parsed['audioPrompt'];
          if (typeof parsed['enableAudio'] === 'boolean') input.enableAudio = parsed['enableAudio'];
          const seed = num(parsed['seed']);
          if (seed !== undefined) input.seed = seed;
          const numFrames = num(parsed['numFrames']);
          if (numFrames !== undefined) input.numFrames = numFrames;
          const width = num(parsed['width']);
          if (width !== undefined) input.width = width;
          const height = num(parsed['height']);
          if (height !== undefined) input.height = height;
          if (isHostedEngine(engine)) {
            runHosted(engine, input);
            return;
          }
          if (!session) return reject('video_unavailable');
          touchVideoPool('animate_request'); // active use = strongest interest signal
          session.requestAnimate(input);
        } else if (parsed.type === 'animate_cancel') {
          const requestId = typeof parsed['requestId'] === 'string' ? parsed['requestId'] : null;
          if (hosted && (requestId === null || requestId === hosted.requestId)) {
            const cancelled = hosted;
            hosted = null;
            cancelled.abort.abort();
            sendToClient(JSON.stringify({ type: 'video_cancelled', requestId: cancelled.requestId }));
            request.log.info(
              { userId, connId, req: cancelled.requestId, event: 'animate_hosted_cancelled' },
              'animate_hosted_cancelled',
            );
            return;
          }
          session?.cancel(requestId);
        }
      });

      // Handshake hello, sent BEFORE anything else: the iOS
      // StreamWebSocketClient consumes the FIRST message as a connection
      // status — if that first message were the system_availability push,
      // it would be swallowed by the handshake path and (being deduped
      // server-side) never re-sent, leaving the screen stuck on "warming".
      socket.send(JSON.stringify({ type: 'state', state: 'ready' }));

      // ── Slow path: identity → budget → session ────────────────────────
      const identity = await resolveWsIdentity({
        url: request.url,
        headers: { authorization: request.headers.authorization },
      });
      if ('error' in identity) {
        socket.send(JSON.stringify({ type: 'error', message: identity.error }));
        socket.close(identity.code, identity.error);
        return;
      }
      userId = identity.userId;
      if (clientDisconnected) return; // closed during identity resolution
      request.log.info(
        { userId, connId, source: identity.source, event: 'animate_ws_open' },
        'Animate client connected',
      );

      // Spend cap: same ledger as drawing. Deny at open when over cap;
      // meter $VIDEO_USD_PER_GENERATION per delivered video for non-exempt
      // users. Fail-open on DB trouble.
      if (identity.source === 'jwt') {
        try {
          const budget = await checkFalBudget(userId);
          if (!budget.allowed) {
            request.log.info(
              { userId, connId, spendUsd: budget.spendUsd, capUsd: budget.capUsd, event: 'free_limit_reached' },
              'AI spend cap reached at animate open — denying',
            );
            socket.send(
              JSON.stringify({
                type: 'error',
                code: 'free_limit_reached',
                message: "You're out of free AI time this month — subscribe to keep animating.",
              }),
            );
            socket.close(1008, 'free_limit_reached');
            return;
          }
          videoMeteringEnabled = !budget.exempt;
        } catch (err) {
          request.log.warn(
            { userId, connId, err: (err as Error).message, event: 'fal_budget_check_failed' },
            'budget check failed — failing open (allowing animate session)',
          );
          videoMeteringEnabled = true;
        }
      }

      const billVideoGeneration = (usd: number = config.VIDEO_USD_PER_GENERATION): void => {
        if (!videoMeteringEnabled) return;
        const uidNow = userId;
        if (!uidNow) return;
        void addMonthlySpendUsd(uidNow, usd)
          .then((total) => {
            sendToClient(
              JSON.stringify({ type: 'usage', spendUsd: total, capUsd: config.FREE_TIER_FAL_USD }),
            );
            // No mid-session cut here: a single video is a bounded ~$0.05
            // spend and the next animate open re-checks the cap.
          })
          .catch(() => {
            // Fail-open: a dropped ~$0.05 write is preferable to blocking.
          });
      };

      // ── Hosted (fal) engine path ──────────────────────────────────────
      // Mirrors AnimateSession's contract: video_started immediately, then
      // exactly one terminal reply (video_complete_data or video_cancelled).
      // No preview frames — fal returns a finished MP4. The keyframe contract
      // maps down to first/last frame; mid-video keyframes are dropped.
      const runHosted = (
        engine: 'wan3' | 'h3max',
        input: Parameters<AnimateSession['requestAnimate']>[0],
      ): void => {
        const requestId = input.requestId;
        const fail = (error: string): void => {
          request.log.info(
            { userId, connId, req: requestId, engine, reason: error, event: 'animate_request_failed' },
            'animate_request_failed',
          );
          sendToClient(JSON.stringify({ type: 'video_cancelled', requestId, error }));
        };
        if (hosted) return fail('busy');
        if (!config.FAL_KEY) return fail('engine_unavailable');
        const spec = hostedEngineSpec(engine);
        const first = input.keyframes[0];
        if (!first) return fail('no_image');
        const start = input.keyframes.find((kf) => kf.position <= 0.001) ?? first;
        const end = input.keyframes.find((kf) => kf.position >= 0.999 && kf !== start);
        const dropped = input.keyframes.length - (end ? 2 : 1);
        const enableAudio = input.enableAudio !== false;
        let prompt = input.prompt.trim().length > 0 ? input.prompt.trim() : DEFAULT_ANIMATION_PROMPT;
        const audioPrompt = (input.audioPrompt ?? '').trim();
        if (enableAudio && audioPrompt.length > 0) {
          if (!/[.!?]$/.test(prompt)) prompt += '.';
          prompt += ` Sound: ${audioPrompt}`;
        }
        const numFrames = input.numFrames ?? 145;
        const durationSeconds = Math.min(
          spec.maxSeconds,
          Math.max(spec.minSeconds, Math.round(numFrames / 24)),
        );
        const abort = new AbortController();
        hosted = { requestId, abort };
        const firedAt = Date.now();
        sendToClient(JSON.stringify({ type: 'video_started', requestId }));
        request.log.info(
          {
            userId, connId, req: requestId, engine, model: spec.model, resolution: spec.resolution,
            durationSeconds, keyframes: input.keyframes.length, droppedKeyframes: dropped,
            event: 'animate_hosted_fired',
          },
          'animate_hosted_fired',
        );
        const hostedInput: Parameters<typeof falAnimate>[0] = {
          engine, prompt, startImageB64: start.imageB64, durationSeconds, enableAudio,
        };
        if (end) hostedInput.endImageB64 = end.imageB64;
        if (typeof input.seed === 'number') hostedInput.seed = input.seed;
        void falAnimate(hostedInput, { signal: abort.signal })
          .then((result) => {
            if (hosted?.requestId !== requestId || abort.signal.aborted) return; // cancelled meanwhile
            hosted = null;
            if (clientDisconnected) return;
            // fps/frames are nominal (24 fps × delivered seconds): the iPad
            // derives the clip's displayed duration from them, and hosted
            // engines can round the requested duration (H3 Max's 5 s floor).
            const meta = {
              requestId,
              engine,
              fps: 24,
              frames: Math.round(result.durationSeconds * 24),
              genMs: result.elapsedMs,
              durationSeconds: result.durationSeconds,
              costUsd: result.costUsd,
              actualPrompt: result.actualPrompt,
            };
            sendToClient(
              JSON.stringify({ type: 'video_complete_data', data: result.mp4.toString('base64'), meta }),
            );
            billVideoGeneration(result.costUsd);
            if (!frameCapture && userId) frameCapture = new FrameCapture(captureId, userId, request.log);
            frameCapture?.captureVideo(result.mp4);
            if (userId) {
              trackVideoGeneration({
                userId, streamId: captureId, source: 'animate_screen', engine,
                waitMs: Date.now() - firedAt, genMs: result.elapsedMs, bytes: result.mp4.length,
                costUsd: result.costUsd,
              });
            }
            request.log.info(
              {
                userId, connId, req: requestId, engine, bytes: result.mp4.length, genMs: result.elapsedMs,
                waitMs: Date.now() - firedAt, costUsd: result.costUsd, event: 'video_delivered',
              },
              'video_delivered',
            );
          })
          .catch((err: Error) => {
            const wasCurrent = hosted?.requestId === requestId;
            if (wasCurrent) hosted = null;
            if (abort.signal.aborted) return; // cancel already answered
            request.log.warn(
              { userId, connId, req: requestId, engine, err: err.message, event: 'animate_hosted_failed' },
              'animate_hosted_failed',
            );
            fail('hosted_failed');
          });
      };

      // ── Availability push (same payload family as /v1/stream) ─────────
      const systemPayload = (
        state: ReturnType<typeof videoPoolGetState>,
        systemEnabled: boolean,
      ): Record<string, unknown> => {
        if (!systemEnabled) return { availability: 'off' };
        if (state.status === 'ready') return { availability: 'ready' };
        const stage =
          state.status === 'launching' ? 'searching' : state.status === 'booting' ? 'booting' : 'waking';
        return {
          availability: 'warming',
          stage,
          stageStartedAtMs:
            stage === 'searching' ? state.searchStartedAtMs : stage === 'booting' ? state.launchedAtMs : undefined,
          bootEstimateSeconds: state.bootEstimateSeconds,
        };
      };
      let lastAvailabilityJson: string | null = null;
      const pushAvailability = (): void => {
        if (clientDisconnected || socket.readyState !== socket.OPEN) return;
        const video = config.LAMBDA_VIDEO_URL
          ? { availability: 'ready' }
          : systemPayload(videoPoolGetState(), videoPoolEnabled());
        const payload = JSON.stringify({
          type: 'system_availability',
          image: systemPayload(poolGetState(), config.LAMBDA_DEV_POOL_ENABLED || Boolean(config.LAMBDA_IMAGE_URL)),
          video,
        });
        if (payload === lastAvailabilityJson) return;
        lastAvailabilityJson = payload;
        socket.send(payload);
      };

      // The budget check awaited above — if the client disconnected while it
      // ran, cleanup() has already fired and anything created below (session,
      // avail timer) would leak with nothing left to tear it down.
      if (clientDisconnected) return;

      const videoEnabled = Boolean(config.LAMBDA_VIDEO_URL) || videoPoolEnabled();
      if (videoEnabled) {
        const staticUrl = config.LAMBDA_VIDEO_URL;
        if (!staticUrl) touchVideoPool('animate_screen_open'); // intent → pool wakes/warms
        session = new AnimateSession({
          acquire: staticUrl ? () => ({ url: staticUrl }) : videoPoolAcquire,
          release: staticUrl ? undefined : videoPoolRelease,
          reportFailure: staticUrl ? undefined : videoPoolReportFailure,
          touchInstance: staticUrl ? undefined : videoPoolTouchInstance,
          tlsCa: config.LAMBDA_TLS_CA || null,
          sendToClient,
          isClientOpen: () => !clientDisconnected && socket.readyState === socket.OPEN,
          onVideoDelivered: (mp4, meta, info) => {
            billVideoGeneration();
            if (!frameCapture && userId) {
              frameCapture = new FrameCapture(captureId, userId, request.log);
            }
            frameCapture?.captureVideo(mp4);
            const genMs = typeof meta['genMs'] === 'number' ? meta['genMs'] : null;
            if (userId) {
              trackVideoGeneration({
                userId,
                streamId: captureId,
                source: 'animate_screen',
                engine: 'ltx',
                waitMs: info.waitMs,
                genMs,
                bytes: mp4.length,
                costUsd: config.VIDEO_USD_PER_GENERATION,
              });
            }
            request.log.info(
              { userId, connId, bytes: mp4.length, genMs: genMs ?? undefined, waitMs: info.waitMs, event: 'video_delivered' },
              'video_delivered',
            );
          },
          log: request.log,
          ctx: { userId, connId },
        });
      }

      pushAvailability();
      availTimer = setInterval(() => {
        // Keep the pool's interest fresh while the screen is open, so a
        // floor-0 pool doesn't wind down under a user who is mid-visit.
        if (videoEnabled && !config.LAMBDA_VIDEO_URL) touchVideoPool('animate_screen_open');
        pushAvailability();
        // Keepalive: unlike the drawing stream (constant frame traffic),
        // this socket goes silent once the deduped availability push
        // settles — and Railway's edge kills idle WebSockets after ~60s
        // (observed as 1006 closes every 60s, masked by the client's
        // reconnect). A ping every tick keeps bytes flowing; iOS's
        // URLSessionWebSocketTask auto-pongs.
        if (!clientDisconnected && socket.readyState === socket.OPEN) {
          try {
            socket.ping();
          } catch {
            // Best-effort — a failed ping just means the close is imminent.
          }
        }
      }, 15_000);
      availTimer.unref?.();
    })();
  });
};

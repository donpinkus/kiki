import { randomBytes } from 'crypto';
import type { FastifyPluginAsync } from 'fastify';

import { config } from '../config/index.js';
import { resolveWsIdentity, extractQueryParam } from '../modules/auth/wsIdentity.js';
import { checkFalBudget, addMonthlySpendUsd } from '../modules/falBudget/index.js';
import { FrameCapture } from '../modules/insights/frameCapture.js';
import { trackVideoGeneration } from '../modules/analytics/index.js';
import { AnimateSession, type AnimateKeyframe } from '../modules/video/animateSession.js';
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
 *   client → { type: 'animate_request', requestId, prompt, seed?, numFrames?,
 *              width?, height?,
 *              keyframes: [{ data: <b64 image>, position: 0..1, strength? }] }
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
          if (!session) return reject('video_unavailable');
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
          const seed = num(parsed['seed']);
          if (seed !== undefined) input.seed = seed;
          const numFrames = num(parsed['numFrames']);
          if (numFrames !== undefined) input.numFrames = numFrames;
          const width = num(parsed['width']);
          if (width !== undefined) input.width = width;
          const height = num(parsed['height']);
          if (height !== undefined) input.height = height;
          touchVideoPool('animate_request'); // active use = strongest interest signal
          session.requestAnimate(input);
        } else if (parsed.type === 'animate_cancel') {
          const requestId = typeof parsed['requestId'] === 'string' ? parsed['requestId'] : null;
          session?.cancel(requestId);
        }
      });

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

      const billVideoGeneration = (): void => {
        if (!videoMeteringEnabled) return;
        const uidNow = userId;
        if (!uidNow) return;
        void addMonthlySpendUsd(uidNow, config.VIDEO_USD_PER_GENERATION)
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
                waitMs: info.waitMs,
                genMs,
                bytes: mp4.length,
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
      }, 15_000);
      availTimer.unref?.();
    })();
  });
};

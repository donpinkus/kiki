/**
 * POST /v1/sketchify — convert a generated image into an editable sketch
 * (the "Edit → pull onto canvas" feature).
 *
 * Body: { imageBase64: string (JPEG), mode: 'lines' | 'lines_colors' }
 * 200 → { imageBase64: string (JPEG of the sketch) }
 * 503 → { error: 'lambda_not_ready', status, etaSeconds } — H100 still booting
 *
 * Methodology (validated on 6 real drawings, see
 * documents/plans/completed/generation-to-canvas-roundtrip.md): the sketch is ONE extra
 * klein generation on the same Lambda instance — the generated image goes in
 * as the reference and a fixed style prompt + fixed seed produce a clean
 * coloring-book sketch. `lines` re-derives colors from the drawing prompt on
 * later regenerations; `lines_colors` carries (and steers by) the palette.
 *
 * Transport: a short-lived WebSocket to the dev-pool instance speaking the
 * pod's existing protocol (JSON config → binary JPEG in, frame_meta + binary
 * JPEG out). One-shot; interleaves fairly with any live drawing stream via
 * the server's per-connection round-robin (measured). No pod changes.
 */

import type { FastifyPluginAsync } from 'fastify';
import WebSocket from 'ws';
import { testAccountsOnly } from '../modules/falBudget/index.js';
import { falKleinEdit } from '../modules/fal/falEdit.js';
import { touch as touchDevPool, wsUrl as devPoolWsUrl, ensure as ensureDevPool } from '../modules/lambda/devPool.js';
import { config } from '../config/index.js';

// Fixed prompts + seed from the validated methodology. Changing these changes
// the product's sketch look — treat as product constants, not tunables.
const SKETCH_PROMPTS: Record<string, string> = {
  lines:
    'simple clean black and white line art drawing on white paper, ' +
    'uncolored coloring book outline style, no shading, no color',
  lines_colors:
    'simple clean line art drawing with flat marker colors on white paper, ' +
    'minimal children\'s coloring book style',
};
const SKETCH_SEED = 7;
const SKETCH_STEPS = 4;
const TIMEOUT_MS = 30_000;

// fal FALLBACK prompts (klein 9B edit is instruction-following, so these are
// phrased as conversion commands — NOT the reference-mode style prompts
// above). Validated side-by-side against the lambda output on 2026-08-23:
// `lines` matches; `lines_colors` needs the cel-shaded phrasing — softer
// wordings left the subject half-uncolored. Product constants like the
// lambda prompts: changing them changes the fallback's sketch look.
const FAL_SKETCH_PROMPTS: Record<string, string> = {
  lines:
    'Convert this image into a simple clean black and white line art drawing ' +
    'on white paper, uncolored coloring book outline style, no shading, no color. ' +
    'Remove all color and shading, keep only clean outlines.',
  lines_colors:
    'Convert this image to flat cel-shaded cartoon style with bold clean black ' +
    'outlines: keep every original color as a single flat fill per region, ' +
    'remove all shading, gradients and texture. The whole image must remain fully colored.',
};
const FAL_SKETCH_STEPS = 8;

function runSketchify(url: string, jpeg: Buffer, prompt: string): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url, {
      perMessageDeflate: false,
      ...(url.startsWith('wss') && config.LAMBDA_TLS_CA
        ? { ca: [config.LAMBDA_TLS_CA], checkServerIdentity: () => false }
        : {}),
    });
    const timer = setTimeout(() => {
      ws.close();
      reject(new Error('sketchify timed out'));
    }, TIMEOUT_MS);
    const fail = (err: Error): void => {
      clearTimeout(timer);
      ws.close();
      reject(err);
    };
    ws.on('open', () => {
      ws.send(
        JSON.stringify({
          type: 'config',
          prompt,
          steps: SKETCH_STEPS,
          seed: SKETCH_SEED,
          requestId: 'sketchify',
        }),
      );
      ws.send(jpeg);
    });
    ws.on('message', (data: Buffer, isBinary: boolean) => {
      if (!isBinary) return; // status / frame_meta preamble
      clearTimeout(timer);
      ws.close();
      resolve(data);
    });
    ws.on('error', fail);
    ws.on('close', () => {
      // If we get here without resolving, surface a clean error.
      clearTimeout(timer);
      reject(new Error('sketchify connection closed before a frame arrived'));
    });
  });
}

export const sketchifyRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: { imageBase64?: string; mode?: string } }>(
    '/v1/sketchify',
    // Same gate as the other Lambda-backed dev surfaces for now; drop the
    // preHandler when the feature ships to everyone.
    { preHandler: testAccountsOnly },
    async (request, reply) => {
      const { imageBase64, mode } = request.body ?? {};
      const prompt = SKETCH_PROMPTS[mode ?? ''];
      const falPrompt = FAL_SKETCH_PROMPTS[mode ?? ''];
      if (!imageBase64 || !prompt || !falPrompt) {
        return reply.code(400).send({ error: "imageBase64 and mode ('lines'|'lines_colors') required" });
      }

      const jpeg = Buffer.from(imageBase64, 'base64');
      const url = config.LAMBDA_IMAGE_URL || devPoolWsUrl();

      if (!url) {
        // No H100 available (drought / still booting) — FALL BACK to fal's
        // klein 9B edit endpoint instead of bouncing the user (2026-08-23;
        // previously a 503). Still kick the pool so the H100 keeps coming
        // for later calls — fal is the fallback, never the replacement.
        const state = ensureDevPool('sketchify');
        const t0 = Date.now();
        try {
          const result = await falKleinEdit({
            prompt: falPrompt,
            image: jpeg,
            imageContentType: 'image/jpeg',
            steps: FAL_SKETCH_STEPS,
            seed: SKETCH_SEED,
          });
          request.log.info(
            { userId: request.userId, mode, provider: 'fal', poolStatus: state.status, elapsedMs: Date.now() - t0, bytes: result.image.length, event: 'sketchify_ok' },
            'sketchify_ok (fal fallback — lambda pool not ready)',
          );
          return { imageBase64: result.image.toString('base64') };
        } catch (err) {
          request.log.warn(
            { userId: request.userId, mode, provider: 'fal', poolStatus: state.status, err: (err as Error).message, event: 'sketchify_failed' },
            'sketchify_failed (fal fallback)',
          );
          // Both providers unavailable — keep the old contract so the iPad's
          // existing "warming up, retry" handling still applies.
          return reply.code(503).send({
            error: 'lambda_not_ready',
            status: state.status,
            etaSeconds: state.etaSeconds,
          });
        }
      }

      const t0 = Date.now();
      try {
        const sketch = await runSketchify(url, jpeg, prompt);
        touchDevPool('sketchify');
        request.log.info(
          { userId: request.userId, mode, provider: 'lambda', elapsedMs: Date.now() - t0, bytes: sketch.length, event: 'sketchify_ok' },
          'sketchify_ok',
        );
        return { imageBase64: sketch.toString('base64') };
      } catch (err) {
        request.log.warn(
          { userId: request.userId, mode, provider: 'lambda', err: (err as Error).message, event: 'sketchify_failed' },
          'sketchify_failed',
        );
        return reply.code(502).send({ error: 'sketchify_failed', message: (err as Error).message });
      }
    },
  );
};
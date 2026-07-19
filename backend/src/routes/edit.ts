/**
 * POST /v1/edit — AI Edit / inpaint: one-shot instruction edit of the user's
 * drawing via fal's FLUX.2 [klein] 9B edit endpoint (modules/fal/falEdit.ts).
 *
 * Body: {
 *   imageBase64: string   — flattened visible-layer composite (JPEG or PNG)
 *   prompt: string        — editing instruction
 *   scope?: 'region'|'full' — analytics only; masking is CLIENT-side (the
 *                           endpoint has no mask param, and client compositing
 *                           guarantees out-of-selection pixels never change)
 *   steps?: number        — num_inference_steps (default 8, clamped 1..50)
 *   seed?: number
 *   width?/height?: number — requested output size (fal caps ~1 MP)
 * }
 * 200 → { imageBase64: string (PNG), width, height, seed }
 * 402 → { error: 'free_limit_reached' } — free-tier fal cap hit
 * 502 → { error: 'edit_failed', message }
 *
 * Metered like animate: gated by checkFalBudget up front, billed
 * EDIT_USD_PER_GENERATION per delivered edit for non-exempt users.
 */

import type { FastifyPluginAsync } from 'fastify';
import { checkFalBudget, addMonthlySpendUsd } from '../modules/falBudget/index.js';
import { falKleinEdit } from '../modules/fal/falEdit.js';
import { trackImageEdit } from '../modules/analytics/index.js';
import { config } from '../config/index.js';

const MAX_PROMPT_LEN = 2000;

interface EditBody {
  imageBase64?: string;
  prompt?: string;
  scope?: string;
  steps?: number;
  seed?: number;
  width?: number;
  height?: number;
}

export const editRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: EditBody }>('/v1/edit', async (request, reply) => {
    const { imageBase64, prompt, scope, steps, seed, width, height } = request.body ?? {};
    if (!imageBase64 || !prompt?.trim()) {
      return reply.code(400).send({ error: 'imageBase64 and prompt required' });
    }
    if (prompt.length > MAX_PROMPT_LEN) {
      return reply.code(400).send({ error: 'prompt too long' });
    }

    const userId = request.userId;
    const budget = await checkFalBudget(userId);
    if (!budget.allowed) {
      request.log.info(
        { userId, spendUsd: budget.spendUsd, capUsd: budget.capUsd, event: 'edit_budget_blocked' },
        'edit blocked by free-tier cap',
      );
      return reply.code(402).send({ error: 'free_limit_reached' });
    }

    const image = Buffer.from(imageBase64, 'base64');
    // JPEG magic ff d8; anything else we label PNG (fal sniffs content anyway).
    const contentType = image[0] === 0xff && image[1] === 0xd8 ? 'image/jpeg' : 'image/png';
    const clampedSteps = Math.max(1, Math.min(50, Math.round(steps ?? 8)));
    const imageSize =
      width && height
        ? { width: Math.round(width), height: Math.round(height) }
        : undefined;

    try {
      const result = await falKleinEdit({
        prompt: prompt.trim(),
        image,
        imageContentType: contentType,
        steps: clampedSteps,
        seed,
        imageSize,
      });
      if (!budget.exempt) {
        await addMonthlySpendUsd(userId, config.EDIT_USD_PER_GENERATION);
      }
      trackImageEdit({
        userId,
        scope: scope === 'region' ? 'region' : 'full',
        steps: clampedSteps,
        elapsedMs: result.elapsedMs,
        bytes: result.image.length,
      });
      request.log.info(
        {
          userId,
          scope,
          steps: clampedSteps,
          elapsedMs: result.elapsedMs,
          bytes: result.image.length,
          width: result.width,
          height: result.height,
          event: 'edit_ok',
        },
        'edit_ok',
      );
      return {
        imageBase64: result.image.toString('base64'),
        width: result.width,
        height: result.height,
        seed: result.seed,
      };
    } catch (err) {
      request.log.warn(
        { userId, scope, err: (err as Error).message, event: 'edit_failed' },
        'edit_failed',
      );
      return reply.code(502).send({ error: 'edit_failed', message: (err as Error).message });
    }
  });
};

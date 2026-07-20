/**
 * POST /v1/lift3d — lift a drawn object (transparent-PNG cutout from the
 * object library) to a canonical 3D model via Hunyuan3D v3 (modules/fal/
 * falLift3d.ts). The textured GLB comes back inline for on-device placement (GLTFKit2 → SceneKit).
 *
 * Body: { imageBase64: string (PNG/JPEG) }
 * 200 → { glbBase64, thumbnailBase64? }
 * 402 → { error: 'free_limit_reached' }
 * 502 → { error: 'lift3d_failed', message }
 *
 * Long request by design (1-4 min generation, server-side queue polling);
 * the client sets a generous timeout. Metered like edits/videos.
 */

import type { FastifyPluginAsync } from 'fastify';
import { checkFalBudget, addMonthlySpendUsd } from '../modules/falBudget/index.js';
import { falLift3d } from '../modules/fal/falLift3d.js';
import { config } from '../config/index.js';

export const lift3dRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post<{ Body: { imageBase64?: string } }>('/v1/lift3d', async (request, reply) => {
    const { imageBase64 } = request.body ?? {};
    if (!imageBase64) return reply.code(400).send({ error: 'imageBase64 required' });

    const userId = request.userId;
    const budget = await checkFalBudget(userId);
    if (!budget.allowed) return reply.code(402).send({ error: 'free_limit_reached' });

    const image = Buffer.from(imageBase64, 'base64');
    const contentType = image[0] === 0xff && image[1] === 0xd8 ? 'image/jpeg' : 'image/png';
    try {
      const result = await falLift3d(image, contentType);
      if (!budget.exempt) {
        await addMonthlySpendUsd(userId, config.LIFT3D_USD_PER_GENERATION);
      }
      request.log.info(
        {
          userId,
          elapsedMs: result.elapsedMs,
          glbBytes: result.glb.length,
          event: 'lift3d_ok',
        },
        'lift3d_ok',
      );
      return {
        glbBase64: result.glb.toString('base64'),
        thumbnailBase64: result.thumbnail?.toString('base64'),
      };
    } catch (err) {
      request.log.warn({ userId, err: (err as Error).message, event: 'lift3d_failed' }, 'lift3d_failed');
      return reply.code(502).send({ error: 'lift3d_failed', message: (err as Error).message });
    }
  });
};

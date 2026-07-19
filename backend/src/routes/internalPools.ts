/**
 * GET /v1/internal/pools — live pool state (both fleets) for Kiki Insights'
 * "Live pods" section: per-instance hold verdicts + interest attribution,
 * which exist only in this process's memory (getState()), not in Postgres.
 *
 * Auth: `x-internal-key` must equal INSIGHTS_INGEST_KEY — the secret the two
 * services already share for the ingest direction, reused for this one
 * read-only reverse call. 404s when the key isn't configured.
 */

import type { FastifyPluginAsync } from 'fastify';
import { timingSafeEqual } from 'node:crypto';
import { config } from '../config/index.js';
import { getState as imagePoolState } from '../modules/lambda/devPool.js';
import { getState as videoPoolState, poolEnabled as videoPoolEnabled } from '../modules/lambda/videoPool.js';

export const internalPoolsRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/internal/pools', { config: { public: true } }, async (request, reply) => {
    const key = config.INSIGHTS_INGEST_KEY;
    const given = request.headers['x-internal-key'];
    if (!key || typeof given !== 'string') return reply.code(404).send();
    const a = Buffer.from(given);
    const b = Buffer.from(key);
    if (a.length !== b.length || !timingSafeEqual(a, b)) return reply.code(404).send();
    return {
      image: imagePoolState(),
      video: { enabled: videoPoolEnabled(), ...videoPoolState() },
    };
  });
};

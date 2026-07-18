/**
 * Dev-only Lambda pool endpoints (test accounts only, JWT-authed via the
 * global auth gate — no `config: { public: true }`).
 *
 *   POST /v1/dev/lambda/ensure — spin up (or keep) the kiki-serve H100.
 *     Called by iOS at sign-in/app-open and when the Settings image-provider
 *     toggle flips to lambda. Non-blocking: returns the pool state snapshot.
 *   GET  /v1/dev/lambda/status — same snapshot, for the settings UI.
 *
 * See modules/lambda/devPool.ts for lifecycle (30-min idle reaper, /health
 * readiness) and documents/plans/lambda-image-provider.md for context.
 */

import type { FastifyPluginAsync } from 'fastify';
import { ensure, getState } from '../modules/lambda/devPool.js';
import { poolEnabled as videoPoolEnabled, ensure as ensureVideoPool } from '../modules/lambda/videoPool.js';
import { isTestAccount } from '../modules/falBudget/index.js';

export const lambdaDevRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post('/v1/dev/lambda/ensure', async (request, reply) => {
    if (!(await isTestAccount(request.userId))) {
      return reply.code(403).send({ error: 'test accounts only' });
    }
    // Side-effect: app-open is also video-pool interest, so the LTX node
    // starts its ~10 min boot before the user's first idle pause. (The
    // response stays the IMAGE pool state — iOS's status line parses it.)
    if (videoPoolEnabled()) ensureVideoPool();
    const state = ensure();
    request.log.info(
      { userId: request.userId, poolStatus: state.status, instanceId: state.instanceId, event: 'lambda_pool_ensure' },
      'lambda dev pool ensure',
    );
    return state;
  });

  fastify.get('/v1/dev/lambda/status', async (request, reply) => {
    if (!(await isTestAccount(request.userId))) {
      return reply.code(403).send({ error: 'test accounts only' });
    }
    return getState();
  });
};
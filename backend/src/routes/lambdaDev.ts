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
import { testAccountsOnly } from '../modules/falBudget/index.js';

export const lambdaDevRoute: FastifyPluginAsync = async (fastify) => {
  fastify.post('/v1/dev/lambda/ensure', { preHandler: testAccountsOnly }, async (request) => {
    const state = ensure();
    request.log.info(
      { userId: request.userId, poolStatus: state.status, instanceId: state.instanceId, event: 'lambda_pool_ensure' },
      'lambda dev pool ensure',
    );
    return state;
  });

  fastify.get('/v1/dev/lambda/status', { preHandler: testAccountsOnly }, async () => getState());
};
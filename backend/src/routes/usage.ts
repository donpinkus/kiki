/**
 * Usage route — current free-tier fal-spend for the signed-in user.
 *
 * Powers the in-app usage meter (the little bar that fills toward the monthly
 * $10 cap). JWT-authed via the global `authPlugin` preHandler (sets
 * `request.userId`). `exempt` is true for test accounts + active subscribers —
 * the client hides the meter for them (no cap applies).
 */

import type { FastifyPluginAsync } from 'fastify';

import { checkFalBudget } from '../modules/falBudget/index.js';

export const usageRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/usage', async (request, reply) => {
    const userId = request.userId;
    if (!userId) {
      return reply.code(401).send({ error: 'authentication_required' });
    }
    const budget = await checkFalBudget(userId);
    return reply.send({
      spendUsd: budget.spendUsd,
      capUsd: budget.capUsd,
      exempt: budget.exempt,
    });
  });
};

/**
 * Usage route — current free-tier fal-spend for the signed-in user.
 *
 * Powers the in-app usage meter (the little bar that fills toward the monthly
 * $10 cap). JWT-authed via the global `authPlugin` preHandler (sets
 * `request.userId`). `exempt` is true for test accounts + active subscribers —
 * the client hides the meter for them (no cap applies).
 */

import type { FastifyPluginAsync } from 'fastify';

import { extractBearer } from '../modules/auth/index.js';
import { verifyAccess } from '../modules/auth/jwt.js';
import { checkFalBudget } from '../modules/falBudget/index.js';

export const usageRoute: FastifyPluginAsync = async (fastify) => {
  fastify.get('/v1/usage', async (request, reply) => {
    // Self-authenticate: the global authPlugin preHandler is encapsulated and
    // does NOT run for sibling routes, so `request.userId` is never set here.
    // Verify the Bearer token directly (same pattern as /v1/auth/signout).
    const token = extractBearer(request.headers.authorization);
    if (!token) {
      return reply.code(401).send({ error: 'authentication_required' });
    }
    let userId: string;
    try {
      userId = (await verifyAccess(token)).sub;
    } catch {
      return reply.code(401).send({ error: 'invalid_token' });
    }
    const budget = await checkFalBudget(userId);
    return reply.send({
      spendUsd: budget.spendUsd,
      capUsd: budget.capUsd,
      exempt: budget.exempt,
    });
  });
};

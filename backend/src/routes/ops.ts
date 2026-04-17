/**
 * Ops endpoints for cost monitoring (WS4) and future observability (WS6).
 *
 * All endpoints gated by `X-Ops-Key` shared-secret header. If OPS_API_KEY
 * is unset, the route plugin registers but every request returns 401.
 */

import type { FastifyInstance } from 'fastify';

import {
  getSnapshot,
  getHistory,
  isValidOpsKey,
} from '../modules/orchestrator/costMonitor.js';

export async function opsRoute(app: FastifyInstance): Promise<void> {
  // Shared auth preHandler for all ops endpoints
  app.addHook('preHandler', async (request, reply) => {
    const key = request.headers['x-ops-key'] as string | undefined;
    if (!isValidOpsKey(key)) {
      return reply.status(401).send({ error: 'Unauthorized', statusCode: 401 });
    }
  });

  app.get('/v1/ops/cost', async (_request, reply) => {
    const snapshot = getSnapshot();
    if (!snapshot) {
      return reply.status(503).send({
        error: 'No data yet — cost monitor has not completed its first tick',
        statusCode: 503,
      });
    }
    return reply.send(snapshot);
  });

  app.get('/v1/ops/cost/history', async (_request, reply) => {
    return reply.send(getHistory());
  });
}

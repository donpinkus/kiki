/**
 * Ops endpoints.
 *
 * Two categories:
 *   - /v1/ops/cost/*  — cost-monitor snapshots for observability (WS4).
 *   - /v1/ops/test/*  — dev-only simulators that trigger specific orchestrator
 *                       flows so we can test UX without waiting for natural
 *                       timers (e.g. 30-min idle reap) or engineering a real
 *                       failure. Each simulator is a single small handler;
 *                       new ones land here as new scenarios come up.
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
import { emitState } from '../modules/orchestrator/orchestrator.js';

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

  // ─── /v1/ops/test/* — dev simulators ─────────────────────────────────
  //
  // Simulate the idle-reaper path for a given session: emits state='terminated'
  // with failure_category='idle_timeout' through the broker. The iPad WS
  // subscriber closes the client cleanly, iPad shows the "Session paused"
  // overlay. Does NOT terminate the pod — the natural reaper will clean it
  // up later (or manually via RunPod API). Intended only for exercising iOS
  // UX and broker plumbing.
  app.post<{ Params: { userId: string } }>(
    '/v1/ops/test/idle-timeout/:userId',
    async (request, reply) => {
      const { userId } = request.params;
      await emitState(userId, 'terminated', 'idle_timeout');
      return reply.send({ ok: true, userId, emitted: 'terminated', failureCategory: 'idle_timeout' });
    },
  );
}

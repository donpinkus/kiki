import type { FastifyPluginAsync } from 'fastify';
import { pool } from '../db.js';

export const healthRoute: FastifyPluginAsync = async (app) => {
  app.get('/health', async (_request, reply) => {
    try {
      await pool.query('SELECT 1');
      return reply.send({ status: 'ok' });
    } catch {
      return reply.code(503).send({ status: 'degraded', db: 'unreachable' });
    }
  });
};

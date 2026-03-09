import type { FastifyPluginAsync } from 'fastify';

/**
 * Mock auth plugin for Phase 1 prototype.
 *
 * In production this will validate JWTs from Sign in with Apple.
 * For now it passes through all requests with a placeholder user ID.
 */
export const authPlugin: FastifyPluginAsync = async (fastify) => {
  fastify.decorateRequest('userId', '');

  fastify.addHook('onRequest', async (request, _reply) => {
    // Skip auth for health check
    if (request.url === '/health') {
      return;
    }

    // TODO: Phase 2 — validate JWT from Authorization: Bearer <token>
    // For now, assign a placeholder user ID
    request.userId = 'mock-user-id';
  });
};

// Extend Fastify type definitions
declare module 'fastify' {
  interface FastifyRequest {
    userId: string;
  }
}

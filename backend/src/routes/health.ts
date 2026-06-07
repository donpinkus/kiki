import type { FastifyPluginAsync } from 'fastify';

export const healthRoute: FastifyPluginAsync = async (fastify) => {
  // Sentry test route — triggers a test error to verify Sentry is capturing.
  // Only available when SENTRY_DSN is set.
  if (process.env['SENTRY_DSN']) {
    fastify.get('/debug-sentry', { config: { public: true } }, async () => {
      throw new Error('Sentry test error — if you see this in Sentry, it works!');
    });
  }

  fastify.get('/health', {
    config: { public: true },
    schema: {
      response: {
        200: {
          type: 'object',
          properties: {
            status: { type: 'string' },
            timestamp: { type: 'string' },
          },
        },
      },
    },
    handler: async (_request, _reply) => {
      return {
        status: 'ok',
        timestamp: new Date().toISOString(),
      };
    },
  });
};

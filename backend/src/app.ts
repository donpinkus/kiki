import Fastify from 'fastify';
import cors from '@fastify/cors';
import { config } from './config/index.js';
import { generateRoute } from './routes/generate.js';
import { healthRoute } from './routes/health.js';
import { AppError } from './modules/errors.js';

export function buildApp() {
  const app = Fastify({
    bodyLimit: 10 * 1024 * 1024, // 10MB — base64 sketch images can be several MB
    logger: {
      level: config.LOG_LEVEL,
      transport:
        config.NODE_ENV === 'development'
          ? { target: 'pino-pretty', options: { translateTime: 'HH:MM:ss' } }
          : undefined,
    },
  });

  // Plugins
  app.register(cors, { origin: true });

  // Routes
  app.register(generateRoute);
  app.register(healthRoute);

  // Error handler
  app.setErrorHandler((error, _request, reply) => {
    if (error instanceof AppError) {
      reply.status(error.statusCode).send({
        error: error.code,
        message: error.message,
      });
      return;
    }

    // Fastify validation errors have statusCode set
    const fastifyError = error as { statusCode?: number; message?: string };
    if (fastifyError.statusCode && fastifyError.statusCode < 500) {
      reply.status(fastifyError.statusCode).send({
        error: 'VALIDATION_ERROR',
        message: fastifyError.message ?? 'Validation error',
      });
      return;
    }

    app.log.error(error);
    reply.status(500).send({
      error: 'INTERNAL_ERROR',
      message: 'An unexpected error occurred',
    });
  });

  return app;
}

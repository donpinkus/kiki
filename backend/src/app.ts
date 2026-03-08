import Fastify from 'fastify';
import cors from '@fastify/cors';
import { config } from './config/index.js';
import { generateRoute } from './routes/generate.js';
import { healthRoute } from './routes/health.js';
import { AppError } from './modules/errors.js';

export function buildApp() {
  const app = Fastify({
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
    if (error.statusCode && error.statusCode < 500) {
      reply.status(error.statusCode).send({
        error: 'VALIDATION_ERROR',
        message: error.message,
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

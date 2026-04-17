import Fastify from 'fastify';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import { config } from './config/index.js';
import { AppError, RateLimitedError } from './errors.js';
import { healthRoute } from './routes/health.js';
import { streamRoute } from './routes/stream.js';
import { authRoute } from './routes/auth.js';
import { opsRoute } from './routes/ops.js';
import { authPlugin } from './modules/auth/index.js';
import { start as startOrchestrator } from './modules/orchestrator/orchestrator.js';
import { start as startCostMonitor } from './modules/orchestrator/costMonitor.js';

const app = Fastify({
  bodyLimit: 10 * 1024 * 1024, // 10 MB — composited lineart snapshots are larger than plain sketches
  logger: {
    level: config.LOG_LEVEL,
    ...(config.NODE_ENV === 'development'
      ? {
          transport: {
            target: 'pino-pretty',
            options: { colorize: true },
          },
        }
      : {}),
  },
});

// --- Plugins ---
await app.register(cors, {
  origin: true,
  methods: ['GET', 'POST', 'PUT', 'DELETE', 'OPTIONS'],
});
await app.register(websocket);

// --- Application modules ---
await app.register(authPlugin);

// --- Routes ---
await app.register(healthRoute);
await app.register(authRoute);
await app.register(streamRoute);
await app.register(opsRoute);

// --- Error handler ---
app.setErrorHandler((error, request, reply) => {
  if (error instanceof AppError) {
    request.log.warn(
      { err: error, statusCode: error.statusCode },
      error.message,
    );

    const response: Record<string, unknown> = {
      error: error.name,
      message: error.message,
      statusCode: error.statusCode,
    };

    if (error instanceof RateLimitedError && error.retryAfter) {
      void reply.header('Retry-After', String(error.retryAfter));
    }

    return reply.status(error.statusCode).send(response);
  }

  // Fastify validation errors (from JSON schema)
  const err = error as Record<string, unknown>;
  if (err.validation) {
    request.log.warn({ err: error }, 'Validation error');
    return reply.status(400).send({
      error: 'ValidationError',
      message: String(err.message ?? 'Validation failed'),
      statusCode: 400,
    });
  }

  // Unexpected errors
  request.log.error({ err: error }, 'Unhandled error');
  return reply.status(500).send({
    error: 'InternalServerError',
    message: 'An unexpected error occurred',
    statusCode: 500,
  });
});

// --- Start ---
const start = async () => {
  try {
    // Orchestrator boots before the server accepts connections: reconciles any
    // orphan pods from a prior run and arms the idle reaper.
    await startOrchestrator(app.log);
    startCostMonitor(app.log);

    await app.listen({ port: config.PORT, host: config.HOST });
    app.log.info(`Server listening on ${config.HOST}:${config.PORT}`);
  } catch (err) {
    app.log.fatal(err);
    process.exit(1);
  }
};

start();

export { app };

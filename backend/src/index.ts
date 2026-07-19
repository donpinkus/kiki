// Sentry must init before all other imports for auto-instrumentation.
// (observability/* is safe: it imports only node:async_hooks + Sentry types.)
import * as Sentry from '@sentry/node';
import { beforeSendLog } from './modules/observability/sentryLog.js';

Sentry.init({
  dsn: process.env['SENTRY_DSN'] || '',
  environment: process.env['NODE_ENV'] ?? 'development',
  tracesSampleRate: 1.0,
  enableLogs: true,
  // Don't send if DSN is empty (local dev without Sentry)
  enabled: !!process.env['SENTRY_DSN'],
  integrations: [
    // Auto-captures `request.log.X({...}, 'msg')` and `app.log.X(...)` Pino
    // calls into Sentry's Logs product, preserving the structured first-arg
    // object as log attributes. Existing call sites in stream.ts flow
    // through unchanged.
    Sentry.pinoIntegration(),
    // Per-request async-context isolation so `Sentry.setUser({ id })` set in
    // the JWT preHandler stays scoped to that request. Without this, a setUser
    // call would leak to whichever request happened to be running next on the
    // same isolation scope.
    Sentry.fastifyIntegration(),
  ],
  // Cross-stack log-attribute normalization (snake_case remap + phase +
  // background_task injection) — see modules/observability/sentryLog.ts.
  beforeSendLog,
});

import Fastify from 'fastify';
import cors from '@fastify/cors';
import websocket from '@fastify/websocket';
import { config } from './config/index.js';
import { AppError } from './errors.js';
import { healthRoute } from './routes/health.js';
import { streamRoute } from './routes/stream.js';
import { animateRoute } from './routes/animate.js';
import { authRoute } from './routes/auth.js';
import { subscriptionRoute } from './routes/subscription.js';
import { appStoreNotifyRoute } from './routes/appStoreNotify.js';
import { usageRoute } from './routes/usage.js';
import { lambdaDevRoute } from './routes/lambdaDev.js';
import { internalPoolsRoute } from './routes/internalPools.js';
import { sketchifyRoute } from './routes/sketchify.js';
import { start as startLambdaDevPool, stop as stopLambdaDevPool } from './modules/lambda/devPool.js';
import { start as startLambdaVideoPool, stop as stopLambdaVideoPool } from './modules/lambda/videoPool.js';
import { startVideoFlag, stopVideoFlag } from './modules/video/videoFlag.js';
import { start as startCapacityMonitor, stop as stopCapacityMonitor } from './modules/lambda/capacityMonitor.js';
import { installAuth } from './modules/auth/index.js';
import { start as startFalWarmer, stop as stopFalWarmer } from './modules/fal/falWarmer.js';
import { shutdownAnalytics } from './modules/analytics/index.js';
import { ensureDb, pool as pgPool } from './postgres/client.js';
import { migrate } from './postgres/migrate.js';

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
// maxPayload raised from the 1 MiB default for /v1/animate: an
// animate_request carries up to 4 base64 keyframe images in one JSON text
// frame (~350 KB each after the iPad's ≤1024px JPEG downscale, 8 MB/frame
// hard cap server-side).
await app.register(websocket, { options: { maxPayload: 64 * 1024 * 1024 } });

// --- Application modules ---
// Global, fail-closed auth gate on the root app (see modules/auth/index.ts).
// Must precede route registration.
installAuth(app);

// --- Routes ---
await app.register(healthRoute);
await app.register(authRoute);
await app.register(subscriptionRoute);
await app.register(appStoreNotifyRoute);
await app.register(usageRoute);
await app.register(streamRoute);
await app.register(animateRoute);
await app.register(lambdaDevRoute);
await app.register(internalPoolsRoute);
await app.register(sketchifyRoute);

// --- Sentry error handler (must be before custom error handler) ---
Sentry.setupFastifyErrorHandler(app);

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
    // Durable store first: connect to Postgres and apply the (idempotent)
    // schema before anything serves traffic.
    await ensureDb();
    await migrate();
    app.log.info('Postgres connected and schema applied');

    // Keep the fal realtime pool warm (no-op unless IMAGE_PROVIDER=fal or
    // 'auto' — fal is auto-mode's fallback and must not be cold when the
    // H100 pool degrades a session onto it).
    startFalWarmer(app.log);
    // Lambda dev pool idle-reaper + redeploy re-adoption (no-op unless
    // LAMBDA_DEV_POOL_ENABLED). Instance launch happens on demand via
    // POST /v1/dev/lambda/ensure, not here.
    startLambdaDevPool(app.log);
    // Video pool: same machinery, dedicated LTX fleet (no-op unless
    // LAMBDA_VIDEO_POOL_ENABLED). Launch happens on user interest (stream
    // open / lambda ensure route), not here.
    // Runtime video kill switch (admin_config.video_generation, edited from
    // Insights → Ops) — loaded before the pool so its first tick sees it.
    startVideoFlag(app.log);
    startLambdaVideoPool(app.log);
    // Free read-only /instance-types heartbeat → Insights Capacity page.
    startCapacityMonitor(app.log);

    await app.listen({ port: config.PORT, host: config.HOST });
    app.log.info(`Server listening on ${config.HOST}:${config.PORT}`);
  } catch (err) {
    app.log.fatal(err);
    process.exit(1);
  }
};

start();

// Flush queued Insights events on graceful shutdown so we don't lose in-flight
// analytics when Railway restarts the container.
async function gracefulShutdown(signal: string): Promise<void> {
  app.log.info({ signal }, 'Shutting down — flushing analytics');
  stopFalWarmer();
  // Timer only — the kiki-serve instance intentionally survives redeploys
  // (start() re-adopts it via the name prefix + deterministic token).
  stopLambdaDevPool();
  stopLambdaVideoPool();
  stopVideoFlag();
  stopCapacityMonitor();
  try {
    await shutdownAnalytics();
  } catch (err) {
    app.log.warn({ err }, 'Failed to flush analytics during shutdown');
  }
  try {
    await pgPool.end();
  } catch (err) {
    app.log.warn({ err }, 'Failed to close Postgres pool during shutdown');
  }
  process.exit(0);
}
process.on('SIGTERM', () => void gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => void gracefulShutdown('SIGINT'));

export { app };

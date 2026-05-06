// Sentry must init before all other imports for auto-instrumentation.
import * as Sentry from '@sentry/node';
import { getActivePhase } from './modules/observability/phase.js';

// Pino fields → Sentry log attribute names. Keep snake_case across the stack
// (pod side already does — pod_kind, pod_id, phase, user_id, stream_id) so
// `user_id:X` returns identical results from kiki-pod, node-fastify, and
// kiki-ios. Without this normalization, Pino's camelCase would land as
// `attributes.userId` in Sentry while pods write `attributes.user_id`, and
// cross-stack queries would silently fragment.
const PINO_TO_SENTRY: Record<string, string> = {
  userId: 'user_id',
  sessionId: 'session_id',
  podId: 'pod_id',
  videoPodId: 'video_pod_id',
  connId: 'conn_id',
  streamId: 'stream_id',
  kind: 'pod_kind',
  elapsedMs: 'elapsed_ms',
};

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
    // object as log attributes. Existing call sites in orchestrator.ts /
    // stream.ts flow through unchanged.
    Sentry.pinoIntegration(),
    // Per-request async-context isolation so `Sentry.setUser({ id })` set in
    // the JWT preHandler stays scoped to that request. Without this, a setUser
    // call would leak to whichever request happened to be running next on the
    // same isolation scope.
    Sentry.fastifyIntegration(),
  ],
  // Promote Pino's camelCase structured fields to snake_case Sentry log
  // attributes per the cross-stack convention. Also injects the active
  // `phase` from AsyncLocalStorage if any `withPhase(...)` block is on the
  // stack at log-emit time. Mirrors `before_send_log` in
  // `flux-klein-server/sentry_init.py` (which does the same for the pod).
  beforeSendLog: (log) => {
    log.attributes ??= {};
    // Rebuild attributes once with snake_case keys mapped over. Building a
    // new dict (rather than `delete log.attributes[dynamicKey]` per pair)
    // sidesteps `@typescript-eslint/no-dynamic-delete` and avoids any
    // ordering subtleties if Sentry preserves insertion order.
    const remapped: Record<string, unknown> = {};
    for (const [k, v] of Object.entries(log.attributes)) {
      const sentryKey = PINO_TO_SENTRY[k] ?? k;
      remapped[sentryKey] = v;
    }
    log.attributes = remapped;
    const activePhase = getActivePhase();
    if (activePhase !== undefined) {
      log.attributes['phase'] = activePhase;
    }
    return log;
  },
});

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
import { shutdownAnalytics } from './modules/analytics/index.js';

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

// Flush queued PostHog events on graceful shutdown so we don't lose in-flight
// analytics when Railway restarts the container.
async function gracefulShutdown(signal: string): Promise<void> {
  app.log.info({ signal }, 'Shutting down — flushing analytics');
  try {
    await shutdownAnalytics();
  } catch (err) {
    app.log.warn({ err }, 'Failed to flush analytics during shutdown');
  }
  process.exit(0);
}
process.on('SIGTERM', () => void gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => void gracefulShutdown('SIGINT'));

export { app };

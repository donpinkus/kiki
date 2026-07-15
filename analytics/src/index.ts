/**
 * Kiki Insights — internal per-user analytics microsite.
 *
 * One Fastify process with two faces:
 *   - Ingest (public, authenticated): /ingest, /ingest/drawing
 *   - Dashboard (internal, admin-cookie): /admin/*, /blobs/*, and the React SPA
 *
 * The React SPA is built to web/dist and served statically; unknown non-API GETs
 * fall back to index.html for client-side routing.
 */

import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';

import Fastify from 'fastify';
import cookie from '@fastify/cookie';
import cors from '@fastify/cors';
import multipart from '@fastify/multipart';
import fastifyStatic from '@fastify/static';

import { config } from './config.js';
import { ensureDb } from './db.js';
import { migrate } from './migrate.js';
import { healthRoute } from './routes/health.js';
import { ingestRoute } from './routes/ingest.js';
import { adminRoute } from './routes/admin.js';

const here = dirname(fileURLToPath(import.meta.url));
const webDist = join(here, '..', 'web', 'dist');

const app = Fastify({
  bodyLimit: 5 * 1024 * 1024, // event batches (JSON); blobs go through multipart
  logger: {
    level: config.LOG_LEVEL,
    ...(config.NODE_ENV === 'development'
      ? { transport: { target: 'pino-pretty', options: { colorize: true } } }
      : {}),
  },
});

// --- Plugins ---
await app.register(cookie);
await app.register(cors, { origin: true, credentials: true });
await app.register(multipart, {
  // fileSize: headroom for generated images / small clips. files: a brush test
  // run (/ingest/test-run) uploads the whole scene battery + fixture replays in
  // one request (~10–30 PNGs today).
  limits: { fileSize: 25 * 1024 * 1024, files: 64 },
});

// --- API routes ---
await app.register(healthRoute);
await app.register(ingestRoute);
await app.register(adminRoute);

// --- Static SPA (built separately to web/dist) ---
if (existsSync(webDist)) {
  await app.register(fastifyStatic, { root: webDist, prefix: '/' });

  // SPA fallback: any non-API GET that didn't match a file serves index.html so
  // client-side routing (e.g. /users/:id) works on refresh / deep link.
  const indexHtml = join(webDist, 'index.html');
  app.setNotFoundHandler(async (request, reply) => {
    if (
      request.method === 'GET' &&
      !request.url.startsWith('/admin/api') &&
      !request.url.startsWith('/ingest') &&
      !request.url.startsWith('/blobs') &&
      !request.url.startsWith('/health')
    ) {
      return reply.type('text/html').send(await readFile(indexHtml, 'utf8'));
    }
    return reply.code(404).send({ error: 'not found' });
  });
} else {
  app.log.warn({ webDist }, 'web/dist not found — SPA not served (run npm run build:web)');
}

// --- Session-replay retention ---
// Capture frames are the only unbounded-growth blobs (a busy day can add
// hundreds of MB); prune rows + blobs past CAPTURE_RETENTION_DAYS daily.
// Batched so a large backlog can't hold a connection for minutes.
async function pruneCaptures(): Promise<void> {
  const { query } = await import('./db.js');
  const { blobStore } = await import('./blobStore.js');
  for (;;) {
    const { rows } = await query<{ id: string; blob_key: string }>(
      `SELECT id, blob_key FROM capture_frames
       WHERE captured_at < now() - make_interval(days => $1)
       ORDER BY captured_at LIMIT 500`,
      [config.CAPTURE_RETENTION_DAYS],
    );
    if (rows.length === 0) break;
    for (const r of rows) await blobStore.delete(r.blob_key);
    await query(`DELETE FROM capture_frames WHERE id = ANY($1::bigint[])`, [rows.map((r) => r.id)]);
    app.log.info({ pruned: rows.length }, 'capture retention prune batch');
  }
  // Prompt rows have no blobs — one bulk delete on the same retention window.
  await query(
    `DELETE FROM capture_prompts WHERE captured_at < now() - make_interval(days => $1)`,
    [config.CAPTURE_RETENTION_DAYS],
  );
}

// --- Boot ---
try {
  await migrate();
  await ensureDb();
  app.log.info('Postgres ready, schema applied');
  await app.listen({ port: config.PORT, host: config.HOST });
  app.log.info(`Kiki Insights listening on ${config.HOST}:${config.PORT}`);
  void pruneCaptures().catch((err) => app.log.warn({ err }, 'capture prune failed'));
  setInterval(
    () => void pruneCaptures().catch((err) => app.log.warn({ err }, 'capture prune failed')),
    24 * 60 * 60 * 1000,
  ).unref();
} catch (err) {
  app.log.error(err, 'failed to start Kiki Insights');
  process.exit(1);
}

for (const sig of ['SIGTERM', 'SIGINT'] as const) {
  process.on(sig, () => {
    app.log.info(`${sig} received, shutting down`);
    void app.close().then(() => process.exit(0));
  });
}

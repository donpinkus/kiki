/**
 * Ingestion — the public-but-authenticated write path.
 *
 *   POST /ingest          batch of events (iOS Bearer OR backend service key)
 *   POST /ingest/drawing  multipart: drawing metadata + thumbnail/generated blobs
 *
 * Events are the spine; sessions are rolled up here at write time from the
 * app-foreground/background and drawing-open/close events so the dashboard
 * timeline can render durations without recomputing on read.
 */

import type { FastifyPluginAsync } from 'fastify';
import type { PoolClient } from 'pg';
import { authenticateIngest } from '../auth.js';
import { pool, query } from '../db.js';
import { blobStore } from '../blobStore.js';

interface IncomingEvent {
  name?: string;
  properties?: Record<string, unknown>;
  occurred_at?: string | number;
  stream_id?: string;
  drawing_id?: string;
  user_id?: string; // required only for backend (service-key) source
}

interface IngestBody {
  events?: IncomingEvent[];
}

/** Normalize a client timestamp (ISO string | epoch ms | absent) to a Date. */
function toDate(value: string | number | undefined): Date {
  if (value === undefined) return new Date();
  if (typeof value === 'number') return new Date(value);
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? new Date() : d;
}

function numProp(props: Record<string, unknown> | undefined, key: string): number | undefined {
  const v = props?.[key];
  return typeof v === 'number' && Number.isFinite(v) ? v : undefined;
}

function strProp(props: Record<string, unknown> | undefined, key: string): string | undefined {
  const v = props?.[key];
  return typeof v === 'string' && v.length > 0 ? v : undefined;
}

/** Roll an event into the sessions table when it carries a completed duration. */
async function rollUpSession(
  client: PoolClient,
  userId: string,
  ev: IncomingEvent,
  occurredAt: Date,
): Promise<void> {
  // App-level session: emitted on background with how long the app was foregrounded.
  if (ev.name === 'app.backgrounded') {
    const durationMs = numProp(ev.properties, 'duration_ms') ?? numProp(ev.properties, 'session_duration_ms');
    if (durationMs !== undefined) {
      const started = new Date(occurredAt.getTime() - durationMs);
      await client.query(
        `INSERT INTO sessions (user_id, source, started_at, ended_at, duration_ms)
         VALUES ($1, 'app', $2, $3, $4)`,
        [userId, started, occurredAt, durationMs],
      );
    }
    return;
  }
  // Drawing-level session: drawing.closed already carries session_duration_ms.
  if (ev.name === 'drawing.closed') {
    const durationMs = numProp(ev.properties, 'session_duration_ms') ?? numProp(ev.properties, 'duration_ms');
    if (durationMs !== undefined) {
      const started = new Date(occurredAt.getTime() - durationMs);
      await client.query(
        `INSERT INTO sessions (user_id, source, started_at, ended_at, duration_ms, drawing_id)
         VALUES ($1, 'drawing', $2, $3, $4, $5)`,
        [userId, started, occurredAt, durationMs, ev.drawing_id ?? strProp(ev.properties, 'drawing_id') ?? null],
      );
    }
  }
}

export const ingestRoute: FastifyPluginAsync = async (app) => {
  app.post('/ingest', async (request, reply) => {
    let principal;
    try {
      principal = await authenticateIngest(request);
    } catch (err) {
      request.log.warn({ err: (err as Error).message }, 'ingest auth failed');
      return reply.code(401).send({ error: 'unauthorized' });
    }

    const body = request.body as IngestBody | undefined;
    const events = body?.events;
    if (!Array.isArray(events) || events.length === 0) {
      return reply.code(400).send({ error: 'events[] required' });
    }
    if (events.length > 500) {
      return reply.code(400).send({ error: 'too many events (max 500 per batch)' });
    }

    const client = await pool.connect();
    let accepted = 0;
    try {
      await client.query('BEGIN');
      for (const ev of events) {
        if (!ev.name || typeof ev.name !== 'string') continue;
        // iOS: trust the JWT sub. Backend: trust the per-event user_id.
        const userId = principal.source === 'ios' ? principal.userId : ev.user_id;
        if (!userId) continue;
        const occurredAt = toDate(ev.occurred_at);

        // No user upsert here — identity is owned by the backend's `users` table
        // (shared DB). We only record events/sessions keyed by user_id.
        await client.query(
          `INSERT INTO events (user_id, name, properties, occurred_at, source, stream_id, drawing_id)
           VALUES ($1, $2, $3::jsonb, $4, $5, $6, $7)`,
          [
            userId,
            ev.name,
            JSON.stringify(ev.properties ?? {}),
            occurredAt,
            principal.source,
            ev.stream_id ?? null,
            ev.drawing_id ?? null,
          ],
        );
        await rollUpSession(client, userId, ev, occurredAt);
        accepted += 1;
      }
      await client.query('COMMIT');
    } catch (err) {
      await client.query('ROLLBACK');
      request.log.error({ err: (err as Error).message }, 'ingest failed');
      return reply.code(500).send({ error: 'ingest failed' });
    } finally {
      client.release();
    }

    return reply.send({ accepted });
  });

  // ─── Drawing upload (multipart) ───────────────────────────────────────────
  // Fields: drawing_id (required), prompt, style_id, created_at, updated_at,
  //         user_id (only for service-key callers).
  // Files:  thumbnail, generated  (JPEG). Both optional; upsert merges.
  app.post('/ingest/drawing', async (request, reply) => {
    let principal;
    try {
      principal = await authenticateIngest(request);
    } catch (err) {
      request.log.warn({ err: (err as Error).message }, 'drawing ingest auth failed');
      return reply.code(401).send({ error: 'unauthorized' });
    }

    const fields: Record<string, string> = {};
    let thumbnailKey: string | null = null;
    let generatedKey: string | null = null;
    let drawingId: string | undefined;

    // Two-pass isn't possible with the streaming parser, so collect field values
    // and stream file parts as they arrive. drawing_id must precede files in the
    // multipart body; the iOS client is responsible for ordering fields first.
    const parts = (request as unknown as { parts: () => AsyncIterableIterator<MultipartPart> }).parts();
    for await (const part of parts) {
      if (part.type === 'field') {
        fields[part.fieldname] = String(part.value);
        if (part.fieldname === 'drawing_id') drawingId = String(part.value);
      } else {
        if (!drawingId) {
          // Drain to avoid backpressure, then reject.
          await part.toBuffer();
          continue;
        }
        const buf = await part.toBuffer();
        if (part.fieldname === 'thumbnail') {
          thumbnailKey = `drawings/${drawingId}/thumb.jpg`;
          await blobStore.put(thumbnailKey, buf);
        } else if (part.fieldname === 'generated') {
          generatedKey = `drawings/${drawingId}/generated.jpg`;
          await blobStore.put(generatedKey, buf);
        }
      }
    }

    if (!drawingId) return reply.code(400).send({ error: 'drawing_id required (must precede files)' });
    const userId = principal.source === 'ios' ? principal.userId : fields['user_id'];
    if (!userId) return reply.code(400).send({ error: 'user_id required' });

    await query(
      `INSERT INTO drawings (drawing_id, user_id, prompt, style_id, created_at, updated_at, thumbnail_key, generated_key)
       VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
       ON CONFLICT (drawing_id) DO UPDATE SET
         prompt        = COALESCE(EXCLUDED.prompt, drawings.prompt),
         style_id      = COALESCE(EXCLUDED.style_id, drawings.style_id),
         updated_at    = COALESCE(EXCLUDED.updated_at, drawings.updated_at),
         thumbnail_key = COALESCE(EXCLUDED.thumbnail_key, drawings.thumbnail_key),
         generated_key = COALESCE(EXCLUDED.generated_key, drawings.generated_key)`,
      [
        drawingId,
        userId,
        fields['prompt'] ?? null,
        fields['style_id'] ?? null,
        fields['created_at'] ? toDate(fields['created_at']) : null,
        fields['updated_at'] ? toDate(fields['updated_at']) : new Date(),
        thumbnailKey,
        generatedKey,
      ],
    );

    // drawing_count is computed live in the admin queries (COUNT over drawings),
    // so there's no counter to maintain here.
    return reply.send({ ok: true, drawing_id: drawingId });
  });
};

// Minimal shape of @fastify/multipart parts we consume.
interface MultipartPart {
  type: 'field' | 'file';
  fieldname: string;
  value?: unknown;
  toBuffer(): Promise<Buffer>;
}

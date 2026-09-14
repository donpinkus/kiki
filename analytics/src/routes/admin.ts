/**
 * Dashboard API (internal). Everything under /admin/api and /blobs is gated by
 * the admin session cookie. Login exchanges the single admin password for that
 * cookie.
 *
 * The read model is deliberately per-user: list users, then drill into one
 * user's full timeline (sessions + events) and drawings gallery — the view the
 * aggregate tools (Sentry) don't give.
 */

import type { FastifyPluginAsync, FastifyReply, FastifyRequest } from 'fastify';
import {
  ADMIN_COOKIE,
  requireAdmin,
  signAdminSession,
  verifyAdminPassword,
} from '../auth.js';
import { query } from '../db.js';
import { blobStore, randomStamp, safeFilename } from '../blobStore.js';
import { config } from '../config.js';

/** Parse the numeric `:id` route param; sends the 400 and returns null on junk. */
function parseIdParam(request: FastifyRequest, reply: FastifyReply): number | null {
  const id = Number((request.params as { id: string }).id);
  if (!Number.isFinite(id)) {
    void reply.code(400).send({ error: 'bad id' });
    return null;
  }
  return id;
}

/** Group child rows by parent key, preserving input (SQL ORDER BY) order. */
function groupBy<C>(children: C[], key: (c: C) => string): Map<string, C[]> {
  const map = new Map<string, C[]>();
  for (const c of children) {
    const k = key(c);
    const list = map.get(k) ?? [];
    list.push(c);
    map.set(k, list);
  }
  return map;
}

/** "Our H100 grid" regions for /admin/api/capacity/grid when the caller
 * doesn't pass ?regions= — mirrors the backend's LAMBDA_REGIONS (widened
 * 2026-09-12). Insights can't read the backend's env, so this is a mirror,
 * not a source of truth: keep it in step with the Railway var. */
const DEFAULT_GRID_REGIONS = 'us-southeast-1,us-south-2,us-east-1,us-west-3,us-south-3';

export const adminRoute: FastifyPluginAsync = async (app) => {
  // ─── Auth ──────────────────────────────────────────────────────────────────
  app.post('/admin/login', async (request, reply) => {
    const { password } = (request.body ?? {}) as { password?: string };
    if (!password || !verifyAdminPassword(password)) {
      return reply.code(401).send({ error: 'invalid password' });
    }
    const token = await signAdminSession();
    reply.setCookie(ADMIN_COOKIE, token, {
      httpOnly: true,
      sameSite: 'lax',
      secure: config.NODE_ENV === 'production',
      path: '/',
      maxAge: 30 * 24 * 60 * 60,
    });
    return reply.send({ ok: true });
  });

  app.post('/admin/logout', async (_request, reply) => {
    reply.clearCookie(ADMIN_COOKIE, { path: '/' });
    return reply.send({ ok: true });
  });

  // ─── Gated API ───────────────────────────────────────────────────────────
  app.register(async (gated) => {
    gated.addHook('preHandler', requireAdmin);

    gated.get('/admin/api/me', async () => ({ ok: true }));

    // ─── Brush clone targets (Brushes tab) ─────────────────────────────────
    // Reference briefs for recreating Procreate-style brushes: name + notes +
    // screenshots (stroke samples, settings panes). Claude pulls these via
    // BrushHarness/fetch-targets.sh and posts attempt renders back.

    gated.get('/admin/api/brush-targets', async () => {
      const { rows: targets } = await query<{ id: string; name: string; note: string | null; status: string; created_at: string; updated_at: string }>(
        `SELECT id, name, note, status, created_at, updated_at FROM brush_targets ORDER BY created_at DESC`,
      );
      if (targets.length === 0) return { targets: [] };
      const { rows: images } = await query<{ id: string; target_id: string; kind: string; label: string | null; note: string | null; blob_key: string; created_at: string }>(
        `SELECT id, target_id, kind, label, note, blob_key, created_at
         FROM brush_target_images WHERE target_id = ANY($1::bigint[]) ORDER BY created_at`,
        [targets.map((t) => t.id)],
      );
      const byTarget = groupBy(images, (img) => String(img.target_id));
      return {
        targets: targets.map((t) => ({
          ...t,
          images: (byTarget.get(String(t.id)) ?? []).map((img) => ({
            id: img.id, kind: img.kind, label: img.label, note: img.note, blob_key: img.blob_key, created_at: img.created_at,
          })),
        })),
      };
    });

    gated.post('/admin/api/brush-targets', async (request, reply) => {
      const body = request.body as { name?: string; note?: string };
      const name = (body?.name ?? '').trim();
      if (!name) return reply.code(400).send({ error: 'name required' });
      const { rows } = await query<{ id: string }>(
        `INSERT INTO brush_targets (name, note) VALUES ($1, $2) RETURNING id`,
        [name, body?.note ?? null],
      );
      return { ok: true, id: rows[0]?.id };
    });

    gated.patch('/admin/api/brush-targets/:id', async (request, reply) => {
      const id = parseIdParam(request, reply);
      if (id === null) return;
      const body = request.body as { name?: string; note?: string; status?: string };
      await query(
        `UPDATE brush_targets SET
           name = COALESCE($2, name),
           note = COALESCE($3, note),
           status = COALESCE($4, status),
           updated_at = now()
         WHERE id = $1`,
        [id, body?.name ?? null, body?.note ?? null, body?.status ?? null],
      );
      return { ok: true };
    });

    gated.delete('/admin/api/brush-targets/:id', async (request, reply) => {
      const id = parseIdParam(request, reply);
      if (id === null) return;
      await query(`DELETE FROM brush_targets WHERE id = $1`, [id]);
      return { ok: true };
    });

    // Multipart upload: any number of file parts (fieldname 'image'); optional
    // 'kind' field applies to all files in the request (reference | settings |
    // attempt; default reference). Filenames become the initial labels.
    gated.post('/admin/api/brush-targets/:id/images', async (request, reply) => {
      const id = parseIdParam(request, reply);
      if (id === null) return;
      const { rows: t } = await query(`SELECT id FROM brush_targets WHERE id = $1`, [id]);
      if (t.length === 0) return reply.code(404).send({ error: 'no such target' });

      let kind = 'reference';
      const saved: { id: string; label: string }[] = [];
      const parts = (request as unknown as { parts: () => AsyncIterableIterator<{ type: string; fieldname: string; value?: unknown; filename?: string; mimetype?: string; toBuffer: () => Promise<Buffer> }> }).parts();
      for await (const part of parts) {
        if (part.type === 'field') {
          if (part.fieldname === 'kind') kind = String(part.value);
          continue;
        }
        const buf = await part.toBuffer();
        if (buf.length === 0) continue;
        if (buf.length > 24 * 1024 * 1024) return reply.code(400).send({ error: 'image too large' });
        const label = (part.filename ?? 'image').replace(/\.[a-zA-Z0-9]+$/, '');
        const key = `brush-targets/${id}/${randomStamp()}-${safeFilename(part.filename ?? 'image.png')}`;
        await blobStore.put(key, buf);
        const { rows } = await query<{ id: string }>(
          `INSERT INTO brush_target_images (target_id, kind, label, blob_key) VALUES ($1, $2, $3, $4) RETURNING id`,
          [id, ['reference', 'settings', 'attempt'].includes(kind) ? kind : 'reference', label, key],
        );
        const savedId = rows[0]?.id;
        if (savedId) saved.push({ id: savedId, label });
      }
      await query(`UPDATE brush_targets SET updated_at = now() WHERE id = $1`, [id]);
      return { ok: true, images: saved };
    });

    gated.patch('/admin/api/brush-target-images/:id', async (request, reply) => {
      const id = parseIdParam(request, reply);
      if (id === null) return;
      const body = request.body as { label?: string; note?: string; kind?: string };
      await query(
        `UPDATE brush_target_images SET
           label = COALESCE($2, label),
           note = COALESCE($3, note),
           kind = COALESCE($4, kind)
         WHERE id = $1`,
        [id, body?.label ?? null, body?.note ?? null, body?.kind ?? null],
      );
      return { ok: true };
    });

    gated.delete('/admin/api/brush-target-images/:id', async (request, reply) => {
      const id = parseIdParam(request, reply);
      if (id === null) return;
      await query(`DELETE FROM brush_target_images WHERE id = $1`, [id]);
      return { ok: true };
    });

    // Brush-test battery runs (newest first), images nested per run. Feeds the
    // Tests tab (visual gallery + cross-run side-by-sides; no pass/fail).
    gated.get('/admin/api/test-runs', async (request) => {
      const limit = Math.min(Number((request.query as { limit?: string }).limit) || 30, 200);
      const { rows: runs } = await query<{ id: string; git_sha: string | null; note: string | null; created_at: string }>(
        `SELECT id, git_sha, note, created_at FROM test_runs ORDER BY created_at DESC LIMIT $1`,
        [limit],
      );
      if (runs.length === 0) return { runs: [] };
      const { rows: images } = await query<{ run_id: string; scene: string; blob_key: string; description: string | null }>(
        `SELECT run_id, scene, blob_key, description FROM test_run_images WHERE run_id = ANY($1::bigint[]) ORDER BY scene`,
        [runs.map((r) => r.id)],
      );
      const byRun = groupBy(images, (img) => String(img.run_id));
      return {
        runs: runs.map((r) => ({
          ...r,
          images: (byRun.get(String(r.id)) ?? []).map((img) => ({
            scene: img.scene, blob_key: img.blob_key, description: img.description,
          })),
        })),
      };
    });

    // Brush-dev stroke fixtures (newest first) — consumed by
    // `BrushHarness/fetch-fixtures.sh`, which downloads the keys via /blobs/*.
    gated.get('/admin/api/fixtures', async (request) => {
      const limit = Math.min(Number((request.query as { limit?: string }).limit) || 25, 200);
      const { rows } = await query(
        `SELECT id, user_id, name, note, stroke_count, fixture_key, snapshot_key, created_at
         FROM fixtures ORDER BY created_at DESC LIMIT $1`,
        [limit],
      );
      return { fixtures: rows };
    });

    // Day key in the admin's timezone (America/Los_Angeles) — matches the SQL
    // `AT TIME ZONE 'America/Los_Angeles'` bucketing below so a session at
    // 11pm Pacific lands on the same bar the admin expects.
    const laDay = (d: Date): string =>
      new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Los_Angeles' }).format(d);

    // Users list. Source of truth is the BACKEND's `users` table (identity +
    // subscription + test flag) and `monthly_usage` (this month's fal spend);
    // Insights-owned events/sessions/drawings contribute the activity rollups.
    // user_id is UUID in `users` and TEXT in our tables → cast u.user_id::text.
    gated.get('/admin/api/users', async (request) => {
      const q = (request.query as { q?: string }).q?.trim() ?? '';
      const { rows } = await query(
        `SELECT u.user_id::text                       AS user_id,
                u.email,
                u.is_test_account,
                u.subscription_status,
                u.created_at,
                ev.last_seen,
                COALESCE(ev.event_count, 0)           AS event_count,
                COALESCE(se.session_count, 0)         AS session_count,
                COALESCE(dr.drawing_count, 0)         AS drawing_count,
                COALESCE(mu.fal_spend_usd, 0)::float8 AS fal_spend_usd_month
         FROM users u
         LEFT JOIN (SELECT user_id, count(*)::int AS event_count, max(occurred_at) AS last_seen
                    FROM events GROUP BY user_id) ev ON ev.user_id = u.user_id::text
         LEFT JOIN (SELECT user_id, count(*)::int AS session_count
                    FROM sessions GROUP BY user_id) se ON se.user_id = u.user_id::text
         LEFT JOIN (SELECT user_id, count(*)::int AS drawing_count
                    FROM drawings GROUP BY user_id) dr ON dr.user_id = u.user_id::text
         LEFT JOIN monthly_usage mu
                ON mu.user_id = u.user_id
               AND mu.month = to_char(now() AT TIME ZONE 'utc', 'YYYY-MM')
         WHERE ($1 = '' OR u.email ILIKE '%' || $1 || '%' OR u.user_id::text ILIKE '%' || $1 || '%')
         ORDER BY COALESCE(ev.last_seen, u.created_at) DESC
         LIMIT 200`,
        [q],
      );

      // Per-user daily in-app minutes for the row sparklines (last 14 Pacific
      // days). One aggregate query, merged in JS — avoids a lateral join per
      // user row. source='app' = foregrounded time (drawing sessions overlap
      // app sessions; summing both would double-count).
      const act = await query<{ user_id: string; day: string; minutes: number }>(
        `SELECT user_id,
                to_char(started_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                ceil(sum(duration_ms) / 60000.0)::int AS minutes
         FROM sessions
         WHERE source = 'app' AND started_at > now() - interval '15 days'
         GROUP BY 1, 2`,
      );
      const actByUser = new Map<string, Record<string, number>>();
      for (const r of act.rows) {
        const m = actByUser.get(r.user_id) ?? {};
        m[r.day] = r.minutes;
        actByUser.set(r.user_id, m);
      }
      const days = Array.from({ length: 14 }, (_, i) =>
        laDay(new Date(Date.now() - (13 - i) * 86_400_000)),
      );
      return {
        users: rows.map((u) => ({
          ...u,
          activity14d: days.map((d) => actByUser.get(u['user_id'] as string)?.[d] ?? 0),
        })),
      };
    });

    // Full per-user view: profile + sessions + recent events + drawings.
    gated.get('/admin/api/users/:id', async (request, reply) => {
      const { id } = request.params as { id: string };
      // Profile from the backend's authoritative users table. Compare ::text so a
      // non-uuid :id returns 404 rather than throwing on the uuid cast.
      const userRes = await query(
        `SELECT user_id::text AS user_id, email, apple_sub, is_test_account,
                subscription_status, subscription_expires_at, created_at, updated_at
         FROM users WHERE user_id::text = $1`,
        [id],
      );
      if (userRes.rowCount === 0) return reply.code(404).send({ error: 'user not found' });

      const [sessions, events, drawings, usage, dailyActivity, providerStats] = await Promise.all([
        query(
          `SELECT id, source, started_at, ended_at, duration_ms::int AS duration_ms, drawing_id
           FROM sessions WHERE user_id = $1 ORDER BY started_at DESC LIMIT 500`,
          [id],
        ),
        query(
          `SELECT id, name, properties, occurred_at, source, stream_id, drawing_id
           FROM events WHERE user_id = $1 ORDER BY occurred_at DESC LIMIT 1000`,
          [id],
        ),
        query(
          `SELECT drawing_id, prompt, style_id, created_at, updated_at,
                  thumbnail_key, generated_key, video_key
           FROM drawings WHERE user_id = $1 ORDER BY updated_at DESC NULLS LAST LIMIT 500`,
          [id],
        ),
        // Per-month fal spend (backend-owned). Newest first.
        query(
          `SELECT month, fal_spend_usd::float8 AS fal_spend_usd
           FROM monthly_usage WHERE user_id::text = $1 ORDER BY month DESC LIMIT 24`,
          [id],
        ),
        // Full-history daily in-app minutes (Pacific days) for the activity
        // bar chart. Gaps (zero days) are filled client-side.
        query(
          `SELECT to_char(started_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                  ceil(sum(duration_ms) / 60000.0)::int AS minutes
           FROM sessions
           WHERE user_id = $1 AND source = 'app'
           GROUP BY 1 ORDER BY 1`,
          [id],
        ),
        // Per-provider stream outcomes (all-time) from stream.provider_session
        // — H100 acquisition success, wait, disconnects, frame share.
        query(
          `SELECT COALESCE(properties->>'provider', 'unknown') AS provider,
                  count(*)::int AS sessions,
                  count(*) FILTER (WHERE (properties->>'lambda_bounced')::bool)::int AS bounced,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                    FILTER (WHERE (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS wait_p50_ms,
                  COALESCE(sum((properties->>'frames_delivered')::int), 0)::bigint AS frames,
                  COALESCE(sum((properties->>'upstream_disconnects')::int), 0)::int AS disconnects,
                  COALESCE(sum((properties->>'upstream_reconnects')::int), 0)::int AS reconnects
           FROM events
           WHERE user_id = $1 AND name = 'stream.provider_session'
           GROUP BY 1 ORDER BY sessions DESC`,
          [id],
        ),
      ]);

      return {
        user: userRes.rows[0],
        usage: usage.rows,
        daily_activity: dailyActivity.rows,
        sessions: sessions.rows,
        events: events.rows,
        provider_stats: providerStats.rows,
        drawings: drawings.rows.map((d) => ({
          ...d,
          thumbnail_url: d['thumbnail_key'] ? blobStore.urlFor(d['thumbnail_key'] as string) : null,
          generated_url: d['generated_key'] ? blobStore.urlFor(d['generated_key'] as string) : null,
        })),
      };
    });

    // ─── Launch analytics (aggregate views for launch week) ─────────────────
    // Everything derives from data already collected: events (iOS + backend
    // dual-write), sessions, users. Days are Pacific (matches the rest of the
    // dashboard). "Error event" = name matching error/fail — same heuristic as
    // the user-timeline highlighting.
    gated.get('/admin/api/launch', async (request) => {
      // ?excludeTest=1 → drop test accounts (users.is_test_account) from every
      // number on the page. Applied server-side: events rows don't carry the
      // flag, so each query filters via the users table.
      const excl = (request.query as { excludeTest?: string }).excludeTest === '1';
      // Test-account exclusion predicates, interpolated into the queries below
      // (every query binds [excl] as $1). Two forms because not every query
      // joins users: EXCL_EVENTS filters bare events rows via a subquery;
      // EXCL_JOINED expects a `u` alias from a LEFT JOIN users.
      const EXCL_EVENTS = `($1::bool = false OR user_id NOT IN
                  (SELECT user_id::text FROM users WHERE is_test_account))`;
      const EXCL_JOINED = `($1::bool = false OR COALESCE(u.is_test_account, false) = false)`;
      const [daily, newUsers, funnelRows, errorUsers, recentErrors, summary, providers, h100Waterfall, h100Pool, drawingOpened, drawingStages, videoPool, videoGen] = await Promise.all([
        query(
          `SELECT to_char(occurred_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                  count(DISTINCT user_id)::int AS dau,
                  count(*) FILTER (WHERE name = 'drawing.created')::int AS drawings,
                  count(*) FILTER (WHERE name = 'stream.started')::int AS streams,
                  count(*) FILTER (WHERE name ~* 'error|fail')::int AS errors,
                  count(*) FILTER (WHERE name = 'stream.ended'
                    AND (properties->>'frames_received') ~ '^[0-9]+$'
                    AND (properties->>'frames_received')::int = 0)::int AS dead_streams,
                  COALESCE(sum((properties->>'frames_received')::int)
                    FILTER (WHERE name = 'stream.ended'
                      AND (properties->>'frames_received') ~ '^[0-9]+$'), 0)::int AS frames,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'wait_ms')::float)
                    FILTER (WHERE name = 'stream.first_frame' AND (properties->>'wait_ms') ~ '^[0-9.]+$'))::int AS ttfi_p50,
                  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'wait_ms')::float)
                    FILTER (WHERE name = 'stream.first_frame' AND (properties->>'wait_ms') ~ '^[0-9.]+$'))::int AS ttfi_p90
           FROM events
           WHERE occurred_at > now() - interval '30 days'
             AND ${EXCL_EVENTS}
           GROUP BY 1`,
          [excl],
        ),
        query(
          `SELECT to_char(created_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                  count(*)::int AS new_users
           FROM users
           WHERE created_at > now() - interval '30 days'
             AND ($1::bool = false OR NOT is_test_account)
           GROUP BY 1`,
          [excl],
        ),
        // One row per user with funnel step flags + retention flags relative
        // to their Pacific signup day. ≤ a few hundred users at launch scale.
        query(
          `SELECT u.user_id::text AS user_id,
                  to_char(date_trunc('week', u.created_at AT TIME ZONE 'America/Los_Angeles'), 'YYYY-MM-DD') AS week,
                  EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id::text
                          AND e.name = 'drawing.opened') AS opened_drawing,
                  EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id::text
                          AND e.name = 'stream.first_frame') AS saw_image,
                  EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id::text
                          AND (e.occurred_at AT TIME ZONE 'America/Los_Angeles')::date
                              > (u.created_at AT TIME ZONE 'America/Los_Angeles')::date) AS returned,
                  EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id::text
                          AND (e.occurred_at AT TIME ZONE 'America/Los_Angeles')::date
                              = (u.created_at AT TIME ZONE 'America/Los_Angeles')::date + 1) AS d1,
                  EXISTS (SELECT 1 FROM events e WHERE e.user_id = u.user_id::text
                          AND (e.occurred_at AT TIME ZONE 'America/Los_Angeles')::date
                              BETWEEN (u.created_at AT TIME ZONE 'America/Los_Angeles')::date + 1
                                  AND (u.created_at AT TIME ZONE 'America/Los_Angeles')::date + 7) AS w1
           FROM users u
           WHERE ($1::bool = false OR NOT u.is_test_account)`,
          [excl],
        ),
        query(
          `SELECT e.user_id, u.email, count(*)::int AS errors, max(e.occurred_at) AS last_at
           FROM events e
           LEFT JOIN users u ON u.user_id::text = e.user_id
           WHERE e.name ~* 'error|fail' AND e.occurred_at > now() - interval '7 days'
             AND ${EXCL_JOINED}
           GROUP BY 1, 2
           ORDER BY errors DESC
           LIMIT 20`,
          [excl],
        ),
        query(
          `SELECT e.occurred_at, e.user_id, u.email, e.name, e.properties
           FROM events e
           LEFT JOIN users u ON u.user_id::text = e.user_id
           WHERE e.name ~* 'error|fail'
             AND ${EXCL_JOINED}
           ORDER BY e.occurred_at DESC
           LIMIT 25`,
          [excl],
        ),
        query(
          `SELECT round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'wait_ms')::float))::int AS ttfi_p50_7d,
                  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'wait_ms')::float))::int AS ttfi_p90_7d
           FROM events
           WHERE name = 'stream.first_frame' AND (properties->>'wait_ms') ~ '^[0-9.]+$'
             AND occurred_at > now() - interval '7 days'
             AND ${EXCL_EVENTS}`,
          [excl],
        ),
      // ─── H100 / provider visibility (7d): per-provider session outcomes ──
      // from stream.provider_session (emitted by the backend at socket close).
      query(
        `SELECT COALESCE(properties->>'provider', 'unknown') AS provider,
                count(*)::int AS sessions,
                count(*) FILTER (WHERE (properties->>'lambda_bounced')::bool)::int AS bounced,
                count(*) FILTER (WHERE properties->>'time_to_provider_ms' IS NOT NULL)::int AS wired,
                round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                  FILTER (WHERE (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS wait_p50_ms,
                round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                  FILTER (WHERE (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS wait_p90_ms,
                COALESCE(sum((properties->>'frames_delivered')::int), 0)::bigint AS frames,
                COALESCE(sum((properties->>'upstream_disconnects')::int), 0)::int AS disconnects,
                COALESCE(sum((properties->>'upstream_reconnects')::int), 0)::int AS reconnects,
                count(*) FILTER (WHERE (properties->>'upstream_disconnects')::int > 0)::int AS sessions_with_disconnect
         FROM events
         WHERE name = 'stream.provider_session'
           AND occurred_at > now() - interval '7 days'
           AND ${EXCL_EVENTS}
         GROUP BY 1
         ORDER BY sessions DESC`,
        [excl],
      ),
      // ─── H100 waterfall: session-side stages (7d) ────────────────────────
      // Seven cumulative stages over ALL provider sessions:
      //   sessions → requested H100 (intent auto|lambda) → found (an instance
      //   existed) → warmed (a READY instance existed) → connected (lambda
      //   relay opened) → ≥1 H100 frame → held (no downgrade, no drop).
      // Stage fields shipped by trackProviderSession; rows predating them are
      // counted in `sessions` but reported as `untracked` for stages 2+.
      (() => {
        const wired = `COALESCE((properties->>'lambda_wired')::bool, false)`;
        const bounced = `COALESCE((properties->>'lambda_bounced')::bool, false)`;
        const downgraded = `COALESCE((properties->>'lambda_downgraded')::bool, false)`;
        const disconnects = `COALESCE((properties->>'upstream_disconnects')::int, 0)`;
        const requested = `properties->>'requested_provider' IN ('auto', 'lambda')`;
        // Warmed = a ready instance existed for this session: it wired, or
        // auto resolved while the pool was ready, or an explicit-lambda
        // session got an assignment (final provider lambda, not bounced).
        const warmed = `(${wired} OR properties->>'pool_status_at_resolve' = 'ready'
          OR (properties->>'provider' = 'lambda' AND NOT ${bounced}))`;
        // Found = warmed, or an instance existed but was still warming.
        const found = `(${warmed} OR properties->>'pool_status_at_resolve' = 'booting'
          OR properties->>'pool_status_at_bounce' = 'booting')`;
        return query(
          `SELECT count(*)::int AS sessions,
                  count(*) FILTER (WHERE properties ? 'requested_provider')::int AS tracked,
                  count(*) FILTER (WHERE ${requested})::int AS requested,
                  count(*) FILTER (WHERE ${requested} AND ${found})::int AS found,
                  count(*) FILTER (WHERE ${requested} AND ${warmed})::int AS warmed,
                  count(*) FILTER (WHERE ${wired})::int AS connected,
                  count(*) FILTER (WHERE COALESCE((properties->>'lambda_frames')::int, 0) > 0)::int AS h100_frames,
                  count(*) FILTER (WHERE ${wired} AND NOT ${downgraded} AND ${disconnects} = 0)::int AS held,
                  count(*) FILTER (WHERE ${downgraded})::int AS downgraded,
                  count(*) FILTER (WHERE ${wired} AND NOT ${downgraded} AND ${disconnects} > 0)::int AS dropped,
                  -- Session-side transition timings (min/median/max) for the
                  -- side-by-side duration widget.
                  min((properties->>'time_to_provider_ms')::int) FILTER (WHERE ${wired}) AS connect_min_ms,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                    FILTER (WHERE ${wired} AND (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS connect_med_ms,
                  max((properties->>'time_to_provider_ms')::int) FILTER (WHERE ${wired}) AS connect_max_ms,
                  min((properties->>'lambda_first_frame_ms')::int) AS ff_min_ms,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'lambda_first_frame_ms')::float)
                    FILTER (WHERE (properties->>'lambda_first_frame_ms') ~ '^[0-9.]+$'))::int AS ff_med_ms,
                  max((properties->>'lambda_first_frame_ms')::int) AS ff_max_ms
           FROM events
           WHERE name = 'stream.provider_session'
             AND occurred_at > now() - interval '7 days'
             AND ${EXCL_EVENTS}`,
          [excl],
        );
      })(),
      // ─── H100 waterfall: pool-side stages + timings (7d, infra events — no
      // test-account dimension). search = capacity request → granted;
      // boot = granted → OUR /health ok.
      query(
        `SELECT count(*) FILTER (WHERE event = 'launch_requested')::int AS launch_requests,
                count(*) FILTER (WHERE event = 'launched')::int AS capacity_granted,
                count(*) FILTER (WHERE event = 'ready' AND duration_ms > 5000)::int AS became_ready,
                count(*) FILTER (WHERE event = 'launch_failed')::int AS launch_failed,
                count(*) FILTER (WHERE event = 'instance_dead')::int AS died,
                round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)
                  FILTER (WHERE event = 'launched'))::int AS search_p50_ms,
                min(duration_ms) FILTER (WHERE event = 'launched') AS search_min_ms,
                max(duration_ms) FILTER (WHERE event = 'launched') AS search_max_ms,
                -- duration > 5s: excludes adoption-era 'ready' rows whose
                -- launchedAtMs was the redeploy adoption time, not a boot.
                round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)
                  FILTER (WHERE event = 'ready' AND duration_ms > 5000))::int AS boot_p50_ms,
                min(duration_ms) FILTER (WHERE event = 'ready' AND duration_ms > 5000) AS boot_min_ms,
                max(duration_ms) FILTER (WHERE event = 'ready' AND duration_ms > 5000) AS boot_max_ms
         FROM lambda_pool_events
         WHERE ts > now() - interval '7 days' AND pool = 'image'`,
      ).catch((err: { code?: string }) => {
        // Table (and, briefly, the 'pool' column added 2026-07-18 with the
        // video fleet) is backend-owned; absent until the backend deploy
        // that creates it. Don't let that 500 the whole Launch payload.
        // 42P01 = undefined_table, 42703 = undefined_column.
        if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
        throw err;
      }),
      // ─── Drawing-experience waterfall (7d): one funnel per canvas open ───
      // Stage 1 comes from drawing.opened; every later stage is measured on
      // the matching drawing.closed event (generation_count / strokes_added /
      // session_duration_ms) — a canvas open without a close (app killed
      // mid-session) can't be staged and is surfaced as the gap in stage 2.
      query(
        `SELECT count(*)::int AS opened
         FROM events
         WHERE name = 'drawing.opened' AND occurred_at > now() - interval '7 days'
           AND ${EXCL_EVENTS}`,
        [excl],
      ),
      (() => {
        const gen = `COALESCE((properties->>'generation_count')::int, 0)`;
        // strokes_added ships with the next iOS build; older closes fall back
        // to "generated something ⇒ must have stroked".
        const stroked = `(COALESCE((properties->>'strokes_added')::int, 0) > 0
          OR ((properties->>'strokes_added') IS NULL AND ${gen} > 0))`;
        const durOk = `(properties->>'session_duration_ms') ~ '^[0-9.]+$'`;
        const durI = `(properties->>'session_duration_ms')::int`;
        const durF = `(properties->>'session_duration_ms')::float`;
        const stages: Array<[string, string]> = [
          ['closed', 'true'],
          ['stroked', stroked],
          ['gen1', `${gen} >= 1`],
          ['gen10', `${gen} > 10`],
          ['gen50', `${gen} > 50`],
          ['gen100', `${gen} > 100`],
        ];
        const cols = stages
          .map(
            ([k, cond]) => `
                count(*) FILTER (WHERE ${cond})::int AS ${k},
                min(${durI}) FILTER (WHERE ${cond} AND ${durOk}) AS ${k}_min_ms,
                round(percentile_cont(0.5) WITHIN GROUP (ORDER BY ${durF})
                  FILTER (WHERE ${cond} AND ${durOk}))::int AS ${k}_med_ms,
                max(${durI}) FILTER (WHERE ${cond} AND ${durOk}) AS ${k}_max_ms`,
          )
          .join(',');
        return query(
          `SELECT ${cols}
           FROM events
           WHERE name = 'drawing.closed' AND occurred_at > now() - interval '7 days'
             AND ${EXCL_EVENTS}`,
          [excl],
        );
      })(),
      // ─── VIDEO pool waterfall (7d): same infra stages as the image pool,
      // pool='video' (launch → capacity → ready; deaths, boot stalls, and
      // drain terminations from the Insights kill switch). ─────────────────
      query(
        `SELECT count(*) FILTER (WHERE event = 'launch_requested')::int AS launch_requests,
                count(*) FILTER (WHERE event = 'launched')::int AS capacity_granted,
                count(*) FILTER (WHERE event = 'ready' AND duration_ms > 5000)::int AS became_ready,
                count(*) FILTER (WHERE event = 'launch_failed')::int AS launch_failed,
                count(*) FILTER (WHERE event = 'instance_dead')::int AS died,
                count(*) FILTER (WHERE event = 'boot_stalled')::int AS boot_stalled,
                count(*) FILTER (WHERE event = 'disabled_terminate')::int AS drained,
                round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)
                  FILTER (WHERE event = 'launched'))::int AS search_p50_ms,
                round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)
                  FILTER (WHERE event = 'ready' AND duration_ms > 5000))::int AS boot_p50_ms
         FROM lambda_pool_events
         WHERE ts > now() - interval '7 days' AND pool = 'video'`,
      ).catch((err: { code?: string }) => {
        if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
        throw err;
      }),
      // ─── Video generation funnel (7d) from stream.provider_session's
      // video_* counters: sessions with a video path → ≥1 trigger →
      // ≥1 delivered; totals for rate math. ────────────────────────────────
      query(
        `SELECT count(*) FILTER (WHERE (properties->>'video_triggered') IS NOT NULL)::int AS video_sessions,
                count(*) FILTER (WHERE COALESCE((properties->>'video_triggered')::int, 0) > 0)::int AS sessions_triggered,
                count(*) FILTER (WHERE COALESCE((properties->>'video_completed')::int, 0) > 0)::int AS sessions_delivered,
                COALESCE(sum((properties->>'video_triggered')::int), 0)::int AS videos_triggered,
                COALESCE(sum((properties->>'video_completed')::int), 0)::int AS videos_delivered,
                COALESCE(sum((properties->>'video_cancelled')::int), 0)::int AS videos_cancelled,
                COALESCE(sum((properties->>'video_failed')::int), 0)::int AS videos_failed
         FROM events
         WHERE name = 'stream.provider_session'
           AND occurred_at > now() - interval '7 days'
           AND ${EXCL_EVENTS}`,
        [excl],
      ),
      ]);

      // Merge the two daily sources and aggregate the per-user funnel rows.
      const byDay = new Map<string, Record<string, unknown>>();
      for (const r of daily.rows) byDay.set(r['day'] as string, { ...r });
      for (const r of newUsers.rows) {
        const d: Record<string, unknown> = byDay.get(r['day'] as string) ?? { day: r['day'] };
        d['new_users'] = r['new_users'];
        byDay.set(r['day'] as string, d);
      }

      const funnel = { signed_up: 0, opened_drawing: 0, saw_image: 0, returned: 0 };
      const cohortMap = new Map<string, { week: string; signups: number; d1: number; w1: number }>();
      for (const r of funnelRows.rows) {
        funnel.signed_up += 1;
        if (r['opened_drawing']) funnel.opened_drawing += 1;
        if (r['saw_image']) funnel.saw_image += 1;
        if (r['returned']) funnel.returned += 1;
        const wk = r['week'] as string;
        const c = cohortMap.get(wk) ?? { week: wk, signups: 0, d1: 0, w1: 0 };
        c.signups += 1;
        if (r['d1']) c.d1 += 1;
        if (r['w1']) c.w1 += 1;
        cohortMap.set(wk, c);
      }

      return {
        daily: [...byDay.values()],
        funnel,
        cohorts: [...cohortMap.values()].sort((a, b) => b.week.localeCompare(a.week)),
        errorUsers: errorUsers.rows,
        recentErrors: recentErrors.rows,
        summary: summary.rows[0] ?? null,
        providers: providers.rows,
        h100_waterfall: h100Waterfall.rows[0] ?? null,
        h100_pool: h100Pool.rows[0] ?? null,
        video_pool: videoPool.rows[0] ?? null,
        video_generation: videoGen.rows[0] ?? null,
        drawing_funnel: {
          opened: (drawingOpened.rows[0]?.['opened'] as number) ?? 0,
          ...(drawingStages.rows[0] ?? {}),
        },
      };
    });

    // ─── GPU Fleet (dedicated tab): the user-experienced quality of both
    // H100 systems + the fleet lifecycle behind it. Session-side numbers come
    // from stream.provider_session / stream.video_generation; infra-side from
    // lambda_pool_events. All 7d unless noted; ?excludeTest=1 as elsewhere.
    gated.get('/admin/api/fleet', async (request) => {
      const excl = (request.query as { excludeTest?: string }).excludeTest === '1';
      const EXCL = `($1::bool = false OR user_id NOT IN
        (SELECT user_id::text FROM users WHERE is_test_account))`;
      const wired = `COALESCE((properties->>'lambda_wired')::bool, false)`;
      // Lambda per-hour price by instance type (parsed from the launched
      // event's `type@region` detail). $/hr from Lambda's list, 2026-07.
      const priceCase = `CASE split_part(COALESCE(l.detail,''), '@', 1)
                    WHEN 'gpu_1x_h100_sxm5' THEN 4.29
                    WHEN 'gpu_1x_h100_pcie' THEN 3.29
                    WHEN 'gpu_1x_a100_sxm4' THEN 1.99
                    WHEN 'gpu_1x_a100'      THEN 1.99
                    WHEN 'gpu_1x_gh200'     THEN 2.29
                    WHEN 'gpu_1x_a6000'     THEN 1.09
                    ELSE 4.29 END`;
      const [image, video, pools, recentEvents, daily, gpuSpend, falSpend, spendDaily, acquisitions, h100Misses, recentMisses] = await Promise.all([
        // Image system: acquisition + waits + generation + render ratio.
        query(
          `SELECT count(*)::int AS sessions,
                  count(*) FILTER (WHERE properties->>'requested_provider' IN ('auto','lambda'))::int AS requested,
                  count(*) FILTER (WHERE ${wired})::int AS wired,
                  count(*) FILTER (WHERE COALESCE((properties->>'lambda_frames')::int,0) > 0)::int AS framed,
                  count(*) FILTER (WHERE COALESCE((properties->>'lambda_downgraded')::bool,false))::int AS downgraded,
                  count(*) FILTER (WHERE COALESCE((properties->>'upstream_disconnects')::int,0) > 0)::int AS disconnected,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                    FILTER (WHERE ${wired} AND (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS wait_p50_ms,
                  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                    FILTER (WHERE ${wired} AND (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS wait_p90_ms,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'lambda_first_frame_ms')::float)
                    FILTER (WHERE (properties->>'lambda_first_frame_ms') ~ '^[0-9.]+$'))::int AS first_frame_p50_ms,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'image_gen_ms_p50')::float)
                    FILTER (WHERE (properties->>'image_gen_ms_p50') ~ '^[0-9.]+$'))::int AS gen_p50_ms,
                  round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'image_gen_ms_p90')::float)
                    FILTER (WHERE (properties->>'image_gen_ms_p90') ~ '^[0-9.]+$'))::int AS gen_p90_ms,
                  -- Render-ratio sums PAIRED over sessions that report
                  -- sketches_sent (instrumented 2026-07-18) — mixing older
                  -- frames-only sessions would inflate the ratio nonsensically.
                  COALESCE(sum((properties->>'frames_delivered')::int)
                    FILTER (WHERE COALESCE((properties->>'sketches_sent')::int, 0) > 0), 0)::int AS frames_delivered,
                  COALESCE(sum((properties->>'sketches_sent')::int), 0)::int AS sketches_sent,
                  COALESCE(sum((properties->>'frames_delivered')::int)
                    FILTER (WHERE ${wired} AND COALESCE((properties->>'sketches_sent')::int, 0) > 0), 0)::int AS h100_frames_delivered,
                  COALESCE(sum((properties->>'sketches_sent')::int)
                    FILTER (WHERE ${wired}), 0)::int AS h100_sketches_sent
           FROM events
           WHERE name = 'stream.provider_session'
             AND occurred_at > now() - interval '7 days' AND ${EXCL}`,
          [excl],
        ),
        // Video system: delivery funnel + waits + generation times.
        query(
          `WITH sessions AS (
             SELECT count(*) FILTER (WHERE (properties->>'video_triggered') IS NOT NULL)::int AS video_sessions,
                    count(*) FILTER (WHERE COALESCE((properties->>'video_triggered')::int,0) > 0)::int AS sessions_triggered,
                    count(*) FILTER (WHERE COALESCE((properties->>'video_completed')::int,0) > 0)::int AS sessions_delivered,
                    COALESCE(sum((properties->>'video_triggered')::int),0)::int AS videos_triggered,
                    COALESCE(sum((properties->>'video_completed')::int),0)::int AS videos_delivered,
                    COALESCE(sum((properties->>'video_cancelled')::int),0)::int AS videos_cancelled,
                    COALESCE(sum((properties->>'video_failed')::int),0)::int AS videos_failed
             FROM events
             WHERE name = 'stream.provider_session'
               AND occurred_at > now() - interval '7 days' AND ${EXCL}
           ), deliveries AS (
             SELECT count(*)::int AS delivered_events,
                    count(*) FILTER (WHERE properties->>'source' = 'manual')::int AS manual_count,
                    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'wait_ms')::float))::int AS wait_p50_ms,
                    round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'wait_ms')::float))::int AS wait_p90_ms,
                    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'gen_ms')::float)
                      FILTER (WHERE (properties->>'gen_ms') ~ '^[0-9.]+$'))::int AS gen_p50_ms,
                    round(percentile_cont(0.9) WITHIN GROUP (ORDER BY (properties->>'gen_ms')::float)
                      FILTER (WHERE (properties->>'gen_ms') ~ '^[0-9.]+$'))::int AS gen_p90_ms
             FROM events
             WHERE name = 'stream.video_generation'
               AND occurred_at > now() - interval '7 days' AND ${EXCL}
           )
           SELECT * FROM sessions, deliveries`,
          [excl],
        ),
        // Fleet lifecycle per pool.
        query(
          `SELECT pool,
                  count(*) FILTER (WHERE event = 'launch_requested')::int AS launch_requests,
                  count(*) FILTER (WHERE event = 'launched')::int AS capacity_granted,
                  count(*) FILTER (WHERE event = 'ready' AND duration_ms > 5000)::int AS became_ready,
                  count(*) FILTER (WHERE event = 'launch_failed')::int AS launch_failed,
                  count(*) FILTER (WHERE event = 'instance_dead')::int AS died,
                  count(*) FILTER (WHERE event = 'boot_stalled')::int AS boot_stalled,
                  count(*) FILTER (WHERE event = 'idle_terminate')::int AS idle_reaped,
                  count(*) FILTER (WHERE event = 'disabled_terminate')::int AS drained,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)
                    FILTER (WHERE event = 'launched'))::int AS search_p50_ms,
                  max(duration_ms) FILTER (WHERE event = 'launched') AS search_max_ms,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY duration_ms)
                    FILTER (WHERE event = 'ready' AND duration_ms > 5000))::int AS boot_p50_ms,
                  max(duration_ms) FILTER (WHERE event = 'ready' AND duration_ms > 5000) AS boot_max_ms
           FROM lambda_pool_events
           WHERE ts > now() - interval '7 days'
           GROUP BY pool ORDER BY pool`,
        ).catch((err: { code?: string }) => {
          if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
          throw err;
        }),
        // Raw recent lifecycle events — the debugging strip.
        query(
          `SELECT ts, pool, event, instance_name, duration_ms, detail
           FROM lambda_pool_events
           ORDER BY ts DESC LIMIT 40`,
        ).catch((err: { code?: string }) => {
          if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
          throw err;
        }),
        // 14-day daily trend of the experienced quality.
        query(
          `SELECT to_char(occurred_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                  count(*)::int AS sessions,
                  count(*) FILTER (WHERE ${wired})::int AS wired,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'time_to_provider_ms')::float)
                    FILTER (WHERE ${wired} AND (properties->>'time_to_provider_ms') ~ '^[0-9.]+$'))::int AS wait_p50_ms,
                  COALESCE(sum((properties->>'frames_delivered')::int)
                    FILTER (WHERE COALESCE((properties->>'sketches_sent')::int, 0) > 0),0)::int AS frames,
                  COALESCE(sum((properties->>'sketches_sent')::int),0)::int AS sketches,
                  COALESCE(sum((properties->>'video_completed')::int),0)::int AS videos
           FROM events
           WHERE name = 'stream.provider_session'
             AND occurred_at > now() - interval '14 days' AND ${EXCL}
           GROUP BY 1 ORDER BY 1 DESC`,
          [excl],
        ),
        // ─── GPU SPEND (7d): reconstruct instance lifetimes. Each
        // launched instance (name = kiki-(serve|video)-<epochMs>) is paired
        // with its earliest terminate-family event; still-open instances
        // count to now(). Price from the launched event's `type@region`
        // detail. Per (pool, type). Lambda bills per-minute from ready →
        // terminate; using launched→terminate slightly overcounts the boot
        // window (a few min) — acceptable for a spend "sense". ─────────────
        query(
          `WITH lifetimes AS (
             SELECT l.pool,
                    split_part(COALESCE(l.detail,''), '@', 1) AS itype,
                    ${priceCase} AS price_hr,
                    l.ts AS launched_at,
                    (SELECT min(t.ts) FROM lambda_pool_events t
                     WHERE t.instance_name = l.instance_name
                       AND t.event IN ('idle_terminate','instance_dead','boot_stalled','disabled_terminate')
                       AND t.ts >= l.ts) AS terminated_at
             FROM lambda_pool_events l
             WHERE l.event = 'launched' AND l.instance_name IS NOT NULL
               AND l.ts > now() - interval '7 days'
           )
           SELECT pool, itype,
                  count(*)::int AS instances,
                  count(*) FILTER (WHERE terminated_at IS NULL)::int AS still_open,
                  round(sum(extract(epoch FROM (COALESCE(terminated_at, now()) - launched_at)) / 3600.0)::numeric, 2)::float AS gpu_hours,
                  price_hr::float AS price_hr,
                  round(sum(extract(epoch FROM (COALESCE(terminated_at, now()) - launched_at)) / 3600.0 * price_hr)::numeric, 2)::float AS cost_usd
           FROM lifetimes
           GROUP BY pool, itype, price_hr
           ORDER BY pool, cost_usd DESC`,
        ).catch((err: { code?: string }) => {
          if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
          throw err;
        }),
        // ─── fal SPEND (7d): fal bills warm-runner-ATTACHED time only — a
        // cold ping's spin-up wait (≈ first_frame_ms) has no runner attached
        // and isn't billed (verified vs dashboard 2026-07-14). Split
        // user-drawing vs warmer overhead. ────────────────────────────────
        query(
          `SELECT source,
                  count(*)::int AS conns,
                  round(sum(greatest(0, open_ms - CASE WHEN found_warm IS DISTINCT FROM true
                    THEN COALESCE(first_frame_ms, open_ms) ELSE 0 END)) / 3600000.0, 2)::float AS billed_hours,
                  round(sum(greatest(0, open_ms - CASE WHEN found_warm IS DISTINCT FROM true
                    THEN COALESCE(first_frame_ms, open_ms) ELSE 0 END)) / 1000.0 * 0.00194, 2)::float AS cost_usd
           FROM fal_connections
           WHERE opened_at > now() - interval '7 days'
           GROUP BY source`,
        ).catch((err: { code?: string }) => {
          if (err.code === '42P01') return { rows: [] as Record<string, unknown>[] };
          throw err;
        }),
        // ─── Daily spend trend (14d): GPU cost/day (by launch day) + fal
        // cost/day. Two separate day-keyed series merged client-side. ──────
        query(
          `WITH lifetimes AS (
             SELECT to_char(l.ts AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                    ${priceCase} AS price_hr,
                    l.ts AS launched_at,
                    (SELECT min(t.ts) FROM lambda_pool_events t
                     WHERE t.instance_name = l.instance_name
                       AND t.event IN ('idle_terminate','instance_dead','boot_stalled','disabled_terminate')
                       AND t.ts >= l.ts) AS terminated_at
             FROM lambda_pool_events l
             WHERE l.event = 'launched' AND l.instance_name IS NOT NULL
               AND l.ts > now() - interval '14 days'
           ),
           gpu AS (
             SELECT day, round(sum(extract(epoch FROM (COALESCE(terminated_at, now()) - launched_at)) / 3600.0 * price_hr)::numeric, 2)::float AS gpu_usd
             FROM lifetimes GROUP BY day
           ),
           fal AS (
             SELECT to_char(opened_at AT TIME ZONE 'America/Los_Angeles', 'YYYY-MM-DD') AS day,
                    round(sum(greatest(0, open_ms - CASE WHEN found_warm IS DISTINCT FROM true
                      THEN COALESCE(first_frame_ms, open_ms) ELSE 0 END)) / 1000.0 * 0.00194, 2)::float AS fal_usd
             FROM fal_connections WHERE opened_at > now() - interval '14 days' GROUP BY day
           )
           SELECT COALESCE(gpu.day, fal.day) AS day,
                  COALESCE(gpu.gpu_usd, 0) AS gpu_usd,
                  COALESCE(fal.fal_usd, 0) AS fal_usd
           FROM gpu FULL OUTER JOIN fal ON gpu.day = fal.day
           ORDER BY day DESC`,
        ).catch((err: { code?: string }) => {
          if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
          throw err;
        }),
        // ─── GPU acquisition timeline: EVERY capacity hunt (7d), including
        // the ones that failed or were abandoned — each launch_requested
        // chained to its search outcome (launched / launch_failed /
        // sweep_abandoned / nothing = in flight or lost to a redeploy), boot
        // outcome (ready / boot_stalled), and end (reap / death / drain),
        // with the duration of every step. The anti-survivorship view: the
        // aggregate search stats above only average the wins. ──────────────
        query(
          `WITH req AS (
             SELECT ts, pool, instance_name FROM lambda_pool_events
             WHERE event = 'launch_requested' AND ts > now() - interval '7 days')
           SELECT req.ts, req.pool, req.instance_name,
                  s.event AS search_outcome, s.duration_ms::int AS search_ms, s.detail AS search_detail,
                  b.event AS boot_outcome, b.duration_ms::int AS boot_ms,
                  e.event AS end_event, e.duration_ms::int AS end_ms
           FROM req
           LEFT JOIN LATERAL (
             SELECT event, duration_ms, detail FROM lambda_pool_events x
             WHERE x.instance_name = req.instance_name AND x.ts >= req.ts
               AND x.event IN ('launched','launch_failed','sweep_abandoned')
             ORDER BY x.ts LIMIT 1) s ON true
           LEFT JOIN LATERAL (
             SELECT event, duration_ms FROM lambda_pool_events x
             WHERE x.instance_name = req.instance_name AND x.ts >= req.ts
               AND x.event IN ('ready','boot_stalled')
             ORDER BY x.ts LIMIT 1) b ON true
           LEFT JOIN LATERAL (
             SELECT event, duration_ms FROM lambda_pool_events x
             WHERE x.instance_name = req.instance_name AND x.ts >= req.ts
               AND x.event IN ('idle_terminate','instance_dead','disabled_terminate','hedge_loser_terminate')
             ORDER BY x.ts LIMIT 1) e ON true
           ORDER BY req.ts DESC LIMIT 40`,
        ).catch((err: { code?: string }) => {
          if (err.code === '42P01' || err.code === '42703') return { rows: [] as Record<string, unknown>[] };
          throw err;
        }),
        // ─── H100 misses (7d): sessions that wanted an H100 and NEVER wired,
        // grouped by what the pool was doing when they gave up. waited =
        // session duration (for a never-wired session the whole session IS
        // the wait). pool_ready_mid_session > 0 with status 'ready' = the
        // GPU arrived but auto never upgrades mid-session (product gap, not
        // infra failure). Ships once pool_status_at_close lands (2026-07-25);
        // older rows fall back to pool_status_at_resolve. ────────────────────
        query(
          `SELECT COALESCE(properties->>'pool_status_at_close',
                           properties->>'pool_status_at_resolve', 'untracked') AS pool_status,
                  count(*)::int AS sessions,
                  round(percentile_cont(0.5) WITHIN GROUP (ORDER BY (properties->>'duration_ms')::float))::int AS waited_p50_ms,
                  max((properties->>'duration_ms')::int) AS waited_max_ms,
                  count(*) FILTER (WHERE (properties->>'h100_ready_after_ms') ~ '^[0-9.]+$')::int AS pool_ready_mid_session
           FROM events
           WHERE name = 'stream.provider_session'
             AND occurred_at > now() - interval '7 days' AND ${EXCL}
             AND properties->>'requested_provider' IN ('auto','lambda')
             AND NOT COALESCE((properties->>'lambda_wired')::bool, false)
           GROUP BY 1 ORDER BY sessions DESC`,
          [excl],
        ),
        // The last 25 misses, one row per session — the concrete "this user,
        // this long, pool was doing X" record behind the summary above.
        query(
          `SELECT e.occurred_at, u.email,
                  (e.properties->>'duration_ms')::int AS duration_ms,
                  e.properties->>'pool_status_at_resolve' AS at_resolve,
                  COALESCE(e.properties->>'pool_status_at_close',
                           e.properties->>'pool_status_at_bounce') AS at_close,
                  CASE WHEN (e.properties->>'h100_ready_after_ms') ~ '^[0-9.]+$'
                       THEN (e.properties->>'h100_ready_after_ms')::int END AS ready_after_ms,
                  e.properties->>'client' AS client
           FROM events e
           LEFT JOIN users u ON u.user_id::text = e.user_id
           WHERE e.name = 'stream.provider_session'
             AND e.occurred_at > now() - interval '7 days'
             AND ($1::bool = false OR COALESCE(u.is_test_account, false) = false)
             AND e.properties->>'requested_provider' IN ('auto','lambda')
             AND NOT COALESCE((e.properties->>'lambda_wired')::bool, false)
           ORDER BY e.occurred_at DESC LIMIT 25`,
          [excl],
        ),
      ]);
      return {
        image: image.rows[0] ?? null,
        video: video.rows[0] ?? null,
        pools: pools.rows,
        recent_events: recentEvents.rows,
        daily: daily.rows,
        gpu_spend: gpuSpend.rows,
        fal_spend: falSpend.rows,
        spend_daily: spendDaily.rows,
        acquisitions: acquisitions.rows,
        h100_misses: h100Misses.rows,
        recent_misses: recentMisses.rows,
      };
    });

    // ─── Boots: per-boot success + timing decomposition ────────────────────
    // The dedicated boot view: every capacity hunt of one pool (30d = the
    // events table's retention), chained into a per-instance record with the
    // boot decomposed via the ready event's detail JSON ({provision_s, os_s,
    // stack_s, phases_ms} — recorded by the backend pool since 2026-08-22
    // from the server's own /health clocks). Shaped in TS: the table is tiny
    // (a few events per boot, a few boots per day) and the per-instance
    // chaining is clearer here than as N lateral joins.
    gated.get('/admin/api/boots', async (request) => {
      const q = request.query as { pool?: string };
      const pool = q.pool === 'video' ? 'video' : 'image';
      const { rows } = await query(
        `SELECT ts, event, instance_name, region, duration_ms, detail
         FROM lambda_pool_events
         WHERE pool = $1 AND ts > now() - interval '30 days'
         ORDER BY ts`,
        [pool],
      );
      type Ev = {
        ts: string;
        event: string;
        instance_name: string | null;
        region: string | null;
        duration_ms: number | null;
        detail: string | null;
      };
      const events = rows as Ev[];

      // Race winners are named in the loser's detail ("lost to <name>").
      // NOTE: the winner can be the ORIGINAL (hedge lost) — so this set is
      // "won a race", not "is a hedge". Hedge identity comes from the
      // launch_requested "hedge for …" marker (backend, 2026-08-22).
      const raceWinners = new Set<string>();
      for (const e of events) {
        if (e.event === 'hedge_loser_terminate' && e.detail?.startsWith('lost to ')) {
          raceWinners.add(e.detail.slice('lost to '.length));
        }
      }

      interface BootRow {
        requested_at: string;
        instance_name: string;
        region: string | null;
        gpu_type: string | null;
        outcome: string; // ready | boot_stalled | launch_failed | sweep_abandoned | hedge_lost | booting | unknown
        search_ms: number | null;
        ip_ms: number | null; // capacity granted → IP visible
        boot_ms: number | null; // capacity granted → /health ok
        provision_s: number | null; // launch → kernel (Lambda's share)
        os_s: number | null; // kernel → server process
        stack_s: number | null; // process → ready (our share)
        phases_ms: Record<string, number> | null;
        is_hedge: boolean; // launched as the racing instance
        hedge_won: boolean;
        hedged: boolean; // dragged long enough that a hedge was fired FOR it
        end_event: string | null; // idle_terminate | instance_dead | ...
        fail_detail: string | null;
      }

      const boots: BootRow[] = [];
      for (const [name, evs] of groupBy(events, (e) => e.instance_name ?? '?')) {
        const by = (ev: string): Ev | undefined => evs.find((e) => e.event === ev);
        const requested = by('launch_requested');
        const launched = by('launched');
        const ready = by('ready');
        const stalled = by('boot_stalled');
        const failed = by('launch_failed');
        const abandoned = by('sweep_abandoned');
        const hedgeLost = by('hedge_loser_terminate');
        // Adoption-only groups (instances re-registered on redeploy with no
        // launch in-window) aren't boots — skip unless a real hunt started.
        const anchor = requested ?? launched;
        if (!anchor) continue;

        let decomposition: {
          provision_s?: number;
          os_s?: number;
          stack_s?: number;
          phases_ms?: Record<string, number>;
        } = {};
        if (ready?.detail?.startsWith('{')) {
          try {
            decomposition = JSON.parse(ready.detail) as typeof decomposition;
          } catch {
            // pre-instrumentation / truncated detail — totals still shown
          }
        }

        const ageMs = Date.now() - new Date((launched ?? anchor).ts).getTime();
        const outcome = ready
          ? 'ready'
          : hedgeLost
            ? 'hedge_lost'
            : stalled
              ? 'boot_stalled'
              : failed
                ? 'launch_failed'
                : abandoned
                  ? 'sweep_abandoned'
                  : ageMs < 30 * 60_000
                    ? 'booting'
                    : 'unknown';

        boots.push({
          // pg hands timestamptz back as a Date — normalize to ISO so the
          // sort/day-grouping below and the client all see strings.
          requested_at: new Date(anchor.ts).toISOString(),
          instance_name: name,
          region: launched?.region ?? requested?.region ?? null,
          gpu_type: launched?.detail?.split('@')[0] ?? null,
          outcome,
          search_ms: launched?.duration_ms ?? null,
          ip_ms: by('ip_assigned')?.duration_ms ?? null,
          boot_ms: ready?.duration_ms ?? stalled?.duration_ms ?? null,
          provision_s: decomposition.provision_s ?? null,
          os_s: decomposition.os_s ?? null,
          stack_s: decomposition.stack_s ?? null,
          phases_ms: decomposition.phases_ms ?? null,
          is_hedge: Boolean(requested?.detail?.startsWith('hedge for ')),
          hedge_won: raceWinners.has(name),
          hedged: Boolean(by('hedge_launched')),
          end_event: by('idle_terminate')?.event ?? by('instance_dead')?.event ?? by('disabled_terminate')?.event ?? null,
          fail_detail: failed?.detail ?? abandoned?.detail ?? hedgeLost?.detail ?? null,
        });
      }
      boots.sort((a, b) => b.requested_at.localeCompare(a.requested_at));

      const p = (vals: number[], q: number): number | null => {
        if (vals.length === 0) return null;
        const s = [...vals].sort((a, b) => a - b);
        return s[Math.min(s.length - 1, Math.floor(q * s.length))] ?? null;
      };
      const readyBoots = boots.filter((b) => b.outcome === 'ready');
      const bootTimes = readyBoots.map((b) => b.boot_ms).filter((v): v is number => v != null);
      const searches = boots.map((b) => b.search_ms).filter((v): v is number => v != null);
      const provisions = readyBoots.map((b) => b.provision_s).filter((v): v is number => v != null);
      const stacks = readyBoots.map((b) => b.stack_s).filter((v): v is number => v != null);

      // Phase medians across instrumented boots (which init phase is the
      // stack's critical path — warmup vs load vs prefetch).
      const phaseVals = new Map<string, number[]>();
      for (const b of readyBoots) {
        for (const [k, v] of Object.entries(b.phases_ms ?? {})) {
          // phase_timings_ms also carries non-duration gauges (prefetch_bytes_mb,
          // cpu_mem_avail_mb_at_ready, worker counts) — durations only here.
          if (k.endsWith('_ms') && typeof v === 'number' && v > 500) {
            const list = phaseVals.get(k) ?? [];
            list.push(v);
            phaseVals.set(k, list);
          }
        }
      }
      const phase_medians = [...phaseVals.entries()]
        .map(([phase, vals]) => ({ phase, p50_ms: p(vals, 0.5), n: vals.length }))
        .sort((a, b) => (b.p50_ms ?? 0) - (a.p50_ms ?? 0));

      // Daily trend (UTC days, newest first).
      const byDay = groupBy(readyBoots, (b) => b.requested_at.slice(0, 10));
      const daily = [...byDay.entries()]
        .map(([day, list]) => ({
          day,
          boots: list.length,
          boot_p50_ms: p(list.map((b) => b.boot_ms).filter((v): v is number => v != null), 0.5),
          provision_p50_s: p(list.map((b) => b.provision_s).filter((v): v is number => v != null), 0.5),
          stack_p50_s: p(list.map((b) => b.stack_s).filter((v): v is number => v != null), 0.5),
        }))
        .sort((a, b) => b.day.localeCompare(a.day));

      return {
        pool,
        summary: {
          hunts: boots.length,
          granted: boots.filter((b) => b.search_ms != null).length,
          ready: readyBoots.length,
          stalled: boots.filter((b) => b.outcome === 'boot_stalled').length,
          failed: boots.filter((b) => b.outcome === 'launch_failed').length,
          abandoned: boots.filter((b) => b.outcome === 'sweep_abandoned').length,
          booting_now: boots.filter((b) => b.outcome === 'booting').length,
          hedges_fired: boots.filter((b) => b.hedged).length,
          hedge_wins: boots.filter((b) => b.is_hedge && b.hedge_won).length,
          hedge_losses: boots.filter((b) => b.outcome === 'hedge_lost').length,
          search_p50_ms: p(searches, 0.5),
          search_max_ms: searches.length ? Math.max(...searches) : null,
          boot_p50_ms: p(bootTimes, 0.5),
          boot_p90_ms: p(bootTimes, 0.9),
          boot_max_ms: bootTimes.length ? Math.max(...bootTimes) : null,
          provision_p50_s: p(provisions, 0.5),
          provision_max_s: provisions.length ? Math.max(...provisions) : null,
          stack_p50_s: p(stacks, 0.5),
          stack_max_s: stacks.length ? Math.max(...stacks) : null,
          decomposed: provisions.length,
        },
        boots: boots.slice(0, 60),
        phase_medians,
        daily,
      };
    });

    // ─── Boots — per-cell boot time + hedge outcomes (both pools) ─────────
    // cells: `launched` (detail = 'type@region', duration = search) joined to
    // the instance's first `ready` (duration = capacity granted → /health
    // ok) by instance_name → boot-time percentiles per pool × cell. Answers
    // "is the slow-provisioning lottery a per-cell thing".
    // hedges: `hedge_launched` (stamped on the ORIGINAL, dragging instance)
    // vs `hedge_resolved` (backend, 2026-09-12: detail 'winner=original' |
    // 'winner=hedge'). Pre-instrumentation races only left the legacy
    // `hedge_loser_terminate` on the loser, reported separately so an empty
    // resolved column reads as "not yet recorded", not "never resolved".
    gated.get('/admin/api/boots/cells', async (request) => {
      const days = Math.min(90, Math.max(1, Number((request.query as { days?: string }).days) || 30));
      const iv = `${days} days`;
      const [cells, hedges] = await Promise.all([
        query(
          `SELECT l.pool,
                  split_part(l.detail, '@', 1)                     AS instance_type,
                  coalesce(NULLIF(split_part(l.detail, '@', 2), ''), l.region) AS region,
                  count(*)::int                                     AS boots,
                  round((percentile_cont(0.5) WITHIN GROUP (ORDER BY r.duration_ms) / 60000.0)::numeric, 1)::float AS p50_min,
                  round((percentile_cont(0.9) WITHIN GROUP (ORDER BY r.duration_ms) / 60000.0)::numeric, 1)::float AS p90_min,
                  round((max(r.duration_ms) / 60000.0)::numeric, 1)::float AS max_min
           FROM lambda_pool_events l
           JOIN LATERAL (
             SELECT r.duration_ms FROM lambda_pool_events r
             WHERE r.instance_name = l.instance_name AND r.pool = l.pool
               AND r.event = 'ready' AND r.duration_ms IS NOT NULL AND r.ts >= l.ts
             ORDER BY r.ts LIMIT 1
           ) r ON true
           WHERE l.event = 'launched' AND l.detail LIKE '%@%'
             AND l.ts > now() - interval '${iv}'
           GROUP BY 1, 2, 3
           ORDER BY 1, boots DESC, 2, 3`,
        ),
        query(
          `SELECT pool,
                  count(*) FILTER (WHERE event = 'hedge_launched')::int                                   AS launched,
                  count(*) FILTER (WHERE event = 'hedge_resolved')::int                                   AS resolved,
                  count(*) FILTER (WHERE event = 'hedge_resolved' AND detail LIKE 'winner=hedge%')::int    AS hedge_wins,
                  count(*) FILTER (WHERE event = 'hedge_resolved' AND detail LIKE 'winner=original%')::int AS original_wins,
                  count(*) FILTER (WHERE event = 'hedge_loser_terminate')::int                            AS legacy_loser_terminates
           FROM lambda_pool_events
           WHERE event IN ('hedge_launched', 'hedge_resolved', 'hedge_loser_terminate')
             AND ts > now() - interval '${iv}'
           GROUP BY pool`,
        ),
      ]);
      type HedgeRow = {
        pool: string; launched: number; resolved: number;
        hedge_wins: number; original_wins: number; legacy_loser_terminates: number;
      };
      const byPool = new Map((hedges.rows as HedgeRow[]).map((h) => [h.pool, h]));
      return {
        days,
        cells: cells.rows,
        hedges: ['image', 'video'].map((pool) => {
          const h = byPool.get(pool) ?? {
            pool, launched: 0, resolved: 0, hedge_wins: 0, original_wins: 0, legacy_loser_terminates: 0,
          };
          return { ...h, win_rate_pct: h.resolved > 0 ? Math.round((100 * h.hedge_wins) / h.resolved) : null };
        }),
      };
    });

    // ─── Session replays (capture gallery) ─────────────────────────────────
    // Streams grouped from capture_frames; poster = latest generated frame.
    // Optional ?user_id= scopes to one user (UserDetail's replay section).
    gated.get('/admin/api/captures', async (request) => {
      const userId = (request.query as { user_id?: string }).user_id?.trim() || null;
      const { rows } = await query(
        `SELECT s.*, lp.prompt AS last_prompt
         FROM (
           SELECT c.stream_id,
                  c.user_id,
                  u.email,
                  min(c.captured_at)                                 AS started_at,
                  max(c.captured_at)                                 AS ended_at,
                  count(*) FILTER (WHERE c.kind = 'sketch')::int     AS sketch_count,
                  count(*) FILTER (WHERE c.kind = 'generated')::int  AS generated_count,
                  (array_agg(c.blob_key ORDER BY c.seq DESC)
                     FILTER (WHERE c.kind = 'generated'))[1]         AS poster_key
           FROM capture_frames c
           LEFT JOIN users u ON u.user_id::text = c.user_id
           WHERE ($1::text IS NULL OR c.user_id = $1)
           GROUP BY c.stream_id, c.user_id, u.email
           ORDER BY max(c.captured_at) DESC
           LIMIT 100
         ) s
         LEFT JOIN LATERAL (
           SELECT prompt FROM capture_prompts p
           WHERE p.stream_id = s.stream_id
           ORDER BY p.captured_at DESC LIMIT 1
         ) lp ON true`,
        [userId],
      );
      return {
        captures: rows.map((r) => ({
          ...r,
          poster_url: r['poster_key'] ? blobStore.urlFor(r['poster_key'] as string) : null,
        })),
      };
    });

    // All frames of one stream, replay order. The player interleaves the two
    // kinds by captured_at (latest sketch left, latest generated right).
    gated.get('/admin/api/captures/:streamId', async (request, reply) => {
      const { streamId } = request.params as { streamId: string };
      const [{ rows }, prompts] = await Promise.all([
        query(
          `SELECT c.kind, c.seq, c.captured_at, c.blob_key, c.user_id, u.email
           FROM capture_frames c
           LEFT JOIN users u ON u.user_id::text = c.user_id
           WHERE c.stream_id = $1
           ORDER BY c.captured_at ASC, c.seq ASC`,
          [streamId],
        ),
        query(
          `SELECT seq, captured_at, prompt FROM capture_prompts
           WHERE stream_id = $1 ORDER BY captured_at ASC, seq ASC`,
          [streamId],
        ),
      ]);
      if (rows.length === 0) return reply.code(404).send({ error: 'capture not found' });
      return {
        stream_id: streamId,
        user_id: rows[0]?.['user_id'] ?? null,
        email: rows[0]?.['email'] ?? null,
        frames: rows.map((r) => ({
          kind: r['kind'],
          seq: r['seq'],
          captured_at: r['captured_at'],
          url: blobStore.urlFor(r['blob_key'] as string),
        })),
        prompts: prompts.rows,
      };
    });

    // ─── Ops: fal keep-warm dial ───────────────────────────────────────────
    // The backend's falWarmer reads `admin_config.fal_warmer` every tick
    // (~30s), so writes here take effect live — no backend redeploy. Both
    // tables are backend-owned (created by backend schema.sql); before the
    // first backend deploy with the warmer they won't exist yet, so surface
    // that as schemaReady:false instead of a 500.
    gated.get('/admin/api/ops/warmer', async () => {
      try {
        const [cfg, pings, stats, sources] = await Promise.all([
          query(
            `SELECT value, updated_at FROM admin_config WHERE key = 'fal_warmer'`,
          ),
          query(
            `SELECT ts, found_warm, ms_to_first_frame, open_ms, error
             FROM fal_warmer_pings
             WHERE ts > now() - interval '48 hours'
             ORDER BY ts DESC LIMIT 500`,
          ),
          // billed_ms estimates fal's actual charge: fal bills warm-runner-
          // ATTACHED time only — a cold ping's spin-up wait (≈ its
          // ms_to_first_frame) is enqueue time with no runner attached and is
          // NOT billed (verified vs fal dashboard 2026-07-14).
          query(
            `SELECT count(*)::int                                        AS pings,
                    count(*) FILTER (WHERE found_warm = false)::int      AS cold_encounters,
                    count(*) FILTER (WHERE found_warm IS NULL)::int      AS failures,
                    COALESCE(sum(greatest(0, open_ms - CASE WHEN found_warm IS DISTINCT FROM true
                      THEN COALESCE(ms_to_first_frame, open_ms) ELSE 0 END)), 0)::int AS billed_ms
             FROM fal_warmer_pings
             WHERE ts > now() - interval '24 hours'`,
          ),
          // Warmer-vs-real-users comparison over ALL fal connections (the
          // whole point of fal_connections: same table, GROUP BY source).
          // wait_ms is the user-perceived first-result wait; percentile_cont
          // ignores NULL (zero-frame connections).
          query(
            `SELECT source,
                    count(*)::int                                    AS conns,
                    count(*) FILTER (WHERE frames_received > 0)::int AS answered,
                    count(*) FILTER (WHERE found_warm = false)::int  AS cold,
                    round(percentile_cont(0.5) WITHIN GROUP (ORDER BY wait_ms))::int AS wait_p50,
                    round(percentile_cont(0.9) WITHIN GROUP (ORDER BY wait_ms))::int AS wait_p90,
                    max(wait_ms)::int                                AS wait_max
             FROM fal_connections
             WHERE opened_at > now() - interval '24 hours'
             GROUP BY source ORDER BY source DESC`,
          ),
        ]);
        return {
          schemaReady: true,
          config: cfg.rows[0]?.['value'] ?? null,
          configUpdatedAt: cfg.rows[0]?.['updated_at'] ?? null,
          pings: pings.rows,
          stats24h: stats.rows[0],
          sources24h: sources.rows,
        };
      } catch (err) {
        if ((err as { code?: string }).code === '42P01') {
          return {
            schemaReady: false,
            config: null,
            configUpdatedAt: null,
            pings: [],
            stats24h: null,
            sources24h: [],
          };
        }
        throw err;
      }
    });

    // Selectable lookback for the request history. Bucket widths are sized so
    // each bar aggregates a meaningful sample rather than to hit a bar count:
    // the warmer alone is ~40 connections/hour, so 1-minute buckets on the 1h
    // view would be n=1 — a rate chart that can only read 0% or 100%.
    const CONNECTION_RANGES: Record<string, { seconds: number; bucketSeconds: number }> = {
      '1h': { seconds: 3600, bucketSeconds: 300 },
      '6h': { seconds: 6 * 3600, bucketSeconds: 900 },
      '24h': { seconds: 24 * 3600, bucketSeconds: 1800 },
      '48h': { seconds: 48 * 3600, bucketSeconds: 3600 },
      '7d': { seconds: 7 * 86400, bucketSeconds: 3 * 3600 },
      '30d': { seconds: 30 * 86400, bucketSeconds: 12 * 3600 },
    };

    // General fal request history — one row per fal connection (user +
    // warmer), newest first, with user email joined in. `source` filters
    // server-side so "users only" isn't drowned by ~700 warmer rows/day.
    // `buckets` is a SEPARATE aggregate over the whole range (not derived from
    // the 500-row page) so the cold-rate chart is never truncated by the table
    // limit — at 7d/30d the warmer alone blows past 500 rows.
    gated.get('/admin/api/ops/connections', async (request) => {
      const q = request.query as { source?: string; range?: string };
      const sourceFilter = q.source === 'user' || q.source === 'warmer' ? q.source : null;
      const requested = q.range ? CONNECTION_RANGES[q.range] : undefined;
      const rangeKey = requested ? (q.range as string) : '48h';
      const { seconds, bucketSeconds } = requested ?? CONNECTION_RANGES['48h'];
      try {
        const [conns, buckets] = await Promise.all([
          query(
            `SELECT c.opened_at, c.source, c.user_id::text AS user_id, u.email,
                    c.wait_ms, c.found_warm, c.frames_sent, c.frames_received,
                    c.open_ms, c.close_reason
             FROM fal_connections c
             LEFT JOIN users u ON u.user_id = c.user_id
             WHERE c.opened_at > now() - ($2::int * interval '1 second')
               AND ($1::text IS NULL OR c.source = $1)
             ORDER BY c.opened_at DESC LIMIT 500`,
            [sourceFilter, seconds],
          ),
          // date_bin would be tidier but needs PG14+; the epoch-floor form
          // works on any version. `resolved` excludes found_warm IS NULL
          // (connection never got a result) — those aren't warm OR cold, so
          // they'd drag the rate toward 0 if left in the denominator.
          query(
            `SELECT to_timestamp(floor(extract(epoch FROM c.opened_at) / $3::int)::float8 * $3::int) AS bucket,
                    count(*)::int                                       AS total,
                    count(*) FILTER (WHERE c.found_warm IS NOT NULL)::int AS resolved,
                    count(*) FILTER (WHERE c.found_warm = false)::int    AS cold
             FROM fal_connections c
             WHERE c.opened_at > now() - ($2::int * interval '1 second')
               AND ($1::text IS NULL OR c.source = $1)
             GROUP BY 1 ORDER BY 1`,
            [sourceFilter, seconds, bucketSeconds],
          ),
        ]);
        return {
          schemaReady: true,
          range: rangeKey,
          rangeSeconds: seconds,
          bucketSeconds,
          connections: conns.rows,
          buckets: buckets.rows,
        };
      } catch (err) {
        if ((err as { code?: string }).code === '42P01') {
          return {
            schemaReady: false,
            range: rangeKey,
            rangeSeconds: seconds,
            bucketSeconds,
            connections: [],
            buckets: [],
          };
        }
        throw err;
      }
    });

    gated.put('/admin/api/ops/warmer', async (request, reply) => {
      const b = (request.body ?? {}) as Record<string, unknown>;
      const isHour = (n: unknown): n is number =>
        typeof n === 'number' && Number.isInteger(n) && n >= 0 && n <= 24;
      if (
        typeof b['enabled'] !== 'boolean' ||
        typeof b['intervalMs'] !== 'number' ||
        b['intervalMs'] < 60_000 ||
        b['intervalMs'] > 60 * 60_000 ||
        !isHour(b['offStartHour']) ||
        !isHour(b['offEndHour'])
      ) {
        return reply.code(400).send({
          error:
            'expected {enabled: bool, intervalMs: 60000..3600000, offStartHour: 0..24, offEndHour: 0..24}',
        });
      }
      const value = {
        enabled: b['enabled'],
        intervalMs: b['intervalMs'],
        offStartHour: b['offStartHour'],
        offEndHour: b['offEndHour'],
      };
      await query(
        `INSERT INTO admin_config (key, value) VALUES ('fal_warmer', $1)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
        [JSON.stringify(value)],
      );
      return { ok: true, config: value };
    });

    // ─── Ops: video-generation kill switch ─────────────────────────────────
    // The backend polls `admin_config.video_generation` every 60s
    // (modules/video/videoFlag.ts): off → the video pool DRAINS its H100s
    // (billing stops) and the iPad hides all animation UX; on → restored
    // within one poll+tick cycle. No backend redeploy needed.
    // ─── Live pods: the backend's in-memory pool state (hold verdicts +
    // interest attribution), proxied over the shared ingest key. This data
    // exists only in the backend process — Postgres has lifecycle EVENTS,
    // not current verdicts. 502s degrade to backendReachable:false rather
    // than failing the whole Fleet page.
    gated.get('/admin/api/pods', async () => {
      try {
        const res = await fetch(`${config.BACKEND_URL}/v1/internal/pools`, {
          headers: { 'x-internal-key': config.INSIGHTS_INGEST_KEY },
          signal: AbortSignal.timeout(5000),
        });
        if (!res.ok) return { backendReachable: false, status: res.status };
        return { backendReachable: true, ...(await res.json() as Record<string, unknown>) };
      } catch (err) {
        return { backendReachable: false, error: (err as Error).message };
      }
    });

    // ─── GPU Capacity (dedicated tab): Lambda ADVERTISED availability over
    // time, from the backend's free /instance-types heartbeat. NOT a
    // reservation — capacity flag has no depth, can be stale by seconds; the
    // Fleet tab's real launch outcomes remain ground truth. Tables are
    // backend-owned (shared Postgres); absent before the backend deploy that
    // creates them → schemaReady:false, not a 500.
    gated.get('/admin/api/capacity', async (request) => {
      const days = Math.min(14, Math.max(1, Number((request.query as { days?: string }).days) || 7));
      const iv = `${days} days`;
      try {
        const [ticks, byCell, timeline, heatmap] = await Promise.all([
          // Denominator: how many polls happened in the window.
          query(`SELECT count(*)::int AS ticks, min(tick_at) AS first_at, max(tick_at) AS last_at
                 FROM lambda_capacity_ticks WHERE tick_at > now() - interval '${iv}'`),
          // Per (type, region): % of ticks with capacity + last-seen.
          query(
            `WITH t AS (SELECT count(*)::float AS n FROM lambda_capacity_ticks WHERE tick_at > now() - interval '${iv}')
             SELECT s.instance_type, s.region,
                    count(*)::int AS available_ticks,
                    round(100.0 * count(*) / NULLIF((SELECT n FROM t), 0))::int AS pct,
                    max(s.tick_at) AS last_available
             FROM lambda_capacity_samples s
             WHERE s.tick_at > now() - interval '${iv}'
             GROUP BY s.instance_type, s.region
             ORDER BY s.instance_type, pct DESC`,
          ),
          // Per-type availability across the window, bucketed for a sparkline:
          // fraction of ticks in each bucket where the type had capacity in
          // ANY region (what the pool's cross-region sweep effectively sees).
          query(
            `WITH tick_hours AS (
               SELECT date_trunc('hour', tick_at) AS hour, count(*)::int AS ticks
               FROM lambda_capacity_ticks WHERE tick_at > now() - interval '${iv}'
               GROUP BY 1
             ),
             avail AS (
               SELECT date_trunc('hour', tick_at) AS hour, instance_type,
                      count(DISTINCT tick_at)::int AS avail_ticks
               FROM lambda_capacity_samples WHERE tick_at > now() - interval '${iv}'
               GROUP BY 1, 2
             )
             SELECT to_char(th.hour, 'YYYY-MM-DD"T"HH24:00') AS hour, a.instance_type,
                    th.ticks, a.avail_ticks,
                    round(100.0 * a.avail_ticks / NULLIF(th.ticks, 0))::int AS pct
             FROM tick_hours th JOIN avail a ON a.hour = th.hour
             ORDER BY th.hour, a.instance_type`,
          ),
          // Time-of-day heatmap (Pacific hour × type): avg availability %,
          // to surface daily drought windows.
          query(
            `WITH th AS (
               SELECT extract(hour from tick_at AT TIME ZONE 'America/Los_Angeles')::int AS hod,
                      count(*)::int AS ticks
               FROM lambda_capacity_ticks WHERE tick_at > now() - interval '${iv}' GROUP BY 1
             ),
             av AS (
               SELECT extract(hour from tick_at AT TIME ZONE 'America/Los_Angeles')::int AS hod,
                      instance_type, count(DISTINCT tick_at)::int AS avail_ticks
               FROM lambda_capacity_samples WHERE tick_at > now() - interval '${iv}' GROUP BY 1, 2
             )
             SELECT th.hod, av.instance_type,
                    round(100.0 * av.avail_ticks / NULLIF(th.ticks, 0))::int AS pct
             FROM th JOIN av ON av.hod = th.hod
             ORDER BY th.hod, av.instance_type`,
          ),
        ]);
        return {
          schemaReady: true,
          days,
          ticks: ticks.rows[0] ?? { ticks: 0, first_at: null, last_at: null },
          cells: byCell.rows,
          timeline: timeline.rows,
          heatmap: heatmap.rows,
        };
      } catch (err) {
        if ((err as { code?: string }).code === '42P01') {
          return { schemaReady: false, days, ticks: { ticks: 0 }, cells: [], timeline: [], heatmap: [] };
        }
        throw err;
      }
    });

    // ─── GPU Capacity — grid views: the questions the operator used to
    // compute ad hoc. Everything is keyed off "our H100 grid" = the 1x H100
    // cells (sxm5/pcie) in the CONFIGURED regions (?regions=csv, defaulting
    // to the backend's widened LAMBDA_REGIONS list — Insights can't read the
    // backend's env, so the caller names the grid). Per tick, "grid has
    // capacity" = EXISTS(sample in the set); the same predicate feeds all
    // three views so they can never disagree:
    //   joint      — % of ticks with ≥1 advertised cell, per named grid
    //   droughts   — runs of consecutive dry ticks (gaps-and-islands: the
    //                running sum of ok-flags is constant across a dry run)
    //   dry_alternatives — on the grid's dry ticks, which other H100/A100
    //                cells (any region) WERE advertised — the fallback menu
    gated.get('/admin/api/capacity/grid', async (request) => {
      const q = request.query as { days?: string; regions?: string };
      const days = Math.min(14, Math.max(1, Number(q.days) || 14));
      const iv = `${days} days`;
      const regions = (q.regions ?? DEFAULT_GRID_REGIONS)
        .split(',')
        .map((r) => r.trim())
        .filter((r) => /^[a-z0-9-]+$/.test(r));
      const grid = regions.length ? regions : DEFAULT_GRID_REGIONS.split(',');
      const h100 = ['gpu_1x_h100_sxm5', 'gpu_1x_h100_pcie'];
      const a100 = ['gpu_1x_a100_sxm4', 'gpu_1x_a100'];
      const image = [...h100, ...a100];
      // $1 = h100 types, $2 = grid regions, $3 = image types (h100 + a100).
      // Postgres can't type a parameter a statement never references, so
      // each query passes exactly the prefix of `params` it uses.
      const params = [h100, grid, image];
      const ex = (types: string, regionClause: string): string =>
        `EXISTS (SELECT 1 FROM lambda_capacity_samples s
                 WHERE s.tick_at = k.tick_at AND s.instance_type = ANY(${types}::text[])${regionClause})`;
      const OUR_GRID = ex('$1', ' AND s.region = ANY($2::text[])');
      try {
        const [joint, droughts, dryAlt] = await Promise.all([
          query(
            `SELECT count(*)::int AS ticks,
                    count(*) FILTER (WHERE ${OUR_GRID})::int                                  AS our_h100_grid,
                    count(*) FILTER (WHERE ${ex('$1', '')})::int                              AS any_h100,
                    count(*) FILTER (WHERE ${ex('$3', ' AND s.region = ANY($2::text[])')})::int AS image_grid_incl_a100,
                    count(*) FILTER (WHERE ${ex('$3', '')})::int                              AS any_image_type
             FROM lambda_capacity_ticks k
             WHERE k.tick_at > now() - interval '${iv}'`,
            params,
          ),
          query(
            `WITH t AS (
               SELECT k.tick_at, ${OUR_GRID} AS ok
               FROM lambda_capacity_ticks k
               WHERE k.tick_at > now() - interval '${iv}'
             ),
             g AS (
               SELECT tick_at, ok,
                      lead(tick_at) OVER (ORDER BY tick_at) AS next_tick,
                      sum(CASE WHEN ok THEN 1 ELSE 0 END) OVER (ORDER BY tick_at) AS grp
               FROM t
             ),
             runs AS (
               SELECT min(tick_at) AS started_at,
                      -- the run ends when capacity returns (the tick after the
                      -- last dry one); NULL = still dry at the newest tick
                      max(next_tick) AS ended_at,
                      count(*)::int AS ticks,
                      bool_or(next_tick IS NULL) AS ongoing
               FROM g WHERE NOT ok GROUP BY grp
             )
             SELECT started_at, ended_at, ticks, ongoing,
                    round(extract(epoch FROM (coalesce(ended_at, now()) - started_at)) / 60)::int AS minutes
             FROM runs
             ORDER BY minutes DESC, started_at DESC`,
            params.slice(0, 2),
          ),
          query(
            `WITH dry AS (
               SELECT k.tick_at FROM lambda_capacity_ticks k
               WHERE k.tick_at > now() - interval '${iv}' AND NOT ${OUR_GRID}
             )
             SELECT s.instance_type, s.region,
                    count(DISTINCT s.tick_at)::int AS ticks,
                    round(100.0 * count(DISTINCT s.tick_at) / NULLIF((SELECT count(*) FROM dry), 0))::int AS pct
             FROM lambda_capacity_samples s
             JOIN dry ON dry.tick_at = s.tick_at
             WHERE s.instance_type = ANY($3::text[])
             GROUP BY 1, 2
             ORDER BY ticks DESC, s.instance_type, s.region
             LIMIT 12`,
            params,
          ),
        ]);
        const j = (joint.rows[0] ?? {}) as Record<string, number>;
        const ticks = j['ticks'] ?? 0;
        const pct = (n: number | undefined): number | null =>
          ticks > 0 ? Math.round((100 * (n ?? 0)) / ticks) : null;
        const grids = [
          { key: 'our_h100_grid', label: 'Our H100 grid', types: h100, regions: grid },
          { key: 'any_h100', label: 'Any 1x H100, any region', types: h100, regions: null },
          { key: 'image_grid_incl_a100', label: 'Image grid incl. A100', types: image, regions: grid },
          { key: 'any_image_type', label: 'Any image type, any region', types: image, regions: null },
        ].map((g) => ({ ...g, available_ticks: j[g.key] ?? 0, pct: pct(j[g.key]) }));

        type Run = { started_at: string; ended_at: string | null; ticks: number; ongoing: boolean; minutes: number };
        const runs = droughts.rows as Run[];
        const mins = runs.map((r) => r.minutes).sort((a, b) => a - b);
        const p50 = mins.length ? mins[Math.floor(mins.length / 2)] ?? null : null;
        return {
          schemaReady: true,
          days,
          regions: grid,
          ticks,
          grids,
          droughts: {
            count: runs.length,
            over_30m: runs.filter((r) => r.minutes > 30).length,
            p50_minutes: p50,
            max_minutes: mins.length ? mins[mins.length - 1] : null,
            dry_ticks: runs.reduce((a, r) => a + r.ticks, 0),
            top: runs.slice(0, 15),
          },
          dry_alternatives: dryAlt.rows,
        };
      } catch (err) {
        if ((err as { code?: string }).code === '42P01') {
          return {
            schemaReady: false, days, regions: grid, ticks: 0, grids: [],
            droughts: { count: 0, over_30m: 0, p50_minutes: null, max_minutes: null, dry_ticks: 0, top: [] },
            dry_alternatives: [],
          };
        }
        throw err;
      }
    });

    gated.get('/admin/api/ops/video', async () => {
      try {
        const cfg = await query(
          `SELECT value, updated_at FROM admin_config WHERE key = 'video_generation'`,
        );
        const row = cfg.rows[0] as { value?: { enabled?: boolean }; updated_at?: string } | undefined;
        return {
          schemaReady: true,
          seeded: row !== undefined,
          config: { enabled: row?.value?.enabled === true },
          updatedAt: row?.updated_at ?? null,
        };
      } catch (err) {
        if ((err as { code?: string }).code === '42P01') {
          return { schemaReady: false, seeded: false, config: { enabled: false }, updatedAt: null };
        }
        throw err;
      }
    });

    gated.put('/admin/api/ops/video', async (request, reply) => {
      const b = (request.body ?? {}) as Record<string, unknown>;
      if (typeof b['enabled'] !== 'boolean') {
        return reply.code(400).send({ error: 'expected {enabled: bool}' });
      }
      const value = { enabled: b['enabled'] };
      await query(
        `INSERT INTO admin_config (key, value) VALUES ('video_generation', $1)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now()`,
        [JSON.stringify(value)],
      );
      return { ok: true, config: value };
    });

    // Serve blob assets (admin-gated; SPA <img> sends the cookie same-origin).
    gated.get('/blobs/*', async (request, reply) => {
      const key = (request.params as Record<string, string>)['*'];
      if (!key) return reply.code(404).send({ error: 'not found' });
      try {
        const buf = await blobStore.get(key);
        const type = key.endsWith('.mp4') ? 'video/mp4'
          : key.endsWith('.png') ? 'image/png'
          : key.endsWith('.json') ? 'application/json'
          : 'image/jpeg';
        return reply.header('Content-Type', type).header('Cache-Control', 'private, max-age=3600').send(buf);
      } catch {
        return reply.code(404).send({ error: 'not found' });
      }
    });
  });
};

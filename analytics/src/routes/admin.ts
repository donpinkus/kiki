/**
 * Dashboard API (internal). Everything under /admin/api and /blobs is gated by
 * the admin session cookie. Login exchanges the single admin password for that
 * cookie.
 *
 * The read model is deliberately per-user: list users, then drill into one
 * user's full timeline (sessions + events) and drawings gallery — the view the
 * aggregate tools (PostHog/Sentry) don't give.
 */

import type { FastifyPluginAsync } from 'fastify';
import {
  ADMIN_COOKIE,
  requireAdmin,
  signAdminSession,
  verifyAdminPassword,
} from '../auth.js';
import { query } from '../db.js';
import { blobStore } from '../blobStore.js';
import { config } from '../config.js';

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

    // Brush-test battery runs (newest first), images nested per run. Feeds the
    // Tests tab (visual gallery + cross-run side-by-sides; no pass/fail).
    gated.get('/admin/api/test-runs', async (request) => {
      const limit = Math.min(Number((request.query as { limit?: string }).limit) || 30, 200);
      const { rows: runs } = await query<{ id: string; git_sha: string | null; note: string | null; created_at: string }>(
        `SELECT id, git_sha, note, created_at FROM test_runs ORDER BY created_at DESC LIMIT $1`,
        [limit],
      );
      if (runs.length === 0) return { runs: [] };
      const { rows: images } = await query<{ run_id: string; scene: string; blob_key: string }>(
        `SELECT run_id, scene, blob_key FROM test_run_images WHERE run_id = ANY($1::bigint[]) ORDER BY scene`,
        [runs.map((r) => r.id)],
      );
      const byRun = new Map<string, { scene: string; blob_key: string }[]>();
      for (const img of images) {
        const list = byRun.get(String(img.run_id)) ?? [];
        list.push({ scene: img.scene, blob_key: img.blob_key });
        byRun.set(String(img.run_id), list);
      }
      return { runs: runs.map((r) => ({ ...r, images: byRun.get(String(r.id)) ?? [] })) };
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

      const [sessions, events, drawings, usage, dailyActivity] = await Promise.all([
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
      ]);

      return {
        user: userRes.rows[0],
        usage: usage.rows,
        daily_activity: dailyActivity.rows,
        sessions: sessions.rows,
        events: events.rows,
        drawings: drawings.rows.map((d) => ({
          ...d,
          thumbnail_url: d['thumbnail_key'] ? blobStore.urlFor(d['thumbnail_key'] as string) : null,
          generated_url: d['generated_key'] ? blobStore.urlFor(d['generated_key'] as string) : null,
        })),
      };
    });

    // ─── Session replays (capture gallery) ─────────────────────────────────
    // Streams grouped from capture_frames; poster = latest generated frame.
    // Optional ?user_id= scopes to one user (UserDetail's replay section).
    gated.get('/admin/api/captures', async (request) => {
      const userId = (request.query as { user_id?: string }).user_id?.trim() || null;
      const { rows } = await query(
        `SELECT c.stream_id,
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
         LIMIT 100`,
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
      const { rows } = await query(
        `SELECT c.kind, c.seq, c.captured_at, c.blob_key, c.user_id, u.email
         FROM capture_frames c
         LEFT JOIN users u ON u.user_id::text = c.user_id
         WHERE c.stream_id = $1
         ORDER BY c.captured_at ASC, c.seq ASC`,
        [streamId],
      );
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
            userColdEvents: [],
          };
        }
        throw err;
      }
    });

    // General fal request history — one row per fal connection (user +
    // warmer), newest first, with user email joined in. `source` filters
    // server-side so "users only" isn't drowned by ~700 warmer rows/day.
    gated.get('/admin/api/ops/connections', async (request) => {
      const src = (request.query as { source?: string }).source;
      const sourceFilter = src === 'user' || src === 'warmer' ? src : null;
      try {
        const { rows } = await query(
          `SELECT c.opened_at, c.source, c.user_id::text AS user_id, u.email,
                  c.wait_ms, c.found_warm, c.frames_sent, c.frames_received,
                  c.open_ms, c.close_reason
           FROM fal_connections c
           LEFT JOIN users u ON u.user_id = c.user_id
           WHERE c.opened_at > now() - interval '48 hours'
             AND ($1::text IS NULL OR c.source = $1)
           ORDER BY c.opened_at DESC LIMIT 500`,
          [sourceFilter],
        );
        return { schemaReady: true, connections: rows };
      } catch (err) {
        if ((err as { code?: string }).code === '42P01') {
          return { schemaReady: false, connections: [] };
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

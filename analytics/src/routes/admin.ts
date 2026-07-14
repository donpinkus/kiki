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
      return { users: rows };
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

      const [sessions, events, drawings, usage] = await Promise.all([
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
      ]);

      return {
        user: userRes.rows[0],
        usage: usage.rows,
        sessions: sessions.rows,
        events: events.rows,
        drawings: drawings.rows.map((d) => ({
          ...d,
          thumbnail_url: d['thumbnail_key'] ? blobStore.urlFor(d['thumbnail_key'] as string) : null,
          generated_url: d['generated_key'] ? blobStore.urlFor(d['generated_key'] as string) : null,
        })),
      };
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

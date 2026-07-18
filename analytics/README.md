# Kiki Insights

Internal, per-user analytics microsite for Kiki. Where Sentry gives an
aggregate view, this gives a **single user's full history**: every app open on a
timeline, session durations, the complete event stream, and (once iOS uploads
them) the drawings they made.

Standalone service, separate from the prod backend. One Fastify process with two
faces:

- **Ingest** (public, authenticated) — iOS posts events/drawings with its
  existing Bearer access token; the prod backend posts server-side events with a
  service key. No new secret on the client.
- **Dashboard** (internal) — single admin password → signed session cookie. The
  React SPA, the `/admin/api/*` JSON, and `/blobs/*` are all cookie-gated.

## Stack

- TypeScript + Fastify + Postgres (`pg`), matching the backend's conventions.
- React + Vite SPA in `web/`, built to `web/dist` and served statically by Fastify.
- Blobs (drawing thumbnail/generated image, later video) on a Railway persistent
  volume behind a tiny swappable `BlobStore` interface (`src/blobStore.ts`) — drop
  in S3/R2 later with zero data-model change (Postgres only stores the key).

## Data model

**Shared Postgres with the backend.** Identity is NOT duplicated here — Insights
reads the backend-owned tables and owns only the activity tables.

Backend-owned (read-only here — `backend/src/postgres/schema.sql`):
- `users` — system-of-record: `user_id` UUID, `apple_sub`, `email`,
  `is_test_account`, `subscription_status`, `subscription_expires_at`, timestamps.
- `monthly_usage` — per-user, per-month fal spend (USD) for the $10/mo cap.

Insights-owned (`src/schema.sql` — `user_id` is TEXT holding the backend UUID;
joins cast `users.user_id::text`):
- `events` — raw spine: name + jsonb properties + occurred_at, indexed by user/time.
  "Send an arbitrary event" is just an insert.
- `sessions` — rolled up at ingest from `app.backgrounded` (duration_ms) and
  `drawing.closed` (session_duration_ms). `source` = `app` | `drawing`.
- `drawings` — metadata + blob keys (`thumbnail_key`, `generated_key`,
  `video_key` reserved).
- `fixtures` — brush-dev stroke fixtures (see BrushHarness).
- `capture_frames` / `capture_prompts` — throttled server-side session capture
  (sketch + generated JPEGs, prompts) for Gallery replay; pruned daily after
  `CAPTURE_RETENTION_DAYS` (default 14).
- `test_runs` / `test_run_images` — automated brush-test runs (Tests tab).
- `brush_targets` / `brush_target_images` — Brushes tab target references.

The dashboard JOINs them: per user it shows identity + `is_test_account` +
`subscription_status` + this-month fal spend (from the backend tables) alongside
sessions/events/drawings (Insights tables). Insights' `migrate()` only creates its
own tables — it never touches the backend's.

## API

| Method | Path | Auth | Purpose |
|---|---|---|---|
| POST | `/ingest` | Bearer (iOS) **or** `x-insights-key` (backend) | Batch events `{ events: [...] }` |
| POST | `/ingest/drawing` | same | multipart: drawing metadata + `thumbnail`/`generated` files |
| POST | `/ingest/fixture` | same | multipart: brush-dev stroke fixture (`fixture` JSON + optional `snapshot` PNG) — see `ios/Packages/CanvasModule/BrushHarness/README.md` |
| POST | `/ingest/capture` | same | multipart: throttled session-capture frame (sketch/generated JPEG) |
| POST | `/ingest/capture-prompt` | same | session-capture prompt snapshot |
| POST | `/ingest/test-run` | same | automated brush-test run + images |
| POST | `/ingest/brush-target-attempt` | same | brush-target attempt image (Brushes tab) |
| POST | `/admin/login` | password body | Set admin cookie |
| POST | `/admin/logout` | — | Clear cookie |
| GET | `/admin/api/me` | cookie | Auth check for the SPA |
| GET | `/admin/api/users?q=` | cookie | User list + counts |
| GET | `/admin/api/users/:id` | cookie | Full per-user view |
| GET | `/admin/api/launch` | cookie | Launch tab: provider/pool lifecycle views |
| GET | `/admin/api/captures[/:streamId]` | cookie | Gallery replay: captured sessions + frames |
| GET/PUT | `/admin/api/ops/warmer` | cookie | Ops tab: live fal-warmer config (`admin_config.fal_warmer`) + ping history |
| GET | `/admin/api/ops/connections` | cookie | Ops tab: `fal_connections` history |
| GET | `/admin/api/test-runs` | cookie | Tests tab: brush-test runs |
| CRUD | `/admin/api/brush-targets[...]` | cookie | Brushes tab: targets + reference images |
| GET | `/admin/api/fixtures?limit=` | cookie | Brush-dev fixture list (newest first; `fetch-fixtures.sh`) |
| GET | `/blobs/*` | cookie | Serve a blob |
| GET | `/health` | — | DB health |

SPA nav (`web/src/App.tsx`): Users, Launch, Gallery (replay), Tests, Brushes, Ops.

### Event ingest contract

```jsonc
POST /ingest
Authorization: Bearer <iOS access token>     // user_id taken from JWT sub
{ "events": [
  { "name": "app.foregrounded", "occurred_at": "2026-06-06T12:00:00Z" },
  { "name": "style.selected", "occurred_at": 1749200000000, "properties": { "style_id": "pastel" }, "drawing_id": "<uuid>" }
] }
```

Backend (service-key) callers must include `user_id` on each event and send
`x-insights-key: <INSIGHTS_INGEST_KEY>` instead of a Bearer token.

`occurred_at` accepts ISO-8601 or epoch-ms; absent → server time.

## Local dev

```bash
cd analytics
cp .env.example .env.local        # fill in secrets; point DATABASE_URL at a local PG
npm install
npm run migrate                   # apply schema (also runs automatically at boot)
npm run dev                       # API on :8080 (also applies schema at boot)

# In a second terminal, the SPA with hot reload (proxies API → :8080):
cd web && npm install && npm run dev
```

For a production-like single-process run: `npm run build && npm start` serves the
built SPA + API together on `:8080`.

> Env vars are read from the process environment. For local dev, export them or
> use a tool like `dotenvx`/`direnv`; `.env.local` is the documented place to keep
> them. (No dotenv dependency is bundled — matching the backend.)

## Deploy (Railway — new service)

This is a **separate Railway service** from the backend, in the same repo.

1. **Create the service** pointed at this repo with **root directory `analytics/`**.
   Railway auto-detects the `Dockerfile`.
2. **Use the backend's existing Postgres** (do NOT add a new one). Set this
   service's `DATABASE_URL` to a reference variable pointing at the same Postgres
   service the backend uses — Insights reads the backend's `users`/`monthly_usage`
   and creates its own `events`/`sessions`/`drawings` in that same database.
3. **Add a Volume**, mount path `/data/blobs`, size ~10 GB (bump later when video
   lands). Set `BLOB_DIR=/data/blobs`.
4. **Set env vars** (see `.env.example`):
   - `JWT_ACCESS_SECRET` — **must equal the backend's** `JWT_ACCESS_SECRET`.
   - `INSIGHTS_INGEST_KEY` — long random; set the same value on the backend.
   - `ADMIN_PASSWORD`, `ADMIN_SESSION_SECRET` (≥32 chars), `NODE_ENV=production`.
5. **Deploy:** from `analytics/`, `railway up` (after `railway link` to this service),
   or push if the service is set to deploy on push.

The schema is applied automatically on boot (`migrate()` runs idempotent
`CREATE ... IF NOT EXISTS`).

## Sender wiring (shipped)

Both senders target the `/ingest` contract above:

- **Backend dual-write** — `backend/src/modules/insights/client.ts` mirrors every
  `analytics/index.ts` event to `/ingest` (service key), batched/best-effort,
  Enabled by setting `INSIGHTS_URL` + `INSIGHTS_INGEST_KEY` on
  the backend (no-op otherwise).
- **iOS event mirror** — `ios/Kiki/App/InsightsSink.swift`; `Analytics.track`
  also posts to `/ingest` (Bearer = existing access token). Adds
  `app.foregrounded`/`app.backgrounded` session events (the login/session
  timeline) and uploads thumbnail + generated image on drawing close. Enabled by
  the `insightsURL` arg in `AppCoordinator.init` (nil → no-op until deployed).

## To turn it on

1. Deploy this service (above); note its URL.
2. Backend (Railway): set `INSIGHTS_URL` = that URL, `INSIGHTS_INGEST_KEY` =
   matching key, then `npm run deploy`.
3. iOS: set `insightsURL` in `AppCoordinator.init` to that URL; rebuild/reinstall.

## Not yet wired

- Video storage + export (the `video_key` column + `BlobStore` are ready for it).

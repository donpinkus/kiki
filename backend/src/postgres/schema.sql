-- Kiki backend durable schema. Idempotent (CREATE ... IF NOT EXISTS only) so it
-- can run at every boot and via `npm run db:migrate`. Future column additions
-- must use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (CREATE TABLE IF NOT EXISTS
-- will NOT add columns to an existing table).

-- Registered user accounts. The durable system-of-record for identity +
-- subscription state, replacing the former Redis user hash. `apple_sub` UNIQUE
-- gives cross-deploy dedup natively (was the Redis `apple-sub:{sub}` key).
-- The subscription_* columns are maintained by the StoreKit flow
-- (modules/appstore/subscriptions.ts) and read by the free-tier cap exemption;
-- is_test_account and the usage ledger are consumed by the drawing-spend cap.
CREATE TABLE IF NOT EXISTS users (
  user_id                 UUID PRIMARY KEY,
  apple_sub               TEXT NOT NULL UNIQUE,
  email                   TEXT,
  is_test_account         BOOLEAN NOT NULL DEFAULT false,
  subscription_status     TEXT NOT NULL DEFAULT 'none',   -- 'none' | 'active' | 'expired'
  subscription_expires_at TIMESTAMPTZ,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at              TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- StoreKit subscription binding (Stage 3). `original_transaction_id` is the
-- stable per-subscription key; the (unauthenticated) App Store webhook resolves
-- a user by it, while the authenticated /v1/subscription/verify call binds it.
-- Partial-unique: most users are NULL (no sub), but a given Apple sub maps to
-- exactly one Kiki account. `subscription_last_signed_ms` is the JWS signedDate
-- of the last transaction we applied — the monotonic guard that makes webhook
-- processing idempotent + order-safe (see modules/appstore/subscriptions.ts).
ALTER TABLE users ADD COLUMN IF NOT EXISTS original_transaction_id TEXT;
ALTER TABLE users ADD COLUMN IF NOT EXISTS subscription_last_signed_ms BIGINT;
CREATE UNIQUE INDEX IF NOT EXISTS users_original_transaction_id_key
  ON users (original_transaction_id) WHERE original_transaction_id IS NOT NULL;

-- Per-user, per-month image-generation spend (USD), for the free-tier cap.
-- Despite the column name, fal_spend_usd is the UNIFIED ledger: fal
-- connection-open time (~$0.00194/sec) AND Lambda H100 frames ($0.001/frame)
-- both accumulate here (renaming the column would need a migration; not worth it).
-- One row per (user, calendar month UTC); a new month is a fresh row reading 0,
-- so the monthly reset is implicit. Test accounts + subscribers are exempt
-- from the cap but spend is still recorded for them only if a session runs the
-- metering (exempt sessions skip it).
CREATE TABLE IF NOT EXISTS monthly_usage (
  user_id       UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  month         TEXT NOT NULL,                       -- 'YYYY-MM' (UTC)
  fal_spend_usd NUMERIC NOT NULL DEFAULT 0,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, month)
);

-- Revoked refresh-token jtis (durable, survives deploys). A refresh token is
-- revoked on rotation (each /v1/auth/refresh) and sign-out; verifyRefresh
-- rejects any jti listed here. Was an in-memory Set that reset every deploy —
-- which silently un-revoked tokens (replay window up to the 30d refresh TTL).
-- `expires_at` mirrors the token's exp so rows can be pruned once the token
-- can no longer be presented (jose rejects expired tokens regardless).
CREATE TABLE IF NOT EXISTS revoked_refresh_tokens (
  jti        TEXT PRIMARY KEY,
  user_id    UUID,
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS revoked_refresh_tokens_expires ON revoked_refresh_tokens (expires_at);

-- Runtime ops dials, editable from Kiki Insights (which shares this database)
-- without a backend redeploy. One row per dial, JSONB value. The backend seeds
-- a dial from its env defaults at boot if the row is absent and re-reads it on
-- every consumer tick, so an Insights write takes effect within one tick.
-- Current keys: 'fal_warmer' → {enabled, intervalMs, offStartHour, offEndHour}.
CREATE TABLE IF NOT EXISTS admin_config (
  key        TEXT PRIMARY KEY,
  value      JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- fal keep-warm ping history (see modules/fal/falWarmer.ts). One row per ping;
-- `found_warm` = first frame arrived fast (the pool was already warm) vs. the
-- ping had to sit through a cold spin-up. `open_ms` is total WS-open time (the
-- billed quantity, ~$0.00194/s) so Insights can chart actual warmer spend.
-- Pruned to ~14 days by the warmer itself on insert.
CREATE TABLE IF NOT EXISTS fal_warmer_pings (
  id                 BIGSERIAL PRIMARY KEY,
  ts                 TIMESTAMPTZ NOT NULL DEFAULT now(),
  found_warm         BOOLEAN,             -- NULL when the ping errored/timed out
  ms_to_first_frame  INTEGER,             -- NULL when no frame ever arrived
  open_ms            INTEGER NOT NULL DEFAULT 0,
  error              TEXT
);
CREATE INDEX IF NOT EXISTS fal_warmer_pings_ts ON fal_warmer_pings (ts);

-- Every fal realtime CONNECTION, from both real users (source='user') and the
-- keep-warm loop (source='warmer') — one row per WS open→close span, emitted
-- by FalImageRelay via modules/fal/falConnectionLog.ts. Lets us compare the
-- cold-start experience of real users vs warmer pings (by user, time of day)
-- from the same table. `wait_ms` is the user-perceived metric: time from the
-- first unanswered frame SEND to the first frame received, spanning fal's
-- ~30s cold-window closes/reconnects (a cold sequence looks like N rows with
-- frames_received=0 then a final row whose wait_ms ≈ the full cold start).
-- `found_warm` = wait_ms under the shared 6s threshold. Pruned to ~30 days by
-- the warmer tick.
CREATE TABLE IF NOT EXISTS fal_connections (
  id              BIGSERIAL PRIMARY KEY,
  opened_at       TIMESTAMPTZ NOT NULL,
  source          TEXT NOT NULL,            -- 'user' | 'warmer'
  user_id         UUID,                     -- NULL for warmer
  stream_id       TEXT,
  connect_ms      INTEGER,
  first_frame_ms  INTEGER,                  -- open→first frame on THIS conn
  wait_ms         INTEGER,                  -- send-epoch→first frame, spans reconnects
  found_warm      BOOLEAN,                  -- NULL when no frame arrived on this conn
  frames_sent     INTEGER NOT NULL DEFAULT 0,
  frames_received INTEGER NOT NULL DEFAULT 0,
  open_ms         INTEGER NOT NULL DEFAULT 0,
  close_reason    TEXT,                     -- 'session_end' | 'idle_close' | 'upstream_close'
  close_code      INTEGER
);
CREATE INDEX IF NOT EXISTS fal_connections_opened ON fal_connections (opened_at);
CREATE INDEX IF NOT EXISTS fal_connections_source_opened ON fal_connections (source, opened_at);
CREATE INDEX IF NOT EXISTS fal_connections_user ON fal_connections (user_id, opened_at);

-- Lambda H100 pool lifecycle events (modules/lambda/devPool.ts) — one row per
-- stage transition, powering the Insights Launch tab's H100 waterfall:
--   launch_requested  → we asked Lambda for capacity (search begins)
--   launched          → capacity granted; duration_ms = search time
--   ready             → instance passed OUR /health; duration_ms = boot/warm time
--   launch_failed     → search or boot gave up; detail = reason
--   instance_dead     → ready instance failed 3 health checks (terminated)
--   idle_terminate    → scaled down after 30 min idle
--   adopted           → existing instance re-registered after backend redeploy
-- Pruned to 30 days by the pool tick.
CREATE TABLE IF NOT EXISTS lambda_pool_events (
  id            BIGSERIAL PRIMARY KEY,
  ts            TIMESTAMPTZ NOT NULL DEFAULT now(),
  event         TEXT NOT NULL,
  instance_name TEXT,
  region        TEXT,
  duration_ms   INTEGER,
  detail        TEXT
);
CREATE INDEX IF NOT EXISTS lambda_pool_events_ts ON lambda_pool_events (ts);
CREATE INDEX IF NOT EXISTS lambda_pool_events_event ON lambda_pool_events (event, ts);

-- Kiki backend durable schema. Idempotent (CREATE ... IF NOT EXISTS only) so it
-- can run at every boot and via `npm run db:migrate`. Future column additions
-- must use `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (CREATE TABLE IF NOT EXISTS
-- will NOT add columns to an existing table).

-- Registered user accounts. The durable system-of-record for identity +
-- subscription state, replacing the former Redis user hash. `apple_sub` UNIQUE
-- gives cross-deploy dedup natively (was the Redis `apple-sub:{sub}` key).
-- The subscription_* columns are unused until StoreKit lands; is_test_account
-- and the usage ledger are consumed by the Stage 2 fal-spend cap.
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

-- Per-user, per-month fal image-generation spend (USD), for the free-tier cap.
-- One row per (user, calendar month UTC); a new month is a fresh row reading 0,
-- so the monthly reset is implicit. Incremented atomically as the relay reports
-- connection-open time (~$0.00194/sec). Test accounts + subscribers are exempt
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

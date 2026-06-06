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

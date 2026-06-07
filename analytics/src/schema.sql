-- Kiki Insights schema. Idempotent — safe to run on every boot (migrate.ts).
--
-- IMPORTANT: Insights shares the BACKEND's Postgres. The `users` and
-- `monthly_usage` tables are OWNED BY THE BACKEND (backend/src/postgres/schema.sql)
-- — its `users` is the system-of-record for identity + subscription + the
-- test-account flag, and `monthly_usage` holds per-user fal spend. We do NOT
-- create or write those here; we only READ them (joined onto the tables below).
-- Defining a `users` table here would collide with the backend's and break it
-- (their apple_sub is NOT NULL UNIQUE).
--
-- These three tables are Insights-owned. user_id is TEXT here (it holds the
-- backend's UUID as a string); joins cast the backend's uuid with ::text.

-- Raw event spine. Arbitrary events land here by name + jsonb properties; the
-- "send any event" requirement is just an insert. occurred_at is the client's
-- timestamp; received_at is server ingest time.
CREATE TABLE IF NOT EXISTS events (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     TEXT NOT NULL,
  name        TEXT NOT NULL,
  properties  JSONB NOT NULL DEFAULT '{}'::jsonb,
  occurred_at TIMESTAMPTZ NOT NULL,
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  source      TEXT NOT NULL,             -- 'ios' | 'backend'
  stream_id   TEXT,
  drawing_id  TEXT
);
CREATE INDEX IF NOT EXISTS events_user_time ON events (user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS events_name      ON events (name);

-- Sessions are rolled up from events at ingest time (app foreground/background
-- and drawing open/close), so the timeline can render durations without
-- recomputing from the raw stream on every page load.
CREATE TABLE IF NOT EXISTS sessions (
  id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id     TEXT NOT NULL,
  source      TEXT NOT NULL,             -- 'app' | 'drawing'
  started_at  TIMESTAMPTZ NOT NULL,
  ended_at    TIMESTAMPTZ,
  duration_ms BIGINT,
  drawing_id  TEXT
);
CREATE INDEX IF NOT EXISTS sessions_user_time ON sessions (user_id, started_at DESC);

-- Drawing metadata. Blobs live on disk (BlobStore); only keys are stored here.
CREATE TABLE IF NOT EXISTS drawings (
  drawing_id    TEXT PRIMARY KEY,
  user_id       TEXT NOT NULL,
  prompt        TEXT,
  style_id      TEXT,
  created_at    TIMESTAMPTZ,
  updated_at    TIMESTAMPTZ,
  thumbnail_key TEXT,
  generated_key TEXT,
  video_key     TEXT                      -- reserved: video storage/export (later)
);
CREATE INDEX IF NOT EXISTS drawings_user ON drawings (user_id, updated_at DESC);

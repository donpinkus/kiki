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

-- Brush-dev stroke fixtures (Brush Studio → "Record strokes" → Upload). The fixture
-- JSON (replayable in BrushHarness) + a PNG snapshot of the canvas live in the
-- BlobStore; rows here are the index `BrushHarness/fetch-fixtures.sh` lists.
-- Dev tooling — doubles as a lightweight brush bug-report channel.
CREATE TABLE IF NOT EXISTS fixtures (
  id            BIGSERIAL PRIMARY KEY,
  user_id       TEXT NOT NULL,
  name          TEXT,
  note          TEXT,
  stroke_count  INT,
  fixture_key   TEXT NOT NULL,
  snapshot_key  TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fixtures_time ON fixtures (created_at DESC);

-- Session replay frames (admin Gallery). The backend mirrors a throttled
-- sample of each drawing session's frames here via POST /ingest/capture:
-- kind='sketch' (canvas JPEG the iPad sent to the image provider) and
-- kind='generated' (the JPEG that came back). Blobs live in the BlobStore
-- (captures/<stream_id>/...); rows are the replay index. captured_at is the
-- BACKEND's clock at relay time (frame ordering source of truth). Pruned to
-- CAPTURE_RETENTION_DAYS (blobs + rows) by the daily loop in index.ts.
CREATE TABLE IF NOT EXISTS capture_frames (
  id          BIGSERIAL PRIMARY KEY,
  stream_id   TEXT NOT NULL,
  user_id     TEXT NOT NULL,
  kind        TEXT NOT NULL,               -- 'sketch' | 'generated'
  seq         INT NOT NULL,
  captured_at TIMESTAMPTZ NOT NULL,
  blob_key    TEXT NOT NULL,
  UNIQUE (stream_id, kind, seq)
);
CREATE INDEX IF NOT EXISTS capture_frames_stream ON capture_frames (stream_id, captured_at);
CREATE INDEX IF NOT EXISTS capture_frames_user   ON capture_frames (user_id, captured_at DESC);
CREATE INDEX IF NOT EXISTS capture_frames_time   ON capture_frames (captured_at);

-- Prompt timeline for session replays: one row each time the user's prompt
-- text changed mid-drawing (deduped backend-side; seq 1 is the prompt the
-- session opened with). Rendered in the Gallery player as the prompt that was
-- live at the playhead + change markers on the scrubber. Same retention as
-- capture_frames.
CREATE TABLE IF NOT EXISTS capture_prompts (
  id          BIGSERIAL PRIMARY KEY,
  stream_id   TEXT NOT NULL,
  user_id     TEXT NOT NULL,
  seq         INT NOT NULL,
  captured_at TIMESTAMPTZ NOT NULL,
  prompt      TEXT NOT NULL,
  UNIQUE (stream_id, seq)
);
CREATE INDEX IF NOT EXISTS capture_prompts_stream ON capture_prompts (stream_id, captured_at);
CREATE INDEX IF NOT EXISTS capture_prompts_time   ON capture_prompts (captured_at);

-- Brush-test battery runs (BrushHarness → publish-run.sh). One row per published
-- render of the synthetic scene battery (+ any fixture replays), keyed to the git
-- SHA it was rendered from. PNGs live in the BlobStore; the Tests tab renders
-- side-by-sides/progressions across runs. Dev tooling — no pass/fail semantics
-- by design (visual inspection only, per Donald 2026-07-15).
CREATE TABLE IF NOT EXISTS test_runs (
  id          BIGSERIAL PRIMARY KEY,
  git_sha     TEXT,
  note        TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS test_run_images (
  id          BIGSERIAL PRIMARY KEY,
  run_id      BIGINT NOT NULL REFERENCES test_runs(id) ON DELETE CASCADE,
  scene       TEXT NOT NULL,
  blob_key    TEXT NOT NULL,
  description TEXT
);
-- Added after first deploy; harmless on fresh tables.
ALTER TABLE test_run_images ADD COLUMN IF NOT EXISTS description TEXT;
CREATE INDEX IF NOT EXISTS test_run_images_run ON test_run_images (run_id);

-- Brush clone targets (2026-07-16): reference briefs for recreating Procreate-style
-- brushes. Donald uploads stroke-sample + settings screenshots per target from the
-- Brushes tab; Claude pulls them via fetch-targets.sh, builds a preset, and posts
-- recreation ATTEMPT renders back to the same target for side-by-side review.
CREATE TABLE IF NOT EXISTS brush_targets (
  id          BIGSERIAL PRIMARY KEY,
  name        TEXT NOT NULL,
  note        TEXT,                        -- settings text, tuning intent, feedback
  status      TEXT NOT NULL DEFAULT 'todo', -- todo | in_progress | matched
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS brush_target_images (
  id          BIGSERIAL PRIMARY KEY,
  target_id   BIGINT NOT NULL REFERENCES brush_targets(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL DEFAULT 'reference',  -- reference | settings | attempt
  label       TEXT,
  note        TEXT,
  blob_key    TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS brush_target_images_target ON brush_target_images (target_id);

# `backend/scripts/`

Operational scripts. All run from `backend/` via `npx tsx scripts/<name>.ts`
(or the npm alias where noted).

## Scripts

- **`deploy.ts`** (`npm run deploy`) — deploys the backend to Railway
  (`railway up`) with Sentry `phase:deploying` log markers. Must run from
  `backend/` (the Railway service is linked to that directory).

- **`gen-style-thumbnail.sh <id> "<promptSuffix>"`** — renders a style-picker
  thumbnail via fal.ai `fal-ai/flux-2` text-to-image (klein is img2img-only on
  fal). Needs `FAL_KEY` in `backend/.env.local`. See CLAUDE.md "Adding a
  style".

- **`lambda/`** — Lambda Cloud tooling for the `IMAGE_PROVIDER=lambda` image
  path (per-region filesystem/venv/weights setup, capacity checks, cold-start
  bench, load test). See `lambda/README.md`.

- **`lib/deploy-sentry.ts`** — shared Sentry init for deploy CLIs (pipes
  console output into Sentry Logs with `phase:deploying`).

## Common environment

Scripts read secrets from `.env.local` at the repo root (gitignored):

- `FAL_KEY` — fal.ai API key (thumbnail generation).
- `LAMBDA_API_KEY` — Lambda Cloud API key (`lambda/*` scripts).
- `SENTRY_DSN` — optional; enables deploy log shipping from local runs.

## History

The RunPod-era scripts (volume populate/sync, test-pod lifecycle, DC probes)
were removed 2026-07-17 with the RunPod orchestration system. Recover from
git history if ever needed; the LTX video serving code they deployed is
archived in `archive/video-ltx/`.

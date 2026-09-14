/**
 * Deploy entrypoint: `railway up` with Sentry deploy markers.
 *
 * Wraps the Railway CLI so every deploy emits `phase:deploying` logs to
 * Sentry (see lib/deploy-sentry.ts) — lets you query "everything that
 * happened during the last deploy". Requires SENTRY_DSN in .env.local for
 * local CLI runs to ship to Sentry; no-op without it.
 *
 * Usage (from backend/): npm run deploy
 */

import { spawnSync } from 'node:child_process';
import { rmSync } from 'node:fs';
import { buildFleetBundle } from '../src/modules/lambda/fleetBundle.js';
import { execSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { initDeployLogging, flushDeployLogging } from './lib/deploy-sentry.js';

initDeployLogging('deploy');

const __dirname = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(BACKEND_DIR, '..');

async function main(): Promise<void> {
  const gitSha = execSync('git rev-parse HEAD', { cwd: REPO_ROOT }).toString().trim();
  const startedAt = Date.now();
  // Pack model-servers/ for the fleet (served at /v1/fleet/*; instances
  // self-refresh from it at boot). Content-hashed, so unchanged code yields
  // the same manifest and no re-downloads.
  // fleet/ must NOT be gitignored: `railway up` applies .gitignore even with a
  // .railwayignore present (verified 2026-09-14 — the first deploy shipped no
  // bundle). So it exists only for the duration of the upload: built here,
  // removed in the finally below, never committed.
  const fleetDir = resolve(BACKEND_DIR, 'fleet');
  const manifest = buildFleetBundle(REPO_ROOT, fleetDir, gitSha);
  console.log(`[deploy] fleet bundle: ${manifest.files} files, ${Math.round(manifest.bytes / 1024)} KiB, sha256=${manifest.sha256.slice(0, 12)}`);
  console.log(`[deploy] starting: git=${gitSha.slice(0, 8)}`);

  console.log('[deploy] running railway up...');
  let r;
  try {
    r = spawnSync('railway', ['up'], { cwd: BACKEND_DIR, stdio: 'inherit' });
  } finally {
    rmSync(fleetDir, { recursive: true, force: true });
  }
  const upCode = r.status ?? -1;
  const durationSec = Math.round((Date.now() - startedAt) / 1000);
  if (upCode === 0) {
    console.log(`[deploy] complete: duration_s=${durationSec} git=${gitSha.slice(0, 8)}`);
  } else {
    console.error(`[deploy] railway up failed (exit ${upCode}); duration_s=${durationSec}`);
  }
  await flushDeployLogging();
  process.exit(upCode);
}

main().catch(async (e) => {
  console.error('[deploy] FATAL:', e);
  await flushDeployLogging();
  process.exit(1);
});

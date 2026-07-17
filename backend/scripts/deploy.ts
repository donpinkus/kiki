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
  console.log(`[deploy] starting: git=${gitSha.slice(0, 8)}`);

  console.log('[deploy] running railway up...');
  const r = spawnSync('railway', ['up'], { cwd: BACKEND_DIR, stdio: 'inherit' });
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

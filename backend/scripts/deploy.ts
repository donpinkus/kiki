/**
 * Smart deploy entrypoint. Auto-syncs network volumes only when
 * flux-klein-server/ has changed since the last successful deploy, then
 * runs `railway up`.
 *
 * Reuses backend/.flux-app-version (already maintained for the
 * orchestrator's drift check) as state — no new state files. Compares the
 * file's previous value (= last-deployed flux subtree hash) against the
 * current `git rev-parse HEAD:flux-klein-server`:
 *   - same  → skip sync, fast deploy (backend-only iteration)
 *   - differ → fan out sync-all-dcs.ts; abort if any DC fails
 * After a successful sync (or when sync wasn't needed), write the new
 * flux + git hashes and run `railway up`.
 *
 * Edge cases (all handled by reusing the existing state file):
 *   - First-ever deploy / file missing → triggers sync (safe default)
 *   - Different machine / fresh clone → triggers sync (extra work, never broken)
 *   - Sync partial-fails → don't write new state, don't railway up.
 *     Next attempt re-detects same diff and retries.
 *   - Sync succeeds, railway up fails → state file is updated. Next deploy
 *     skips sync (volumes are current), retries railway up. Correct.
 *   - User runs bare `railway up` → bypasses, drift can occur, but the
 *     production drift check (orchestrator + PostHog volume_status) catches
 *     it on the next pod boot. Escape hatch preserved.
 *
 * Usage (from backend/): npm run deploy
 */

import { execSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { initDeployLogging, flushDeployLogging } from './lib/deploy-sentry.js';

initDeployLogging('deploy');

const __dirname = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(BACKEND_DIR, '..');

const FLUX_VERSION_FILE = resolve(BACKEND_DIR, '.flux-app-version');
const GIT_SHA_FILE = resolve(BACKEND_DIR, '.git-sha');

function git(args: string): string {
  return execSync(`git ${args}`, { cwd: REPO_ROOT }).toString().trim();
}

function readTrimmed(path: string): string {
  if (!existsSync(path)) return '';
  return readFileSync(path, 'utf-8').trim();
}

function runInherit(cmd: string, args: string[]): number {
  const r = spawnSync(cmd, args, { cwd: BACKEND_DIR, stdio: 'inherit' });
  return r.status ?? -1;
}

async function main(): Promise<void> {
  const prevFlux = readTrimmed(FLUX_VERSION_FILE);
  const newFlux = git('rev-parse HEAD:flux-klein-server');
  const newGit = git('rev-parse HEAD');
  const startedAt = Date.now();

  console.log(
    `[deploy] starting: git=${newGit.slice(0, 8)} flux=${newFlux.slice(0, 8)} prev_flux=${prevFlux.slice(0, 8) || '(none)'}`,
  );

  if (prevFlux === newFlux) {
    console.log(`[deploy] flux-klein-server unchanged (${newFlux.slice(0, 8)}); skipping sync`);
  } else {
    const detail = prevFlux
      ? `${prevFlux.slice(0, 8)} → ${newFlux.slice(0, 8)}`
      : `(none) → ${newFlux.slice(0, 8)}`;
    console.log(`[deploy] flux-klein-server changed since last deploy: ${detail}`);
    console.log('[deploy] running sync-all-dcs first...');
    const syncCode = runInherit('npx', ['tsx', 'scripts/sync-all-dcs.ts']);
    if (syncCode !== 0) {
      console.error(`\n[deploy] sync-all failed (exit ${syncCode}); aborting deploy`);
      console.error('[deploy] state files NOT updated — fix the failing DC and re-run npm run deploy');
      await flushDeployLogging();
      process.exit(syncCode);
    }
  }

  // Write state files only after sync succeeded (or wasn't needed).
  writeFileSync(FLUX_VERSION_FILE, newFlux + '\n');
  writeFileSync(GIT_SHA_FILE, newGit + '\n');
  console.log(
    `[deploy] stamped .flux-app-version=${newFlux.slice(0, 8)} .git-sha=${newGit.slice(0, 8)}`,
  );

  console.log('[deploy] running railway up...');
  const upCode = runInherit('railway', ['up']);
  const durationSec = Math.round((Date.now() - startedAt) / 1000);
  if (upCode === 0) {
    console.log(`[deploy] complete: duration_s=${durationSec} git=${newGit.slice(0, 8)}`);
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

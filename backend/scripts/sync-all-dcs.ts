/**
 * Fan out sync-flux-app.ts to every configured network volume in parallel.
 *
 * Used by `npm run deploy` to keep all DC volumes current with the latest
 * flux-klein-server/ before shipping the backend that expects it. Also
 * runnable on its own for ad-hoc syncs (e.g., recovering after a DC was
 * skipped due to capacity exhaustion, without redeploying backend).
 *
 * Reads NETWORK_VOLUMES_BY_DC and RUNPOD_API_KEY from .env.local at the
 * repo root. RUNPOD_SSH_PRIVATE_KEY falls back to ~/.ssh/id_ed25519 when
 * unset, so `npm run deploy` works without explicit env-var passing.
 *
 * Per-DC stdout/stderr captured to /tmp/sync-all-<DC>.log so one DC's
 * 500-line pip-install dump doesn't drown out the others. Final summary
 * table at the end. Exits 1 if any DC failed (so chained `npm run deploy`
 * aborts cleanly without overwriting state files).
 *
 * Usage (from backend/):
 *   npm run sync-all
 */

import { spawn } from 'node:child_process';
import { existsSync, openSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(BACKEND_DIR, '..');

// ─── Env loading ──────────────────────────────────────────────────────────

function loadEnvLocal(): void {
  const path = resolve(REPO_ROOT, '.env.local');
  if (!existsSync(path)) return;
  const content = readFileSync(path, 'utf-8');
  for (const line of content.split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (m && m[1] && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}
loadEnvLocal();

// SSH key fallback — most users keep their RunPod-registered key at the
// default ed25519 path. Letting npm run deploy auto-resolve it removes one
// more "did I set the env?" footgun.
if (!process.env['RUNPOD_SSH_PRIVATE_KEY']) {
  const sshPath = resolve(homedir(), '.ssh', 'id_ed25519');
  if (existsSync(sshPath)) {
    process.env['RUNPOD_SSH_PRIVATE_KEY'] = readFileSync(sshPath, 'utf-8');
  } else {
    console.error(`RUNPOD_SSH_PRIVATE_KEY env not set and ${sshPath} not readable`);
    process.exit(1);
  }
}

if (!process.env['RUNPOD_API_KEY']) {
  console.error('RUNPOD_API_KEY required (set in .env.local at repo root)');
  process.exit(1);
}

function parseMap(name: string, required: boolean): Record<string, string> {
  const raw = process.env[name];
  if (!raw) {
    if (required) {
      console.error(`${name} required (set in .env.local at repo root)`);
      process.exit(1);
    }
    return {};
  }
  try {
    return JSON.parse(raw) as Record<string, string>;
  } catch (e) {
    console.error(`${name} is not valid JSON: ${(e as Error).message}`);
    process.exit(1);
  }
}

// Sync runs against both volume sets — image and video both need the
// flux-klein-server tree (server.py + video_server.py share a venv) up to
// date. Image volumes are required; video are optional (empty if the
// LTX-2.3 migration's video volumes haven't been provisioned yet).
const IMAGE_VOLUMES = parseMap('NETWORK_VOLUMES_BY_DC', true);
const VIDEO_VOLUMES = parseMap('NETWORK_VOLUMES_BY_DC_VIDEO', false);
const overlapDcs = Object.keys(IMAGE_VOLUMES).filter((dc) => dc in VIDEO_VOLUMES);
if (overlapDcs.length > 0) {
  console.error(
    `DCs cannot appear in both NETWORK_VOLUMES_BY_DC and _VIDEO (overlap: ${overlapDcs.join(', ')})`,
  );
  process.exit(1);
}
const VOLUMES: Record<string, string> = { ...IMAGE_VOLUMES, ...VIDEO_VOLUMES };

// ─── Per-DC sync ──────────────────────────────────────────────────────────

interface SyncResult {
  dc: string;
  ok: boolean;
  durationSec: number;
  exitCode: number;
  logPath: string;
}

function syncOne(dc: string, volumeId: string): Promise<SyncResult> {
  const logPath = `/tmp/sync-all-${dc}.log`;
  const out = openSync(logPath, 'w');
  const start = Date.now();
  return new Promise((resolveP) => {
    const proc = spawn(
      'npx',
      ['tsx', 'scripts/sync-flux-app.ts', '--dc', dc, '--volume-id', volumeId],
      { cwd: BACKEND_DIR, stdio: ['ignore', out, out], env: process.env },
    );
    proc.on('exit', (code) => {
      const exitCode = code ?? -1;
      resolveP({
        dc,
        ok: exitCode === 0,
        durationSec: Math.round((Date.now() - start) / 1000),
        exitCode,
        logPath,
      });
    });
  });
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const dcs = Object.keys(VOLUMES).sort();
  console.log(`[sync-all] launching ${dcs.length} parallel syncs: ${dcs.join(', ')}`);
  console.log('[sync-all] per-DC logs: /tmp/sync-all-<DC>.log');
  console.log('[sync-all] each sync takes ~70s when nothing changed, 5-10 min on first sync');

  const results = await Promise.all(dcs.map((dc) => syncOne(dc, VOLUMES[dc]!)));

  console.log('\n[sync-all] summary:');
  for (const r of results) {
    const status = r.ok ? '✓' : '✗';
    console.log(
      `  ${status} ${r.dc.padEnd(10)} (${r.durationSec}s, exit=${r.exitCode}, log=${r.logPath})`,
    );
  }

  const failed = results.filter((r) => !r.ok);
  if (failed.length > 0) {
    console.error(`\n[sync-all] ${failed.length}/${results.length} DCs failed; check log files`);
    process.exit(1);
  }
  console.log(`\n[sync-all] all ${results.length} DCs synced successfully`);
}

main().catch((e) => {
  console.error('[sync-all] FATAL:', e);
  process.exit(1);
});

/**
 * Read-only status check: report the deployed flux-klein-server version on
 * each network volume by querying PostHog for the most recent
 * `pod.provision.completed` event per DC.
 *
 * Drift signal is `app_flux_app_version` — the git tree-hash of
 * `flux-klein-server/` at sync time. This only changes when files in that
 * subtree change, so commits to docs / iOS / backend code don't false-flag
 * drift. `app_git_sha` is shown for forensic context only ("what commit was
 * this synced from") but isn't used for the drift comparison.
 *
 * DCs with no recent provision show as "no recent data" — for those, trigger
 * a manual provision or accept the unknown until natural traffic exposes the
 * version.
 *
 * Usage (run from backend/):
 *   POSTHOG_PERSONAL_API_KEY=phx_... POSTHOG_PROJECT_ID=389365 \
 *     npx tsx scripts/check-volume-versions.ts
 *
 * Reads keys from .env.local at the repo root (sibling to backend/) if
 * they're not in the environment.
 *
 * Cost: free. Runs entirely against PostHog HTTP API.
 *
 * Limitations:
 *   - Only tells you about volumes that have served a recent cold start. A
 *     volume that's been stale for 30 days won't show in PostHog.
 *   - Compares against local working-tree state. If you haven't pulled, the
 *     comparison is to whatever you've got checked out.
 *   - Tree-hash reflects committed state only — uncommitted edits don't
 *     change it. Pair with the gitDirty flag (in stamp metadata) if you
 *     deploy uncommitted.
 */

import { execSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

// ─── Config: load .env.local sibling to backend/ ──────────────────────────

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..', '..');

function loadEnvLocal(): void {
  try {
    const content = readFileSync(resolve(REPO_ROOT, '.env.local'), 'utf-8');
    for (const line of content.split('\n')) {
      const m = line.match(/^([A-Z_]+)=(.*)$/);
      if (m && m[1] && !process.env[m[1]]) process.env[m[1]] = m[2];
    }
  } catch {
    // No .env.local — env vars must already be set
  }
}
loadEnvLocal();

const POSTHOG_KEY = process.env['POSTHOG_PERSONAL_API_KEY'];
const POSTHOG_PROJECT = process.env['POSTHOG_PROJECT_ID'];
if (!POSTHOG_KEY || !POSTHOG_PROJECT) {
  console.error('POSTHOG_PERSONAL_API_KEY and POSTHOG_PROJECT_ID required (or set them in .env.local)');
  process.exit(1);
}

// Mirror of NETWORK_VOLUMES_BY_DC. Hardcoded here so the script is fully
// self-contained — if a DC drops off this list, edit here in lockstep with
// orchestrator config.
const VOLUMES: Record<string, string> = {
  'EUR-NO-1': '49n6i3twuw',
  'EU-RO-1': 'xbiu29htvu',
  'EU-CZ-1': 'hhmat30tzx',
  'US-IL-1': '59plfch67d',
  'US-NC-1': '5vz7ubospw',
};

// ─── PostHog query ────────────────────────────────────────────────────────

interface DcVersion {
  dc: string;
  volumeId: string;
  fluxAppVersion: string | null;  // git tree-hash of flux-klein-server/ — drift signal
  gitSha: string | null;          // commit SHA at sync time — forensic context only
  gitDirty: boolean | null;
  syncedAtUtc: string | null;
  syncedBy: string | null;
  lastProvisionAt: string | null;
}

async function queryDcVersions(): Promise<DcVersion[]> {
  // Window is wide (30d) so we catch even slow-rolling DCs. Pick the most
  // recent stamp per DC — that's what the latest cold start saw on the volume.
  // Drift is derived from app_flux_app_version (subtree hash, only changes when
  // flux-klein-server/ files change). app_git_sha is shown for context only.
  const query = `
    SELECT
      properties.dc AS dc,
      argMax(properties.app_flux_app_version, timestamp) AS flux_app_version,
      argMax(properties.app_git_sha, timestamp) AS git_sha,
      argMax(properties.app_git_dirty, timestamp) AS git_dirty,
      argMax(properties.app_synced_at_utc, timestamp) AS synced_at_utc,
      argMax(properties.app_synced_by, timestamp) AS synced_by,
      max(timestamp) AS last_provision_at
    FROM events
    WHERE event = 'pod.provision.completed'
      AND timestamp > now() - INTERVAL 30 DAY
      AND (properties.app_flux_app_version IS NOT NULL OR properties.app_git_sha IS NOT NULL)
    GROUP BY dc
  `;

  const res = await fetch(
    `https://us.posthog.com/api/projects/${POSTHOG_PROJECT}/query/`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${POSTHOG_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ query: { kind: 'HogQLQuery', query } }),
    },
  );
  if (!res.ok) {
    throw new Error(`PostHog HTTP ${res.status}: ${await res.text()}`);
  }
  const body = (await res.json()) as { results?: unknown[][] };
  const rows = body.results ?? [];

  const seen = new Map<string, DcVersion>();
  for (const row of rows) {
    const [dc, fluxAppVersion, gitSha, gitDirty, syncedAtUtc, syncedBy, lastProvisionAt] = row as [
      string, string | null, string | null, boolean | string | null,
      string | null, string | null, string | null,
    ];
    seen.set(dc, {
      dc,
      volumeId: VOLUMES[dc] ?? '?',
      fluxAppVersion,
      gitSha,
      gitDirty: typeof gitDirty === 'string' ? gitDirty === 'true' : gitDirty,
      syncedAtUtc,
      syncedBy,
      lastProvisionAt,
    });
  }

  // Include DCs with no recent provision data so they're visible in the report.
  for (const dc of Object.keys(VOLUMES)) {
    if (!seen.has(dc)) {
      seen.set(dc, {
        dc,
        volumeId: VOLUMES[dc]!,
        fluxAppVersion: null, gitSha: null, gitDirty: null,
        syncedAtUtc: null, syncedBy: null, lastProvisionAt: null,
      });
    }
  }
  return [...seen.values()].sort((a, b) => a.dc.localeCompare(b.dc));
}

// ─── Local git lookup ─────────────────────────────────────────────────────

/** Tree-hash of flux-klein-server/ at HEAD. Matches what the deploy writes. */
function localFluxAppVersion(): string {
  try {
    return execSync('git rev-parse HEAD:flux-klein-server', { cwd: REPO_ROOT }).toString().trim();
  } catch {
    return 'unknown';
  }
}

function localGitSha(): string {
  try {
    return execSync('git rev-parse HEAD', { cwd: REPO_ROOT }).toString().trim();
  } catch {
    return 'unknown';
  }
}

// ─── Render ───────────────────────────────────────────────────────────────

function fmt(s: string | null, w: number): string {
  return (s ?? '—').padEnd(w);
}

function renderTable(rows: DcVersion[], localFlux: string, localGit: string): void {
  console.log(`\nLocal flux_app_version: ${localFlux.slice(0, 8)}    Local HEAD: ${localGit.slice(0, 8)}\n`);
  console.log(
    [
      fmt('DC', 10),
      fmt('volume', 12),
      fmt('flux_app_v', 12),
      fmt('git_sha', 12),
      fmt('synced_at_utc', 22),
      fmt('drift', 24),
    ].join(' '),
  );
  console.log('-'.repeat(96));
  for (const r of rows) {
    let drift: string;
    if (r.fluxAppVersion === null && r.gitSha === null) {
      drift = 'no recent data';
    } else if (r.fluxAppVersion === null) {
      drift = 'pre-flux_app_version stamp';
    } else if (r.fluxAppVersion === localFlux) {
      drift = r.gitDirty ? 'current (dirty sync)' : 'current';
    } else {
      drift = 'flux-klein-server differs';
    }
    console.log(
      [
        fmt(r.dc, 10),
        fmt(r.volumeId, 12),
        fmt(r.fluxAppVersion?.slice(0, 8) ?? null, 12),
        fmt(r.gitSha?.slice(0, 8) ?? null, 12),
        fmt(r.syncedAtUtc, 22),
        fmt(drift, 24),
      ].join(' '),
    );
  }
  console.log('');
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const [rows, localFlux, localGit] = await Promise.all([
    queryDcVersions(),
    Promise.resolve(localFluxAppVersion()),
    Promise.resolve(localGitSha()),
  ]);
  renderTable(rows, localFlux, localGit);
}

main().catch((e) => {
  console.error('[check-volume-versions] FAILED:', e);
  process.exit(1);
});

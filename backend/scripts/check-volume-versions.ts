/**
 * Read-only status check: report the deployed app version on each network
 * volume by querying PostHog for the most recent `pod.provision.completed`
 * event per DC.
 *
 * Compares each DC's `app_version_git_sha` against local git HEAD and flags
 * drift. DCs with no recent provision (e.g. low-traffic ones that haven't
 * spun up a pod since the last sync) show as "no recent data" — for those,
 * trigger a manual provision or accept the unknown until natural traffic
 * exposes the version.
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
 *   - The "stale" check compares against local git HEAD — if the working tree
 *     is dirty or you haven't pulled, the comparison is to whatever you've
 *     got checked out.
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
  gitSha: string | null;
  gitDirty: boolean | null;
  syncedAtUtc: string | null;
  syncedBy: string | null;
  lastProvisionAt: string | null;
}

async function queryDcVersions(): Promise<DcVersion[]> {
  // Window is wide (30d) so we catch even slow-rolling DCs. Pick the most
  // recent app_version_git_sha per DC — that's what the latest cold start
  // saw on the volume.
  const query = `
    SELECT
      properties.dc AS dc,
      argMax(properties.app_git_sha, timestamp) AS git_sha,
      argMax(properties.app_git_dirty, timestamp) AS git_dirty,
      argMax(properties.app_synced_at_utc, timestamp) AS synced_at_utc,
      argMax(properties.app_synced_by, timestamp) AS synced_by,
      max(timestamp) AS last_provision_at
    FROM events
    WHERE event = 'pod.provision.completed'
      AND timestamp > now() - INTERVAL 30 DAY
      AND properties.app_git_sha IS NOT NULL
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
    const [dc, gitSha, gitDirty, syncedAtUtc, syncedBy, lastProvisionAt] = row as [
      string, string | null, boolean | string | null, string | null, string | null, string | null,
    ];
    seen.set(dc, {
      dc,
      volumeId: VOLUMES[dc] ?? '?',
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
        gitSha: null, gitDirty: null, syncedAtUtc: null, syncedBy: null, lastProvisionAt: null,
      });
    }
  }
  return [...seen.values()].sort((a, b) => a.dc.localeCompare(b.dc));
}

// ─── Local git lookup ─────────────────────────────────────────────────────

function localGitSha(): string {
  try {
    return execSync('git rev-parse HEAD', { cwd: REPO_ROOT }).toString().trim();
  } catch {
    return 'unknown';
  }
}

function commitsBetween(remote: string, local: string): number | null {
  if (remote === local) return 0;
  try {
    const out = execSync(`git rev-list --count ${remote}..${local}`, { cwd: REPO_ROOT }).toString().trim();
    return Number(out);
  } catch {
    // Remote SHA isn't in local history (e.g. user hasn't pulled, or remote is dirty/lost commit).
    return null;
  }
}

// ─── Render ───────────────────────────────────────────────────────────────

function fmt(s: string | null, w: number): string {
  return (s ?? '—').padEnd(w);
}

function renderTable(rows: DcVersion[], localHead: string): void {
  const localShort = localHead.slice(0, 8);
  console.log(`\nLocal HEAD: ${localShort}\n`);
  console.log(
    [
      fmt('DC', 10),
      fmt('volume', 12),
      fmt('git_sha', 12),
      fmt('synced_at_utc', 22),
      fmt('synced_by', 26),
      fmt('drift', 24),
    ].join(' '),
  );
  console.log('-'.repeat(108));
  for (const r of rows) {
    let drift: string;
    if (r.gitSha === null) {
      drift = 'no recent data';
    } else if (r.gitSha === localHead) {
      drift = r.gitDirty ? 'current (dirty sync)' : 'current';
    } else {
      const n = commitsBetween(r.gitSha, localHead);
      if (n === null) drift = 'diverged (unknown)';
      else if (n > 0) drift = `${n} commit${n === 1 ? '' : 's'} behind`;
      else drift = 'ahead/diverged';
    }
    console.log(
      [
        fmt(r.dc, 10),
        fmt(r.volumeId, 12),
        fmt(r.gitSha?.slice(0, 8) ?? null, 12),
        fmt(r.syncedAtUtc, 22),
        fmt(r.syncedBy, 26),
        fmt(drift, 24),
      ].join(' '),
    );
  }
  console.log('');
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const [rows, localHead] = await Promise.all([queryDcVersions(), Promise.resolve(localGitSha())]);
  renderTable(rows, localHead);
}

main().catch((e) => {
  console.error('[check-volume-versions] FAILED:', e);
  process.exit(1);
});

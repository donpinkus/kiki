/**
 * Fleet bundle: model-servers/ packed for delivery to Lambda instances.
 *
 * `npm run deploy` calls buildFleetBundle() before `railway up`, writing
 *   backend/fleet/model-servers.tgz   — the code (no dev/, no caches)
 *   backend/fleet/manifest.json       — { sha256, git_sha, built_at, files, bytes }
 * The Docker build COPYs backend/ so the backend serves both at
 * GET /v1/fleet/{manifest,bundle} (routes/fleet.ts). Every instance's
 * cloud-init bootstrap (instancePool.userData) compares the manifest to the
 * region filesystem's $FS/kiki/app/.manifest and refreshes when they differ —
 * so a backend deploy is the ONLY rollout step for model-server code; no
 * laptop-side rsync, no per-region setup re-run.
 *
 * `sha256` is a CONTENT hash (sorted relative paths + bytes), not the
 * tarball's: identical code across deploys keeps the same manifest, so
 * instances don't re-download on every backend deploy.
 */
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';

const EXCLUDE_DIRS = new Set(['__pycache__', 'dev', '.pytest_cache']);
const EXCLUDE_FILE = (name: string) =>
  name.endsWith('.pyc') || name === '.DS_Store' || name === '.manifest' || name === '.manifest.json';

export interface FleetManifest {
  sha256: string;
  git_sha: string;
  built_at: string;
  files: number;
  bytes: number;
}

/** Sorted list of files under model-servers/ that ship in the bundle. */
export function listBundleFiles(modelServersDir: string): string[] {
  const out: string[] = [];
  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) {
        if (!EXCLUDE_DIRS.has(entry.name)) walk(full);
      } else if (entry.isFile() && !EXCLUDE_FILE(entry.name)) {
        out.push(relative(modelServersDir, full));
      }
    }
  };
  walk(modelServersDir);
  return out.sort();
}

export function contentHash(modelServersDir: string, files: string[]): { sha256: string; bytes: number } {
  const h = createHash('sha256');
  let bytes = 0;
  for (const rel of files) {
    const data = readFileSync(join(modelServersDir, rel));
    h.update(rel).update('\0').update(data).update('\0');
    bytes += data.length;
  }
  return { sha256: h.digest('hex'), bytes };
}

export function buildFleetBundle(repoRoot: string, outDir: string, gitSha: string): FleetManifest {
  const modelServersDir = resolve(repoRoot, 'model-servers');
  if (!statSync(modelServersDir).isDirectory()) throw new Error(`no model-servers/ at ${modelServersDir}`);
  const files = listBundleFiles(modelServersDir);
  const { sha256, bytes } = contentHash(modelServersDir, files);
  mkdirSync(outDir, { recursive: true });
  // `-C repoRoot model-servers/<file>` keeps the top-level `model-servers/`
  // directory in the archive — the bootstrap extracts and moves that dir.
  execFileSync(
    'tar',
    ['czf', resolve(outDir, 'model-servers.tgz'), '-C', repoRoot, ...files.map((f) => `model-servers/${f}`)],
    { stdio: 'inherit' },
  );
  const manifest: FleetManifest = { sha256, git_sha: gitSha, built_at: new Date().toISOString(), files: files.length, bytes };
  writeFileSync(resolve(outDir, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
  return manifest;
}

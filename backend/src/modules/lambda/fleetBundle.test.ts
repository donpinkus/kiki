import { execFileSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, mkdirSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { describe, expect, it } from 'vitest';
import { buildFleetBundle, contentHash, listBundleFiles } from './fleetBundle.js';

function fakeRepo(): string {
  const root = mkdtempSync(join(tmpdir(), 'kiki-repo-'));
  const ms = join(root, 'model-servers');
  mkdirSync(join(ms, 'image'), { recursive: true });
  mkdirSync(join(ms, 'dev'), { recursive: true });
  mkdirSync(join(ms, 'shared', '__pycache__'), { recursive: true });
  writeFileSync(join(ms, 'image', 'server.py'), 'print(1)\n');
  writeFileSync(join(ms, 'image', 'boot.sh'), '#!/bin/bash\n');
  writeFileSync(join(ms, 'dev', 'bench.py'), 'x');
  writeFileSync(join(ms, 'shared', '__pycache__', 'a.pyc'), 'x');
  writeFileSync(join(ms, 'shared', 'config.py'), 'y=1\n');
  writeFileSync(join(ms, '.manifest'), 'stale');
  return root;
}

describe('fleet bundle', () => {
  it('ships code only: no dev/, caches, or prior manifests; deterministic content hash', () => {
    const root = fakeRepo();
    const files = listBundleFiles(join(root, 'model-servers'));
    expect(files).toEqual(['image/boot.sh', 'image/server.py', 'shared/config.py']);
    const a = contentHash(join(root, 'model-servers'), files).sha256;
    const b = contentHash(join(root, 'model-servers'), files).sha256;
    expect(a).toBe(b);
    writeFileSync(join(root, 'model-servers', 'shared', 'config.py'), 'y=2\n');
    expect(contentHash(join(root, 'model-servers'), files).sha256).not.toBe(a);
  });

  it('writes manifest.json + a tarball rooted at model-servers/', () => {
    const root = fakeRepo();
    const out = join(root, 'fleet');
    const m = buildFleetBundle(root, out, 'deadbeef');
    expect(m.files).toBe(3);
    expect(JSON.parse(readFileSync(join(out, 'manifest.json'), 'utf8')).sha256).toBe(m.sha256);
    const listing = execFileSync('tar', ['tzf', join(out, 'model-servers.tgz')]).toString();
    expect(listing).toContain('model-servers/image/boot.sh');
    expect(listing).not.toContain('dev/');
  });
});

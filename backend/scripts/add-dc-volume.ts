/**
 * One-shot: provision a new image-pod network volume in a RunPod DC where
 * we don't already have one, populate it with FLUX weights, and sync app
 * code. Output is the env-var snippet to paste into NETWORK_VOLUMES_BY_DC.
 *
 * Why: orchestrator placement is bounded by the DCs in NETWORK_VOLUMES_BY_DC.
 * If all of those DCs simultaneously run out of 5090 spot stock, users get
 * "no instances available" errors. Wider DC coverage = fewer outages.
 *
 * Usage (from backend/):
 *   # Explicit single DC:
 *   npm run add-dc-volume -- --dc EUR-IS-1
 *
 *   # Auto-discover: provision in every DC that has 5090 stock and isn't
 *   # already in NETWORK_VOLUMES_BY_DC. Sequential, ~15 min per DC.
 *   npm run add-dc-volume
 *
 * Idempotent — re-runs safely:
 *   - If a volume already exists in the DC AND is in NETWORK_VOLUMES_BY_DC,
 *     skip entirely (fully provisioned previously).
 *   - If a volume exists but isn't in the env map (partial previous run),
 *     reuse it and re-attempt populate + sync.
 *   - populate-volume.ts and sync-flux-app.ts are themselves idempotent.
 *
 * After success, the operator must add the new DC to NETWORK_VOLUMES_BY_DC
 * in .env.local AND Railway, then `npm run deploy`. The script prints the
 * exact JSON fragment to paste.
 *
 * Currently image-pod only (RTX 5090, 50 GB volumes). Video support would
 * be a small extension — pass through --kind to the subscripts and use the
 * H100 GPU type for the stock probe.
 */

import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import {
  createNetworkVolume,
  getGpuStock,
  listDataCenters,
  listNetworkVolumes,
  type NetworkVolume,
} from './lib/runpod-graphql.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BACKEND_DIR = resolve(__dirname, '..');
const REPO_ROOT = resolve(BACKEND_DIR, '..');

// ─── Constants ────────────────────────────────────────────────────────────

const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const VOLUME_SIZE_GB = 50;
const VOLUME_NAME_PREFIX = 'kiki-flux';

// ─── Env loading (mirrors sync-all-dcs.ts) ────────────────────────────────

function loadEnvLocal(): void {
  const path = resolve(REPO_ROOT, '.env.local');
  if (!existsSync(path)) return;
  const content = readFileSync(path, 'utf-8');
  for (const line of content.split('\n')) {
    const m = line.match(/^([A-Z_]+)=(.*)$/);
    if (!m || !m[1]) continue;
    if (process.env[m[1]]) continue;
    let value = m[2] ?? '';
    if (
      (value.startsWith("'") && value.endsWith("'")) ||
      (value.startsWith('"') && value.endsWith('"'))
    ) {
      value = value.slice(1, -1);
    }
    process.env[m[1]] = value;
  }
}
loadEnvLocal();

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

// ─── CLI args ─────────────────────────────────────────────────────────────

function getOptionalArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  if (idx === -1 || idx === process.argv.length - 1) return undefined;
  return process.argv[idx + 1];
}

const EXPLICIT_DC = getOptionalArg('--dc');

// ─── Subprocess helpers ───────────────────────────────────────────────────

function runScript(script: string, args: string[]): Promise<void> {
  return new Promise((resolveP, rejectP) => {
    const proc = spawn('npx', ['tsx', `scripts/${script}`, ...args], {
      cwd: BACKEND_DIR,
      stdio: 'inherit',
      env: process.env,
    });
    proc.on('exit', (code) => {
      if (code === 0) resolveP();
      else rejectP(new Error(`${script} exited with code ${code}`));
    });
  });
}

// ─── Per-DC provision ─────────────────────────────────────────────────────

interface ProvisionResult {
  dc: string;
  volumeId: string;
  status: 'created' | 'reused' | 'already-wired' | 'skipped-no-stock' | 'error';
  error?: string;
}

async function provisionOne(
  dc: string,
  existingVolumes: NetworkVolume[],
  wiredDcs: Set<string>,
): Promise<ProvisionResult> {
  console.log(`\n━━━ ${dc} ━━━`);

  const existingInDc = existingVolumes.find((v) => v.dataCenterId === dc);

  if (existingInDc && wiredDcs.has(dc)) {
    console.log(`[add-dc] ${dc} already in NETWORK_VOLUMES_BY_DC (vol=${existingInDc.id}); skipping`);
    return { dc, volumeId: existingInDc.id, status: 'already-wired' };
  }

  let volumeId: string;
  let resultStatus: 'created' | 'reused';

  if (existingInDc) {
    console.log(
      `[add-dc] ${dc} has volume ${existingInDc.id} (${existingInDc.size} GB) but it's not in env map — reusing it`,
    );
    volumeId = existingInDc.id;
    resultStatus = 'reused';
  } else {
    const stock = await getGpuStock(GPU_TYPE_ID, dc);
    if (!stock.stockStatus || stock.stockStatus === 'None') {
      console.log(`[add-dc] ${dc} has no 5090 stock right now (${stock.stockStatus ?? 'null'}); skipping`);
      return { dc, volumeId: '', status: 'skipped-no-stock' };
    }
    console.log(`[add-dc] ${dc} has 5090 stock (${stock.stockStatus}, $${stock.uninterruptablePrice}/hr); creating volume...`);
    const name = `${VOLUME_NAME_PREFIX}-${dc.toLowerCase()}`;
    const vol = await createNetworkVolume(name, dc, VOLUME_SIZE_GB);
    console.log(`[add-dc] created volume ${vol.id} (${vol.name}, ${vol.size} GB)`);
    volumeId = vol.id;
    resultStatus = 'created';
  }

  console.log(`[add-dc] populating ${volumeId} with FLUX weights...`);
  await runScript('populate-volume.ts', ['--kind', 'image', '--dc', dc, '--volume-id', volumeId]);

  console.log(`[add-dc] syncing app code + venv to ${volumeId}...`);
  await runScript('sync-flux-app.ts', ['--dc', dc, '--volume-id', volumeId]);

  console.log(`[add-dc] ✓ ${dc} ready: ${volumeId}`);
  return { dc, volumeId, status: resultStatus };
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const wiredDcs = new Set(
    Object.keys(JSON.parse(process.env['NETWORK_VOLUMES_BY_DC'] ?? '{}') as Record<string, string>),
  );
  const existingVolumes = await listNetworkVolumes();

  let targetDcs: string[];
  if (EXPLICIT_DC) {
    targetDcs = [EXPLICIT_DC];
    console.log(`[add-dc] explicit mode: ${EXPLICIT_DC}`);
  } else {
    console.log('[add-dc] auto mode: scanning all RunPod DCs for 5090 stock...');
    const allDcs = await listDataCenters();
    const stocks = await Promise.all(
      allDcs.map(async (dc) => ({ dc, stock: await getGpuStock(GPU_TYPE_ID, dc) })),
    );
    targetDcs = stocks
      .filter(({ dc, stock }) => stock.stockStatus && stock.stockStatus !== 'None' && !wiredDcs.has(dc))
      .map(({ dc }) => dc);
    if (targetDcs.length === 0) {
      console.log('[add-dc] no candidate DCs found: every 5090-stocked DC is already in NETWORK_VOLUMES_BY_DC');
      return;
    }
    console.log(`[add-dc] candidates (sequential, ~15 min each): ${targetDcs.join(', ')}`);
  }

  const results: ProvisionResult[] = [];
  for (const dc of targetDcs) {
    try {
      results.push(await provisionOne(dc, existingVolumes, wiredDcs));
    } catch (e) {
      console.error(`[add-dc] ✗ ${dc} failed: ${(e as Error).message}`);
      results.push({ dc, volumeId: '', status: 'error', error: (e as Error).message });
    }
  }

  // ─── Summary + env paste fragment ───────────────────────────────────────
  console.log('\n━━━ summary ━━━');
  for (const r of results) {
    const sym = r.status === 'error' ? '✗' : r.status === 'skipped-no-stock' ? '⊘' : '✓';
    console.log(`  ${sym} ${r.dc.padEnd(12)} ${r.status}${r.volumeId ? ` ${r.volumeId}` : ''}${r.error ? ` (${r.error})` : ''}`);
  }

  const newlyProvisioned = results.filter((r) => r.status === 'created' || r.status === 'reused');
  if (newlyProvisioned.length > 0) {
    const merged: Record<string, string> = { ...(JSON.parse(process.env['NETWORK_VOLUMES_BY_DC'] ?? '{}') as Record<string, string>) };
    for (const r of newlyProvisioned) merged[r.dc] = r.volumeId;
    console.log('\n[add-dc] Add to NETWORK_VOLUMES_BY_DC in .env.local + Railway:');
    console.log(`  NETWORK_VOLUMES_BY_DC='${JSON.stringify(merged)}'`);
    console.log('\n[add-dc] then: cd backend && npm run deploy');
  }

  const errored = results.filter((r) => r.status === 'error');
  if (errored.length > 0) process.exit(1);
}

main().catch((e) => {
  console.error('[add-dc] FATAL:', e);
  process.exit(1);
});

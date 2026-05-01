/**
 * Launch a manually-managed video test pod for perf experiments.
 *
 * Why this script exists:
 *   The production orchestrator provisions video pods named `kiki-vsession-*`
 *   and reaps anything in that namespace whose `/health` returns not-ready.
 *   That makes it impossible to SSH into a production pod and try a risky
 *   experiment (different env var, scp'd code change, profiler config) — if
 *   the experiment makes the pod unresponsive for >60s, the reaper kills it.
 *
 *   This script provisions a pod with the prefix `kiki-vtest-*` instead.
 *   Everything else is identical (image, volume, env, entrypoint), but the
 *   reaper filters by name prefix, so the test pod is invisible to it. We
 *   can iterate freely: scp updated code, pkill+respawn (the dev-mode
 *   respawn loop in BOOT_DOCKER_ARGS_VIDEO does the rest), profile, repeat.
 *
 * Usage (from backend/):
 *   npm run launch-test-pod                          # default DC, no extra env
 *   npm run launch-test-pod -- --dc US-CA-2          # specific DC
 *   npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1
 *   npm run launch-test-pod -- --env LTX_TORCH_COMPILE=1 --env FOO=bar
 *
 * Cleanup:
 *   npm run terminate-test-pod -- <podId>
 *   npm run list-test-pods                           # see what's still alive
 *
 * Test pods are NOT auto-reaped. Cost during dev is negligible (CLAUDE.md),
 * so prefer leaving a pod up for the duration of an experiment session.
 * Terminate when actually done.
 *
 * Reads the same env as `sync-flux-app.ts` etc. — RUNPOD_API_KEY and the
 * NETWORK_VOLUMES_BY_DC_VIDEO map from `.env.local`.
 */

import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createOnDemandPod, getPod } from '../src/modules/orchestrator/runpodClient.js';

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

if (!process.env['RUNPOD_API_KEY']) {
  console.error('RUNPOD_API_KEY required (set in .env.local at repo root)');
  process.exit(1);
}

const VIDEO_VOLUMES: Record<string, string> = (() => {
  const raw = process.env['NETWORK_VOLUMES_BY_DC_VIDEO'];
  if (!raw) {
    console.error('NETWORK_VOLUMES_BY_DC_VIDEO required (set in .env.local at repo root)');
    process.exit(1);
  }
  try {
    return JSON.parse(raw) as Record<string, string>;
  } catch (e) {
    console.error(`NETWORK_VOLUMES_BY_DC_VIDEO is not valid JSON: ${(e as Error).message}`);
    process.exit(1);
  }
})();

const PUBLIC_KEY = (() => {
  if (process.env['PUBLIC_KEY']) return process.env['PUBLIC_KEY'];
  const sshPath = resolve(homedir(), '.ssh', 'id_ed25519.pub');
  if (existsSync(sshPath)) return readFileSync(sshPath, 'utf-8').trim();
  console.error(
    'PUBLIC_KEY env not set and ~/.ssh/id_ed25519.pub not readable. ' +
      'Test pods must have PUBLIC_KEY so the dev-mode respawn loop is active.',
  );
  process.exit(1);
})();

// ─── CLI parsing ──────────────────────────────────────────────────────────

interface Args {
  dc: string;
  envOverrides: Array<{ key: string; value: string }>;
  nameSuffix: string;
}

function parseArgs(argv: string[]): Args {
  const dcs = Object.keys(VIDEO_VOLUMES);
  // Default DC: pick the first one that's known to be reliable. US-CA-2 has
  // been most reliable in recent sync-all-dcs runs; fall back to whatever
  // is first if it's not configured.
  const defaultDc = dcs.includes('US-CA-2') ? 'US-CA-2' : dcs[0]!;
  const args: Args = {
    dc: defaultDc,
    envOverrides: [],
    nameSuffix: randomHex(6),
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--dc') {
      const v = argv[++i];
      if (!v) throw new Error('--dc requires a value');
      if (!dcs.includes(v)) {
        throw new Error(
          `--dc ${v} not in NETWORK_VOLUMES_BY_DC_VIDEO. Available: ${dcs.join(', ')}`,
        );
      }
      args.dc = v;
    } else if (a === '--env') {
      const v = argv[++i];
      if (!v || !v.includes('=')) throw new Error('--env requires KEY=VALUE');
      const eqIdx = v.indexOf('=');
      args.envOverrides.push({ key: v.slice(0, eqIdx), value: v.slice(eqIdx + 1) });
    } else if (a === '--name') {
      const v = argv[++i];
      if (!v) throw new Error('--name requires a value');
      args.nameSuffix = v;
    } else if (a === '--help' || a === '-h') {
      console.log(
        'Usage: npm run launch-test-pod -- [--dc <DC>] [--env KEY=VALUE]... [--name SUFFIX]',
      );
      console.log(`  Available DCs: ${dcs.join(', ')}`);
      console.log(`  Default DC: ${defaultDc}`);
      console.log('  Default env: BOOT_ENV defaults from orchestrator (LTX_TORCH_COMPILE=0)');
      console.log('               + PUBLIC_KEY always set (forces dev-mode respawn loop)');
      process.exit(0);
    } else {
      throw new Error(`Unknown arg: ${a}`);
    }
  }
  return args;
}

function randomHex(n: number): string {
  return Array.from({ length: n }, () =>
    Math.floor(Math.random() * 16).toString(16),
  ).join('');
}

// ─── BOOT_ENV + BOOT_DOCKER_ARGS_VIDEO duplicated from orchestrator.ts ────
// Source of truth: backend/src/modules/orchestrator/orchestrator.ts. Kept
// in sync manually because importing orchestrator.ts triggers full config
// validation (Redis, JWT secrets, etc.) which we don't have for a CLI.

const BASE_IMAGE = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';

const BASE_BOOT_ENV: Array<{ key: string; value: string }> = [
  { key: 'HF_HOME', value: '/workspace/huggingface' },
  { key: 'HF_HUB_OFFLINE', value: '1' },
  { key: 'FLUX_HOST', value: '0.0.0.0' },
  { key: 'FLUX_PORT', value: '8766' },
  { key: 'FLUX_USE_NVFP4', value: '1' },
  { key: 'PYTORCH_CUDA_ALLOC_CONF', value: 'expandable_segments:True' },
  // Test pods default to compile OFF; pass --env LTX_TORCH_COMPILE=1 to enable.
  { key: 'LTX_TORCH_COMPILE', value: '0' },
];

// SSH_BOOTSTRAP + SERVER_LAUNCH for video_server.py with PUBLIC_KEY-aware
// dev-mode respawn loop. VERBATIM from orchestrator.ts BOOT_DOCKER_ARGS_VIDEO
// (lines 224-267). Keep in lockstep — divergence here means test pods boot
// differently from production pods, which defeats the point of the test pod
// being a production-equivalent canary.
const SSH_BOOTSTRAP =
  'if [ -n "$PUBLIC_KEY" ]; then ' +
  '{ ' +
  'echo "ssh bootstrap start at $(date -u +%FT%TZ)"; ' +
  'mkdir -p /root/.ssh && ' +
  'echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys && ' +
  'chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && ' +
  'echo "wrote authorized_keys"; ' +
  'ssh-keygen -A && echo "host keys generated"; ' +
  'if service ssh start; then echo "service ssh start ok"; ' +
  'else echo "service ssh start failed; trying /usr/sbin/sshd"; /usr/sbin/sshd && echo "/usr/sbin/sshd ok"; ' +
  'fi; ' +
  'echo "ssh bootstrap done at $(date -u +%FT%TZ)"; ' +
  '} > /tmp/ssh-bootstrap.log 2>&1 || true; ' +
  'fi';

const SERVER_LAUNCH = (script: string): string =>
  'if [ -n "$PUBLIC_KEY" ]; then ' +
  `while true; do python3 -u ${script}; sleep 2; done; ` +
  'else ' +
  `exec python3 -u ${script}; ` +
  'fi';

const BOOT_DOCKER_ARGS_VIDEO =
  `bash -lc '${SSH_BOOTSTRAP}; source /workspace/venv/bin/activate && cd /workspace/app && ${SERVER_LAUNCH('video_server.py')}'`;

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const args = parseArgs(process.argv.slice(2));
  const podName = `kiki-vtest-${args.nameSuffix}`;
  const volumeId = VIDEO_VOLUMES[args.dc];
  if (!volumeId) {
    throw new Error(`No video volume configured for ${args.dc}`);
  }

  // Build env: defaults + overrides (overrides win) + PUBLIC_KEY (always
  // last, never overridden).
  const envMap = new Map<string, string>();
  for (const e of BASE_BOOT_ENV) envMap.set(e.key, e.value);
  for (const e of args.envOverrides) envMap.set(e.key, e.value);
  envMap.set('PUBLIC_KEY', PUBLIC_KEY);
  const env = Array.from(envMap.entries()).map(([key, value]) => ({ key, value }));

  console.log(`[launch-test-pod] DC=${args.dc} volume=${volumeId} name=${podName}`);
  console.log(
    `[launch-test-pod] env: ${env
      .filter((e) => e.key !== 'PUBLIC_KEY')
      .map((e) => `${e.key}=${e.value}`)
      .join(' ')} PUBLIC_KEY=<redacted>`,
  );
  console.log('[launch-test-pod] creating on-demand pod (H100 SXM 80GB)...');

  const result = await createOnDemandPod({
    name: podName,
    imageName: BASE_IMAGE,
    gpuTypeId: 'NVIDIA H100 80GB HBM3',
    cloudType: 'SECURE',
    dockerArgs: BOOT_DOCKER_ARGS_VIDEO,
    env,
    dataCenterId: args.dc,
    networkVolumeId: volumeId,
    containerRegistryAuthId: process.env['RUNPOD_REGISTRY_AUTH_ID'],
  });

  console.log(`[launch-test-pod] pod created: id=${result.id} costPerHr=$${result.costPerHr}/hr`);
  console.log('[launch-test-pod] waiting for SSH ports to be assigned...');

  // Poll until the pod has a runtime + ports populated. Initial pod creation
  // returns immediately but ports show up after the container starts (~30s).
  const deadline = Date.now() + 5 * 60 * 1000; // 5 min cap
  let lastStatus = '';
  let sshPort: number | null = null;
  let sshIp: string | null = null;
  let httpPort: number | null = null;
  let httpIp: string | null = null;
  while (Date.now() < deadline) {
    await new Promise((r) => setTimeout(r, 5000));
    const pod = await getPod(result.id);
    if (!pod) {
      console.error(`[launch-test-pod] pod ${result.id} disappeared`);
      process.exit(1);
    }
    const status = `${pod.desiredStatus} runtime=${pod.runtime ? 'yes' : 'no'}`;
    if (status !== lastStatus) {
      console.log(`[launch-test-pod] status: ${status}`);
      lastStatus = status;
    }
    if (pod.runtime && pod.runtime.ports) {
      const ssh = pod.runtime.ports.find((p) => p.privatePort === 22 && p.isIpPublic);
      const http = pod.runtime.ports.find((p) => p.privatePort === 8766 && p.isIpPublic);
      if (ssh) {
        sshPort = ssh.publicPort;
        sshIp = ssh.ip;
      }
      if (http) {
        httpPort = http.publicPort;
        httpIp = http.ip;
      }
      if (sshPort && sshIp) break;
    }
  }

  if (!sshPort || !sshIp) {
    console.error(
      `[launch-test-pod] timed out waiting for SSH port assignment after 5 min. ` +
        `Pod ${result.id} may still be starting; check the RunPod web console.`,
    );
    process.exit(1);
  }

  console.log('');
  console.log(`✅ Test pod ready: ${podName} (${result.id})`);
  console.log('');
  console.log('SSH:');
  console.log(`  ssh root@${sshIp} -p ${sshPort} -i ~/.ssh/id_ed25519`);
  console.log('');
  if (httpIp && httpPort) {
    console.log('HTTP service (video_server is loading; takes ~60–120s):');
    console.log(`  curl https://${result.id}-8766.proxy.runpod.net/health`);
    console.log(`  (or direct: curl http://${httpIp}:${httpPort}/health)`);
    console.log('');
  }
  console.log('SCP a file change to iterate fast (no full deploy needed):');
  console.log(`  scp -P ${sshPort} -i ~/.ssh/id_ed25519 \\`);
  console.log('       ../flux-klein-server/video_pipeline.py \\');
  console.log(`       root@${sshIp}:/workspace/app/`);
  console.log('  Then SSH in and: pkill -f video_server.py');
  console.log('  (bash respawn loop will restart with the new code in ~30s)');
  console.log('');
  console.log('Tail live python stdout over SSH (works through bash respawn loop):');
  console.log(
    `  ssh root@${sshIp} -p ${sshPort} -i ~/.ssh/id_ed25519 ` +
      `'tail -f /proc/$(pgrep -f video_server | head -1)/fd/1'`,
  );
  console.log('');
  console.log('Terminate when done:');
  console.log(`  npm run terminate-test-pod -- ${result.id}`);
  console.log('');
}

main().catch((err) => {
  console.error('[launch-test-pod] failed:', err);
  process.exit(1);
});

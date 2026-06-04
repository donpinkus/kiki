/**
 * One-shot script: sync Python deps + app code to a RunPod network volume.
 *
 * Part of the "no custom Docker image" architecture (see documents/decisions.md
 * entry 2026-04-23). Runtime pods launch from stock runpod/pytorch and expect
 * to find a populated /workspace/venv/ and /workspace/app/ on the attached
 * network volume. This script (run per-DC) is what puts them there.
 *
 * Usage (run from backend/):
 *   RUNPOD_API_KEY=... RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
 *     npx tsx scripts/sync-flux-app.ts --dc US-IL-1 --volume-id 59plfch67d
 *
 * Idempotent:
 *   - rsync skips unchanged files under /workspace/app/.
 *   - venv is skipped if already exists; `python3 -m venv` is a no-op when dir
 *     present (and we never want to recreate it post-facto because that would
 *     break active-pod venvs).
 *   - pip install is near-instant when all requirements already satisfied.
 *
 * On torch ABI breakage (base image Python/CUDA changes):
 *   Delete /workspace/venv/ manually (via SSH into an ephemeral pod) then
 *   re-run this script. That rebuilds the venv against the new base.
 *
 * Rollback: sync-flux-app is additive. A past revert of orchestrator code
 * simply stops using /workspace/venv/ — the dir and its contents are harmless
 * to leave on the volume.
 */

import { spawn, execSync } from 'node:child_process';
import { chmodSync, writeFileSync } from 'node:fs';
import { hostname, userInfo } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { initDeployLogging, flushDeployLogging, setLogAttribute } from './lib/deploy-sentry.js';

initDeployLogging('sync-flux-app');

// ─── CLI args ─────────────────────────────────────────────────────────────
function getArg(flag: string): string {
  const idx = process.argv.indexOf(flag);
  if (idx === -1 || idx === process.argv.length - 1) {
    console.error(`Missing required arg: ${flag}`);
    process.exit(1);
  }
  return process.argv[idx + 1]!;
}

const DC = getArg('--dc');
const VOLUME_ID = getArg('--volume-id');

// Tag every Sentry log from this process with the DC so per-DC sync activity
// is filterable in the Logs UI: `phase:deploying dc:US-TX-3`.
setLogAttribute('dc', DC);

const API_KEY = process.env['RUNPOD_API_KEY'];
const SSH_KEY = process.env['RUNPOD_SSH_PRIVATE_KEY'];
const REGISTRY_AUTH_ID = process.env['RUNPOD_REGISTRY_AUTH_ID'];
if (!API_KEY) {
  console.error('RUNPOD_API_KEY env var is required');
  process.exit(1);
}
if (!SSH_KEY) {
  console.error('RUNPOD_SSH_PRIVATE_KEY env var is required');
  process.exit(1);
}

// ─── Constants ────────────────────────────────────────────────────────────

// We don't need a GPU for pip install + rsync — we just need a pod that can
// mount the network volume. RunPod requires gpuCount ≥ 1, so we discover
// GPU types stocked in the target DC at runtime via lowestPrice probes
// (see listAvailableGpuTypesInDc) and try them cheapest-first. Set
// SYNC_GPU_TYPE_ID to pin a specific type.
//
// Why dynamic discovery: a hardcoded candidate list went stale every time
// RunPod added/removed a SKU. US-TX-3 stocks 4090/H100 SXM/L40S — none
// were in the old list, so syncs there exhausted all candidates and bailed.
// Discovery reflects whatever RunPod has stocked today.
//
// NOTE (2026-06): these skips were originally needed because RunPod's
// `startSsh:true` never opened port 22 on 4090 / Blackwell-Server-Edition hosts.
// We no longer use startSsh — the pod now starts sshd itself via SSH_BOOTSTRAP
// (see below), which we verified works on SKUs startSsh failed on. The skips are
// retained defensively (harmless) but are likely no longer necessary; can be
// removed if these SKUs prove fine under the inline bootstrap.
const SKIP_GPU_PATTERNS = ['4090', 'Blackwell Server Edition'];
const PINNED_GPU_TYPE = process.env['SYNC_GPU_TYPE_ID'];
// Must match the pinned base used by runtime pods (orchestrator.ts / runpodClient.ts).
// Base image determines torch/CUDA ABI; venv + pip installs are tied to this.
const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
const POD_NAME = `kiki-sync-${DC.toLowerCase()}-${Date.now()}`;
const SSH_KEY_PATH = '/tmp/kiki-sync-key';

// Inline SSH bootstrap — we start sshd ourselves instead of relying on RunPod's
// `startSsh: true`. As of 2026-06, startSsh is failing to open port 22 across
// mainstream SKUs (verified: H100, A100-SXM4, H200, RTX 3090, RTX PRO 4500
// Blackwell all booted to RUNNING/runtime then "sshd never came up"). The
// runtime serving pods avoid this by starting sshd in-container via this exact
// bootstrap (orchestrator BOOT_DOCKER_ARGS / src/.../podBoot.ts SSH_BOOTSTRAP),
// which works reliably on the same hosts. `$PUBLIC_KEY` is injected via the
// pod's env (the public half of RUNPOD_SSH_PRIVATE_KEY) so the bootstrap can
// authorize our key. Validated 2026-06-03 on RTX 2000 Ada in EU-RO-1.
const SSH_BOOTSTRAP =
  'if [ -n "$PUBLIC_KEY" ]; then { ' +
  'echo "ssh bootstrap start"; ' +
  'mkdir -p /root/.ssh && echo "$PUBLIC_KEY" > /root/.ssh/authorized_keys && ' +
  'chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys && echo "wrote authorized_keys"; ' +
  'ssh-keygen -A && echo "host keys generated"; ' +
  'if service ssh start; then echo "service ssh start ok"; ' +
  'else echo "service ssh start failed; trying /usr/sbin/sshd"; /usr/sbin/sshd && echo "/usr/sbin/sshd ok"; fi; ' +
  'echo "ssh bootstrap done"; ' +
  '} > /tmp/ssh-bootstrap.log 2>&1 || true; fi';
// `sleep infinity` keeps the pod alive for the rsync once sshd is up (no server
// to run here, unlike runtime pods).
const SYNC_DOCKER_ARGS = `bash -lc '${SSH_BOOTSTRAP}; sleep infinity'`;

// Public half of the sync's SSH key, injected into the pod's PUBLIC_KEY env so
// the bootstrap above can authorize our connection. Memoized; writes the private
// key to SSH_KEY_PATH first (ensureSshKey is idempotent).
let _syncPubKey: string | null = null;
function syncPodPublicKey(): string {
  if (_syncPubKey) return _syncPubKey;
  ensureSshKey();
  _syncPubKey = execSync(`ssh-keygen -y -f ${SSH_KEY_PATH}`).toString().trim();
  return _syncPubKey;
}

// Resolve model-servers/ relative to this script (backend/scripts/ → ../../model-servers).
const __dirname = dirname(fileURLToPath(import.meta.url));
const MODEL_SRC_DIR = resolve(__dirname, '..', '..', 'model-servers');

// ─── GraphQL helper ───────────────────────────────────────────────────────

async function gql<T>(query: string): Promise<T> {
  const res = await fetch(`https://api.runpod.io/graphql?api_key=${API_KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}: ${await res.text()}`);
  const body = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
  if (body.errors?.length) throw new Error(`GraphQL: ${body.errors.map((e) => e.message).join('; ')}`);
  if (!body.data) throw new Error('No data');
  return body.data;
}

// ─── Pod lifecycle ────────────────────────────────────────────────────────

interface DcGpuCandidate {
  id: string;
  price: number;       // uninterruptable USD/hr
  stock: string;       // 'High' | 'Medium' | 'Low' (Unknown / None filtered out)
}

/**
 * Probe RunPod for GPU types currently stocked in `dc`. Returns candidates
 * sorted cheapest-first. Filters out:
 *   - GPUs with stockStatus None or Unknown (no allocatable capacity).
 *   - Any GPU matching SKIP_GPU_PATTERNS (e.g. 4090 SSH bug).
 *
 * One `lowestPrice` query per known GPU type — the full `gpuTypes` listing
 * has ~30-40 entries, so this is ~30s of GraphQL latency for a 5-15 min
 * sync. Acceptable.
 */
async function listAvailableGpuTypesInDc(dc: string): Promise<DcGpuCandidate[]> {
  const allTypes = await gql<{ gpuTypes: Array<{ id: string }> }>(
    'query { gpuTypes { id } }',
  );
  const ids = allTypes.gpuTypes.map((g) => g.id);
  const candidates: DcGpuCandidate[] = [];
  // Probe in parallel — RunPod's GraphQL endpoint handles concurrent
  // queries fine and serializing makes a 30-type probe take 30+ seconds.
  const probes = await Promise.all(
    ids.map(async (gpuTypeId) => {
      if (SKIP_GPU_PATTERNS.some((p) => gpuTypeId.includes(p))) return null;
      try {
        const data = await gql<{
          gpuTypes: Array<{
            lowestPrice: {
              uninterruptablePrice: number | null;
              stockStatus: string | null;
            };
          }>;
        }>(`query {
          gpuTypes(input: { id: "${gpuTypeId}" }) {
            lowestPrice(input: { gpuCount: 1, secureCloud: true, dataCenterId: "${dc}" }) {
              uninterruptablePrice
              stockStatus
            }
          }
        }`);
        const lp = data.gpuTypes[0]?.lowestPrice;
        if (!lp) return null;
        const stock = lp.stockStatus;
        // RunPod returns null/'None' when the SKU has zero allocatable
        // capacity in this DC. Anything else (High / Medium / Low) is fair
        // game — we retry on per-pod create failure anyway.
        if (!stock || stock === 'None') return null;
        const price = lp.uninterruptablePrice;
        if (price == null) return null;
        return { id: gpuTypeId, price, stock };
      } catch {
        return null;
      }
    }),
  );
  for (const p of probes) if (p) candidates.push(p);
  candidates.sort((a, b) => a.price - b.price);
  return candidates;
}

async function createPod(): Promise<{ id: string; costPerHr: number; gpuType: string }> {
  const authField = REGISTRY_AUTH_ID
    ? `, containerRegistryAuthId: "${REGISTRY_AUTH_ID}"`
    : '';

  // Discover candidates: pinned override → DC stock probe.
  let candidates: DcGpuCandidate[];
  if (PINNED_GPU_TYPE) {
    candidates = [{ id: PINNED_GPU_TYPE, price: 0, stock: 'pinned' }];
  } else {
    console.log(`[sync] probing GPU stock in ${DC}...`);
    candidates = await listAvailableGpuTypesInDc(DC);
    if (candidates.length === 0) {
      throw new Error(
        `No allocatable GPU types reported in ${DC} (all SKUs returned stockStatus=None or Unknown). ` +
          `RunPod may be experiencing a regional capacity outage; retry later.`,
      );
    }
    const summary = candidates
      .slice(0, 6)
      .map((c) => `${c.id} ($${c.price}/hr, ${c.stock})`)
      .join(', ');
    console.log(
      `[sync] ${candidates.length} stocked SKUs in ${DC}; trying cheapest first: ${summary}${candidates.length > 6 ? `, ...` : ''}`,
    );
  }

  const failures: string[] = [];
  for (const { id: gpuType } of candidates) {
    const query = `mutation {
      podFindAndDeployOnDemand(input: {
        name: "${POD_NAME}",
        imageName: "${IMAGE_NAME}",
        gpuTypeId: "${gpuType}",
        gpuCount: 1,
        cloudType: SECURE,
        volumeInGb: 0,
        containerDiskInGb: 40,
        minMemoryInGb: 16,
        minVcpuCount: 4,
        ports: "22/tcp",
        dataCenterId: "${DC}",
        networkVolumeId: "${VOLUME_ID}",
        volumeMountPath: "/workspace",
        env: [{ key: "PUBLIC_KEY", value: ${JSON.stringify(syncPodPublicKey())} }],
        dockerArgs: ${JSON.stringify(SYNC_DOCKER_ARGS)}${authField}
      }) { id desiredStatus costPerHr }
    }`;
    try {
      const data = await gql<{ podFindAndDeployOnDemand: { id: string; costPerHr: number } | null }>(query);
      if (data.podFindAndDeployOnDemand) {
        return { ...data.podFindAndDeployOnDemand, gpuType };
      }
      failures.push(`${gpuType}: no capacity`);
      console.log(`[sync] ${gpuType} unavailable in ${DC}, trying next...`);
    } catch (e) {
      const msg = (e as Error).message;
      failures.push(`${gpuType}: ${msg}`);
      console.log(`[sync] ${gpuType} create failed (${msg}), trying next...`);
    }
  }
  throw new Error(
    `Failed to create sync pod in ${DC} — tried ${candidates.length} stocked GPU types:\n  ${failures.join('\n  ')}`,
  );
}

interface PodRuntime {
  id: string;
  desiredStatus: string;
  runtime: {
    ports: Array<{ ip: string; privatePort: number; publicPort: number; type: string }>;
  } | null;
}

async function getPod(podId: string): Promise<PodRuntime | null> {
  const query = `query {
    pod(input: { podId: "${podId}" }) {
      id desiredStatus
      runtime { ports { ip privatePort publicPort type } }
    }
  }`;
  const data = await gql<{ pod: PodRuntime | null }>(query);
  return data.pod;
}

async function terminatePod(podId: string): Promise<void> {
  await gql(`mutation { podTerminate(input: { podId: "${podId}" }) }`);
}

// ─── SSH helpers ──────────────────────────────────────────────────────────

function ensureSshKey(): void {
  writeFileSync(SSH_KEY_PATH, SSH_KEY!.endsWith('\n') ? SSH_KEY! : SSH_KEY! + '\n');
  chmodSync(SSH_KEY_PATH, 0o600);
}

interface SshInfo {
  ip: string;
  port: number;
}

async function waitForSsh(podId: string, timeoutMs = 15 * 60 * 1000): Promise<SshInfo> {
  const deadline = Date.now() + timeoutMs;
  let lastStatus = '';
  while (Date.now() < deadline) {
    const pod = await getPod(podId);
    const status = `${pod?.desiredStatus ?? '?'}/${pod?.runtime ? 'runtime' : 'no-runtime'}`;
    if (status !== lastStatus) {
      const elapsed = Math.round((Date.now() - (deadline - timeoutMs)) / 1000);
      console.log(`[sync] pod status after ${elapsed}s: ${status}`);
      lastStatus = status;
    }
    const ssh = pod?.runtime?.ports?.find((p) => p.privatePort === 22);
    if (ssh?.ip) return { ip: ssh.ip, port: ssh.publicPort };
    // Fail-fast on terminated/exited pods. Without this, an externally-
    // killed broken-SSH pod (4090/Blackwell-Server-Edition style) would
    // burn the full 15-min timeout — the runtime stays null forever.
    if (pod === null || pod?.desiredStatus === 'EXITED' || pod?.desiredStatus === 'TERMINATED') {
      throw new Error(`Pod ${podId} ${pod?.desiredStatus ?? 'gone'} before SSH came up`);
    }
    await new Promise((r) => setTimeout(r, 10_000));
  }
  throw new Error(`Pod ${podId} never got SSH info within ${Math.round(timeoutMs / 1000)}s`);
}

function runSsh(ssh: SshInfo, cmd: string, timeoutMs = 30 * 60 * 1000): Promise<void> {
  const args = [
    '-i', SSH_KEY_PATH,
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ServerAliveInterval=30',
    '-p', String(ssh.port),
    `root@${ssh.ip}`,
    cmd,
  ];
  return new Promise((resolvePromise, reject) => {
    const proc = spawn('ssh', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    const t = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`SSH command timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    proc.on('exit', (code) => {
      clearTimeout(t);
      if (code === 0) resolvePromise();
      else reject(new Error(`SSH exited with ${code}`));
    });
  });
}

async function retrySsh(ssh: SshInfo, tries = 20): Promise<void> {
  for (let i = 0; i < tries; i++) {
    try {
      await runSsh(ssh, 'echo ok', 10_000);
      return;
    } catch {
      if (i === tries - 1) throw new Error('sshd never came up');
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

function runRsync(ssh: SshInfo, localPath: string, remotePath: string, timeoutMs = 5 * 60 * 1000): Promise<void> {
  // -rlptDvz instead of -avz: preserve perms/times/devices but NOT owner/group.
  // RunPod NFS volumes deny chown → `-a` always fails with exit 23 even though
  // file contents transfer successfully.
  //
  // --exclude list: only ship what the runtime pod needs. Dockerfile and the
  // dev/ test clients live in model-servers/ for dev use but don't belong on
  // the volume.
  //
  // --delete keeps remote exactly in sync with local — on a source rename or
  // deletion, the stale file goes away rather than lingering on the volume.
  const sshCmd = `ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${ssh.port}`;
  const args = [
    '-rlptDvz',
    '--delete',
    '--exclude', 'Dockerfile',
    '--exclude', 'dev',
    '--exclude', '*.pyc',
    '--exclude', '__pycache__',
    '-e', sshCmd,
    `${localPath}/`,
    `root@${ssh.ip}:${remotePath}`,
  ];
  return new Promise((resolvePromise, reject) => {
    const proc = spawn('rsync', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    const t = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`rsync timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    proc.on('exit', (code) => {
      clearTimeout(t);
      if (code === 0) resolvePromise();
      else reject(new Error(`rsync exited with ${code}`));
    });
  });
}

// ─── Version stamp ────────────────────────────────────────────────────────

/**
 * Build the .version.json payload that gets written to /workspace/app/ on
 * each sync. Pipeline reads this at boot and surfaces it on /health, so
 * PostHog records per-DC version skew on every cold start. See
 * `documents/references/provider-config.md` "Volume version tracking".
 *
 * `flux_app_version` is the git tree-hash of `model-servers/`. It only
 * changes when files in that subtree change — committing CLAUDE.md, iOS
 * code, or backend code does NOT bump it. This is the field the drift
 * check compares against. `git_sha` is retained as forensic context only.
 */
function buildVersionStamp(): Record<string, string | boolean> {
  const REPO_ROOT = resolve(__dirname, '..', '..');
  let gitSha = 'unknown';
  let gitDirty = false;
  let fluxAppVersion = 'unknown';
  try {
    gitSha = execSync('git rev-parse HEAD', { cwd: REPO_ROOT }).toString().trim();
    const dirty = execSync('git status --porcelain', { cwd: REPO_ROOT }).toString().trim();
    gitDirty = dirty.length > 0;
    // Tree-hash of the model-servers/ subtree at HEAD. Reflects committed
    // state only — uncommitted edits don't change this. Pair with git_dirty
    // to spot deploys-with-uncommitted-changes (where two volumes could
    // share a version but actually differ).
    fluxAppVersion = execSync('git rev-parse HEAD:model-servers', { cwd: REPO_ROOT }).toString().trim();
  } catch (e) {
    console.warn('[sync] git lookup failed; version stamp will be partial:', (e as Error).message);
  }
  return {
    flux_app_version: fluxAppVersion,
    git_sha: gitSha,
    git_dirty: gitDirty,
    synced_at_utc: new Date().toISOString(),
    synced_by: `${userInfo().username}@${hostname()}`,
    dc: DC,
    volume_id: VOLUME_ID,
  };
}

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log(`[sync] DC=${DC} volume=${VOLUME_ID}`);
  console.log(`[sync] source dir: ${MODEL_SRC_DIR}`);
  ensureSshKey();

  console.log(`[sync] creating on-demand pod in ${DC}...`);
  // Ride out transient regional capacity outages — RunPod's stockStatus
  // for entire DCs can flicker to None for a few minutes during stock churn,
  // and a parallel deploy across 10 DCs is much more likely to hit one
  // than a single-DC sync. Retry every 30s up to MAX_ATTEMPTS rather than
  // failing the whole deploy and forcing a manual re-run.
  const MAX_ATTEMPTS = 12; // 12 × 30s = 6 min cap; longer outages need manual attention
  let attempt = 0;
  let podCreate: { id: string; costPerHr: number; gpuType: string } | null = null;
  while (true) {
    attempt += 1;
    try {
      podCreate = await createPod();
      break;
    } catch (e) {
      const msg = (e as Error).message;
      if (attempt >= MAX_ATTEMPTS) {
        console.error(
          `[sync] createPod failed after ${attempt} attempts in ${DC}; giving up. Last error: ${msg}`,
        );
        throw e;
      }
      console.warn(
        `[sync] createPod attempt ${attempt}/${MAX_ATTEMPTS} failed in ${DC} (${msg}); retrying in 30s...`,
      );
      await new Promise((r) => setTimeout(r, 30_000));
    }
  }
  const { id: podId, costPerHr, gpuType } = podCreate;
  console.log(
    `[sync] pod ${podId} created on ${gpuType} ($${costPerHr}/hr)${attempt > 1 ? ` after ${attempt} attempts` : ''}`,
  );

  try {
    console.log('[sync] waiting for SSH...');
    const ssh = await waitForSsh(podId);
    console.log(`[sync] SSH ready at ${ssh.ip}:${ssh.port}`);

    console.log('[sync] waiting for sshd to accept connections...');
    await retrySsh(ssh);

    // 1. Prep /workspace/app/ and rsync source files
    console.log('[sync] creating /workspace/app ...');
    await runSsh(ssh, 'mkdir -p /workspace/app');

    console.log('[sync] rsyncing model-servers sources -> /workspace/app/ ...');
    // Only copy what the runtime pod needs: the image/, video/, shared/ packages + requirements.txt.
    // Not test_client.py, not Dockerfile, not *.jpg, etc.
    await runRsync(
      ssh,
      `${MODEL_SRC_DIR}`,
      '/workspace/app',
      5 * 60 * 1000,
    );

    // 2. Create venv if needed, then pip install
    // --system-site-packages is CRITICAL. Without it, pip will pull torch 2.11.0
    // + nvidia-cu13 wheels into the venv, shadowing base image torch 2.9.1+cu128
    // and breaking CUDA at runtime. The smoke test below asserts torch stays 2.9.1.
    const installCmd = `set -e
export PIP_BREAK_SYSTEM_PACKAGES=1

echo "=== ENV ==="
python3 --version
nvidia-smi -L | head -2

echo "=== VENV (create if missing) ==="
if [ ! -d /workspace/venv ]; then
  echo "creating venv at /workspace/venv..."
  python3 -m venv --system-site-packages /workspace/venv
else
  echo "venv already exists, skipping create"
fi

echo "=== PIP INSTALL ==="
source /workspace/venv/bin/activate
which python3
which pip
pip install --no-cache-dir -r /workspace/app/requirements.txt

echo "=== POST-INSTALL STATE ==="
du -sh /workspace/venv
python3 -c "import torch; print('torch:', torch.__version__, torch.__file__)"
python3 -c "import diffusers; print('diffusers:', diffusers.__version__, diffusers.__file__)"

echo "=== SMOKE TEST ==="
# Asserts (1) base-image torch is still active (venv didn't accidentally install
# a conflicting torch), and (2) all runtime imports resolve (image + video pods).
python3 - <<'PYEOF'
import sys
import torch
assert torch.__version__.startswith('2.9.1'), f'torch version drift: {torch.__version__} (expected 2.9.1+cu128)'
assert '/usr/local/lib/python3.12/dist-packages' in torch.__file__, f'torch path drift: {torch.__file__}'
assert torch.cuda.is_available(), 'CUDA not available'
# Runtime imports — any ImportError here means the sync is broken for prod use.
from diffusers import Flux2KleinPipeline  # noqa: F401
from diffusers import LTXImageToVideoPipeline, LTXVideoTransformer3DModel  # noqa: F401
import transformers, accelerate, safetensors, huggingface_hub, PIL, fastapi, uvicorn, websockets, sentencepiece  # noqa: F401
import imageio_ffmpeg  # noqa: F401  -- video pod MP4 encoder
# Ensure the bundled ffmpeg binary is actually present (imageio-ffmpeg lazy-
# downloads it on first call to get_ffmpeg_exe; do that here so first video
# request doesn't pay that cost on a cold pod).
ff = imageio_ffmpeg.get_ffmpeg_exe()
import os; assert os.path.exists(ff), f'ffmpeg missing: {ff}'
print('smoke OK; ffmpeg at', ff)
PYEOF

echo "=== DONE ==="
`;

    console.log('[sync] creating venv + pip installing (takes 5-15 min first time, <30s idempotent reruns)...');
    // 30-min budget covers a fresh ltx-core + ltx-pipelines install on a
    // slow DC (heavy deps: torch, diffusers, transformers, av, openimageio).
    // Idempotent reruns finish under a minute. Previous 20-min budget hit
    // mid-install on a fresh DC (US-MO-1, 2026-04-27).
    await runSsh(ssh, installCmd, 30 * 60 * 1000);

    // 3. Write version stamp AFTER all other steps succeed — its presence
    //    is the signal that this volume is fully provisioned at this version.
    //    A pod that boots and sees no .version.json knows something interrupted.
    const stamp = buildVersionStamp();
    const stampJson = JSON.stringify(stamp, null, 2).replace(/'/g, "'\\''");
    console.log(`[sync] stamping version (flux_app=${stamp['flux_app_version'].toString().slice(0, 8)} git=${stamp['git_sha'].toString().slice(0, 8)}${stamp['git_dirty'] ? '+dirty' : ''})...`);
    await runSsh(ssh, `cat > /workspace/app/.version.json <<'VEREOF'
${stampJson}
VEREOF`);

    console.log('[sync] sync complete');
  } finally {
    console.log(`[sync] terminating pod ${podId}...`);
    await terminatePod(podId).catch((e) => console.error('[sync] terminate failed:', e));
  }

  console.log(`[sync] done. Volume ${VOLUME_ID} ready to serve runtime pods in ${DC}.`);
}

main()
  .then(async () => {
    await flushDeployLogging();
  })
  .catch(async (e) => {
    console.error('[sync] FAILED:', e);
    await flushDeployLogging();
    process.exit(1);
  });

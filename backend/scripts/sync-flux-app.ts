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

import { spawn } from 'node:child_process';
import { chmodSync, writeFileSync } from 'node:fs';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

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
// mount the network volume. RunPod requires gpuCount ≥ 1, so we try an
// ordered list of cheap GPUs (cheapest first) and use whichever one has
// capacity in the target DC. Set SYNC_GPU_TYPE_ID to pin a specific type.
// 4090 deliberately omitted: hosts in EUR-NO-1 + US-IL-1 boot the
// container but `startSsh:true` never opens port 22 (verified across 3
// retries, 2026-04-27). The cheaper tiers above + 5090 fallback are
// proven to work. 5090 last so we don't pay the premium when a cheap
// host is available.
const DEFAULT_GPU_CANDIDATES = [
  'NVIDIA RTX 2000 Ada Generation',
  'NVIDIA RTX A4000',
  'NVIDIA GeForce RTX 3090',
  'NVIDIA L4',
  'NVIDIA GeForce RTX 5090',
];
const GPU_CANDIDATES = process.env['SYNC_GPU_TYPE_ID']
  ? [process.env['SYNC_GPU_TYPE_ID']!]
  : DEFAULT_GPU_CANDIDATES;
// Must match the pinned base used by runtime pods (orchestrator.ts / runpodClient.ts).
// Base image determines torch/CUDA ABI; venv + pip installs are tied to this.
const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
const POD_NAME = `kiki-sync-${DC.toLowerCase()}-${Date.now()}`;
const SSH_KEY_PATH = '/tmp/kiki-sync-key';

// Resolve flux-klein-server/ relative to this script (backend/scripts/ → ../../flux-klein-server).
const __dirname = dirname(fileURLToPath(import.meta.url));
const FLUX_SRC_DIR = resolve(__dirname, '..', '..', 'flux-klein-server');

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

async function createPod(): Promise<{ id: string; costPerHr: number; gpuType: string }> {
  const authField = REGISTRY_AUTH_ID
    ? `, containerRegistryAuthId: "${REGISTRY_AUTH_ID}"`
    : '';
  const failures: string[] = [];
  for (const gpuType of GPU_CANDIDATES) {
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
        startSsh: true,
        dataCenterId: "${DC}",
        networkVolumeId: "${VOLUME_ID}",
        volumeMountPath: "/workspace"${authField}
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
    `Failed to create sync pod in ${DC} — exhausted ${GPU_CANDIDATES.length} GPU types:\n  ${failures.join('\n  ')}`,
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
  // --exclude list: only ship what the runtime pod needs. Dockerfile/test_client
  // /output.jpg live in flux-klein-server/ for dev use but don't belong on the
  // volume.
  //
  // --delete keeps remote exactly in sync with local — on a source rename or
  // deletion, the stale file goes away rather than lingering on the volume.
  const sshCmd = `ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p ${ssh.port}`;
  const args = [
    '-rlptDvz',
    '--delete',
    '--exclude', 'Dockerfile',
    '--exclude', 'test_client.py',
    '--exclude', 'output.jpg',
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

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log(`[sync] DC=${DC} volume=${VOLUME_ID}`);
  console.log(`[sync] source dir: ${FLUX_SRC_DIR}`);
  ensureSshKey();

  console.log(`[sync] creating on-demand pod in ${DC}...`);
  const { id: podId, costPerHr, gpuType } = await createPod();
  console.log(`[sync] pod ${podId} created on ${gpuType} ($${costPerHr}/hr)`);

  try {
    console.log('[sync] waiting for SSH...');
    const ssh = await waitForSsh(podId);
    console.log(`[sync] SSH ready at ${ssh.ip}:${ssh.port}`);

    console.log('[sync] waiting for sshd to accept connections...');
    await retrySsh(ssh);

    // 1. Prep /workspace/app/ and rsync source files
    console.log('[sync] creating /workspace/app ...');
    await runSsh(ssh, 'mkdir -p /workspace/app');

    console.log('[sync] rsyncing flux-klein-server sources -> /workspace/app/ ...');
    // Only copy the files the runtime pod needs. server.py/pipeline.py/config.py/requirements.txt.
    // Not test_client.py, not Dockerfile, not *.jpg, etc.
    await runRsync(
      ssh,
      `${FLUX_SRC_DIR}`,
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

    console.log('[sync] creating venv + pip installing (takes 2-5 min first time, <30s idempotent reruns)...');
    await runSsh(ssh, installCmd, 20 * 60 * 1000);
    console.log('[sync] sync complete');
  } finally {
    console.log(`[sync] terminating pod ${podId}...`);
    await terminatePod(podId).catch((e) => console.error('[sync] terminate failed:', e));
  }

  console.log(`[sync] done. Volume ${VOLUME_ID} ready to serve runtime pods in ${DC}.`);
}

main().catch((e) => {
  console.error('[sync] FAILED:', e);
  process.exit(1);
});

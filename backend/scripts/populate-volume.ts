/**
 * One-shot script: populate a RunPod network volume with FLUX.2-klein weights.
 *
 * Spawns an on-demand 5090 pod in the volume's DC, mounts the volume at
 * /workspace, downloads FLUX.2-klein BF16 + NVFP4 weights into
 * /workspace/huggingface, terminates the pod.
 *
 * Usage (run from backend/):
 *   RUNPOD_API_KEY=... RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
 *     tsx scripts/populate-volume.ts --dc EUR-NO-1 --volume-id 49n6i3twuw
 *
 * Idempotent — re-running against an already-populated volume just re-checks
 * sizes and exits quickly (huggingface_hub snapshot_download no-ops on cache hit).
 */

import { spawn } from 'node:child_process';
import { chmodSync, writeFileSync } from 'node:fs';

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
// Optional but strongly recommended: without it the runpod/pytorch Docker Hub
// pull is anonymous and can take 10+ min on a fresh host (rate limits shared
// across RunPod customers on the same egress IP).
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

const GPU_TYPE_ID = 'NVIDIA GeForce RTX 5090';
const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
const POD_NAME = `kiki-populate-${DC.toLowerCase()}-${Date.now()}`;
const SSH_KEY_PATH = '/tmp/kiki-populate-key';

const FLUX_REPO = 'black-forest-labs/FLUX.2-klein-4B';
const NVFP4_REPO = 'black-forest-labs/FLUX.2-klein-4b-nvfp4';
const NVFP4_FILENAME = 'flux-2-klein-4b-nvfp4.safetensors';

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

async function createPod(): Promise<{ id: string; costPerHr: number }> {
  const authField = REGISTRY_AUTH_ID
    ? `, containerRegistryAuthId: "${REGISTRY_AUTH_ID}"`
    : '';
  // On-demand (not spot) — we don't want a preemption mid-download.
  const query = `mutation {
    podFindAndDeployOnDemand(input: {
      name: "${POD_NAME}",
      imageName: "${IMAGE_NAME}",
      gpuTypeId: "${GPU_TYPE_ID}",
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
  const data = await gql<{ podFindAndDeployOnDemand: { id: string; costPerHr: number } | null }>(query);
  if (!data.podFindAndDeployOnDemand) {
    throw new Error(`Failed to create populate pod in ${DC} — capacity?`);
  }
  return data.podFindAndDeployOnDemand;
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
      console.log(`[populate] pod status after ${elapsed}s: ${status}`);
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
  return new Promise((resolve, reject) => {
    const proc = spawn('ssh', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    const t = setTimeout(() => {
      proc.kill('SIGKILL');
      reject(new Error(`SSH command timeout after ${timeoutMs}ms`));
    }, timeoutMs);
    proc.on('exit', (code) => {
      clearTimeout(t);
      if (code === 0) resolve();
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

// ─── Main ─────────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  console.log(`[populate] DC=${DC} volume=${VOLUME_ID}`);
  ensureSshKey();

  console.log(`[populate] creating on-demand 5090 pod in ${DC}...`);
  const { id: podId, costPerHr } = await createPod();
  console.log(`[populate] pod ${podId} created ($${costPerHr}/hr)`);

  try {
    console.log('[populate] waiting for SSH...');
    const ssh = await waitForSsh(podId);
    console.log(`[populate] SSH ready at ${ssh.ip}:${ssh.port}`);

    console.log('[populate] waiting for sshd to accept connections...');
    await retrySsh(ssh);

    // Populate script — downloads FLUX.2-klein BF16 weights + NVFP4 weights
    // into /workspace/huggingface (i.e. the mounted network volume).
    //
    // allow_patterns trims the BF16 repo to just what Flux2KleinPipeline uses
    // — without it we'd pull ~40 GB of alt transformer variants (fp8, bnb).
    // Ubuntu 24.04 (PEP 668) blocks system-wide pip unless --break-system-packages.
    // We're on a throwaway pod so that's fine.
    const populateCmd = `set -e
export HF_HOME=/workspace/huggingface
export HF_HUB_DISABLE_TELEMETRY=1
mkdir -p "$HF_HOME"

echo "=== Disk before ==="
df -h /workspace

echo "=== Ensuring huggingface_hub is installed ==="
python3 -c "import huggingface_hub; print('already installed:', huggingface_hub.__version__)" 2>/dev/null || \
  pip install --no-cache-dir --break-system-packages huggingface-hub

echo "=== Downloading ${FLUX_REPO} (BF16 base, ~13 GB) ==="
python3 -c "
from huggingface_hub import snapshot_download
p = snapshot_download(
    '${FLUX_REPO}',
    allow_patterns=['*.json','*.safetensors','*.txt','tokenizer*/*','text_encoder*/*','transformer/*','vae/*','scheduler/*','model_index.json'],
)
print('base weights at', p)
"

echo "=== Downloading ${NVFP4_REPO}/${NVFP4_FILENAME} (~7 GB) ==="
python3 -c "
from huggingface_hub import hf_hub_download
p = hf_hub_download('${NVFP4_REPO}', '${NVFP4_FILENAME}')
print('nvfp4 weights at', p)
"

echo "=== Disk after ==="
df -h /workspace

echo "=== Layout ==="
ls -la /workspace/huggingface/hub | head -20
du -sh /workspace/huggingface
`;

    console.log('[populate] running download commands (this takes 5-15 min)...');
    await runSsh(ssh, populateCmd, 45 * 60 * 1000);
    console.log('[populate] populate complete');
  } finally {
    console.log(`[populate] terminating pod ${podId}...`);
    await terminatePod(podId).catch((e) => console.error('[populate] terminate failed:', e));
  }

  console.log(`[populate] done. Volume ${VOLUME_ID} ready to use in ${DC}.`);
}

main().catch((e) => {
  console.error('[populate] FAILED:', e);
  process.exit(1);
});

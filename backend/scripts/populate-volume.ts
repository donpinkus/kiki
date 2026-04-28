/**
 * One-shot script: populate a RunPod network volume with model weights.
 *
 * Two kinds of volumes:
 *   --kind image  : FLUX.2-klein BF16 + NVFP4 (~20 GB), for image pods on 5090s
 *   --kind video  : LTX-2.3 22B distilled FP8 + Gemma-3-12B + spatial upscaler
 *                   (~52 GB), for video pods on H100 SXM
 *
 * Spawns an on-demand pod in the volume's DC, mounts the volume at
 * /workspace, downloads weights into /workspace/huggingface, terminates pod.
 *
 * Usage (run from backend/):
 *   # Image volume (5090 DCs)
 *   RUNPOD_API_KEY=... RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
 *     tsx scripts/populate-volume.ts --kind image --dc EUR-NO-1 --volume-id 49n6i3twuw
 *
 *   # Video volume (H100 SXM DCs) — Gemma is gated by Google ToS, requires HF_TOKEN
 *   # with Gemma access pre-accepted at huggingface.co/google/gemma-3-12b-it-qat-q4_0-unquantized
 *   RUNPOD_API_KEY=... HF_TOKEN=... RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
 *     tsx scripts/populate-volume.ts --kind video --dc EU-FR-1 --volume-id <id>
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
const KIND = getArg('--kind');
if (KIND !== 'image' && KIND !== 'video') {
  console.error(`--kind must be 'image' or 'video' (got '${KIND}')`);
  process.exit(1);
}

const API_KEY = process.env['RUNPOD_API_KEY'];
const SSH_KEY = process.env['RUNPOD_SSH_PRIVATE_KEY'];
// Optional but strongly recommended: without it the runpod/pytorch Docker Hub
// pull is anonymous and can take 10+ min on a fresh host (rate limits shared
// across RunPod customers on the same egress IP).
const REGISTRY_AUTH_ID = process.env['RUNPOD_REGISTRY_AUTH_ID'];
// Required for video kind only: Gemma is gated by Google's Gemma ToS. Token
// must have accepted the license terms on huggingface.co.
const HF_TOKEN = process.env['HF_TOKEN'] ?? process.env['HUGGING_FACE_HUB_TOKEN'];
if (!API_KEY) {
  console.error('RUNPOD_API_KEY env var is required');
  process.exit(1);
}
if (!SSH_KEY) {
  console.error('RUNPOD_SSH_PRIVATE_KEY env var is required');
  process.exit(1);
}
if (KIND === 'video' && !HF_TOKEN) {
  console.error(
    'HF_TOKEN env var is required for --kind video (Gemma-3-12B is gated by Google ToS).\n' +
    'Accept terms at https://huggingface.co/google/gemma-3-12b-it-qat-q4_0-unquantized\n' +
    'then export HF_TOKEN=hf_...',
  );
  process.exit(1);
}

// ─── Constants ────────────────────────────────────────────────────────────

// Image volumes live in 5090 DCs; video volumes live in H100 SXM DCs.
// Volume is DC-locked, so the populate pod must be in the same DC as the
// volume. We pick the GPU type that's actually available there.
const GPU_TYPE_ID = KIND === 'image' ? 'NVIDIA GeForce RTX 5090' : 'NVIDIA H100 80GB HBM3';
const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
const POD_NAME = `kiki-populate-${KIND}-${DC.toLowerCase()}-${Date.now()}`;
const SSH_KEY_PATH = '/tmp/kiki-populate-key';

// Image-pod weights.
const FLUX_REPO = 'black-forest-labs/FLUX.2-klein-4B';
const NVFP4_REPO = 'black-forest-labs/FLUX.2-klein-4b-nvfp4';
const NVFP4_FILENAME = 'flux-2-klein-4b-nvfp4.safetensors';

// Video-pod weights (LTX-2.3, Gemma encoder, spatial upscaler).
// Must match config.LTX_* in flux-klein-server/config.py.
const LTX_MODEL_REPO = 'Lightricks/LTX-2.3-fp8';
const LTX_MODEL_FILE = 'ltx-2.3-22b-distilled-fp8.safetensors';
const LTX_SPATIAL_UPSCALER_REPO = 'Lightricks/LTX-2.3';
const LTX_SPATIAL_UPSCALER_FILE = 'ltx-2.3-spatial-upscaler-x2-1.1.safetensors';
const LTX_TEXT_ENCODER_REPO = 'google/gemma-3-12b-it-qat-q4_0-unquantized';

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
  console.log(`[populate] kind=${KIND} DC=${DC} volume=${VOLUME_ID} gpu=${GPU_TYPE_ID}`);
  ensureSshKey();

  console.log(`[populate] creating on-demand pod in ${DC}...`);
  const { id: podId, costPerHr } = await createPod();
  console.log(`[populate] pod ${podId} created ($${costPerHr}/hr)`);

  try {
    console.log('[populate] waiting for SSH...');
    const ssh = await waitForSsh(podId);
    console.log(`[populate] SSH ready at ${ssh.ip}:${ssh.port}`);

    console.log('[populate] waiting for sshd to accept connections...');
    await retrySsh(ssh);

    const populateCmd = KIND === 'image' ? buildImagePopulateCmd() : buildVideoPopulateCmd();

    console.log('[populate] running download commands (this takes 5-15 min)...');
    await runSsh(ssh, populateCmd, 60 * 60 * 1000);
    console.log('[populate] populate complete');
  } finally {
    console.log(`[populate] terminating pod ${podId}...`);
    await terminatePod(podId).catch((e) => console.error('[populate] terminate failed:', e));
  }

  console.log(`[populate] done. Volume ${VOLUME_ID} ready to use in ${DC} (kind=${KIND}).`);
}

// ─── Per-kind populate scripts ────────────────────────────────────────────

function buildImagePopulateCmd(): string {
  // Downloads FLUX.2-klein BF16 weights + NVFP4 weights into
  // /workspace/huggingface (the mounted network volume).
  //
  // allow_patterns trims the BF16 repo to just what Flux2KleinPipeline uses
  // — without it we'd pull ~40 GB of alt transformer variants (fp8, bnb).
  // Ubuntu 24.04 (PEP 668) blocks system-wide pip unless --break-system-packages.
  // We're on a throwaway pod so that's fine.
  return `set -e
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
}

function buildVideoPopulateCmd(): string {
  // Downloads LTX-2.3 22B distilled FP8 + Gemma-3-12B + spatial upscaler.
  // HF_TOKEN must be set with Gemma access accepted on huggingface.co.
  // We pass it via env on the SSH'd shell so the pod can authenticate to HF.
  return `set -e
export HF_HOME=/workspace/huggingface
export HF_HUB_DISABLE_TELEMETRY=1
export HF_TOKEN=${HF_TOKEN}
export HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}
mkdir -p "$HF_HOME"

echo "=== Disk before ==="
df -h /workspace

echo "=== Ensuring huggingface_hub is installed ==="
python3 -c "import huggingface_hub; print('already installed:', huggingface_hub.__version__)" 2>/dev/null || \
  pip install --no-cache-dir --break-system-packages huggingface-hub

echo "=== Downloading ${LTX_MODEL_REPO}/${LTX_MODEL_FILE} (~27.5 GB) ==="
python3 -c "
from huggingface_hub import hf_hub_download
p = hf_hub_download('${LTX_MODEL_REPO}', '${LTX_MODEL_FILE}')
print('ltx-2.3 transformer at', p)
"

echo "=== Downloading ${LTX_SPATIAL_UPSCALER_REPO}/${LTX_SPATIAL_UPSCALER_FILE} (~1 GB) ==="
python3 -c "
from huggingface_hub import hf_hub_download
p = hf_hub_download('${LTX_SPATIAL_UPSCALER_REPO}', '${LTX_SPATIAL_UPSCALER_FILE}')
print('spatial upscaler at', p)
"

echo "=== Downloading ${LTX_TEXT_ENCODER_REPO} (Gemma encoder, ~24 GB, gated) ==="
python3 -c "
from huggingface_hub import snapshot_download
p = snapshot_download('${LTX_TEXT_ENCODER_REPO}')
print('gemma encoder at', p)
"

echo "=== Disk after ==="
df -h /workspace
echo "=== Layout ==="
ls -la /workspace/huggingface/hub | head -20
du -sh /workspace/huggingface
`;
}

main().catch((e) => {
  console.error('[populate] FAILED:', e);
  process.exit(1);
});

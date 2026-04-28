/**
 * One-shot: run video_pipeline.Ltx23VideoPipeline().load() on a pod that
 * mounts a video volume, capture the output (esp. the traceback if
 * load() crashes). Used to diagnose the LTX-2.3 pod crashloop without
 * relying on Railway-side reroll-loop logs.
 *
 * Reuses populate-volume.ts's pod-create + SSH machinery (proven to SSH
 * cleanly during the migration's volume populates). Tries cheap GPUs
 * first, falls through to H100 SXM if necessary.
 *
 * Usage:
 *   RUNPOD_API_KEY=... RUNPOD_SSH_PRIVATE_KEY="$(cat ~/.ssh/id_ed25519)" \
 *     tsx scripts/debug-video-load.ts --dc US-NE-1 --volume-id 92a53hbwc1
 */

import { spawn } from 'node:child_process';
import { chmodSync, writeFileSync } from 'node:fs';

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
const API_KEY = process.env['RUNPOD_API_KEY']!;
const SSH_KEY = process.env['RUNPOD_SSH_PRIVATE_KEY']!;
const REGISTRY_AUTH_ID = process.env['RUNPOD_REGISTRY_AUTH_ID'];
if (!API_KEY || !SSH_KEY) {
  console.error('RUNPOD_API_KEY + RUNPOD_SSH_PRIVATE_KEY required');
  process.exit(1);
}

// Cheaper GPUs first — we don't need compute, just a pod that mounts the
// volume and lets us SSH in.
const GPU_CANDIDATES = [
  'NVIDIA RTX 2000 Ada Generation',
  'NVIDIA RTX 4000 Ada Generation',
  'NVIDIA RTX A4000',
  'NVIDIA GeForce RTX 3090',
  'NVIDIA L4',
  'NVIDIA GeForce RTX 5090',
  'NVIDIA H100 80GB HBM3',
];

const IMAGE_NAME = 'runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404';
const SSH_KEY_PATH = '/tmp/kiki-debug-key';

async function gql<T>(query: string): Promise<T> {
  const res = await fetch(`https://api.runpod.io/graphql?api_key=${API_KEY}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ query }),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
  const body = (await res.json()) as { data?: T; errors?: Array<{ message: string }> };
  if (body.errors?.length) throw new Error(`GraphQL: ${body.errors.map((e) => e.message).join('; ')}`);
  return body.data!;
}

async function createPod(): Promise<{ id: string; gpu: string }> {
  const errs: string[] = [];
  for (const gpu of GPU_CANDIDATES) {
    const authField = REGISTRY_AUTH_ID ? `, containerRegistryAuthId: "${REGISTRY_AUTH_ID}"` : '';
    const podName = `kiki-dbgload-${DC.toLowerCase()}-${Date.now()}`;
    const query = `mutation {
      podFindAndDeployOnDemand(input: {
        name: "${podName}",
        imageName: "${IMAGE_NAME}",
        gpuTypeId: "${gpu}",
        gpuCount: 1,
        cloudType: SECURE,
        volumeInGb: 0,
        containerDiskInGb: 40,
        minMemoryInGb: 8,
        minVcpuCount: 4,
        ports: "22/tcp",
        startSsh: true,
        dataCenterId: "${DC}",
        networkVolumeId: "${VOLUME_ID}",
        volumeMountPath: "/workspace",
        dockerArgs: ${JSON.stringify("bash -lc 'sleep infinity'")}${authField}
      }) { id }
    }`;
    try {
      const data = await gql<{ podFindAndDeployOnDemand: { id: string } | null }>(query);
      if (data.podFindAndDeployOnDemand) {
        console.log(`[debug] pod ${data.podFindAndDeployOnDemand.id} created on ${gpu}`);
        return { id: data.podFindAndDeployOnDemand.id, gpu };
      }
    } catch (e) {
      errs.push(`${gpu}: ${(e as Error).message.slice(0, 80)}`);
    }
  }
  throw new Error(`exhausted ${GPU_CANDIDATES.length} GPUs in ${DC}:\n  ${errs.join('\n  ')}`);
}

interface SshInfo { ip: string; port: number }

async function waitForSsh(podId: string, timeoutMs = 12 * 60 * 1000): Promise<SshInfo> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const data = await gql<{ pod: { runtime: { ports: Array<{ ip: string; privatePort: number; publicPort: number }> } | null } }>(
      `query { pod(input: { podId: "${podId}" }) { runtime { ports { ip privatePort publicPort } } } }`,
    );
    const ports = data.pod?.runtime?.ports ?? [];
    const ssh = ports.find((p) => p.privatePort === 22);
    if (ssh?.ip) return { ip: ssh.ip, port: ssh.publicPort };
    await new Promise((r) => setTimeout(r, 8000));
  }
  throw new Error(`pod ${podId} never got SSH info within ${timeoutMs / 1000}s`);
}

function runSsh(ssh: SshInfo, cmd: string, timeoutMs = 5 * 60 * 1000): Promise<{ exitCode: number }> {
  const args = [
    '-i', SSH_KEY_PATH,
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ServerAliveInterval=30',
    '-o', 'ConnectTimeout=10',
    '-p', String(ssh.port),
    `root@${ssh.ip}`,
    cmd,
  ];
  return new Promise((resolve) => {
    const proc = spawn('ssh', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    const t = setTimeout(() => proc.kill('SIGKILL'), timeoutMs);
    proc.on('exit', (code) => {
      clearTimeout(t);
      resolve({ exitCode: code ?? -1 });
    });
  });
}

async function retrySsh(ssh: SshInfo, tries = 30): Promise<void> {
  for (let i = 0; i < tries; i++) {
    const r = await runSsh(ssh, 'true', 8000);
    if (r.exitCode === 0) return;
    await new Promise((r) => setTimeout(r, 5000));
  }
  throw new Error('sshd never came up after 30 tries');
}

async function terminatePod(podId: string): Promise<void> {
  await gql(`mutation { podTerminate(input: { podId: "${podId}" }) }`);
}

async function main(): Promise<void> {
  writeFileSync(SSH_KEY_PATH, SSH_KEY!.endsWith('\n') ? SSH_KEY! : SSH_KEY! + '\n');
  chmodSync(SSH_KEY_PATH, 0o600);

  const { id: podId, gpu } = await createPod();
  try {
    console.log('[debug] waiting for SSH info...');
    const ssh = await waitForSsh(podId);
    console.log(`[debug] SSH at ${ssh.ip}:${ssh.port}, waiting for sshd...`);
    await retrySsh(ssh);
    console.log('[debug] sshd up; running pipeline load...');

    const cmd = `set -e
cd /workspace/app
source /workspace/venv/bin/activate
export HF_HOME=/workspace/huggingface HF_HUB_OFFLINE=1
echo "=== ENV ==="
python3 -c "import sys; print('python', sys.version); import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"
echo "=== CACHE LAYOUT ==="
ls -la /workspace/huggingface/hub/ | head -10
echo "=== Gemma files ==="
find /workspace/huggingface/hub/models--google--gemma* -type f -not -name "*.safetensors" | head
echo "=== TEST IMPORTS ==="
python3 -c "
import sys
try:
    print('importing ltx_core...')
    import ltx_core
    print('  ltx_core OK')
    print('importing ltx_pipelines...')
    import ltx_pipelines
    print('  ltx_pipelines OK')
    print('importing DistilledPipeline...')
    from ltx_pipelines.distilled import DistilledPipeline
    print('  DistilledPipeline OK')
    print('importing video_pipeline...')
    from video_pipeline import Ltx23VideoPipeline
    print('  Ltx23VideoPipeline OK')
except Exception as e:
    import traceback; traceback.print_exc()
    sys.exit(1)
"
echo "=== TEST LOAD ==="
python3 -u -c "
import sys, traceback
try:
    from video_pipeline import Ltx23VideoPipeline
    p = Ltx23VideoPipeline()
    print('calling load()...')
    p.load()
    print('LOAD SUCCEEDED')
except Exception as e:
    print('LOAD FAILED:', type(e).__name__, e)
    traceback.print_exc()
    sys.exit(1)
"
`;
    const { exitCode } = await runSsh(ssh, cmd, 12 * 60 * 1000);
    console.log(`[debug] command exited with ${exitCode}`);
  } finally {
    console.log(`[debug] terminating pod ${podId}...`);
    await terminatePod(podId).catch((e) => console.error('[debug] terminate failed:', e));
  }
}

main().catch((e) => {
  console.error('[debug] FAILED:', e);
  process.exit(1);
});

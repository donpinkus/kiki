/**
 * One-time Lambda Cloud region setup for the kiki image server.
 *
 * What it does (idempotent — safe to re-run):
 *   1. Registers your SSH public key with Lambda (if not already).
 *   2. Opens inbound TCP 8766 in the account-global firewall (if not already).
 *   3. Creates a persistent filesystem `kiki-image-<region>` (if not already).
 *   4. Launches a setup instance with the filesystem attached and populates it:
 *        /kiki/app/           — model-servers code (image/, shared/, requirements.txt)
 *        /kiki/venv/          — self-contained python venv (torch cu128 + requirements)
 *        /kiki/huggingface/   — FLUX.2-klein-4B BF16 weights (~13 GB; NO NVFP4 —
 *                               H100 is Hopper, no FP4; server falls back to BF16)
 *        /kiki/boot.sh        — entrypoint invoked by cloud-init on serving instances
 *   5. Terminates the setup instance (unless --keep).
 *
 * The filesystem is multi-attach: one populated filesystem per region serves any
 * number of concurrently launched instances.
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/setup-lambda.ts --region us-east-1 --type gpu_1x_h100_pcie
 *   tsx scripts/lambda/setup-lambda.ts --region us-east-1 --type gpu_1x_h100_pcie --keep
 *
 * Run scripts/lambda/capacity.ts first to see which regions have H100 capacity.
 * Requires in .env.local: LAMBDA_API_KEY + HF_TOKEN (FLUX.2-klein-9b-kv — the
 * production serving model — is license-gated; base 4B is not).
 */

import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { launchWithRetry, requireClient, sleep, REPO_ROOT, type Instance } from './lambdaApi.js';

const SSH_KEY_PATH = resolve(homedir(), '.ssh', 'id_ed25519');
const SSH_KEY_NAME = 'kiki-donald';
const KIKI_PORT = 8766;
const FLUX_REPO = 'black-forest-labs/FLUX.2-klein-4B';
// Pin the OS image: regions differ in their DEFAULT image (us-southeast-1
// defaulted to 24.04/py3.12, us-east-1 to 22.04/py3.10 — the py3.10 resolve
// failed on our requirements, 2026-07-15). The venv must be built with the
// same python major.minor that serving instances boot with.
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const EXPECTED_PY = '3.12';
// Pin torch 2.9.1+cu128 — the version the pipeline was validated on (originally
// to match the RunPod-era base image; keep pinned so behavior stays comparable
// across environments). Lambda Stack images ship a recent driver; cu128 wheels
// need driver >= 525 (CUDA 12 minor-version compat).
const TORCH_SPEC = 'torch==2.9.1 torchvision --index-url https://download.pytorch.org/whl/cu128';

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

const REGION = getArg('--region');
const TYPE = getArg('--type') ?? 'gpu_1x_h100_pcie';
const KEEP = process.argv.includes('--keep');
if (!REGION) {
  console.error('Usage: tsx scripts/lambda/setup-lambda.ts --region <region> [--type gpu_1x_h100_pcie] [--keep]');
  process.exit(1);
}
const FS_NAME = getArg('--fs') ?? `kiki-image-${REGION}`;
const FS_ROOT = `/lambda/nfs/${FS_NAME}`;
// Keep retrying the launch on insufficient-capacity for this many minutes.
const RETRY_MINS = Number(getArg('--retry-mins') ?? '0');

const client = requireClient();

// ── ssh helpers (same idiom as scripts/populate-volume.ts) ─────────────────
function runSsh(ip: string, cmd: string, timeoutMs = 60 * 60 * 1000): Promise<void> {
  const args = [
    '-i', SSH_KEY_PATH,
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    '-o', 'ConnectTimeout=10',
    `ubuntu@${ip}`,
    cmd,
  ];
  return new Promise((res, rej) => {
    const proc = spawn('ssh', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    const t = setTimeout(() => { proc.kill(); rej(new Error(`ssh timed out after ${timeoutMs}ms`)); }, timeoutMs);
    proc.on('exit', (code) => {
      clearTimeout(t);
      code === 0 ? res() : rej(new Error(`ssh exited ${code}`));
    });
  });
}

function runScp(ip: string, localFile: string, remotePath: string): Promise<void> {
  const args = [
    '-i', SSH_KEY_PATH,
    '-o', 'StrictHostKeyChecking=no',
    '-o', 'UserKnownHostsFile=/dev/null',
    localFile,
    `ubuntu@${ip}:${remotePath}`,
  ];
  return new Promise((res, rej) => {
    const proc = spawn('scp', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    proc.on('exit', (code) => (code === 0 ? res() : rej(new Error(`scp exited ${code}`))));
  });
}

function runRsync(ip: string, localPath: string, remotePath: string): Promise<void> {
  const sshCmd = `ssh -i ${SSH_KEY_PATH} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null`;
  const args = [
    '-az', '--delete',
    '--exclude', '__pycache__', '--exclude', '*.pyc', '--exclude', 'dev/',
    '-e', sshCmd,
    `${localPath}/`,
    `ubuntu@${ip}:${remotePath}/`,
  ];
  return new Promise((res, rej) => {
    const proc = spawn('rsync', args, { stdio: ['ignore', 'inherit', 'inherit'] });
    proc.on('exit', (code) => (code === 0 ? res() : rej(new Error(`rsync exited ${code}`))));
  });
}

async function waitForStatus(id: string, want: Instance['status'], timeoutMs: number): Promise<Instance> {
  const start = Date.now();
  for (;;) {
    const inst = await client.getInstance(id);
    if (inst.status === want) return inst;
    if (['terminated', 'unhealthy', 'preempted'].includes(inst.status)) {
      throw new Error(`instance ${id} entered status=${inst.status} while waiting for ${want}`);
    }
    if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${want} (last=${inst.status})`);
    await sleep(5000);
  }
}

async function waitForSsh(ip: string, timeoutMs = 5 * 60 * 1000): Promise<void> {
  const start = Date.now();
  for (;;) {
    try {
      await runSsh(ip, 'echo ssh-ok', 20_000);
      return;
    } catch {
      if (Date.now() - start > timeoutMs) throw new Error('timed out waiting for SSH');
      await sleep(5000);
    }
  }
}

// boot.sh — written onto the filesystem; serving instances invoke it via
// cloud-init (see coldstart-bench.ts). Per-instance secrets (KIKI_WS_TOKEN)
// arrive via /etc/kiki.env written by cloud-init, not baked here.
const BOOT_SH = `#!/usr/bin/env bash
# Kiki image server boot — invoked by cloud-init on Lambda serving instances.
# Lives on the shared filesystem so it can be iterated without relaunching.
set -euo pipefail
FS=${FS_ROOT}
[ -f /etc/kiki.env ] && set -a && source /etc/kiki.env && set +a
export FLUX_USE_NVFP4=0            # H100 is Hopper (SM 9.0) — no FP4; BF16 path
export FLUX_COMPILE=1              # torch.compile: 1.2-1.25x, ~85s at boot (hidden in warmup)
export FLUX_PIPELINE=kv            # 9B-KV: per-call reference K/V caching (adherence-best)
export FLUX_MODEL=black-forest-labs/FLUX.2-klein-9b-kv
# Persist compiled-kernel caches on the shared filesystem so only the FIRST
# boot per (model, torch, GPU) pays full compilation; later boots reuse.
export TORCHINDUCTOR_CACHE_DIR=$FS/kiki/inductor-cache
export TRITON_CACHE_DIR=$FS/kiki/triton-cache
mkdir -p "$TORCHINDUCTOR_CACHE_DIR" "$TRITON_CACHE_DIR"
export HF_HOME=$FS/kiki/huggingface
export HF_HUB_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export FLUX_HOST=0.0.0.0
export FLUX_PORT=${KIKI_PORT}
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# TLS: serve wss when the fleet cert is present on the filesystem (backend
# pins it via LAMBDA_TLS_CA_B64). Absent → plain ws (dev filesystems).
if [ -f $FS/kiki/tls/cert.pem ]; then
  export FLUX_SSL_CERT=$FS/kiki/tls/cert.pem
  export FLUX_SSL_KEY=$FS/kiki/tls/key.pem
fi
echo "[kiki-boot] $(date -u +%FT%TZ) sourcing venv"
source $FS/kiki/venv/bin/activate
cd $FS/kiki/app
echo "[kiki-boot] $(date -u +%FT%TZ) starting image.server"
exec python3 -u -m image.server
`;

const HF_TOKEN = process.env['HF_TOKEN'] ?? '';

const POPULATE_CMD = `set -euo pipefail
export HF_TOKEN='${HF_TOKEN}'
FS=${FS_ROOT}
if [ ! -d "$FS" ]; then echo "filesystem not mounted at $FS"; ls /lambda/nfs/; exit 1; fi
mkdir -p $FS/kiki
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true

echo "=== venv (self-contained; NOT system-site-packages — Lambda Stack's system torch version drifts) ==="
# A venv built by a different python major.minor (e.g. a 22.04 image's 3.10)
# is unusable on 24.04 instances — detect and rebuild.
if [ -x $FS/kiki/venv/bin/python3 ]; then
  VENV_PY=$($FS/kiki/venv/bin/python3 -c 'import sys; print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo broken)
  if [ "$VENV_PY" != "${EXPECTED_PY}" ]; then
    echo "existing venv is python $VENV_PY, expected ${EXPECTED_PY} — rebuilding"
    rm -rf $FS/kiki/venv
  fi
fi
if [ ! -x $FS/kiki/venv/bin/python3 ]; then
  python3 -m venv $FS/kiki/venv
fi
source $FS/kiki/venv/bin/activate
pip install --upgrade pip -q
python3 -c "import torch; print('torch already:', torch.__version__)" 2>/dev/null || \\
  pip install --no-cache-dir ${TORCH_SPEC}
pip install --no-cache-dir -r $FS/kiki/app/requirements.txt

echo "=== torch sanity on GPU ==="
python3 - <<'EOF'
import torch
print('torch', torch.__version__, 'cuda', torch.version.cuda, 'available', torch.cuda.is_available())
print('device', torch.cuda.get_device_name(0), 'capability', torch.cuda.get_device_capability(0))
EOF

echo "=== FLUX.2-klein-4B BF16 weights (~13 GB; skipping NVFP4 — Hopper has no FP4) ==="
export HF_HOME=$FS/kiki/huggingface
export HF_HUB_DISABLE_TELEMETRY=1
python3 -c "
from huggingface_hub import snapshot_download
p = snapshot_download(
    '${FLUX_REPO}',
    allow_patterns=['*.json','*.safetensors','*.txt','tokenizer*/*','text_encoder*/*','transformer/*','vae/*','scheduler/*','model_index.json'],
)
print('base weights at', p)
"

echo "=== FLUX.2-klein-9b-kv weights (~33 GB, GATED — the PRODUCTION serving model) ==="
# boot.sh runs FLUX_MODEL=black-forest-labs/FLUX.2-klein-9b-kv; without these
# weights a serving instance dies at load. HF_TOKEN's account must have
# accepted the license (Donald's whatsdonisdon has, 2026-07-17).
python3 -c "
import os
from huggingface_hub import snapshot_download
p = snapshot_download(
    'black-forest-labs/FLUX.2-klein-9b-kv',
    token=os.environ.get('HF_TOKEN') or None,
    allow_patterns=['*.json','*.safetensors','*.txt','tokenizer*/*','text_encoder*/*','transformer/*','vae/*','scheduler/*','model_index.json'],
)
print('9b-kv weights at', p)
"

echo "=== boot.sh ==="
chmod +x $FS/kiki/boot.sh
echo "=== sizes ==="
du -sh $FS/kiki/venv $FS/kiki/huggingface $FS/kiki/app

echo "=== smoke test: load pipeline + one warmup inference on THIS instance ==="
cd $FS/kiki/app
FLUX_USE_NVFP4=0 HF_HOME=$FS/kiki/huggingface HF_HUB_OFFLINE=1 python3 - <<'EOF'
import time
t0 = time.time()
from image.pipeline import FluxKleinPipeline
p = FluxKleinPipeline()
p.load()
print('pipeline load+warmup took %.1fs' % (time.time() - t0))
print(p.get_info())
EOF
echo "=== populate done ==="
`;

// ── main ────────────────────────────────────────────────────────────────────
console.log(`[setup] region=${REGION} type=${TYPE} fs=${FS_NAME}`);

// 1. SSH key
const pubKey = readFileSync(`${SSH_KEY_PATH}.pub`, 'utf-8').trim();
const keys = await client.listSshKeys();
if (!keys.some((k) => k.public_key.trim().split(' ').slice(0, 2).join(' ') === pubKey.split(' ').slice(0, 2).join(' '))) {
  await client.addSshKey(SSH_KEY_NAME, pubKey);
  console.log(`[setup] registered SSH key '${SSH_KEY_NAME}'`);
} else {
  console.log('[setup] SSH key already registered');
}
const keyName = (await client.listSshKeys()).find(
  (k) => k.public_key.trim().split(' ').slice(0, 2).join(' ') === pubKey.split(' ').slice(0, 2).join(' '),
)!.name;

// 2. Firewall (note: rules don't apply in us-south-1 per Lambda docs — avoid it)
await client.ensureInboundTcpPort(KIKI_PORT, 'kiki image server WS');
console.log(`[setup] firewall: inbound tcp/${KIKI_PORT} open account-wide`);

// 3. Filesystem
const filesystems = await client.listFilesystems();
if (!filesystems.some((f) => f.name === FS_NAME && f.region.name === REGION)) {
  await client.createFilesystem(FS_NAME, REGION);
  console.log(`[setup] created filesystem ${FS_NAME} in ${REGION}`);
} else {
  console.log(`[setup] filesystem ${FS_NAME} already exists`);
}

// 4. Setup instance
console.log('[setup] launching setup instance (billing starts when it passes health checks)...');
const t0 = Date.now();
const [instanceId] = await launchWithRetry(
  client,
  {
    region_name: REGION,
    instance_type_name: TYPE,
    ssh_key_names: [keyName],
    file_system_names: [FS_NAME],
    name: `kiki-setup-${Date.now()}`,
    image: { family: OS_IMAGE_FAMILY },
  },
  RETRY_MINS,
);
console.log(`[setup] instance ${instanceId} launched; waiting for active...`);
const inst = await waitForStatus(instanceId!, 'active', 30 * 60 * 1000);
console.log(`[setup] active after ${((Date.now() - t0) / 1000).toFixed(0)}s — ip=${inst.ip}`);

try {
  await waitForSsh(inst.ip!);
  console.log('[setup] SSH up; rsyncing model-servers → filesystem...');
  await runSsh(inst.ip!, `mkdir -p ${FS_ROOT}/kiki/app`);
  await runRsync(inst.ip!, resolve(REPO_ROOT, 'model-servers'), `${FS_ROOT}/kiki/app`);
  // Write boot.sh via stdin-safe heredoc (avoid quoting hell in one ssh arg)
  await runSsh(inst.ip!, `cat > ${FS_ROOT}/kiki/boot.sh <<'KIKI_BOOT_EOF'\n${BOOT_SH}KIKI_BOOT_EOF`);
  // Fleet TLS cert → this region's filesystem (backend pins it via
  // LAMBDA_TLS_CA_B64; boot.sh serves wss iff the cert exists).
  {
    const tlsDir = resolve(homedir(), '.kiki', 'lambda-tls');
    if (existsSync(resolve(tlsDir, 'cert.pem')) && existsSync(resolve(tlsDir, 'key.pem'))) {
      console.log('[setup] copying fleet TLS cert from ~/.kiki/lambda-tls...');
      await runSsh(inst.ip!, `mkdir -p ${FS_ROOT}/kiki/tls`);
      await runScp(inst.ip!, resolve(tlsDir, 'cert.pem'), `${FS_ROOT}/kiki/tls/cert.pem`);
      await runScp(inst.ip!, resolve(tlsDir, 'key.pem'), `${FS_ROOT}/kiki/tls/key.pem`);
      await runSsh(inst.ip!, `chmod 600 ${FS_ROOT}/kiki/tls/key.pem`);
    } else {
      console.log('[setup] no ~/.kiki/lambda-tls cert — instances will serve plain ws:// (dev only)');
    }
  }
  console.log('[setup] populating venv + weights (~10-25 min on first run)...');
  await runSsh(inst.ip!, POPULATE_CMD);
  console.log('[setup] populate complete.');
} finally {
  if (KEEP) {
    console.log(`[setup] --keep: instance ${instanceId} left running (ssh ubuntu@${inst.ip}) — BILLING until terminated`);
  } else {
    console.log(`[setup] terminating setup instance ${instanceId}...`);
    await client.terminate([instanceId!]);
  }
}

console.log(`\n[setup] Done. Next: tsx scripts/lambda/coldstart-bench.ts --region ${REGION} --type ${TYPE}`);

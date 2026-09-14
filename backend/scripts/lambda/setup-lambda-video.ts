/**
 * One-time Lambda Cloud region setup for the kiki VIDEO server (LTX-2.5).
 *
 * The video path runs on its OWN filesystem + instances (`kiki-video-*`),
 * separate from the image pool: LTX-2.5 22B FP8 + Gemma 4 12B hold ~48 GiB
 * resident, which cannot share an 80 GB H100 with the 9B-KV image server
 * (~37 GB) — and a dedicated GPU guarantees video work never contends with
 * the latency-sensitive image path.
 *
 * What it does (idempotent — safe to re-run):
 *   1. Registers your SSH public key with Lambda (if not already).
 *   2. Opens inbound TCP 8766 in the account-global firewall (if not already).
 *   3. Creates a persistent filesystem `kiki-video-<region>` (if not already).
 *   4. Launches a setup instance with the filesystem attached and populates it:
 *        /kiki/app/           — model-servers code (video/, shared/, requirements)
 *        /kiki/venv/          — python venv (torch cu128 + requirements-video.txt)
 *        /kiki/huggingface/   — LTX-2.5 split components: 22B distilled
 *                               transformer (39 GB) + bundled Gemma 4 text
 *                               encoder (24 GB) + video/audio VAEs + spatial
 *                               upscaler + DFR detailing IC-LoRA (~66 GB).
 *                               The 2.3 assets are left in place (rollback).
 *        /kiki/tls/           — fleet TLS cert (copied from ~/.kiki/lambda-tls
 *                               when present locally — same cert as the image
 *                               fleet, so LAMBDA_TLS_CA_B64 pins both)
 *        /kiki/boot.sh        — entrypoint invoked by cloud-init on serving
 *                               instances (scripts/lambda/launch-video.ts)
 *   5. Smoke test: loads the pipeline + one warmup inference on-instance
 *      (skippable with --skip-smoke; ~5-10 min including model load).
 *   6. Terminates the setup instance (unless --keep).
 *
 * Usage (from backend/):
 *   tsx scripts/lambda/setup-lambda-video.ts --region us-south-2 [--type gpu_1x_h100_sxm5] [--keep] [--skip-smoke] [--retry-mins 30]
 *
 * Requires in .env.local:
 *   LAMBDA_API_KEY — cloud.lambda.ai/api-keys
 *   HF_TOKEN       — HuggingFace token whose account has clicked through the
 *                    LTX-2.x Community License on BOTH auto-gated repos
 *                    (Lightricks/LTX-2.5 and the IC-LoRA repo). The Gemma 4
 *                    text encoder is bundled in the LTX repo — no Google
 *                    gate any more.
 *
 * License note: LTX-2.x weights are under the LTX-2.x Community License (NOT
 * Apache-2.0; restricts commercial use >= $10M revenue). Verify before any
 * App Store rollout.
 */

import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { resolve } from 'node:path';
import { launchSetupWithFilesystem, loadEnvLocal, requireClient, sleep, REPO_ROOT, type Instance } from './lambdaApi.js';

const SSH_KEY_PATH = resolve(homedir(), '.ssh', 'id_ed25519');
const SSH_KEY_NAME = 'kiki-donald';
const KIKI_PORT = 8766;
// Pin the OS image (regions differ in their default; the venv must be built
// with the same python major.minor that serving instances boot with).
const OS_IMAGE_FAMILY = 'lambda-stack-24-04';
const EXPECTED_PY = '3.12';
// Same torch pin as the image path so behavior is comparable across servers.
// torchaudio is pinned here because ltx-core depends on it: left to the
// default index, pip grabs a cu13-built torchaudio next to our cu128 torch
// → libcudart.so.13 missing at import (hit live 2026-07-18).
const TORCH_SPEC = 'torch==2.9.1 torchvision torchaudio==2.9.1 --index-url https://download.pytorch.org/whl/cu128';
// Weight repos/files — must match model-servers/shared/config.py defaults.
// LTX-2.5 is one file per component; download only what the two pipelines
// (distilled + DFR) need. Both video VAEs are fetched so LTX_VIDEO_VAE can be
// flipped without a re-populate.
const LTX_MODEL_REPO = 'Lightricks/LTX-2.5';
const LTX_FILES = [
  'diffusion_models/ltx-2.5-22b-distilled-transformer-bf16.safetensors',
  'text_encoders/gemma4-12b-with-proj-ltx-2.5-bf16.safetensors',
  'vae/ltx-2.5-video-vae-bf16.safetensors',
  'vae/ltx-2.5-video-vae-conv-bf16.safetensors',
  'vae/ltx-2.5-audio-vae-bf16.safetensors',
  'latent_upscale_models/ltx-2.5-latent-spatial-upscaler-x2-bf16-1.0.safetensors',
];
const LTX_LORA_REPO = 'Lightricks/LTX-2.5-22b-IC-LoRA-Pixel-Spatial-Upscaler';
const LTX_LORA_FILE = 'ltx-2.5-22b-ic-lora-pixel-spatial-upscaler-x2-1.0.safetensors';
const LOCAL_TLS_DIR = resolve(homedir(), '.kiki', 'lambda-tls');

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx !== -1 ? process.argv[idx + 1] : undefined;
}

const REGION = getArg('--region');
// SXM by default: LTX 22B FP8 + Gemma ≈ 46 GiB resident + activations wants
// the 80 GB card; PCIe H100 also works but capacity has been SXM-only lately.
const TYPE = getArg('--type') ?? 'gpu_1x_h100_sxm5';
const KEEP = process.argv.includes('--keep');
const SKIP_SMOKE = process.argv.includes('--skip-smoke');
if (!REGION) {
  console.error(
    'Usage: tsx scripts/lambda/setup-lambda-video.ts --region <region> [--type gpu_1x_h100_sxm5] [--keep] [--skip-smoke] [--retry-mins 30]',
  );
  process.exit(1);
}
const FS_NAME = getArg('--fs') ?? `kiki-video-${REGION}`;
const FS_ROOT = `/lambda/nfs/${FS_NAME}`;
const RETRY_MINS = Number(getArg('--retry-mins') ?? '0');

const client = requireClient();
loadEnvLocal();
const HF_TOKEN = process.env['HF_TOKEN'] ?? '';
if (!HF_TOKEN) {
  console.error(
    'HF_TOKEN is required in .env.local (Lightricks/LTX-2.5 + the IC-LoRA repo are\n' +
      "auto-gated — accept the LTX-2.x Community License on huggingface.co with the token's account).",
  );
  process.exit(1);
}

// ── ssh helpers (same idiom as setup-lambda.ts) ─────────────────────────────
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
// cloud-init (see launch-video.ts). Per-instance secrets (KIKI_WS_TOKEN)
// arrive via /etc/kiki.env written by cloud-init, not baked here.
// Legacy entrypoint kept for the manual scripts (launch-video.ts,
// coldstart-bench.ts, validate-boot.mts) that still invoke $FS/kiki/boot.sh.
// The real boot script now lives in the repo (model-servers/video/boot.sh)
// and reaches the filesystem through the backend's fleet bundle; pool
// instances run the backend-written kiki-bootstrap instead (instancePool.userData).
const BOOT_SH = `#!/usr/bin/env bash
exec bash "$(dirname "${BASH_SOURCE[0]}")/app/video/boot.sh"
`;

const POPULATE_CMD = `set -euo pipefail
FS=${FS_ROOT}
if [ ! -d "$FS" ]; then echo "filesystem not mounted at $FS"; ls /lambda/nfs/; exit 1; fi
mkdir -p $FS/kiki
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader || true

echo "=== venv (self-contained; NOT system-site-packages — Lambda Stack's system torch version drifts) ==="
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
pip install --no-cache-dir -r $FS/kiki/app/requirements-video.txt
# The ltx packages are direct git URLs; pip treats an already-installed
# "ltx-core 1.x" as satisfied even when the pinned SHA moved. Force the
# pinned commit in (no-deps: the resolved deps above already match).
pip install --no-cache-dir --force-reinstall --no-deps \\
  $(grep -E '^ltx-(core|pipelines) @' $FS/kiki/app/requirements-video.txt | sed 's/ //g' | tr '\\n' ' ')
python3 -c "import ltx_pipelines.dfr_pipeline, ltx_pipelines.distilled; import transformers; print('ltx ok, transformers', transformers.__version__)"
# torchaudio arrives as an ltx-core dependency and the default index serves a
# cu13-linked wheel next to our cu128 torch (libcudart.so.13 missing at
# import — hit live 2026-07-18). Verify by IMPORT (a bad wheel can share the
# version string) and force the cu128 build if broken.
python3 -c "import torchaudio" 2>/dev/null || \
  pip install --no-cache-dir --force-reinstall --no-deps 'torchaudio==2.9.1' --index-url https://download.pytorch.org/whl/cu128

echo "=== torch sanity on GPU ==="
python3 - <<'EOF'
import torch
print('torch', torch.__version__, 'cuda', torch.version.cuda, 'available', torch.cuda.is_available())
print('device', torch.cuda.get_device_name(0), 'capability', torch.cuda.get_device_capability(0))
EOF

echo "=== LTX-2.5 split components (~66 GB incl. bundled Gemma 4) + DFR IC-LoRA ==="
# (the file list is interpolated with single quotes — this python runs inside a
# double-quoted bash string, so JSON double quotes would be eaten by bash)
export HF_HOME=$FS/kiki/huggingface
export HF_HUB_DISABLE_TELEMETRY=1
export HF_TOKEN='${HF_TOKEN}'
python3 -c "
from huggingface_hub import hf_hub_download
for f in ${JSON.stringify(LTX_FILES).replace(/"/g, "'")}:
    p = hf_hub_download('${LTX_MODEL_REPO}', f)
    print('ltx component at', p)
p = hf_hub_download('${LTX_LORA_REPO}', '${LTX_LORA_FILE}')
print('detailing ic-lora at', p)
"

echo "=== boot.sh ==="
chmod +x $FS/kiki/boot.sh
echo "=== sizes ==="
du -sh $FS/kiki/venv $FS/kiki/huggingface $FS/kiki/app
`;

// Smoke test runs the FULL serving path once on the setup instance: pipeline
// load (persistent transformer + Gemma) + one warmup inference at the config
// defaults (512x512x145). Validates weights, venv, and VRAM fit end-to-end
// before any serving instance launches. ~5-10 min.
const SMOKE_CMD = `set -euo pipefail
FS=${FS_ROOT}
source $FS/kiki/venv/bin/activate
cd $FS/kiki/app
echo "=== smoke test: LTX-2.5 pipeline load + warmup inference (~5-10 min) ==="
HF_HOME=$FS/kiki/huggingface HF_HUB_OFFLINE=1 LTX_FP8_MODE=cast \\
PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True python3 - <<'EOF'
import time
t0 = time.time()
from video.pipeline import Ltx25VideoPipeline
p = Ltx25VideoPipeline()
p.load()
print('pipeline load+warmup took %.1fs' % (time.time() - t0))
info = p.get_info()
print({k: info[k] for k in ('video_ready', 'model_file', 'gpu', 'vram_free_gb', 'load_ms')})
EOF
echo "=== smoke test done ==="
`;

// ── main ────────────────────────────────────────────────────────────────────
console.log(`[setup-video] region=${REGION} type=${TYPE} fs=${FS_NAME}`);

// 1. SSH key
const pubKey = readFileSync(`${SSH_KEY_PATH}.pub`, 'utf-8').trim();
const keys = await client.listSshKeys();
if (!keys.some((k) => k.public_key.trim().split(' ').slice(0, 2).join(' ') === pubKey.split(' ').slice(0, 2).join(' '))) {
  await client.addSshKey(SSH_KEY_NAME, pubKey);
  console.log(`[setup-video] registered SSH key '${SSH_KEY_NAME}'`);
} else {
  console.log('[setup-video] SSH key already registered');
}
const keyName = (await client.listSshKeys()).find(
  (k) => k.public_key.trim().split(' ').slice(0, 2).join(' ') === pubKey.split(' ').slice(0, 2).join(' '),
)!.name;

// 2. Firewall (same port as the image fleet; likely already open)
await client.ensureInboundTcpPort(KIKI_PORT, 'kiki image/video server WS');
console.log(`[setup-video] firewall: inbound tcp/${KIKI_PORT} open account-wide`);

// 3 + 4. Filesystem + setup instance, together: the filesystem is created
// only when the cell advertises capacity and deleted again on a miss, so an
// empty kiki-video-<region> never sits unattached where the pool sweep would
// boot into it (see launchSetupWithFilesystem).
console.log('[setup-video] launching setup instance (billing starts when it passes health checks)...');
const t0 = Date.now();
const [instanceId] = await launchSetupWithFilesystem(client, {
  region: REGION,
  type: TYPE,
  fsName: FS_NAME,
  // NOT `kiki-video-setup-…`: the video pool adopts by the `kiki-video-`
  // name prefix on backend deploy, and must never grab a setup instance.
  name: `kiki-vidsetup-${Date.now()}`,
  keyName,
  imageFamily: OS_IMAGE_FAMILY,
  retryMins: RETRY_MINS,
});
console.log(`[setup-video] instance ${instanceId} launched; waiting for active...`);
const inst = await waitForStatus(instanceId!, 'active', 30 * 60 * 1000);
console.log(`[setup-video] active after ${((Date.now() - t0) / 1000).toFixed(0)}s — ip=${inst.ip}`);

try {
  await waitForSsh(inst.ip!);
  console.log('[setup-video] SSH up; rsyncing model-servers → filesystem...');
  await runSsh(inst.ip!, `mkdir -p ${FS_ROOT}/kiki/app`);
  await runRsync(inst.ip!, resolve(REPO_ROOT, 'model-servers'), `${FS_ROOT}/kiki/app`);
  // Write boot.sh via stdin-safe heredoc (avoid quoting hell in one ssh arg)
  await runSsh(inst.ip!, `cat > ${FS_ROOT}/kiki/boot.sh <<'KIKI_BOOT_EOF'\n${BOOT_SH}KIKI_BOOT_EOF`);
  // Fleet TLS cert: reuse the image fleet's shared self-signed cert so the
  // backend's existing LAMBDA_TLS_CA_B64 pin covers video too. Local copy
  // lives at ~/.kiki/lambda-tls (key otherwise only on the filesystems).
  if (existsSync(resolve(LOCAL_TLS_DIR, 'cert.pem')) && existsSync(resolve(LOCAL_TLS_DIR, 'key.pem'))) {
    console.log('[setup-video] copying fleet TLS cert from ~/.kiki/lambda-tls...');
    await runSsh(inst.ip!, `mkdir -p ${FS_ROOT}/kiki/tls`);
    await runScp(inst.ip!, resolve(LOCAL_TLS_DIR, 'cert.pem'), `${FS_ROOT}/kiki/tls/cert.pem`);
    await runScp(inst.ip!, resolve(LOCAL_TLS_DIR, 'key.pem'), `${FS_ROOT}/kiki/tls/key.pem`);
    await runSsh(inst.ip!, `chmod 600 ${FS_ROOT}/kiki/tls/key.pem`);
  } else {
    console.log('[setup-video] no ~/.kiki/lambda-tls cert found — instances will serve plain ws:// (dev only)');
  }
  console.log('[setup-video] populating venv + weights (~20-40 min on first run; ~66 GB of downloads)...');
  // 3.5h ceiling: the venv (torch → NFS) + ~70 GB of weights are pure-IO
  // bound on NFS write throughput — the default 1h ceiling killed a real
  // populate mid-torch-install (2026-07-18).
  await runSsh(inst.ip!, POPULATE_CMD, 3.5 * 60 * 60 * 1000);
  if (SKIP_SMOKE) {
    console.log('[setup-video] --skip-smoke: not running the on-instance pipeline smoke test');
  } else {
    await runSsh(inst.ip!, SMOKE_CMD);
  }
  console.log('[setup-video] populate complete.');
} finally {
  if (KEEP) {
    console.log(`[setup-video] --keep: instance ${instanceId} left running (ssh ubuntu@${inst.ip}) — BILLING until terminated`);
  } else {
    console.log(`[setup-video] terminating setup instance ${instanceId}...`);
    await client.terminate([instanceId!]);
  }
}

console.log(`\n[setup-video] Done. Next: tsx scripts/lambda/launch-video.ts --region ${REGION} --type ${TYPE}`);

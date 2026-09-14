#!/usr/bin/env bash
# Kiki image server boot. Lives IN the repo (model-servers/image/boot.sh) and
# reaches the region filesystem inside the fleet bundle the backend serves
# (GET /v1/fleet/bundle) — see backend instancePool.userData: cloud-init runs
# kiki-bootstrap, which refreshes $FS/kiki/app from the bundle when stale and
# then execs this script. Per-instance secrets (KIKI_WS_TOKEN) arrive via
# /etc/kiki.env, never baked here. $FS is derived from this file's location:
# $FS/kiki/app/image/boot.sh.
set -euo pipefail
FS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
[ -f /etc/kiki.env ] && set -a && source /etc/kiki.env && set +a
export FLUX_USE_NVFP4=0            # H100 is Hopper (SM 9.0) — no FP4; BF16 path
export FLUX_COMPILE=1              # torch.compile: 1.2-1.25x, ~85s at boot (hidden in warmup)
export FLUX_PIPELINE=kv            # 9B-KV: per-call reference K/V caching (adherence-best)
export FLUX_MODEL=black-forest-labs/FLUX.2-klein-9b-kv
# Persist compiled-kernel caches on the shared filesystem so only the FIRST
# boot per (model, torch, GPU) pays full compilation; later boots reuse.
# NOTE: inductor cache keys are path-sensitive — the app must stay at
# $FS/kiki/app (the bootstrap swaps directories in place to keep that true).
export TORCHINDUCTOR_CACHE_DIR=$FS/kiki/inductor-cache
export TRITON_CACHE_DIR=$FS/kiki/triton-cache
mkdir -p "$TORCHINDUCTOR_CACHE_DIR" "$TRITON_CACHE_DIR"
export HF_HOME=$FS/kiki/huggingface
export HF_HUB_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export FLUX_HOST=0.0.0.0
export FLUX_PORT=8766
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# TLS: serve wss when the fleet cert is present on the filesystem (backend
# pins it via LAMBDA_TLS_CA_B64). Absent → plain ws (dev filesystems).
if [ -f $FS/kiki/tls/cert.pem ]; then
  export FLUX_SSL_CERT=$FS/kiki/tls/cert.pem
  export FLUX_SSL_KEY=$FS/kiki/tls/key.pem
fi
echo "[kiki-boot] $(date -u +%FT%TZ) sourcing venv (app $(cat $FS/kiki/app/.manifest 2>/dev/null || echo unversioned))"
source $FS/kiki/venv/bin/activate
cd $FS/kiki/app
echo "[kiki-boot] $(date -u +%FT%TZ) starting image.server"
exec python3 -u -m image.server

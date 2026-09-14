#!/usr/bin/env bash
# Kiki video (LTX-2.5) server boot. Lives IN the repo and is delivered to the
# region filesystem by the backend's fleet bundle; cloud-init's kiki-bootstrap
# refreshes $FS/kiki/app when stale and execs this. Secrets via /etc/kiki.env.
# $FS is derived from this file's location: $FS/kiki/app/video/boot.sh.
set -euo pipefail
FS=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
[ -f /etc/kiki.env ] && set -a && source /etc/kiki.env && set +a
export HF_HOME=$FS/kiki/huggingface
export HF_HUB_OFFLINE=1
export HF_HUB_DISABLE_TELEMETRY=1
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
# fp8_cast: universal FP8 (store FP8, upcast per matmul). scaled_mm needs an
# FP8 checkpoint with per-tensor scales, which Lightricks doesn't ship for
# 2.5 — see shared/config.py. Pipeline/resolution defaults live in
# shared/config.py (LTX_PIPELINE / LTX_WIDTH / LTX_HEIGHT).
export LTX_FP8_MODE=cast
if [ -f $FS/kiki/tls/cert.pem ]; then
  export LTX_SSL_CERT=$FS/kiki/tls/cert.pem
  export LTX_SSL_KEY=$FS/kiki/tls/key.pem
fi
echo "[kiki-video-boot] $(date -u +%FT%TZ) sourcing venv (app $(cat $FS/kiki/app/.manifest 2>/dev/null || echo unversioned))"
source $FS/kiki/venv/bin/activate
cd $FS/kiki/app
echo "[kiki-video-boot] $(date -u +%FT%TZ) starting video.server"
exec python3 -u -m video.server

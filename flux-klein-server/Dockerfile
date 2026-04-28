# INACTIVE — retained for rollback only.
#
# As of the 2026-04-23 cutover (see documents/decisions.md), live pods boot
# from stock runpod/pytorch and read /workspace/app/server.py + /workspace/venv/
# off a network volume populated by backend/scripts/sync-flux-app.ts. This
# Dockerfile and its publishing workflow (.github/workflows/build-flux-image.yml)
# are no longer in the provision path. They are kept around so the rollback
# procedure in the 2026-04-23 decision entry remains a single env-var flip
# instead of a re-rebuild. Slated for deletion at stage-3 cleanup.
#
# ─── (Original header retained below for rollback context) ───
# FLUX.2-klein server image (slim, weights-on-volume).
#
# Contains: torch 2.9.1 + cu128 (from base), diffusers from git, and the
# server.py entrypoint. Weights are NOT baked — the orchestrator attaches a
# pre-populated RunPod network volume at /workspace, so HF_HOME points there
# and diffusers finds the FLUX.2-klein BF16 + NVFP4 weights from volume cache.
#
# Result: ~2-3 GB compressed image (vs 28 GB when weights were baked). Pod
# pulls in ~30-60s on a fresh host instead of timing out after 10 min.
#
# Published via .github/workflows/build-flux-image.yml to ghcr.io.

FROM runpod/pytorch:1.0.3-cu1281-torch291-ubuntu2404

ENV DEBIAN_FRONTEND=noninteractive
# HF cache lives on the mounted network volume. See scripts/populate-volume.ts
# for the one-time populate flow.
ENV HF_HOME=/workspace/huggingface
ENV HF_HUB_DISABLE_TELEMETRY=1

# ─── Layer 1: OS deps ───────────────────────────────────────────────────
# git is needed to pip-install diffusers from source.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

# ─── Layer 2: Python deps ───────────────────────────────────────────────
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt \
 && rm /tmp/requirements.txt

# ─── Layer 3: server code ───────────────────────────────────────────────
WORKDIR /app
COPY server.py pipeline.py config.py /app/

# Offline mode — weights are on the network volume; refuse network lookups so
# a transient DNS issue doesn't trigger a silent re-download.
ENV HF_HUB_OFFLINE=1

ENV FLUX_HOST=0.0.0.0
ENV FLUX_PORT=8766
ENV FLUX_USE_NVFP4=1

EXPOSE 8766

# Exec form so SIGTERM reaches python directly (uvicorn handles shutdown).
CMD ["python", "-u", "/app/server.py"]
